#!/usr/bin/env bash
# Uninstall the nvidia-mig.raw sysext, and (if present) revert the custom
# nvidia.raw driver back to TrueNAS's stock. Auto-detects state:
#
#   - MIG only           → remove MIG sysext + PREINIT entry; stock driver
#                          untouched; no reboot.
#   - MIG + custom driver → revert driver to stock + remove MIG sysext +
#                          both PREINIT entries; REBOOT REQUIRED (kernel
#                          modules need to reload at the stock version).
#   - Neither            → print "nothing to do" and exit cleanly.
#
# Also (when MIG mode is currently Enabled on the GPU, in either of the
# above cases): tears down the MIG **runtime state** that lives outside
# the sysext — MIG instances on the GPU, MIG mode in GPU firmware, and
# per-app `nvidia_gpu_selection` entries pointing at MIG-* UUIDs. Without
# this teardown, the sysext is gone but apps with MIG UUID assignments
# would fail to start on next boot (no PREINIT to recreate the instances).
# Apps that pointed at MIG slices are reassigned to the full-GPU UUID on
# the same PCI slot; ones that were running before are restarted with
# the new config.
#
# This script is bundled into nvidia-mig.raw as /usr/bin/uninstall-nvidia-mig
# so users can run `sudo uninstall-nvidia-mig` without curl|bash. When
# invoked from the bundled location, `systemd-sysext unmerge` below will
# remove the merged copy of this very script mid-execution. That's safe —
# bash reads the script into memory at parse time. Do NOT add code below
# the unmerge that exec()s a binary or sources a file from the bundled
# sysext; only stable system binaries (cp, rm, systemctl, midclt, python3,
# zfs) are safe to use after unmerge.
#
# Usage:
#   sudo ./uninstall-mig-sysext.sh                     # auto-detect + undo
#   sudo ./uninstall-mig-sysext.sh --keep-persist      # don't remove files
#                                                       from /mnt/<pool>/.config/nvidia-gpu/
#   sudo ./uninstall-mig-sysext.sh --skip-backup-check # allow driver revert
#                                                       without nvidia-original.raw

set -euo pipefail

KEEP_PERSIST=false
SKIP_BACKUP_CHECK=false
for arg in "$@"; do
    case "$arg" in
        --keep-persist) KEEP_PERSIST=true ;;
        --skip-backup-check) SKIP_BACKUP_CHECK=true ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

[ "$(id -u 2>/dev/null)" = "0" ] || { echo "ERROR: must run as root" >&2; exit 1; }

SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
LIVE_NVIDIA="${SYSEXT_DIR}/nvidia.raw"

# ─────────────────────────────────────────────────────────────────────────
# State detection — what's actually installed?
# ─────────────────────────────────────────────────────────────────────────
# Driver signals: persistent backup of custom nvidia.raw, or the staged
#   driver PREINIT helper (both new `nvidia-preinit-driver.sh` and legacy
#   `nvidia-preinit-full.sh` names).
# MIG signals: persistent nvidia-mig.raw, or the /etc/extensions symlink.
PERSIST_DIR=""
ORIGINAL=""
HAS_MIG=false
HAS_DRIVER=false
for d in /mnt/*/.config/nvidia-gpu; do
    [ -d "$d" ] || continue
    PERSIST_DIR="$d"
    [ -f "$d/nvidia-original.raw" ] && ORIGINAL="$d/nvidia-original.raw"
    if [ -f "$d/nvidia.raw" ] \
       || [ -x "$d/nvidia-preinit-driver.sh" ] \
       || [ -x "$d/nvidia-preinit-full.sh" ]; then
        HAS_DRIVER=true
    fi
    [ -f "$d/nvidia-mig.raw" ] && HAS_MIG=true
    break
done
# /etc/extensions symlink is a secondary MIG signal — covers the case
# where someone already removed the persistent copy.
if [ -L /etc/extensions/nvidia-mig.raw ] || [ -e /etc/extensions/nvidia-mig.raw ]; then
    HAS_MIG=true
fi

echo "=== Uninstall plan ==="
echo "  Persist dir:             ${PERSIST_DIR:-<none found>}"
echo "  MIG sysext installed:    $HAS_MIG"
echo "  Custom driver installed: $HAS_DRIVER"
echo ""

if ! $HAS_MIG && ! $HAS_DRIVER; then
    echo "Nothing to uninstall — neither MIG sysext nor custom driver detected."
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────
# Pre-flight: driver revert needs a stock backup on hand.
# ─────────────────────────────────────────────────────────────────────────
if $HAS_DRIVER && [ -z "$ORIGINAL" ] && ! $SKIP_BACKUP_CHECK; then
    cat >&2 <<EOF
ERROR: nvidia-original.raw backup not found in /mnt/*/.config/nvidia-gpu/.
       Refusing to revert the driver without a stock copy on hand.
       Run scripts/recover-stock-nvidia.sh first (downloads + extracts
       stock nvidia.raw from the official TrueNAS .update). Or pass
       --skip-backup-check if you accept the risk.
EOF
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────
# Tear down MIG runtime state if it's currently active. Removing the
# sysext alone is NOT enough: MIG mode is GPU firmware state and MIG
# instances are runtime state on the GPU, both independent of whether
# the sysext is merged. Apps with MIG-* UUIDs in their nvidia_gpu_selection
# config also need to be reverted to the full GPU UUID — otherwise on
# next boot (without our PREINIT to recreate MIG instances) they would
# try to claim a stale UUID and fail to start.
#
# Flow:
#   1. Identify apps whose nvidia_gpu_selection.<slot>.uuid starts with
#      `MIG-` (so we only touch apps the user actually pointed at MIG).
#   2. Stop each affected app and save its original state.
#   3. Wait for the GPU to drain.
#   4. Destroy MIG instances and disable MIG mode (cleans the GPU).
#   5. Reassign each affected app's GPU config to the full-GPU UUID on
#      the same PCI slot.
#   6. Restart any app that was originally running.
#
# Skipped silently if nvidia-smi isn't available (no NVIDIA driver
# present), MIG mode is already disabled, or midclt isn't available
# (not a TrueNAS host).
# ─────────────────────────────────────────────────────────────────────────

# Live-elapsed wrapper for blocking midclt -j calls. Matches the helper
# pattern used in configure-mig.sh so app-stop/update/start show a live
# counter instead of an opaque pause.
ELAPSED=0
CAPTURED_OUT=""
run_capture_with_elapsed() {
    local label="$1"; shift
    local start outfile ticker_pid rc
    start=$(date +%s)
    outfile=$(mktemp)
    (
        while sleep 1; do
            printf "\r%s... %ds" "$label" "$(($(date +%s) - start))"
        done
    ) &
    ticker_pid=$!
    "$@" >"$outfile" 2>&1
    rc=$?
    kill "$ticker_pid" 2>/dev/null
    wait "$ticker_pid" 2>/dev/null
    ELAPSED=$(($(date +%s) - start))
    CAPTURED_OUT=$(cat "$outfile")
    rm -f "$outfile"
    printf "\r%80s\r" ""
    return $rc
}

MIG_TEARDOWN_DONE=false
if [ -x /usr/bin/nvidia-smi ] && command -v midclt >/dev/null 2>&1; then
    MIG_MODE_NOW=$(/usr/bin/nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null \
        | head -1 | tr -d '[:space:]' || true)
    if [ "$MIG_MODE_NOW" = "Enabled" ]; then
        echo ""
        echo "=== MIG runtime teardown (MIG mode currently Enabled) ==="

        # Get full-GPU UUID + PCI slot.
        FULL_GPU_UUID=$(/usr/bin/nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null \
            | head -1 | tr -d '[:space:]' || true)
        PCI_SLOT=$(midclt call app.gpu_choices 2>/dev/null \
            | python3 -c "
import sys, json
try:
    choices = json.load(sys.stdin)
    for slot, info in choices.items():
        if isinstance(info, dict):
            vendor = (info.get('vendor') or '').upper()
            desc = (info.get('description') or '').upper()
            if 'NVIDIA' in vendor or 'NVIDIA' in desc:
                print(slot, end=''); break
        elif isinstance(info, str) and 'NVIDIA' in info.upper():
            print(slot, end=''); break
except Exception:
    pass" 2>/dev/null)

        if [ -z "$FULL_GPU_UUID" ] || [ -z "$PCI_SLOT" ]; then
            echo "  WARN: could not determine full-GPU UUID (${FULL_GPU_UUID:-?}) or PCI slot (${PCI_SLOT:-?})"
            echo "        — skipping app reassignment; will still destroy MIG instances + disable mode"
        else
            echo "  Full-GPU UUID: $FULL_GPU_UUID"
            echo "  PCI slot:      $PCI_SLOT"
        fi

        # Find apps with MIG-* UUIDs in nvidia_gpu_selection. One line per
        # match: <name>|<state>|<slot>|<mig_uuid>
        MIG_APPS=$(midclt call app.query 2>/dev/null | python3 -c "
import sys, json
try:
    apps = json.load(sys.stdin)
    for a in apps:
        name = a.get('name', '')
        state = a.get('state', '')
        config = a.get('config', {}) or {}
        resources = config.get('resources', {}) or {}
        gpus = resources.get('gpus', {}) or {}
        sel = gpus.get('nvidia_gpu_selection', {}) or {}
        for slot, cfg in sel.items():
            if isinstance(cfg, dict):
                uuid = cfg.get('uuid', '') or ''
                if uuid.startswith('MIG-'):
                    print(f'{name}|{state}|{slot}|{uuid}')
                    break
except Exception:
    pass" 2>/dev/null)

        if [ -n "$MIG_APPS" ]; then
            echo ""
            echo "Apps currently pointing at MIG slices:"
            printf '%s\n' "$MIG_APPS" | while IFS='|' read -r name state slot mig_uuid; do
                echo "  $name  ($state)  --  $mig_uuid"
            done

            # Stop running MIG-using apps so we can free the GPU.
            echo ""
            while IFS='|' read -r name state _slot _mig_uuid; do
                [ -z "$name" ] && continue
                if [ "$state" = "RUNNING" ]; then
                    if run_capture_with_elapsed "  Stopping $name" \
                        midclt call -j app.stop "$name"; then
                        echo "  Stopping $name... OK (${ELAPSED}s)"
                    else
                        echo "  Stopping $name... WARN (${ELAPSED}s): $CAPTURED_OUT"
                    fi
                else
                    echo "  $name was already $state — not stopping"
                fi
            done <<<"$MIG_APPS"
        else
            echo "  No apps reference a MIG-* UUID in their GPU selection"
        fi

        # Drain GPU compute processes before destroying MIG instances.
        echo ""
        printf "  Waiting for GPU to be released... 0s/120s"
        for attempt in $(seq 1 24); do
            N=$(/usr/bin/nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l || echo 0)
            if [ "${N:-0}" -eq 0 ]; then
                printf "\r  GPU released                                            \n"
                break
            fi
            printf "\r  Waiting for %d GPU process(es)... %ds/120s" "$N" "$((attempt * 5))"
            sleep 5
        done
        [ "${attempt:-0}" -eq 24 ] && echo ""

        # Destroy compute + GPU instances, then disable MIG mode. All three
        # are best-effort: "No GPU instances found" etc. when already-clean
        # is not an error.
        echo "  Destroying MIG compute instances..."
        /usr/bin/nvidia-smi mig -dci 2>&1 | sed 's/^/    /' || true
        echo "  Destroying MIG GPU instances..."
        /usr/bin/nvidia-smi mig -dgi 2>&1 | sed 's/^/    /' || true
        echo "  Disabling MIG mode..."
        /usr/bin/nvidia-smi -mig 0 2>&1 | sed 's/^/    /' || true

        # Reassign affected apps' GPU config to the full-GPU UUID, then
        # restart anything that was running. Skip if we couldn't resolve
        # the UUID/slot above — but still try to restart so we don't leave
        # apps stopped that we stopped.
        if [ -n "$MIG_APPS" ]; then
            echo ""
            echo "Reassigning affected apps to the full GPU..."
            while IFS='|' read -r name state slot _mig_uuid; do
                [ -z "$name" ] && continue
                if [ -n "$FULL_GPU_UUID" ] && [ -n "$slot" ]; then
                    payload="{\"values\":{\"resources\":{\"gpus\":{\"use_all_gpus\":false,\"nvidia_gpu_selection\":{\"${slot}\":{\"use_gpu\":true,\"uuid\":\"${FULL_GPU_UUID}\"}}}}}}"
                    if run_capture_with_elapsed "  Updating $name" \
                        midclt call -j app.update "$name" "$payload"; then
                        echo "  Updating $name... OK (${ELAPSED}s)"
                    else
                        echo "  Updating $name... FAILED (${ELAPSED}s): $CAPTURED_OUT"
                    fi
                fi
                if [ "$state" = "RUNNING" ]; then
                    if run_capture_with_elapsed "  Starting $name" \
                        midclt call -j app.start "$name"; then
                        echo "  Starting $name... OK (${ELAPSED}s)"
                    else
                        echo "  Starting $name... WARN (${ELAPSED}s): $CAPTURED_OUT"
                    fi
                fi
            done <<<"$MIG_APPS"
        fi

        MIG_TEARDOWN_DONE=true
        echo "=== MIG runtime teardown complete ==="
        echo ""
    fi
fi

# ─────────────────────────────────────────────────────────────────────────
# Stop app services + wait for GPU drain — only when the driver is being
# reverted (live-swapping nvidia.raw must happen with no GPU consumers).
# The MIG teardown above already drained the GPU once and reassigned
# apps; the docker.update below is still needed for the driver swap
# because we need to take down the entire docker subsystem (not just
# individual apps) so the kernel module isn't held.
# ─────────────────────────────────────────────────────────────────────────
if $HAS_DRIVER; then
    echo "Stopping app services..."
    midclt call docker.update '{"nvidia": false}' >/dev/null \
        || echo "WARN: app services API call (docker.update) failed — continuing"
    if [ -x /usr/bin/nvidia-smi ]; then
        printf "  Waiting for GPU to be released... 0s/120s"
        for attempt in $(seq 1 24); do
            N=$(/usr/bin/nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l || echo 0)
            if [ "${N:-0}" -eq 0 ]; then
                printf "\r  GPU released                                            \n"
                break
            fi
            printf "\r  Waiting for %d GPU process(es)... %ds/120s" "$N" "$((attempt * 5))"
            sleep 5
        done
        [ "${attempt:-0}" -eq 24 ] && echo ""
    fi
fi

# ─────────────────────────────────────────────────────────────────────────
# Single unmerge → mutations → single re-merge. Cheaper than separate
# cycles for the driver and MIG paths and avoids leaving the system in
# a half-merged state between them.
# ─────────────────────────────────────────────────────────────────────────
echo "Unmerging sysext..."
systemd-sysext unmerge

# --- Revert driver to stock (if installed) ---
if $HAS_DRIVER; then
    if [ -n "$ORIGINAL" ]; then
        echo "Restoring stock nvidia.raw from $ORIGINAL"
        USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null)
        zfs set readonly=off "$USR_DATASET"
        cp "$ORIGINAL" "$LIVE_NVIDIA"
        [ -f "${LIVE_NVIDIA}.bak" ] && rm -f "${LIVE_NVIDIA}.bak" 2>/dev/null || true
        zfs set readonly=on "$USR_DATASET"
        mkdir -p /etc/extensions
        ln -sf "$LIVE_NVIDIA" /etc/extensions/nvidia.raw
    else
        echo "WARN: no nvidia-original.raw backup; leaving live nvidia.raw in place"
        echo "      (run recover-stock-nvidia.sh later to fetch one)"
    fi
fi

# --- Remove MIG symlink (if present) ---
if $HAS_MIG; then
    if [ -L /etc/extensions/nvidia-mig.raw ] || [ -e /etc/extensions/nvidia-mig.raw ]; then
        rm -f /etc/extensions/nvidia-mig.raw
        echo "Removed /etc/extensions/nvidia-mig.raw"
    fi
fi

echo "Re-merging sysext..."
systemd-sysext merge
systemctl daemon-reload

# ─────────────────────────────────────────────────────────────────────────
# Deregister PREINIT entries — matched independently so we only touch what
# we actually installed.
# ─────────────────────────────────────────────────────────────────────────
if $HAS_DRIVER; then
    DRIVER_PREINIT_ID=$(midclt call initshutdownscript.query 2>/dev/null \
        | python3 -c "
import sys, json
try:
    for s in json.load(sys.stdin):
        cmd = (s.get('command') or '') + ' ' + (s.get('script') or '')
        if 'nvidia-preinit-driver' in cmd or 'nvidia-preinit-full' in cmd:
            print(s['id'], end=''); break
except Exception:
    pass
" 2>/dev/null)
    if [ -n "$DRIVER_PREINIT_ID" ]; then
        midclt call initshutdownscript.delete "$DRIVER_PREINIT_ID" >/dev/null 2>&1 \
            && echo "Deregistered driver PREINIT entry (id $DRIVER_PREINIT_ID)" \
            || echo "WARN: deregister driver PREINIT failed"
    else
        echo "No driver PREINIT entry found"
    fi
fi

if $HAS_MIG; then
    # Match `nvidia-mig-setup` but explicitly exclude entries that also
    # contain 'preinit' (the driver PREINIT command happens to reference
    # the MIG service name indirectly in some legacy installs).
    MIG_PREINIT_ID=$(midclt call initshutdownscript.query 2>/dev/null \
        | python3 -c "
import sys, json
try:
    for s in json.load(sys.stdin):
        cmd = (s.get('command') or '') + ' ' + (s.get('script') or '')
        if 'nvidia-mig-setup' in cmd and 'preinit' not in cmd:
            print(s['id'], end=''); break
except Exception:
    pass
" 2>/dev/null)
    if [ -n "$MIG_PREINIT_ID" ]; then
        midclt call initshutdownscript.delete "$MIG_PREINIT_ID" >/dev/null 2>&1 \
            && echo "Deregistered MIG PREINIT entry (id $MIG_PREINIT_ID)" \
            || echo "WARN: deregister MIG PREINIT failed"
    else
        echo "No MIG PREINIT entry found"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────
# Cleanup persistent storage. nvidia-original.raw is always kept — it's
# expensive to re-fetch and the user may want to re-install later.
# ─────────────────────────────────────────────────────────────────────────
if ! $KEEP_PERSIST && [ -n "$PERSIST_DIR" ]; then
    if $HAS_DRIVER; then
        rm -f "$PERSIST_DIR/nvidia.raw" \
              "$PERSIST_DIR/nvidia-preinit-driver.sh" \
              "$PERSIST_DIR/nvidia-preinit-full.sh"
        echo "Removed custom nvidia.raw and driver PREINIT helper from $PERSIST_DIR"
    fi
    if $HAS_MIG; then
        rm -f "$PERSIST_DIR/nvidia-mig.raw" \
              "$PERSIST_DIR/mig.conf"
        echo "Removed $PERSIST_DIR/nvidia-mig.raw + mig.conf"
    fi
    echo "  (nvidia-original.raw kept — pass --keep-persist to retain everything)"
fi

# ─────────────────────────────────────────────────────────────────────────
# Verification + mode-appropriate finishing banner.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Verification ==="
systemd-sysext status || true

# NOTE: we intentionally do NOT attempt to re-enable docker.config.nvidia
# here. TrueNAS resets it during boot and silently rejects re-enable for
# the first ~5–10 min while the docker subsystem initializes. So any
# pre-reboot set is futile in the driver-revert case (gets reset by
# the upcoming reboot); we surface the post-reboot instructions
# explicitly instead. See scripts/install-mig-sysext.sh for the long
# comment explaining the boot-window behavior.

if $HAS_DRIVER; then
    cat <<EOF

=== Uninstall complete — REBOOT REQUIRED ===

Kernel modules currently loaded are still the custom driver's. After
reboot, modules will load fresh from the stock sysext and match the
userspace libs (no more NVML mismatch).

Run: sudo reboot

>>> AFTER REBOOT — give it 5–10 minutes before flipping the Apps toggle <<<

TrueNAS resets the Apps' NVIDIA toggle to OFF during boot and silently
rejects re-enable attempts for the first ~5–10 minutes while the docker
subsystem initializes. App services were turned off during uninstall so
this state continues until you re-enable.

Once the box has been up for ~10 minutes, re-enable the toggle:

  sudo midclt call docker.update '{"nvidia": true}'

  -- or --

  Toggle the "Use NVIDIA GPU" switch on under TrueNAS UI →
  Apps → Settings → 'Use NVIDIA GPU' → Save

Verify it stuck (should print "nvidia = True"):

  sudo midclt call docker.config | python3 -c "import sys,json; print('nvidia =', json.load(sys.stdin).get('nvidia'))"
EOF
else
    cat <<EOF

=== Uninstall complete ===

No reboot needed. The stock NVIDIA driver was never touched, so the
running modules already match the userspace libs.
EOF
fi

if $MIG_TEARDOWN_DONE; then
    cat <<EOF

MIG runtime teardown summary:
  - MIG mode disabled on the GPU (firmware state)
  - MIG instances destroyed
  - Apps that pointed at MIG-* UUIDs were reassigned to the full GPU
    on the same PCI slot; running ones were restarted with the new config
  - mig.conf removed from the persist dir (unless --keep-persist was passed)

EOF
fi

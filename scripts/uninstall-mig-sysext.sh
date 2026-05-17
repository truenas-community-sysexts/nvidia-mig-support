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

MIG_TEARDOWN_ATTEMPTED=false
MIG_TEARDOWN_OK=false
if [ -x /usr/bin/nvidia-smi ] && command -v midclt >/dev/null 2>&1; then
    MIG_MODE_NOW=$(/usr/bin/nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null \
        | head -1 | tr -d '[:space:]' || true)
    if [ "$MIG_MODE_NOW" = "Enabled" ]; then
        MIG_TEARDOWN_ATTEMPTED=true
        echo ""
        echo "=== MIG runtime teardown (MIG mode currently Enabled) ==="

        # Schema-independent approach: we can't reliably identify which
        # apps hold the GPU by inspecting `config.resources.gpus.*`
        # (empirically that path is empty even for apps whose container
        # is actively using a MIG slice — the user's GPU selection may
        # live in a different schema field, or be applied via runtime-
        # only mechanisms). Instead, use TrueNAS's docker.update toggle
        # as a sledgehammer: setting `nvidia: false` causes the docker
        # service to stop every container using the nvidia runtime,
        # regardless of how each app is configured. Then drain, destroy,
        # disable, re-enable, and restart whatever was running before.
        #
        # We record state BEFORE we touch anything so the restart pass
        # at the end re-establishes the prior set of running apps.

        # Snapshot the names of every app currently RUNNING (no schema
        # dependency on GPU fields). `|| true` defends against the same
        # pipefail+set -e abort pattern documented in the reassign loop.
        ORIG_RUNNING=$(midclt call app.query 2>/dev/null | python3 -c "
import sys, json
try:
    for a in json.load(sys.stdin):
        if a.get('state') == 'RUNNING':
            print(a.get('name', ''))
except Exception:
    pass" 2>/dev/null || true)
        if [ -n "$ORIG_RUNNING" ]; then
            echo "  Apps currently RUNNING (will be restarted after teardown):"
            while IFS= read -r app; do
                [ -n "$app" ] && echo "    $app"
            done <<<"$ORIG_RUNNING"
        else
            echo "  No apps are currently running"
        fi

        # Sledgehammer-stop: nvidia=false stops every container that uses
        # the nvidia runtime, no per-app config inspection needed. Use `-j`
        # to block until docker actually applies the change (otherwise the
        # GPU-drain check below races the still-in-flight reconfig).
        echo ""
        echo "  Disabling Apps' NVIDIA toggle to drain all GPU consumers..."
        midclt call -j docker.update '{"nvidia": false}' >/dev/null 2>&1 \
            || echo "  WARN: docker.update '{\"nvidia\": false}' returned an error — continuing"

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

        # Destroy compute + GPU instances, then disable MIG mode.
        echo "  Destroying MIG compute instances..."
        /usr/bin/nvidia-smi mig -dci 2>&1 | sed 's/^/    /' || true
        echo "  Destroying MIG GPU instances..."
        /usr/bin/nvidia-smi mig -dgi 2>&1 | sed 's/^/    /' || true
        echo "  Disabling MIG mode..."
        /usr/bin/nvidia-smi -mig 0 2>&1 | sed 's/^/    /' || true

        # Verify the destroy + disable actually took. Most common failure
        # is "In use by another client" — leftover processes holding a
        # MIG slice we didn't drain. Be honest about it.
        sleep 1
        MIG_MODE_AFTER=$(/usr/bin/nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null \
            | head -1 | tr -d '[:space:]' || true)
        if [ "$MIG_MODE_AFTER" = "Disabled" ]; then
            MIG_TEARDOWN_OK=true
            echo "  Verified: MIG mode now Disabled"
        else
            echo "  WARN: MIG mode is still '${MIG_MODE_AFTER:-unknown}' after teardown attempt."
            echo "        Something is still holding a MIG slice. Inspect 'nvidia-smi'"
            echo "        Processes section; identify the PID's container with"
            echo "        'sudo midclt call app.query | grep -B1 <pid>' or 'docker ps'."
            echo "        Then: 'sudo midclt call -j app.stop <name>' and re-run uninstall."
        fi

        # Re-enable docker.nvidia so apps can come back. Two issues to handle:
        #
        # 1. The previous `docker.update '{"nvidia": false}'` is a job that
        #    takes time to apply (docker has to stop the affected containers
        #    and reconfigure the runtime). A fire-and-forget re-enable
        #    immediately after the disable gets rejected because docker is
        #    still mid-transition. Use `-j` to block on each docker.update
        #    job until it finishes.
        #
        # 2. If uptime is < 10 min, middleware may silently reject re-enable
        #    (boot-window — see install-mig-sysext.sh's long comment). In
        #    practice the typical uninstall scenario is well past 10 min,
        #    but the retry loop below makes both cases self-healing for
        #    transient rejects.
        echo ""
        echo "  Re-enabling Apps' NVIDIA toggle..."
        NVIDIA_TOGGLE_AFTER=""
        for retry in 1 2 3 4 5; do
            midclt call -j docker.update '{"nvidia": true}' >/dev/null 2>&1 || true
            NVIDIA_TOGGLE_AFTER=$(midclt call docker.config 2>/dev/null \
                | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('true' if d.get('nvidia') else 'false')
except Exception:
    pass" 2>/dev/null || true)
            if [ "$NVIDIA_TOGGLE_AFTER" = "true" ]; then
                break
            fi
            printf "    re-enable attempt %d/5 returned '%s', retrying in 3s...\n" "$retry" "${NVIDIA_TOGGLE_AFTER:-unknown}"
            sleep 3
        done
        if [ "$NVIDIA_TOGGLE_AFTER" = "true" ]; then
            echo "  Verified: docker.config.nvidia=true"
        else
            echo "  WARN: docker.config.nvidia is still '${NVIDIA_TOGGLE_AFTER:-unknown}' after 5 retries."
            echo "        Probably the boot-window (re-enable rejected for ~10 min after boot)."
            echo "        Re-run: 'sudo midclt call -j docker.update {\"nvidia\": true}' once uptime > 10 min."
        fi

        # Reassign any app whose persisted nvidia_gpu_selection.<slot>.uuid
        # still points at a MIG-* UUID. After this teardown those UUIDs no
        # longer exist (we just destroyed the instances), so leaving the
        # config alone means app.start fails with `[EFAULT] Failed 'up'
        # action`. Rewrite to the full-GPU UUID on the same PCI slot so the
        # app comes back up cleanly with whole-GPU access.
        #
        # Walk EVERY app (not just ORIG_RUNNING) because a stale MIG-* UUID
        # in config is bad regardless of whether the app was running at
        # snapshot time — STOPPED/CRASHED/DEPLOYING apps will fail next
        # boot otherwise.
        #
        # Schema path was verified empirically (see CHANGELOG):
        #   midclt call app.config <name>
        #     → resources.gpus.nvidia_gpu_selection.<slot>.{use_gpu, uuid}
        # `app.query` doesn't return this data — must use `app.config <name>`.
        #
        # Robustness note: each `midclt call app.config <name>` is wrapped
        # in `|| true` because `set -e` + `pipefail` would otherwise abort
        # the entire uninstall if a single app's config read fails (e.g.
        # an app mid-deploy returns an error). A previous version of this
        # script silently aborted here mid-loop; do not regress.
        FULL_GPU_UUID_FOR_REASSIGN=$(/usr/bin/nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null \
            | head -1 | tr -d '[:space:]' || true)
        ALL_APPS=$(midclt call app.query 2>/dev/null | python3 -c "
import sys, json
try:
    for a in json.load(sys.stdin):
        n = a.get('name', '')
        if n: print(n)
except Exception:
    pass" 2>/dev/null || true)
        if [ -n "$ALL_APPS" ] && [ -n "$FULL_GPU_UUID_FOR_REASSIGN" ]; then
            echo ""
            echo "  Reassigning apps that still point at MIG-* UUIDs..."
            REASSIGN_COUNT=0
            while IFS= read -r app; do
                [ -z "$app" ] && continue
                # Returns "slot|uuid" on the first MIG-* UUID found, empty otherwise.
                config_json=$(midclt call app.config "$app" 2>/dev/null || true)
                mig_info=$(printf '%s' "$config_json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    gpus = (d.get('resources', {}) or {}).get('gpus', {}) or {}
    sel = gpus.get('nvidia_gpu_selection', {}) or {}
    for slot, cfg in sel.items():
        if isinstance(cfg, dict):
            uuid = cfg.get('uuid', '') or ''
            if uuid.startswith('MIG-'):
                print(f'{slot}|{uuid}')
                break
except Exception:
    pass" 2>/dev/null || true)
                if [ -n "$mig_info" ]; then
                    REASSIGN_COUNT=$((REASSIGN_COUNT + 1))
                    slot="${mig_info%|*}"
                    old_uuid="${mig_info#*|}"
                    payload="{\"values\":{\"resources\":{\"gpus\":{\"use_all_gpus\":false,\"nvidia_gpu_selection\":{\"${slot}\":{\"use_gpu\":true,\"uuid\":\"${FULL_GPU_UUID_FOR_REASSIGN}\"}}}}}}"
                    if run_capture_with_elapsed "    Reassigning $app (was ${old_uuid:0:20}...)" \
                        midclt call -j app.update "$app" "$payload"; then
                        echo "    Reassigning $app... OK (${ELAPSED}s, now full GPU)"
                    else
                        echo "    Reassigning $app... WARN (${ELAPSED}s): $CAPTURED_OUT"
                    fi
                fi
            done <<<"$ALL_APPS"
            if [ "$REASSIGN_COUNT" -eq 0 ]; then
                echo "    (no apps held MIG-* UUIDs — nothing to reassign)"
            fi
        elif [ -z "$FULL_GPU_UUID_FOR_REASSIGN" ]; then
            echo "  WARN: could not read full-GPU UUID from nvidia-smi — skipping app reassign"
            echo "        Apps with persisted MIG-* UUIDs may fail to start; check 'sudo midclt call app.config <name>'"
        fi

        # Restart anything that WAS running before we touched it. Some apps
        # may have come back automatically when nvidia=true was set; we
        # check current state first and only start if still not RUNNING,
        # which makes this idempotent.
        #
        # Same `|| true` hardening as the reassign loop above: a single
        # midclt failure here must not abort the script before sysext
        # unmerge, PREINIT deregister, and persist cleanup run.
        if [ -n "$ORIG_RUNNING" ]; then
            echo ""
            echo "  Restarting apps that were RUNNING pre-teardown..."
            while IFS= read -r app; do
                [ -z "$app" ] && continue
                cur_state=$(midclt call app.get_instance "$app" 2>/dev/null \
                    | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('state',''))
except: print('')" 2>/dev/null || true)
                if [ "$cur_state" = "RUNNING" ]; then
                    echo "    $app: already RUNNING — no-op"
                else
                    if run_capture_with_elapsed "    Starting $app" \
                        midclt call -j app.start "$app"; then
                        echo "    Starting $app... OK (${ELAPSED}s)"
                    else
                        echo "    Starting $app... WARN (${ELAPSED}s): $CAPTURED_OUT"
                    fi
                fi
            done <<<"$ORIG_RUNNING"
        fi

        echo "=== MIG runtime teardown finished ==="
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

if $MIG_TEARDOWN_ATTEMPTED; then
    if $MIG_TEARDOWN_OK; then
        cat <<EOF

MIG runtime teardown summary:
  - MIG mode disabled on the GPU (firmware state) ✓ verified
  - MIG instances destroyed
  - Apps' NVIDIA toggle stopped all GPU consumers; toggle re-enabled
  - Apps that pointed at MIG-* UUIDs were reassigned to the full GPU
    UUID on the same PCI slot
  - Apps that were RUNNING pre-teardown were restarted
  - mig.conf removed from the persist dir (unless --keep-persist was passed)

EOF
    else
        cat <<EOF

WARNING: MIG runtime teardown did NOT fully succeed.

  - MIG mode is still Enabled on the GPU (a process must still be
    holding a MIG slice).
  - Inspect: nvidia-smi   (Processes block shows the surviving PIDs)
  - Identify the container: docker ps | grep <pid>  (or use ps -ef)
  - Stop the holding app: sudo midclt call -j app.stop <name>
  - Then manually finish the teardown:
      sudo nvidia-smi mig -dci
      sudo nvidia-smi mig -dgi
      sudo nvidia-smi -mig 0
  - Verify: sudo nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader
            (expect: Disabled)
  - Re-enable apps' NVIDIA toggle (if uptime > 10 min):
      sudo midclt call docker.update '{"nvidia": true}'

EOF
    fi
fi

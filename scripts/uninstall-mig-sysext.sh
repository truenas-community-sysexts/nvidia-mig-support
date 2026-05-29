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
#
# MIG-holding apps are identified by walking app.config for every app,
# stopped explicitly via app.stop, and reassigned to the full-GPU UUID
# on the same PCI slot; ones that were running before are restarted
# with the new config.
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

# Track mutations so the trap can undo them if we die mid-revert (failure
# under set -e, or a SIGTERM/SIGINT). Without this, an abort between
# readonly=off and readonly=on leaves /usr writable until reboot, and an abort
# after the docker toggle (disabled below to evict GPU containers) leaves
# nvidia stuck off, both until manually fixed.
USR_WAS_WRITABLE=0
USR_DATASET=""
DOCKER_NVIDIA_DISABLED=0

restore_state() {
    if [ "$USR_WAS_WRITABLE" = "1" ] && [ -n "$USR_DATASET" ]; then
        zfs set readonly=on "$USR_DATASET" 2>/dev/null || true
        USR_WAS_WRITABLE=0
    fi
    if [ "$DOCKER_NVIDIA_DISABLED" = "1" ]; then
        midclt call docker.update '{"nvidia": true}' >/dev/null 2>&1 || true
        DOCKER_NVIDIA_DISABLED=0
    fi
}
trap restore_state EXIT INT TERM

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

        # Approach: identify exactly which apps are holding MIG slices via
        # their persisted `nvidia_gpu_selection.<slot>.uuid` config, stop
        # them explicitly with `app.stop`, then destroy the instances.
        #
        # Previous versions toggled `docker.update '{"nvidia": false}'` as
        # a "sledgehammer" stop. That doesn't actually stop running
        # containers — it only reconfigures the docker runtime for future
        # starts, so containers with open CUDA/NVENC contexts keep holding
        # MIG slices. `nvidia-smi --query-compute-apps` then reports 0
        # (compute idle ≠ no clients), the drain check passes, and
        # `nvidia-smi mig -dci` fails with "In use by another client"
        # because NVENC/NVDEC clients are still attached. Frigate's ffmpeg
        # is the canonical case. See CHANGELOG entry for the test that
        # exposed this.

        # Cache the full-GPU UUID up front — we'll need it for reassign
        # after the instances are destroyed (at which point nvidia-smi
        # output changes shape).
        FULL_GPU_UUID_FOR_REASSIGN=$(/usr/bin/nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null \
            | head -1 | tr -d '[:space:]' || true)

        # Step 1: pre-scan. Walk every app via app.query, fetch each one's
        # app.config, and remember the (name, slot, old MIG UUID, state)
        # for every app whose `nvidia_gpu_selection.<slot>.uuid` starts
        # with `MIG-`. Store as `name|slot|old_uuid|state` lines in
        # MIG_APPS_INFO so we can drive all later phases off that cache
        # — no second walk needed.
        #
        # `|| true` on every middleware command substitution: `set -e` +
        # `pipefail` would otherwise abort the script if any one app's
        # config read fails (mid-deploy, crashed, transient middleware
        # error). PR #42 hardened these; do not regress.
        echo ""
        echo "  Scanning apps for MIG-* UUID assignments..."
        ALL_APPS=$(midclt call app.query 2>/dev/null | python3 -c "
import sys, json
try:
    for a in json.load(sys.stdin):
        n = a.get('name', '')
        s = a.get('state', '')
        if n: print(f'{n}|{s}')
except Exception:
    pass" 2>/dev/null || true)

        MIG_APPS_INFO=""
        if [ -n "$ALL_APPS" ]; then
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                app="${line%|*}"
                state="${line#*|}"
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
                    slot="${mig_info%|*}"
                    old_uuid="${mig_info#*|}"
                    MIG_APPS_INFO+="$app|$slot|$old_uuid|$state"$'\n'
                fi
            done <<<"$ALL_APPS"
        fi

        if [ -z "$MIG_APPS_INFO" ]; then
            echo "  No apps hold MIG-* UUIDs — nothing to stop or reassign"
        else
            echo "  Apps holding MIG-* UUIDs (will be stopped, reassigned, restarted if RUNNING):"
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                IFS='|' read -r mapp _ _ mstate <<<"$line"
                echo "    $mapp (state=$mstate)"
            done <<<"$MIG_APPS_INFO"

            # Step 2: explicitly stop each MIG-holding app. `app.stop -j`
            # waits for the container to actually tear down, which is the
            # only reliable way to get NVENC/NVDEC clients off the GPU.
            # Skip apps already in a non-RUNNING state (no container to
            # stop) — they still get reassigned in Step 5.
            echo ""
            echo "  Stopping MIG-holding apps..."
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                IFS='|' read -r app _ _ state <<<"$line"
                if [ "$state" != "RUNNING" ]; then
                    echo "    $app: state=$state — no container to stop"
                    continue
                fi
                if run_capture_with_elapsed "    Stopping $app" \
                    midclt call -j app.stop "$app"; then
                    echo "    Stopping $app... OK (${ELAPSED}s)"
                else
                    echo "    Stopping $app... WARN (${ELAPSED}s): $CAPTURED_OUT"
                fi
            done <<<"$MIG_APPS_INFO"
        fi

        # Step 3: drain GPU. After app.stop -j the containers are gone,
        # but the driver can take a moment to release the CUDA / NVENC
        # client contexts. Short window (15s) — `app.stop -j` already
        # blocked on the heavy lifting.
        echo ""
        printf "  Waiting for GPU clients to release... 0s/15s"
        for attempt in $(seq 1 5); do
            N=$(/usr/bin/nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l || echo 0)
            if [ "${N:-0}" -eq 0 ]; then
                printf "\r  GPU compute clients released                              \n"
                break
            fi
            printf "\r  Waiting for %d GPU process(es)... %ds/15s" "$N" "$((attempt * 3))"
            sleep 3
        done

        # Step 4: destroy compute instances + GPU instances, then disable
        # MIG mode. Retry the full sequence on "In use by another client"
        # — sometimes the driver doesn't release a CUDA context for a few
        # seconds after the container PID is reaped. 3 × 3s should cover
        # this; if it still fails the holder is something outside the apps
        # the script can manage (manual nvidia-smi, bare CUDA process, etc).
        echo ""
        for retry in 1 2 3; do
            echo "  Destroying MIG instances + disabling mode (attempt $retry/3)..."
            /usr/bin/nvidia-smi mig -dci 2>&1 | sed 's/^/    /' || true
            /usr/bin/nvidia-smi mig -dgi 2>&1 | sed 's/^/    /' || true
            /usr/bin/nvidia-smi -mig 0 2>&1 | sed 's/^/    /' || true
            sleep 1
            MIG_MODE_AFTER=$(/usr/bin/nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null \
                | head -1 | tr -d '[:space:]' || true)
            if [ "$MIG_MODE_AFTER" = "Disabled" ]; then
                MIG_TEARDOWN_OK=true
                break
            fi
            if [ "$retry" -lt 3 ]; then
                echo "    MIG mode still '${MIG_MODE_AFTER:-unknown}', retrying in 3s..."
                sleep 3
            fi
        done

        if $MIG_TEARDOWN_OK; then
            echo "  Verified: MIG mode now Disabled"
        else
            echo "  WARN: MIG mode is still '${MIG_MODE_AFTER:-unknown}' after 3 retries."
            echo "        A non-app process must be holding a MIG slice."
            echo "        Inspect: nvidia-smi (Processes block) and 'docker ps'."
        fi

        # Step 5: reassign each MIG-holding app's config to the full-GPU
        # UUID. The slot + old_uuid we cached in Step 1 is still valid in
        # the persisted config (we never modified it). After this rewrite
        # the app's nvidia_gpu_selection points at the full GPU, so it'll
        # come back up cleanly on next start with whole-GPU access.
        if [ -n "$MIG_APPS_INFO" ] && [ -n "$FULL_GPU_UUID_FOR_REASSIGN" ]; then
            echo ""
            echo "  Reassigning apps to full-GPU UUID..."
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                IFS='|' read -r app slot old_uuid _ <<<"$line"
                payload="{\"values\":{\"resources\":{\"gpus\":{\"use_all_gpus\":false,\"nvidia_gpu_selection\":{\"${slot}\":{\"use_gpu\":true,\"uuid\":\"${FULL_GPU_UUID_FOR_REASSIGN}\"}}}}}}"
                if run_capture_with_elapsed "    Reassigning $app (was ${old_uuid:0:20}...)" \
                    midclt call -j app.update "$app" "$payload"; then
                    echo "    Reassigning $app... OK (${ELAPSED}s, now full GPU)"
                else
                    echo "    Reassigning $app... WARN (${ELAPSED}s): $CAPTURED_OUT"
                fi
            done <<<"$MIG_APPS_INFO"
        elif [ -n "$MIG_APPS_INFO" ] && [ -z "$FULL_GPU_UUID_FOR_REASSIGN" ]; then
            echo "  WARN: could not read full-GPU UUID from nvidia-smi — skipping app reassign"
            echo "        Apps with persisted MIG-* UUIDs may fail to start; rerun once"
            echo "        nvidia-smi is responsive, or manually edit each app."
        fi

        # Step 6: restart apps that were RUNNING when we started. We
        # only restart apps that were RUNNING pre-stop — apps in any
        # other state stay in their pre-uninstall state.
        if [ -n "$MIG_APPS_INFO" ]; then
            need_restart=false
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                IFS='|' read -r _ _ _ state <<<"$line"
                [ "$state" = "RUNNING" ] && need_restart=true
            done <<<"$MIG_APPS_INFO"

            if $need_restart; then
                echo ""
                echo "  Restarting apps that were RUNNING pre-teardown..."
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    IFS='|' read -r app _ _ state <<<"$line"
                    [ "$state" != "RUNNING" ] && continue
                    if run_capture_with_elapsed "    Starting $app" \
                        midclt call -j app.start "$app"; then
                        echo "    Starting $app... OK (${ELAPSED}s)"
                    else
                        echo "    Starting $app... WARN (${ELAPSED}s): $CAPTURED_OUT"
                    fi
                done <<<"$MIG_APPS_INFO"
            fi
        fi

        echo "=== MIG runtime teardown finished ==="
        echo ""
    fi
fi

# ─────────────────────────────────────────────────────────────────────────
# Stop app services + wait for GPU drain — only when the driver is being
# reverted (live-swapping nvidia.raw must happen with no GPU consumers
# at all, since we're replacing the kernel module file). The MIG teardown
# above already stopped MIG-holding apps and reassigned them; this
# docker.update toggle takes down every remaining nvidia-runtime container
# so the kernel module isn't held by anything else. `-j` blocks until
# docker has actually applied the change.
# ─────────────────────────────────────────────────────────────────────────
if $HAS_DRIVER; then
    echo "Stopping app services..."
    midclt call -j docker.update '{"nvidia": false}' >/dev/null \
        || echo "WARN: app services API call (docker.update) failed — continuing"
    DOCKER_NVIDIA_DISABLED=1
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
        if [ -z "$USR_DATASET" ]; then
            echo "ERROR: could not determine the ZFS dataset for /usr" >&2
            exit 1
        fi
        zfs set readonly=off "$USR_DATASET"
        USR_WAS_WRITABLE=1
        cp "$ORIGINAL" "$LIVE_NVIDIA"
        [ -f "${LIVE_NVIDIA}.bak" ] && rm -f "${LIVE_NVIDIA}.bak" 2>/dev/null || true
        zfs set readonly=on "$USR_DATASET"
        USR_WAS_WRITABLE=0
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

# Restore the nvidia toggle if we turned it off above to evict containers
# before the driver swap. Hardware testing confirmed the toggle DOES
# persist across reboot — earlier comments in this file claimed it gets
# reset, but that turned out to be a misattribution: it was THIS script
# leaving it false pre-reboot, and the value survived the reboot. Without
# this restore the user gets a clean revert to stock driver but apps come
# back with the nvidia toggle stuck off and no GPU access until they
# notice and flip it manually.
if $HAS_DRIVER; then
    echo "Restoring nvidia toggle..."
    midclt call docker.update '{"nvidia": true}' >/dev/null 2>&1 || true
    DOCKER_NVIDIA_DISABLED=0
    NV_STATE=$(midclt call docker.config 2>/dev/null | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('nvidia'))
except Exception: print('')" 2>/dev/null || true)
    if [ "$NV_STATE" = "True" ]; then
        echo "  docker.config.nvidia=True (restored)"
    else
        echo "  WARN: docker.config.nvidia=${NV_STATE:-?} after restore attempt." >&2
        echo "        Re-enable manually after reboot:" >&2
        echo "          sudo midclt call docker.update '{\"nvidia\": true}'" >&2
    fi
fi

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

# NOTE: docker.config.nvidia is restored above (right after the sysext
# re-merge) in the HAS_DRIVER path. Earlier revisions left this to the
# user post-reboot, on the assumption that TrueNAS resets the toggle on
# boot anyway — hardware testing showed the toggle actually persists,
# so the restore is both safe and necessary.

if $HAS_DRIVER; then
    cat <<EOF

=== Uninstall complete — REBOOT REQUIRED ===

Kernel modules currently loaded are still the custom driver's. After
reboot, modules will load fresh from the stock sysext and match the
userspace libs (no more NVML mismatch).

Run: sudo reboot

>>> AFTER REBOOT <<<

The nvidia toggle was restored to ON above and the value persists across
reboot, so apps come back with GPU access automatically. If you want to
verify after the reboot:

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
  - MIG-holding apps were stopped explicitly via app.stop
  - MIG instances destroyed; MIG mode disabled ✓ verified
  - Apps that held MIG-* UUIDs were reassigned to the full-GPU UUID
    on the same PCI slot
  - Apps that were RUNNING pre-teardown were restarted
  - mig.conf removed from the persist dir (unless --keep-persist was passed)

EOF
    else
        cat <<EOF

WARNING: MIG runtime teardown did NOT fully succeed.

  - MIG mode is still Enabled on the GPU after 3 retries — a non-app
    process must be holding a MIG slice (app.stop already took care of
    every app the script could find via app.config).
  - Inspect: nvidia-smi   (Processes block shows the surviving PIDs)
  - Identify the holder: docker ps | grep <pid>  (or use ps -ef)
  - Stop it, then manually finish the teardown:
      sudo nvidia-smi mig -dci
      sudo nvidia-smi mig -dgi
      sudo nvidia-smi -mig 0
  - Verify: sudo nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader
            (expect: Disabled)

EOF
    fi
fi

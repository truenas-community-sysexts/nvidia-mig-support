#!/usr/bin/env bash
# Uninstall the nvidia-mig.raw sysext. The NVIDIA driver is NOT touched — it's
# managed separately (see nvidia-driver-support). Auto-detects state:
#
#   - MIG installed → tear down MIG runtime state (if active), remove the MIG
#                     sysext + its PREINIT entry; no reboot.
#   - Not installed → print "nothing to do" and exit cleanly.
#
# When MIG mode is currently Enabled on the GPU, this also tears down the MIG
# **runtime state** that lives outside the sysext — MIG instances on the GPU,
# MIG mode in GPU firmware, and per-app `nvidia_gpu_selection` entries pointing
# at MIG-* UUIDs. Without this teardown the sysext is gone but apps with MIG
# UUID assignments would fail to start on next boot (no PREINIT to recreate the
# instances).
#
# MIG-holding apps are identified by walking app.config for every app, stopped
# explicitly via app.stop, and reassigned to the full-GPU UUID on the same PCI
# slot; ones that were running before are restarted with the new config.
#
# This script is bundled into nvidia-mig.raw as /usr/bin/uninstall-nvidia-mig
# so users can run `sudo uninstall-nvidia-mig` without curl|bash. When invoked
# from the bundled location, `systemd-sysext unmerge` below will remove the
# merged copy of this very script mid-execution. That's safe — bash reads the
# script into memory at parse time. Do NOT add code below the unmerge that
# exec()s a binary or sources a file from the bundled sysext; only stable
# system binaries (rm, systemctl, midclt, python3) are safe after unmerge.
#
# Usage:
#   sudo ./uninstall-mig-sysext.sh                     # auto-detect + undo
#   sudo ./uninstall-mig-sysext.sh --keep-persist      # don't remove anything
#                                                       from /mnt/<pool>/.config/nvidia-gpu/

set -euo pipefail

KEEP_PERSIST=false
for arg in "$@"; do
    case "$arg" in
        --keep-persist) KEEP_PERSIST=true ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

[ "$(id -u 2>/dev/null)" = "0" ] || { echo "ERROR: must run as root" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────
# State detection — is the MIG sysext installed?
# ─────────────────────────────────────────────────────────────────────────
# MIG signals: persistent nvidia-mig.raw, or the /etc/extensions symlink.
PERSIST_DIR=""
HAS_MIG=false
for d in /mnt/*/.config/nvidia-gpu; do
    [ -d "$d" ] || continue
    PERSIST_DIR="$d"
    [ -f "$d/nvidia-mig.raw" ] && HAS_MIG=true
    break
done
# /etc/extensions symlink is a secondary MIG signal — covers the case where
# someone already removed the persistent copy.
if [ -L /etc/extensions/nvidia-mig.raw ] || [ -e /etc/extensions/nvidia-mig.raw ]; then
    HAS_MIG=true
fi

echo "=== Uninstall plan ==="
echo "  Persist dir:          ${PERSIST_DIR:-<none found>}"
echo "  MIG sysext installed: $HAS_MIG"
echo ""

if ! $HAS_MIG; then
    echo "Nothing to uninstall — no MIG sysext detected."
    echo "(The NVIDIA driver is managed separately — see nvidia-driver-support.)"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────
# Tear down MIG runtime state if it's currently active. Removing the sysext
# alone is NOT enough: MIG mode is GPU firmware state and MIG instances are
# runtime state on the GPU, both independent of whether the sysext is merged.
# Apps with MIG-* UUIDs in their nvidia_gpu_selection config also need to be
# reverted to the full GPU UUID — otherwise on next boot (without our PREINIT
# to recreate MIG instances) they would try to claim a stale UUID and fail to
# start.
#
# Flow:
#   1. Identify apps whose nvidia_gpu_selection.<slot>.uuid starts with `MIG-`.
#   2. Stop each affected app and save its original state.
#   3. Wait for the GPU to drain.
#   4. Destroy MIG instances and disable MIG mode (cleans the GPU).
#   5. Reassign each affected app's GPU config to the full-GPU UUID on the
#      same PCI slot.
#   6. Restart any app that was originally running.
#
# Skipped silently if nvidia-smi isn't available (no NVIDIA driver present),
# MIG mode is already disabled, or midclt isn't available (not a TrueNAS host).
# ─────────────────────────────────────────────────────────────────────────

# Live-elapsed wrapper for blocking midclt -j calls. Matches the helper pattern
# used in configure-mig.sh so app-stop/update/start show a live counter instead
# of an opaque pause.
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
        # is the canonical case.

        # Cache the full-GPU UUID up front — we'll need it for reassign
        # after the instances are destroyed (at which point nvidia-smi
        # output changes shape).
        FULL_GPU_UUID_FOR_REASSIGN=$(/usr/bin/nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null \
            | head -1 | tr -d '[:space:]' || true)

        # Step 1: pre-scan. Walk every app via app.query, fetch each one's
        # app.config, and remember the (name, slot, old MIG UUID, state)
        # for every app whose `nvidia_gpu_selection.<slot>.uuid` starts
        # with `MIG-`. Store as `name|slot|old_uuid|state` lines in
        # MIG_APPS_INFO so we can drive all later phases off that cache.
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

        # Step 6: restart apps that were RUNNING when we started. We only
        # restart apps that were RUNNING pre-stop — apps in any other state
        # stay in their pre-uninstall state.
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
# Unmerge → remove the MIG symlink → re-merge. The driver sysext is left
# untouched (no /usr write, no driver swap).
# ─────────────────────────────────────────────────────────────────────────
echo "Unmerging sysext..."
systemd-sysext unmerge

if [ -L /etc/extensions/nvidia-mig.raw ] || [ -e /etc/extensions/nvidia-mig.raw ]; then
    rm -f /etc/extensions/nvidia-mig.raw
    echo "Removed /etc/extensions/nvidia-mig.raw"
fi

echo "Re-merging sysext..."
systemd-sysext merge
systemctl daemon-reload

# ─────────────────────────────────────────────────────────────────────────
# Deregister the MIG PREINIT entry.
# ─────────────────────────────────────────────────────────────────────────
# Match `nvidia-mig-setup` but explicitly exclude entries that also contain
# 'preinit' (a legacy driver PREINIT command referenced the MIG service name
# indirectly in some old installs).
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

# ─────────────────────────────────────────────────────────────────────────
# Cleanup persistent storage (MIG artifacts only — the driver and its
# backups belong to nvidia-driver-support and are left alone).
# ─────────────────────────────────────────────────────────────────────────
if ! $KEEP_PERSIST && [ -n "$PERSIST_DIR" ]; then
    rm -f "$PERSIST_DIR/nvidia-mig.raw" "$PERSIST_DIR/mig.conf"
    echo "Removed $PERSIST_DIR/nvidia-mig.raw + mig.conf"
    echo "  (pass --keep-persist to retain them)"
fi

# ─────────────────────────────────────────────────────────────────────────
# Verification + finishing banner.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Verification ==="
systemd-sysext status || true

cat <<EOF

=== Uninstall complete ===

No reboot needed. The NVIDIA driver was never touched — it stays as installed
(stock, or whatever nvidia-driver-support put in place).
EOF

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

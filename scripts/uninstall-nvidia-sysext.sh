#!/usr/bin/env bash
# Restore stock nvidia.raw from /mnt/<pool>/.config/nvidia-gpu/nvidia-original.raw
# and remove the custom-driver PREINIT entry. Counterpart to
# `install-sysext.sh --with-driver`. Leaves the MIG sysext (nvidia-mig.raw)
# in place — it works on top of either the stock or a custom driver.
#
# This script is also bundled into the custom nvidia.raw as
# /usr/bin/uninstall-nvidia-driver so users can run
# `sudo uninstall-nvidia-driver` after install without a curl|bash.
# When invoked from the bundled location, `systemd-sysext unmerge` below will
# remove the merged copy of this very script mid-execution. That's safe — bash
# reads the script into memory at parse time. Do NOT add code below the unmerge
# that exec()s a binary or sources a file from the bundled sysext; only stable
# system binaries (cp, rm, systemctl, midclt, python3, zfs) are safe to use
# after unmerge.
#
# Usage: sudo ./uninstall-nvidia-sysext.sh [--keep-persist]
#   --keep-persist  Leave /mnt/<pool>/.config/nvidia-gpu/ contents in place

set -euo pipefail

KEEP_PERSIST=false
for arg in "$@"; do
    case "$arg" in
        --keep-persist) KEEP_PERSIST=true ;;
        -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

[ "$(id -u 2>/dev/null)" = "0" ] || { echo "ERROR: must run as root" >&2; exit 1; }

SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
LIVE_NVIDIA="${SYSEXT_DIR}/nvidia.raw"

# Locate persistent custom + stock backup
ORIGINAL=""
PERSIST_DIR=""
for d in /mnt/*/.config/nvidia-gpu; do
    [ -d "$d" ] || continue
    PERSIST_DIR="$d"
    [ -f "$d/nvidia-original.raw" ] && ORIGINAL="$d/nvidia-original.raw" && break
done

echo "=== Uninstall full-driver nvidia.raw ==="

# --- Stop app services, drain GPU ---
# "App services" is the user-facing name for what TrueNAS calls Docker
# internally; the middleware endpoint is still `docker.update`.
echo "Stopping app services..."
midclt call docker.update '{"nvidia": false}' >/dev/null \
    || echo "WARN: app services API call (docker.update) failed — continuing"
if [ -x /usr/bin/nvidia-smi ]; then
    # Match the install script's visible-counter pattern so users see
    # progress instead of an opaque pause.
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

# --- Restore stock if we have a backup, else just leave whatever's there ---
if [ -n "$ORIGINAL" ]; then
    echo "Restoring stock from $ORIGINAL"
    systemd-sysext unmerge
    USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null)
    zfs set readonly=off "$USR_DATASET"
    cp "$ORIGINAL" "$LIVE_NVIDIA"
    [ -f "${LIVE_NVIDIA}.bak" ] && rm -f "${LIVE_NVIDIA}.bak" 2>/dev/null || true
    zfs set readonly=on "$USR_DATASET"

    mkdir -p /etc/extensions
    ln -sf "$LIVE_NVIDIA" /etc/extensions/nvidia.raw
    systemd-sysext merge
    systemctl daemon-reload
    echo "Stock nvidia.raw restored"
else
    echo "No nvidia-original.raw backup found; leaving live nvidia.raw in place"
    echo "  (run recover-stock-nvidia.sh later to fetch one if needed)"
fi

# --- Deregister driver PREINIT (matches both new and legacy names) ---
PREINIT_ID=$(midclt call initshutdownscript.query 2>/dev/null \
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

if [ -n "$PREINIT_ID" ]; then
    midclt call initshutdownscript.delete "$PREINIT_ID" >/dev/null 2>&1 \
        && echo "Deregistered driver PREINIT entry (id $PREINIT_ID)" \
        || echo "WARN: deregister failed"
else
    echo "No matching driver PREINIT entry found"
fi

# --- Cleanup persistent storage ---
if ! $KEEP_PERSIST && [ -n "$PERSIST_DIR" ]; then
    rm -f "$PERSIST_DIR/nvidia.raw" \
          "$PERSIST_DIR/nvidia-preinit-driver.sh" \
          "$PERSIST_DIR/nvidia-preinit-full.sh"
    echo "Removed custom nvidia.raw and driver PREINIT script from $PERSIST_DIR"
    echo "  (nvidia-original.raw and nvidia-mig.raw kept — MIG sysext still works on stock driver)"
fi

# Intentionally NOT calling `midclt call docker.update '{"nvidia": true}'`
# here. At this point in the flow:
#   - userspace libs in /usr are the stock driver (just cp'd from the
#     persistent backup)
#   - kernel modules in RAM are still the custom driver we just removed
#   - NVML reports "Driver/library version mismatch"
# Recent TrueNAS middleware validates docker.update by probing NVML, so
# the call gets silently rejected and persisted as nvidia=false — the
# script has no way to detect that (errors swallowed) and the user finds
# the Apps "Use NVIDIA GPU" toggle off after reboot. Defer the re-enable
# to the user, with explicit instructions in the final banner below.

echo ""
echo "=== Uninstall complete — REBOOT REQUIRED ==="
echo ""
echo "Kernel modules currently loaded are still the custom driver's."
echo "After reboot, modules will load fresh from the stock sysext and"
echo "match the userspace libs (no more NVML mismatch)."
echo ""
echo "Run: sudo reboot"
echo ""
echo ">>> AFTER REBOOT — one-time step to make Apps see the GPU again <<<"
echo ""
echo "App services were turned off during uninstall (so we could swap"
echo "the driver). The matching re-enable was deliberately skipped"
echo "because TrueNAS's middleware validates that call against NVML,"
echo "which is in driver/library mismatch right now — the call would"
echo "silently fail."
echo ""
echo "Once the box is back up and 'nvidia-smi' shows the stock driver, run:"
echo ""
echo "  sudo midclt call docker.update '{\"nvidia\": true}'"
echo ""
echo "  -- or --"
echo ""
echo "  Toggle the 'Use NVIDIA GPU' switch on under TrueNAS UI →"
echo "  Apps → Settings → Configure → check 'Use NVIDIA GPU' → Save"

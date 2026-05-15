#!/usr/bin/env bash
# Restore stock nvidia.raw from /mnt/<pool>/.config/nvidia-gpu/nvidia-original.raw
# and remove the full-driver PREINIT entry. Counterpart to install-nvidia-sysext.sh.
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

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root" >&2; exit 1; }

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

# --- Stop Docker, drain GPU ---
echo "Stopping Docker..."
midclt call docker.update '{"nvidia": false}' >/dev/null || true
if [ -x /usr/bin/nvidia-smi ]; then
    for attempt in $(seq 1 24); do
        N=$(/usr/bin/nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l || echo 0)
        [ "${N:-0}" -eq 0 ] && break
        sleep 5
    done
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

# --- Deregister PREINIT ---
PREINIT_ID=$(midclt call initshutdownscript.query 2>/dev/null \
    | python3 -c "
import sys, json
try:
    for s in json.load(sys.stdin):
        cmd = (s.get('command') or '') + ' ' + (s.get('script') or '')
        if 'nvidia-preinit-full' in cmd:
            print(s['id'], end=''); break
except Exception:
    pass
" 2>/dev/null)

if [ -n "$PREINIT_ID" ]; then
    midclt call initshutdownscript.delete "$PREINIT_ID" >/dev/null 2>&1 \
        && echo "Deregistered PREINIT entry (id $PREINIT_ID)" \
        || echo "WARN: deregister failed"
else
    echo "No matching PREINIT entry found"
fi

# --- Cleanup persistent storage ---
if ! $KEEP_PERSIST && [ -n "$PERSIST_DIR" ]; then
    rm -f "$PERSIST_DIR/nvidia.raw" "$PERSIST_DIR/nvidia-preinit-full.sh"
    echo "Removed custom nvidia.raw and PREINIT script from $PERSIST_DIR"
    echo "  (nvidia-original.raw kept — pass --keep-persist=false to also remove)"
fi

# --- Re-enable Docker ---
echo ""
echo "Re-enabling Docker..."
midclt call docker.update '{"nvidia": true}' >/dev/null || true

echo ""
echo "=== Uninstall complete ==="
echo "REBOOT REQUIRED for kernel modules to reload at the matching driver version."

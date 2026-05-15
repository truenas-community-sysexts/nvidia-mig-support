#!/usr/bin/env bash
# Remove the lightweight nvidia-mig sysext deployed by install-mig-sysext.sh.
# Does NOT touch the stock TrueNAS nvidia.raw or any MIG mode state.
#
# This script is also bundled into nvidia-mig.raw as /usr/bin/uninstall-nvidia-mig
# so users can run `sudo uninstall-nvidia-mig` after install without a curl|bash.
# When invoked from the bundled location, `systemd-sysext unmerge` below will
# remove the merged copy of this very script mid-execution. That's safe — bash
# reads the script into memory at parse time. Do NOT add code below the unmerge
# that exec()s a binary or sources a file from the bundled sysext; only system
# binaries (rm, systemctl, midclt, python3) and shell builtins are safe to use
# after unmerge.

set -euo pipefail

KEEP_PERSIST=false
for arg in "$@"; do
    case "$arg" in
        --keep-persist) KEEP_PERSIST=true ;;
        -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

echo "=== Uninstall nvidia-mig sysext ==="

# --- Deregister PREINIT entry ---
PREINIT_ID=$(midclt call initshutdownscript.query 2>/dev/null \
    | python3 -c "
import sys, json
try:
    scripts = json.load(sys.stdin)
    for s in scripts:
        cmd = (s.get('command') or '') + ' ' + (s.get('script') or '')
        if 'nvidia-mig-setup' in cmd:
            print(s['id'], end='')
            break
except Exception:
    pass
" 2>/dev/null)

if [ -n "$PREINIT_ID" ]; then
    midclt call initshutdownscript.delete "$PREINIT_ID" >/dev/null 2>&1 \
        && echo "Deregistered PREINIT entry (id: ${PREINIT_ID})" \
        || echo "WARNING: Failed to deregister PREINIT entry (id: ${PREINIT_ID})"
else
    echo "No nvidia-mig-setup PREINIT entry found to deregister"
fi

if [ -L /etc/extensions/nvidia-mig.raw ] || [ -e /etc/extensions/nvidia-mig.raw ]; then
    rm -f /etc/extensions/nvidia-mig.raw
    echo "Removed /etc/extensions/nvidia-mig.raw"
else
    echo "No symlink at /etc/extensions/nvidia-mig.raw"
fi

echo "Re-merging systemd-sysext..."
systemd-sysext unmerge
systemd-sysext merge
systemctl daemon-reload

if ! $KEEP_PERSIST; then
    for f in /mnt/*/.config/nvidia-gpu/nvidia-mig.raw; do
        if [ -f "$f" ]; then
            rm -f "$f"
            echo "Removed $f"
        fi
    done
fi

echo ""
echo "=== Verification ==="
systemd-sysext status || true
if [ -x /usr/bin/nvidia-mig-setup ]; then
    echo "WARN: /usr/bin/nvidia-mig-setup still present — sysext may still be merged"
else
    echo "OK:   nvidia-mig-setup gone from /usr/bin"
fi

echo ""
echo "=== Uninstall complete ==="

#!/usr/bin/env bash
# Remove the lightweight nvidia-mig sysext deployed by install-mig-sysext.sh.
# Does NOT touch the stock TrueNAS nvidia.raw or any MIG mode state.
#
# Usage: sudo ./uninstall-mig-sysext.sh [--keep-persist]
#   --keep-persist  Leave the persistent copy at /mnt/<pool>/.config/nvidia-gpu/nvidia-mig.raw

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

# --- Disable before removal so /etc symlink doesn't dangle ---
if systemctl is-enabled nvidia-mig-setup.service >/dev/null 2>&1; then
    systemctl disable nvidia-mig-setup.service
    echo "Disabled nvidia-mig-setup.service"
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

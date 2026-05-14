#!/usr/bin/env bash
# Recover the stock TrueNAS nvidia.raw from the official .update archive
# when no backup is available locally. Run as root on TrueNAS.
#
# Pulls the .update file (~1.8 GB) into a working dir on a ZFS pool (not
# tmpfs), peels the two-level squashfs to extract
#   /usr/share/truenas/sysext-extensions/nvidia.raw
# and either stages it as a backup or restores it in place.
#
# Usage:
#   sudo ./recover-stock-nvidia.sh                  # download + extract, stage as nvidia-original.raw
#   sudo ./recover-stock-nvidia.sh --install        # also install over the current nvidia.raw
#   sudo ./recover-stock-nvidia.sh --version=25.10.3.1
#   sudo ./recover-stock-nvidia.sh --update-file=/path/to/preloaded.update
#   sudo ./recover-stock-nvidia.sh --keep-workdir   # leave the ~2 GB download in place

set -euo pipefail

VERSION=""
UPDATE_FILE=""
DO_INSTALL=false
KEEP_WORKDIR=false

for arg in "$@"; do
    case "$arg" in
        --version=*) VERSION="${arg#*=}" ;;
        --update-file=*) UPDATE_FILE="${arg#*=}" ;;
        --install) DO_INSTALL=true ;;
        --keep-workdir) KEEP_WORKDIR=true ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

[ -n "$VERSION" ] || VERSION=$(cat /etc/version 2>/dev/null | tr -d '[:space:]')
[ -n "$VERSION" ] || { echo "ERROR: cannot determine TrueNAS version, pass --version=X.Y.Z" >&2; exit 1; }

case "$VERSION" in
    25.*) CODENAME="Goldeye"; URL_FILE="TrueNAS-SCALE-${VERSION}.update" ;;
    26.*) CODENAME=""; URL_FILE="TrueNAS-${VERSION}.update" ;;
    *) echo "ERROR: unsupported version pattern: $VERSION" >&2; exit 1 ;;
esac

POOL=$(zpool list -H -o name 2>/dev/null | grep -v '^boot-pool$' | head -1 || true)
[ -n "$POOL" ] || { echo "ERROR: no data pool found (need somewhere with ~3 GB free)" >&2; exit 1; }

WORK="/mnt/${POOL}/.config/nvidia-gpu/recovery"
PERSIST="/mnt/${POOL}/.config/nvidia-gpu"
SYSEXT_DIR="/usr/share/truenas/sysext-extensions"

echo "=== Recover stock nvidia.raw ==="
echo "Version:  $VERSION ($CODENAME)"
echo "Pool:     $POOL"
echo "Workdir:  $WORK"
echo ""

mkdir -p "$WORK" "$PERSIST"

# --- 1. Get the .update file ---
if [ -n "$UPDATE_FILE" ]; then
    [ -f "$UPDATE_FILE" ] || { echo "ERROR: $UPDATE_FILE not found" >&2; exit 1; }
    echo "Using preloaded update file: $UPDATE_FILE"
else
    UPDATE_FILE="${WORK}/truenas.update"
    if [ -s "$UPDATE_FILE" ]; then
        echo "Resuming/using existing download at ${UPDATE_FILE}"
    fi
    if [ "$CODENAME" = "Goldeye" ]; then
        URL="https://download.truenas.com/TrueNAS-SCALE-${CODENAME}/${VERSION}/${URL_FILE}?download=1"
    else
        URL="https://update-public.sys.truenas.net/TrueNAS-26-BETA/${URL_FILE}"
    fi
    echo "Downloading ${URL}"
    curl -fL --retry 3 --continue-at - -o "$UPDATE_FILE" "$URL"
fi
ls -lh "$UPDATE_FILE"

# --- 2. Peel outer squashfs to get rootfs.squashfs ---
OUTER_DIR="${WORK}/outer"
rm -rf "$OUTER_DIR"
echo ""
echo "Extracting rootfs.squashfs from .update..."
unsquashfs -f -d "$OUTER_DIR" "$UPDATE_FILE" rootfs.squashfs

INNER="${OUTER_DIR}/rootfs.squashfs"
[ -f "$INNER" ] || { echo "ERROR: rootfs.squashfs not found inside .update" >&2; exit 1; }
ls -lh "$INNER"

# --- 3. Peel inner squashfs to get the stock nvidia.raw ---
INNER_DIR="${WORK}/rootfs"
rm -rf "$INNER_DIR"
echo ""
echo "Extracting usr/share/truenas/sysext-extensions/nvidia.raw from rootfs.squashfs..."
unsquashfs -f -d "$INNER_DIR" "$INNER" usr/share/truenas/sysext-extensions/nvidia.raw

STOCK="${INNER_DIR}/usr/share/truenas/sysext-extensions/nvidia.raw"
[ -f "$STOCK" ] || { echo "ERROR: stock nvidia.raw not found inside rootfs.squashfs" >&2; exit 1; }

echo ""
echo "=== Stock nvidia.raw recovered ==="
ls -lh "$STOCK"
STOCK_SHA=$(sha256sum "$STOCK" | awk '{print $1}')
STOCK_SIZE=$(stat -c '%s' "$STOCK")
echo "SHA256: $STOCK_SHA"
echo "Size:   $STOCK_SIZE bytes"

# Sanity bounds — observed: TrueNAS 25.10.x stock nvidia.raw is ~400 MB
# (570.172.08 driver + libs + nvidia-container-toolkit). Warn outside a
# generous range that catches truncated downloads or wildly different content.
if [ "$STOCK_SIZE" -lt 100000000 ]; then
    echo "WARN: extracted nvidia.raw is suspiciously small (${STOCK_SIZE} bytes); verify before installing"
elif [ "$STOCK_SIZE" -gt 700000000 ]; then
    echo "WARN: extracted nvidia.raw is unexpectedly large (${STOCK_SIZE} bytes); verify before installing"
fi

# --- 4. Stage as nvidia-original.raw for restore.sh to find next time ---
cp "$STOCK" "${PERSIST}/nvidia-original.raw"
echo ""
echo "Staged: ${PERSIST}/nvidia-original.raw"

# --- 5. Optionally install over the live nvidia.raw ---
if $DO_INSTALL; then
    CURRENT_SHA=$(sha256sum "${SYSEXT_DIR}/nvidia.raw" 2>/dev/null | awk '{print $1}' || echo "")
    if [ "$CURRENT_SHA" = "$STOCK_SHA" ]; then
        echo ""
        echo "Live nvidia.raw already matches stock — no install needed."
    else
        echo ""
        echo "=== Installing stock nvidia.raw over current ==="
        echo "Stopping Docker so the GPU is free..."
        midclt call docker.update '{"nvidia": false}' >/dev/null

        echo "Unmerging sysext..."
        systemd-sysext unmerge

        USR_DATASET=$(zfs list -H -o name /usr)
        echo "Setting ${USR_DATASET} writable..."
        zfs set readonly=off "${USR_DATASET}"

        # Backup current (custom) as .bak in case we need it later
        if [ ! -f "${SYSEXT_DIR}/nvidia.raw.bak" ]; then
            cp "${SYSEXT_DIR}/nvidia.raw" "${SYSEXT_DIR}/nvidia.raw.bak"
            echo "Backed up current (custom) to nvidia.raw.bak"
        fi
        cp "$STOCK" "${SYSEXT_DIR}/nvidia.raw"

        echo "Restoring ${USR_DATASET} readonly..."
        zfs set readonly=on "${USR_DATASET}"

        echo "Ensuring /etc/extensions/nvidia.raw symlink..."
        mkdir -p /etc/extensions
        ln -sf "${SYSEXT_DIR}/nvidia.raw" /etc/extensions/nvidia.raw

        echo "Re-merging sysext..."
        systemd-sysext merge
        systemctl daemon-reload

        echo "Re-enabling NVIDIA in Docker..."
        midclt call docker.update '{"nvidia": true}' >/dev/null

        sleep 3
        DRIVER=$(/usr/bin/nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo "unknown")
        echo "Active driver version after install: $DRIVER"
    fi
fi

# --- 6. Cleanup workdir ---
if $KEEP_WORKDIR; then
    echo ""
    echo "Workdir preserved at $WORK ($(du -sh "$WORK" | cut -f1))"
else
    rm -rf "$WORK"
    echo ""
    echo "Cleaned up workdir."
fi

echo ""
echo "=== Done ==="
if ! $DO_INSTALL; then
    echo "Re-run with --install to actually swap the live nvidia.raw back to stock."
fi

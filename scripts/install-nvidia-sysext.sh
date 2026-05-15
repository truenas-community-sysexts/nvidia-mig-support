#!/usr/bin/env bash
# Deploy the FULL-DRIVER nvidia.raw sysext on TrueNAS — replaces the stock
# /usr/share/truenas/sysext-extensions/nvidia.raw with a custom build that
# may ship a different driver version + bundled MIG tooling.
#
# Reboot REQUIRED after install: live-swapping nvidia.raw leaves the old
# kernel modules in memory, mismatching the new userspace libraries
# (NVML "driver/library version mismatch"). See agents.md memory.
#
# Default: downloads from the dev-nvidia-sysext rolling prerelease.
# Override with --sysext=PATH for a local file.
#
# Usage:
#   sudo ./install-nvidia-sysext.sh                       # default release
#   sudo ./install-nvidia-sysext.sh --sysext=/tmp/x.raw
#   sudo ./install-nvidia-sysext.sh --pool=fast
#
# Requirements:
#   - Stock nvidia.raw must be backed up first (run recover-stock-nvidia.sh
#     if you don't have /mnt/<pool>/.config/nvidia-gpu/nvidia-original.raw).

set -euo pipefail

DEFAULT_RELEASE_URL="https://github.com/scyto/truenas-nvidia-rtx6000-pro-mig/releases/download/dev-nvidia-sysext/nvidia.raw"
SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
LIVE_NVIDIA="${SYSEXT_DIR}/nvidia.raw"

SYSEXT_SRC=""
POOL_NAME=""
PERSIST_PATH=""
SKIP_BACKUP_CHECK=false

for arg in "$@"; do
    case "$arg" in
        --sysext=*) SYSEXT_SRC="${arg#*=}" ;;
        --pool=*) POOL_NAME="${arg#*=}" ;;
        --persist-path=*) PERSIST_PATH="${arg#*=}" ;;
        --skip-backup-check) SKIP_BACKUP_CHECK=true ;;
        -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root" >&2; exit 1; }

# --- Resolve persistent storage location ---
if [ -n "$PERSIST_PATH" ]; then
    PERSIST_DIR="$PERSIST_PATH"
elif [ -n "$POOL_NAME" ]; then
    PERSIST_DIR="/mnt/${POOL_NAME}/.config/nvidia-gpu"
else
    POOL_NAME=$(zpool list -H -o name 2>/dev/null | grep -v '^boot-pool$' | head -1 || true)
    [ -n "$POOL_NAME" ] || { echo "ERROR: no ZFS pool found. Pass --pool=NAME." >&2; exit 1; }
    PERSIST_DIR="/mnt/${POOL_NAME}/.config/nvidia-gpu"
    echo "Auto-detected pool: ${POOL_NAME}"
fi
mkdir -p "$PERSIST_DIR"

# --- Pre-flight: stock backup required so user can recover from a bad swap ---
if ! $SKIP_BACKUP_CHECK; then
    if [ ! -f "${PERSIST_DIR}/nvidia-original.raw" ]; then
        cat >&2 <<EOF
ERROR: ${PERSIST_DIR}/nvidia-original.raw not found.
       Refusing to swap nvidia.raw without a stock backup on hand.
       Run scripts/recover-stock-nvidia.sh first (downloads + extracts
       stock nvidia.raw from the official TrueNAS .update). Or pass
       --skip-backup-check if you accept the risk.
EOF
        exit 1
    fi
fi

# --- Fetch sysext if not provided ---
if [ -z "$SYSEXT_SRC" ]; then
    SYSEXT_SRC=$(mktemp -t nvidia.raw.XXXXXX)
    trap 'rm -f "$SYSEXT_SRC"' EXIT
    echo "Downloading $DEFAULT_RELEASE_URL"
    curl -fL --retry 3 -o "$SYSEXT_SRC" "$DEFAULT_RELEASE_URL" \
        || { echo "ERROR: download failed" >&2; exit 1; }
fi
[ -f "$SYSEXT_SRC" ] || { echo "ERROR: sysext source not found: $SYSEXT_SRC" >&2; exit 1; }

# --- Sanity-check the sysext contents ---
if command -v unsquashfs >/dev/null 2>&1; then
    unsquashfs -l "$SYSEXT_SRC" 2>/dev/null | grep -q 'extension-release.nvidia$' \
        || { echo "ERROR: $SYSEXT_SRC missing extension-release.nvidia" >&2; exit 1; }
    NEW_DRIVER=$(unsquashfs -l "$SYSEXT_SRC" 2>/dev/null \
        | grep -oE 'libnvidia-ml\.so\.[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1 | sed 's/^libnvidia-ml\.so\.//' || true)
    echo "Sysext driver version: ${NEW_DRIVER:-unknown}"
fi

echo "=== Install full-driver nvidia.raw ==="
echo "Source:      $SYSEXT_SRC"
echo "Persist dir: $PERSIST_DIR"
echo ""

# --- Stash to persistent storage so TrueNAS updates can be survived ---
cp "$SYSEXT_SRC" "${PERSIST_DIR}/nvidia.raw"
echo "Copied custom nvidia.raw to ${PERSIST_DIR}/nvidia.raw"

# --- Stop Docker so the GPU is free, wait for processes to drain ---
echo ""
echo "Stopping Docker (releasing GPU)..."
midclt call docker.update '{"nvidia": false}' >/dev/null \
    || echo "WARN: docker.update failed (middleware may be transitionally down — continuing)"

if [ -x /usr/bin/nvidia-smi ]; then
    for attempt in $(seq 1 24); do
        N=$(/usr/bin/nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l || echo 0)
        if [ "${N:-0}" -eq 0 ]; then
            echo "GPU released"; break
        fi
        printf "\r  Waiting for %d GPU process(es)... %ds/120s" "$N" "$((attempt * 5))"
        sleep 5
    done
    echo ""
fi

# --- Swap nvidia.raw ---
echo "Unmerging sysext..."
systemd-sysext unmerge

USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null)
echo "Setting $USR_DATASET writable..."
zfs set readonly=off "$USR_DATASET"

# Stash current (likely stock) as .bak unless we already have nvidia-original.raw
if [ ! -f "${LIVE_NVIDIA}.bak" ]; then
    cp "$LIVE_NVIDIA" "${LIVE_NVIDIA}.bak" 2>/dev/null \
        && echo "Backed up current to ${LIVE_NVIDIA}.bak" \
        || echo "WARN: could not back up to .bak"
fi

cp "$SYSEXT_SRC" "$LIVE_NVIDIA"
echo "Installed custom nvidia.raw"

zfs set readonly=on "$USR_DATASET"

echo "Ensuring /etc/extensions/nvidia.raw symlink..."
mkdir -p /etc/extensions
ln -sf "$LIVE_NVIDIA" /etc/extensions/nvidia.raw

echo "Re-merging sysext..."
systemd-sysext merge
systemctl daemon-reload

# --- Install the PREINIT script + register with midclt ---
echo ""
echo "Installing PREINIT script..."
SCRIPT_URL_BASE="https://raw.githubusercontent.com/scyto/truenas-nvidia-rtx6000-pro-mig/refactor/dual-sysext/scripts"
PREINIT_LOCAL="${PERSIST_DIR}/nvidia-preinit-full.sh"

# Prefer in-repo copy if running from a checkout; fall back to download
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || true)"
if [ -n "${SCRIPT_DIR:-}" ] && [ -f "${SCRIPT_DIR}/nvidia-preinit-full.sh" ]; then
    cp "${SCRIPT_DIR}/nvidia-preinit-full.sh" "$PREINIT_LOCAL"
else
    curl -fL -o "$PREINIT_LOCAL" "${SCRIPT_URL_BASE}/nvidia-preinit-full.sh"
fi
chmod 0755 "$PREINIT_LOCAL"
echo "Installed: $PREINIT_LOCAL"

PREINIT_CMD="$PREINIT_LOCAL"
COMMENT="Full-driver nvidia.raw restore + start MIG service"

EXISTING_ID=$(midclt call initshutdownscript.query 2>/dev/null \
    | python3 -c "
import sys, json
try:
    for s in json.load(sys.stdin):
        cmd = (s.get('command') or '') + ' ' + (s.get('script') or '')
        if 'nvidia-preinit-full' in cmd or 'nvidia-mig-setup' in cmd or 'nvidia-preinit' in cmd:
            print(s['id'], end=''); break
except Exception:
    pass
" 2>/dev/null)

JSON="{\"type\": \"COMMAND\", \"command\": \"${PREINIT_CMD}\", \"when\": \"PREINIT\", \"enabled\": true, \"timeout\": 180, \"comment\": \"${COMMENT}\"}"

if [ -n "$EXISTING_ID" ]; then
    echo "Updating existing PREINIT entry (id $EXISTING_ID)..."
    midclt call initshutdownscript.update "$EXISTING_ID" "$JSON" >/dev/null \
        || echo "WARN: PREINIT update failed"
else
    midclt call initshutdownscript.create "$JSON" >/dev/null \
        && echo "Registered PREINIT entry" \
        || echo "WARN: PREINIT create failed"
fi

# --- Re-enable Docker ---
echo ""
echo "Re-enabling Docker..."
midclt call docker.update '{"nvidia": true}' >/dev/null || echo "WARN: docker.update re-enable failed"

echo ""
echo "=== Install complete ==="
cat <<EOF

REBOOT REQUIRED. The kernel modules currently loaded are the previous
driver's; userspace libraries are now the new driver's. Until you reboot:

  nvidia-smi will report "Driver/library version mismatch"

After reboot:
  - new kernel modules load from /usr/lib/modules/<kernel>/video/
  - userspace libs match
  - the bundled MIG service runs via the registered PREINIT entry
  - if you have mig.conf in $PERSIST_DIR, MIG instances are recreated

Run: sudo reboot
EOF

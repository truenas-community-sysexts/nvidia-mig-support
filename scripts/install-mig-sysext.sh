#!/usr/bin/env bash
# Deploy the lightweight nvidia-mig sysext on TrueNAS.
# This is the mechanical sysext install only — it does NOT configure MIG
# profiles, register a PREINIT script, or touch app assignments. Use the
# full install.sh for that (Phase 3, not yet rewritten).
#
# Default: downloads the latest dev build from the dev-mig-sysext release.
# Override with --sysext=PATH for a local file.
#
# Usage:
#   sudo ./install-mig-sysext.sh
#   sudo ./install-mig-sysext.sh --sysext=/tmp/nvidia-mig.raw
#   sudo ./install-mig-sysext.sh --pool=fast
#
# Assumes the stock TrueNAS nvidia.raw is already merged (provides drivers).

set -euo pipefail

DEFAULT_RELEASE_URL="https://github.com/scyto/truenas-nvidia-rtx6000-pro-mig/releases/download/dev-mig-sysext/nvidia-mig.raw"
STOCK_NVIDIA="/usr/share/truenas/sysext-extensions/nvidia.raw"
MIN_DRIVER_MAJOR=570

SYSEXT_SRC=""
POOL_NAME=""
PERSIST_PATH=""
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --sysext=*) SYSEXT_SRC="${arg#*=}" ;;
        --pool=*) POOL_NAME="${arg#*=}" ;;
        --persist-path=*) PERSIST_PATH="${arg#*=}" ;;
        --force) FORCE=true ;;
        -h|--help)
            sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

# --- Pre-flight: detect stock nvidia driver version inside the sysext on disk ---
# Doesn't require the driver to be loaded; reads the version directly from
# filenames inside /usr/share/truenas/sysext-extensions/nvidia.raw.
command -v unsquashfs >/dev/null 2>&1 || { echo "ERROR: unsquashfs not found (squashfs-tools)" >&2; exit 1; }

if [ ! -f "$STOCK_NVIDIA" ]; then
    echo "ERROR: $STOCK_NVIDIA not found — TrueNAS doesn't appear to have an NVIDIA sysext." >&2
    echo "       The lightweight nvidia-mig sysext depends on the stock driver being present." >&2
    exit 1
fi

DRIVER_VER=$(unsquashfs -l "$STOCK_NVIDIA" 2>/dev/null \
    | grep -oE 'libnvidia-ml\.so\.[0-9]+\.[0-9]+\.[0-9]+' \
    | head -1 \
    | sed 's/^libnvidia-ml\.so\.//' || true)

if [ -z "$DRIVER_VER" ]; then
    echo "WARN: could not detect driver version inside $STOCK_NVIDIA — proceeding (no support gate)."
else
    DRIVER_MAJOR=${DRIVER_VER%%.*}
    echo "Stock NVIDIA driver in $STOCK_NVIDIA: $DRIVER_VER"
    if [ "$DRIVER_MAJOR" -lt "$MIN_DRIVER_MAJOR" ]; then
        echo "" >&2
        echo "ERROR: stock driver $DRIVER_VER is below the minimum-validated $MIN_DRIVER_MAJOR.x." >&2
        echo "       MIG support has only been validated on $MIN_DRIVER_MAJOR.x and above on Blackwell GPUs." >&2
        echo "       Re-run with --force to bypass this check at your own risk." >&2
        $FORCE || exit 1
        echo "       --force given, continuing anyway." >&2
    fi
fi

# If no source given, fetch the latest dev build from the release.
if [ -z "$SYSEXT_SRC" ]; then
    SYSEXT_SRC=$(mktemp -t nvidia-mig.raw.XXXXXX)
    trap 'rm -f "$SYSEXT_SRC"' EXIT
    echo "Downloading ${DEFAULT_RELEASE_URL}"
    curl -fL --retry 3 -o "$SYSEXT_SRC" "$DEFAULT_RELEASE_URL"
fi

if [ ! -f "$SYSEXT_SRC" ]; then
    echo "ERROR: sysext source $SYSEXT_SRC does not exist" >&2
    exit 1
fi

# --- Resolve persistent storage location ---
if [ -n "$PERSIST_PATH" ]; then
    PERSIST_DIR="$PERSIST_PATH"
elif [ -n "$POOL_NAME" ]; then
    PERSIST_DIR="/mnt/${POOL_NAME}/.config/nvidia-gpu"
else
    POOL_NAME=$(zpool list -H -o name 2>/dev/null | grep -v '^boot-pool$' | head -1 || true)
    [ -n "$POOL_NAME" ] || { echo "ERROR: no ZFS pool found (excluding boot-pool). Pass --pool=NAME or --persist-path=PATH." >&2; exit 1; }
    PERSIST_DIR="/mnt/${POOL_NAME}/.config/nvidia-gpu"
    echo "Auto-detected pool: ${POOL_NAME}"
fi

echo "=== Install nvidia-mig sysext ==="
echo "Source:      $SYSEXT_SRC"
echo "Persist dir: $PERSIST_DIR"
echo ""

# --- Verify the source is a usable sysext ---
if command -v unsquashfs >/dev/null 2>&1; then
    if ! unsquashfs -l "$SYSEXT_SRC" 2>/dev/null | grep -q 'extension-release.nvidia-mig'; then
        echo "ERROR: $SYSEXT_SRC does not contain extension-release.nvidia-mig" >&2
        exit 1
    fi
fi

# --- Copy to persistent storage ---
mkdir -p "$PERSIST_DIR"
cp "$SYSEXT_SRC" "${PERSIST_DIR}/nvidia-mig.raw"
echo "Copied to ${PERSIST_DIR}/nvidia-mig.raw"

# --- Symlink into /etc/extensions/ alongside stock nvidia ---
mkdir -p /etc/extensions
ln -sf "${PERSIST_DIR}/nvidia-mig.raw" /etc/extensions/nvidia-mig.raw
echo "Symlinked /etc/extensions/nvidia-mig.raw"

# --- Re-merge sysext to overlay the new extension ---
echo ""
echo "Re-merging systemd-sysext..."
systemd-sysext unmerge
systemd-sysext merge
systemctl daemon-reload

# --- Register PREINIT script via midclt for boot-time activation ---
# WantedBy=multi-user.target doesn't reliably activate sysext-shipped units
# at boot on TrueNAS (silent skip, no journal entries, as confirmed on
# hardware). TrueNAS's PREINIT mechanism runs before services like Docker
# and is the canonical way to trigger GPU setup at boot.
PREINIT_CMD="/usr/bin/systemctl start nvidia-mig-setup.service"
PREINIT_COMMENT="Start nvidia-mig-setup (lightweight sysext path)"
echo "Registering PREINIT command: $PREINIT_CMD"

EXISTING_ID=$(midclt call initshutdownscript.query 2>/dev/null \
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

PREINIT_JSON="{\"type\": \"COMMAND\", \"command\": \"${PREINIT_CMD}\", \"when\": \"PREINIT\", \"enabled\": true, \"timeout\": 120, \"comment\": \"${PREINIT_COMMENT}\"}"

if [ -n "$EXISTING_ID" ]; then
    echo "PREINIT entry already exists (id: ${EXISTING_ID}), updating..."
    midclt call initshutdownscript.update "$EXISTING_ID" "$PREINIT_JSON" >/dev/null \
        || echo "WARNING: Failed to update PREINIT entry"
else
    midclt call initshutdownscript.create "$PREINIT_JSON" >/dev/null \
        || echo "WARNING: Failed to register PREINIT entry"
    echo "PREINIT entry registered"
fi

# --- Verify ---
echo ""
echo "=== Verification ==="
systemd-sysext status || true
echo ""

OK=true
if [ ! -x /usr/bin/nvidia-mig-setup ]; then
    echo "FAIL: /usr/bin/nvidia-mig-setup not found after merge"
    OK=false
else
    echo "OK:   /usr/bin/nvidia-mig-setup present"
fi

if ! systemctl cat nvidia-mig-setup.service >/dev/null 2>&1; then
    echo "FAIL: nvidia-mig-setup.service not loaded"
    OK=false
else
    echo "OK:   nvidia-mig-setup.service loaded"
fi

if [ -x /usr/bin/nvidia-smi ]; then
    DRIVER=$(/usr/bin/nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo unknown)
    echo "OK:   stock driver still available, version ${DRIVER}"
else
    echo "FAIL: /usr/bin/nvidia-smi not available — stock nvidia sysext may not be merged"
    OK=false
fi

echo ""
if $OK; then
    cat <<EOF
=== Install complete — ready to configure NOW (no reboot needed) ===

The stock NVIDIA driver is still running, so MIG can be set up
immediately. The config helper is bundled in the sysext at
/usr/bin/configure-mig:

  sudo configure-mig                       # interactive prompt
  sudo configure-mig --mig=14,14,14,14     # non-interactive

It writes /mnt/<pool>/.config/nvidia-gpu/mig.conf, runs the MIG service,
and walks you through assigning MIG devices to your TrueNAS apps.
EOF
else
    echo "=== Install completed with errors — see FAIL lines above ==="
    exit 1
fi

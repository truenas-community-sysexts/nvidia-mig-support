#!/usr/bin/env bash
# Deploy the FULL-DRIVER nvidia.raw sysext on TrueNAS — replaces the stock
# /usr/share/truenas/sysext-extensions/nvidia.raw with a custom build that
# may ship a different driver version + bundled MIG tooling.
#
# Reboot REQUIRED after install: live-swapping nvidia.raw leaves the old
# kernel modules in memory, mismatching the new userspace libraries
# (NVML "driver/library version mismatch"). See agents.md memory.
#
# Default: queries the latest non-prerelease (production) release via the
# GitHub API and downloads nvidia.raw from it. Falls back to the
# dev-nvidia-sysext rolling prerelease if no production release exists yet
# (transitional — the fallback goes away once a production release is
# promoted via the Phase 4 mark_latest gate).
#
# Override with --release=TAG (specific tag) or --sysext=PATH (local file).
#
# Usage:
#   sudo ./install-nvidia-sysext.sh                                 # latest production, fallback dev
#   sudo ./install-nvidia-sysext.sh --release=dev-nvidia-sysext     # pin to rolling dev
#   sudo ./install-nvidia-sysext.sh --release=v25.10.3.1-nvidia580.126.18-r5
#   sudo ./install-nvidia-sysext.sh --sysext=/tmp/x.raw             # local file
#   sudo ./install-nvidia-sysext.sh --pool=fast
#
# Flags:
#   --sysext=PATH          Local nvidia.raw to install (skips download)
#   --release=TAG          Download from this exact release tag
#   --pool=NAME            ZFS pool for persistent storage (skips auto-detect)
#   --persist-path=PATH    Exact directory for persistent storage (overrides --pool)
#   --skip-backup-check    Don't refuse if nvidia-original.raw backup is missing
#                          (use at your own risk — you may be unable to recover
#                          the stock driver later)
#   -h, --help             Show this help and exit
#
# Pool selection priority: --persist-path > --pool > existing config dir > only
# data pool > interactive prompt (multi-pool) > error (no tty + ambiguous).
#
# Requirements:
#   - Stock nvidia.raw must be backed up first (run recover-stock-nvidia.sh
#     if you don't have /mnt/<pool>/.config/nvidia-gpu/nvidia-original.raw).

set -euo pipefail

REPO="truenas-community-sysexts/nvidia-mig-support"
ASSET="nvidia.raw"
FALLBACK_TAG="dev-nvidia-sysext"
SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
LIVE_NVIDIA="${SYSEXT_DIR}/nvidia.raw"

SYSEXT_SRC=""
RELEASE_TAG=""
POOL_NAME=""
PERSIST_PATH=""
SKIP_BACKUP_CHECK=false

for arg in "$@"; do
    case "$arg" in
        --sysext=*) SYSEXT_SRC="${arg#*=}" ;;
        --release=*) RELEASE_TAG="${arg#*=}" ;;
        --pool=*) POOL_NAME="${arg#*=}" ;;
        --persist-path=*) PERSIST_PATH="${arg#*=}" ;;
        --skip-backup-check) SKIP_BACKUP_CHECK=true ;;
        -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

resolve_release_url() {
    # Returns the release-asset URL on stdout. Strategy:
    #   1. If --release=TAG was passed, use it as-is.
    #   2. Else, query /releases/latest for the most recent non-prerelease.
    #   3. Else, fall back to the rolling dev prerelease.
    # Step 3 is transitional. Once Phase 4 of the CI refactor introduces the
    # mark_latest gate and a release is promoted, step 2 will succeed and the
    # fallback becomes dead code.
    local tag="$1"
    if [ -n "$tag" ]; then
        printf 'https://github.com/%s/releases/download/%s/%s\n' "$REPO" "$tag" "$ASSET"
        return
    fi
    local latest_tag
    latest_tag=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get("tag_name", ""))
except Exception:
    pass' 2>/dev/null || true)
    if [ -n "$latest_tag" ]; then
        printf 'https://github.com/%s/releases/download/%s/%s\n' "$REPO" "$latest_tag" "$ASSET"
        return
    fi
    printf 'https://github.com/%s/releases/download/%s/%s\n' "$REPO" "$FALLBACK_TAG" "$ASSET"
}

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root" >&2; exit 1; }

# --- Resolve persistent storage location ---
# resolve_persist_dir is duplicated verbatim across install-mig-sysext.sh,
# install-nvidia-sysext.sh, configure-mig.sh, and recover-stock-nvidia.sh.
# Inline (rather than sourced from a sibling file) so each script remains
# a self-contained curl|bash artifact. Keep these copies in sync when
# changing the function.
resolve_persist_dir() {
    PERSIST_DIR=""
    local d p
    local -a existing=() pools=() choices=()
    local header n i

    if [ -n "${PERSIST_PATH:-}" ]; then
        PERSIST_DIR="$PERSIST_PATH"
        return 0
    fi
    if [ -n "${POOL_NAME:-}" ]; then
        PERSIST_DIR="/mnt/${POOL_NAME}/.config/nvidia-gpu"
        return 0
    fi

    for d in /mnt/*/.config/nvidia-gpu; do
        [ -d "$d" ] && existing+=("$d")
    done

    while IFS= read -r p; do
        [ -n "$p" ] && [ "$p" != "boot-pool" ] && pools+=("$p")
    done < <(zpool list -H -o name 2>/dev/null)

    if [ "${#pools[@]}" -eq 0 ]; then
        echo "ERROR: no data pool found (only boot-pool). Pass --pool=NAME or --persist-path=PATH." >&2
        return 1
    fi

    if [ "${#existing[@]}" -eq 1 ]; then
        PERSIST_DIR="${existing[0]}"
        echo "Using existing nvidia-gpu config: $PERSIST_DIR"
        return 0
    fi
    if [ "${#existing[@]}" -eq 0 ] && [ "${#pools[@]}" -eq 1 ]; then
        PERSIST_DIR="/mnt/${pools[0]}/.config/nvidia-gpu"
        echo "Auto-selected pool: ${pools[0]} → $PERSIST_DIR"
        return 0
    fi

    if [ "${#existing[@]}" -gt 1 ]; then
        header="Found existing nvidia-gpu configs on multiple pools:"
        choices=("${existing[@]}")
    else
        header="No existing nvidia-gpu config. Multiple data pools available:"
        for p in "${pools[@]}"; do
            choices+=("/mnt/${p}/.config/nvidia-gpu")
        done
    fi

    # /dev/tty the device node almost always exists; the real question is
    # whether THIS process can open it. CI runners and daemons can't.
    # `: < /dev/tty` forces an open() call and fails fast if no controlling
    # terminal is attached.
    if ! { : </dev/tty; } 2>/dev/null; then
        echo "ERROR: $header" >&2
        echo "       No controlling terminal for prompt. Pass --pool=NAME or --persist-path=PATH." >&2
        return 1
    fi

    echo "$header"
    for i in "${!choices[@]}"; do
        echo "  [$((i+1))] ${choices[$i]}"
    done
    while true; do
        printf "Pick one (1-%d): " "${#choices[@]}"
        read -r n </dev/tty || return 1
        if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#choices[@]}" ]; then
            PERSIST_DIR="${choices[$((n-1))]}"
            echo "Selected: $PERSIST_DIR"
            return 0
        fi
        echo "  Invalid. Enter 1-${#choices[@]}."
    done
}
resolve_persist_dir || exit 1
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
    RELEASE_URL=$(resolve_release_url "$RELEASE_TAG")
    echo "Downloading $RELEASE_URL"
    curl -fL --retry 3 -o "$SYSEXT_SRC" "$RELEASE_URL" \
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

# --- Stage PREINIT helper BEFORE any system mutations ---
# If the download fails (e.g. transient network issue), we want it to fail
# NOW — not after Docker is stopped and nvidia.raw has been swapped, which
# would leave the box half-installed. Fetched from main (durable), not the
# refactor branch (deleted post-merge).
SCRIPT_URL_BASE="https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts"
PREINIT_LOCAL="${PERSIST_DIR}/nvidia-preinit-full.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || true)"
if [ -n "${SCRIPT_DIR:-}" ] && [ -f "${SCRIPT_DIR}/nvidia-preinit-full.sh" ]; then
    cp "${SCRIPT_DIR}/nvidia-preinit-full.sh" "$PREINIT_LOCAL"
    echo "Staged PREINIT helper from local checkout"
else
    echo "Downloading PREINIT helper from ${SCRIPT_URL_BASE}/nvidia-preinit-full.sh"
    curl -fL --retry 3 -o "$PREINIT_LOCAL" "${SCRIPT_URL_BASE}/nvidia-preinit-full.sh" \
        || { echo "ERROR: failed to download PREINIT helper — aborting BEFORE system changes" >&2; exit 1; }
fi
chmod 0755 "$PREINIT_LOCAL"
echo "Staged: $PREINIT_LOCAL"

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

# --- Register the (already-staged) PREINIT helper with midclt ---
echo ""
echo "Registering PREINIT entry..."
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

DO NOT run configure-mig before rebooting — it will refuse with a
driver/library-mismatch error. After the box is back up, the helper
is available locally (bundled in the sysext) at /usr/bin/configure-mig:

  sudo configure-mig                       # interactive prompt
  sudo configure-mig --mig=14,14,14,14     # non-interactive

It writes mig.conf, runs the MIG service, and walks you through
assigning MIG devices to your TrueNAS apps.
EOF

#!/usr/bin/env bash
# Build nvidia-mig.raw — a tiny systemd-sysext containing only the
# MIG setup script + service. Pairs with TrueNAS's bundled nvidia.raw
# (stock drivers). ID=_any so it merges on any TrueNAS host version.
#
# Usage: scripts/build-mig-sysext.sh [--out=PATH] [--displaymodeselector=PATH]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_ROOT}/dist/nvidia-mig.raw"
DMS_PATH=""

for arg in "$@"; do
    case "$arg" in
        --out=*) OUT="${arg#*=}" ;;
        --displaymodeselector=*) DMS_PATH="${arg#*=}" ;;
        -h|--help)
            sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

command -v mksquashfs >/dev/null || { echo "mksquashfs not found (apt install squashfs-tools)" >&2; exit 1; }

STAGE="$(mktemp -d -t nvidia-mig-stage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "${STAGE}/usr/bin" "${STAGE}/usr/lib/systemd/system"

cp "${REPO_ROOT}/sysext/usr/bin/nvidia-mig-setup" "${STAGE}/usr/bin/nvidia-mig-setup"
chmod 0755 "${STAGE}/usr/bin/nvidia-mig-setup"

# Bundle the user-facing config helper so it lives at /usr/bin/configure-mig
# once the sysext is merged — no need to curl the script over the network.
cp "${REPO_ROOT}/scripts/configure-mig.sh" "${STAGE}/usr/bin/configure-mig"
chmod 0755 "${STAGE}/usr/bin/configure-mig"

# Bundle the uninstall script at /usr/bin/uninstall-nvidia-mig so users
# can tear down with `sudo uninstall-nvidia-mig` instead of a curl|bash.
# Bash reads the script into memory at parse time, so the script keeps
# running fine after `systemd-sysext unmerge` removes the merged copy.
cp "${REPO_ROOT}/scripts/uninstall-mig-sysext.sh" "${STAGE}/usr/bin/uninstall-nvidia-mig"
chmod 0755 "${STAGE}/usr/bin/uninstall-nvidia-mig"

cp "${REPO_ROOT}/sysext/usr/lib/systemd/system/nvidia-mig-setup.service" \
   "${STAGE}/usr/lib/systemd/system/nvidia-mig-setup.service"
chmod 0644 "${STAGE}/usr/lib/systemd/system/nvidia-mig-setup.service"

# No multi-user.target.wants symlink — boot activation is via a TrueNAS
# PREINIT entry registered by install-sysext.sh, not via WantedBy.

if [ -n "$DMS_PATH" ]; then
    [ -f "$DMS_PATH" ] || { echo "displaymodeselector not found: $DMS_PATH" >&2; exit 1; }
    cp "$DMS_PATH" "${STAGE}/usr/bin/displaymodeselector"
    chmod 0755 "${STAGE}/usr/bin/displaymodeselector"
fi

mkdir -p "${STAGE}/usr/lib/extension-release.d"
cat > "${STAGE}/usr/lib/extension-release.d/extension-release.nvidia-mig" <<EOF
ID=_any
EXTENSION_RELOAD_MANAGER=1
EOF

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
mksquashfs "$STAGE" "$OUT" -noappend -all-root -comp zstd >/dev/null

( cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )

echo "Built: $OUT"
echo "Size:  $(du -h "$OUT" | cut -f1)"
echo "SHA:   $(cut -d' ' -f1 "${OUT}.sha256")"

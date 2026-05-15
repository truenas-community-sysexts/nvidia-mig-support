#!/usr/bin/env bash
# TrueNAS PREINIT for the full-driver sysext path.
#
# Two responsibilities, both must run before Docker starts:
#   1. Survive TrueNAS updates — /usr gets replaced on update, which wipes
#      our custom nvidia.raw and restores stock. Compare SHAs between
#      live and persistent custom; if they differ, restore the custom.
#   2. Start nvidia-mig-setup.service so MIG instances are recreated.
#
# Registered via midclt initshutdownscript by install-nvidia-sysext.sh.
# Never exits non-zero — must not block boot.

set -uo pipefail

log() { echo "[nvidia-preinit-full] $*"; }

log "Starting (boot: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown))"

SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
LIVE_NVIDIA="${SYSEXT_DIR}/nvidia.raw"

# Find persistent custom nvidia.raw
PERSIST_NVIDIA=""
for f in /mnt/*/.config/nvidia-gpu/nvidia.raw; do
    [ -f "$f" ] && PERSIST_NVIDIA="$f" && break
done

if [ -z "$PERSIST_NVIDIA" ]; then
    log "No persistent custom nvidia.raw found; nothing to restore"
else
    log "Persistent custom: $PERSIST_NVIDIA"
    PERSIST_SHA=$(sha256sum "$PERSIST_NVIDIA" 2>/dev/null | awk '{print $1}')
    LIVE_SHA=""
    [ -f "$LIVE_NVIDIA" ] && LIVE_SHA=$(sha256sum "$LIVE_NVIDIA" 2>/dev/null | awk '{print $1}')

    if [ "$LIVE_SHA" = "$PERSIST_SHA" ]; then
        log "Live nvidia.raw matches persistent custom; no restore needed"
    else
        log "Live nvidia.raw differs from custom (likely after TrueNAS update); restoring"
        log "  live SHA:    ${LIVE_SHA:-<missing>}"
        log "  persist SHA: $PERSIST_SHA"

        systemd-sysext unmerge 2>/dev/null || true

        USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null)
        if [ -n "$USR_DATASET" ]; then
            zfs set readonly=off "$USR_DATASET" \
                || { log "ERROR: failed to set $USR_DATASET writable"; exit 0; }
            cp "$PERSIST_NVIDIA" "$LIVE_NVIDIA" \
                || { log "ERROR: failed to copy custom nvidia.raw"; zfs set readonly=on "$USR_DATASET"; exit 0; }
            zfs set readonly=on "$USR_DATASET" || log "WARN: failed to restore readonly"
            log "Restored custom nvidia.raw"
        fi

        mkdir -p /etc/extensions
        ln -sf "$LIVE_NVIDIA" /etc/extensions/nvidia.raw
        systemd-sysext merge 2>/dev/null || log "WARN: sysext merge failed"
        systemctl daemon-reload 2>/dev/null || true
    fi
fi

# --- Start the bundled MIG service (idempotent) ---
if [ -x /usr/bin/nvidia-mig-setup ]; then
    log "Starting nvidia-mig-setup.service"
    systemctl start nvidia-mig-setup.service \
        || log "WARN: systemctl start nvidia-mig-setup.service failed"
else
    log "/usr/bin/nvidia-mig-setup not present; skipping MIG service start"
fi

log "Done"
exit 0

#!/usr/bin/env bash
# TrueNAS PREINIT for the MIG sysext — self-heals the activation after a
# TrueNAS update, then runs the MIG setup service.
#
# Why this exists: a major TrueNAS upgrade replaces /usr AND /etc, which wipes
# the /etc/extensions/nvidia-mig.raw activation symlink and the merged sysext
# content. The persistent nvidia-mig.raw and mig.conf survive on the data pool,
# but nothing re-merges the sysext on boot — so MIG silently stays off until the
# user re-runs install-mig-sysext.sh. This script closes that gap.
#
# It lives on the data pool (staged by install-mig-sysext.sh) and is registered
# by its on-pool path via midclt initshutdownscript, so it survives the wipe —
# the same reason the driver's nvidia-preinit-driver.sh lives there. It replaces
# the older "systemctl start nvidia-mig-setup.service" PREINIT, which assumed the
# sysext was already merged (it isn't, after a major upgrade).
#
# Ordering: runs before docker (the nvidia-mig-setup.service it starts declares
# Before=docker.service, and that service waits up to 60s for the NVIDIA driver
# to become responsive — covering the concurrent driver-restore race).
#
# Never exits non-zero — must not block boot. All errors are logged and the
# script continues. Logs to stdout (journalctl -u <init-shutdown-script>) and
# syslog tagged `nvidia-mig-preinit` (journalctl -b -t nvidia-mig-preinit).

set -uo pipefail

log() {
    echo "[nvidia-mig-preinit] $*"
    logger -t nvidia-mig-preinit "$*" 2>/dev/null || true
}

log "Starting (boot: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown))"

# ── Locate the persistent MIG sysext on the data pool ────────────────────────
PERSIST_MIG=""
for f in /mnt/*/.config/nvidia-gpu/nvidia-mig.raw; do
    [ -f "$f" ] && PERSIST_MIG="$f" && break
done
if [ -z "$PERSIST_MIG" ]; then
    log "No persistent nvidia-mig.raw under /mnt/*/.config/nvidia-gpu/; nothing to restore"
    log "Done"
    exit 0
fi
log "Persistent MIG sysext: $PERSIST_MIG"

# ── Re-create the activation symlink if a TrueNAS update wiped it ─────────────
# systemd-sysext only merges what it finds under /etc/extensions (or
# /run/extensions). A major upgrade wipes /etc, taking the symlink with it.
LINK="/etc/extensions/nvidia-mig.raw"
NEED_MERGE=false
if [ -L "$LINK" ] && \
   [ "$(readlink -f "$LINK" 2>/dev/null)" = "$(readlink -f "$PERSIST_MIG" 2>/dev/null)" ]; then
    log "Activation symlink present: $LINK"
else
    log "Activation symlink missing or stale; recreating $LINK -> $PERSIST_MIG"
    mkdir -p /etc/extensions
    ln -sf "$PERSIST_MIG" "$LINK"
    NEED_MERGE=true
fi

# Merge if nvidia-mig isn't currently merged (covers the symlink-was-present-but-
# not-merged case too).
if ! systemd-sysext list 2>/dev/null | awk '{print $1}' | grep -qx nvidia-mig; then
    NEED_MERGE=true
fi

if $NEED_MERGE; then
    # `merge` errors when extensions are already merged ("use refresh"); fall
    # back to `refresh` (unmerge+merge) so the freshly-linked nvidia-mig is
    # picked up whether or not the driver sysext was already merged.
    if ! systemd-sysext merge >/dev/null 2>&1; then
        systemd-sysext refresh >/dev/null 2>&1 \
            || log "WARN: systemd-sysext merge/refresh failed (check 'systemd-sysext status')"
    fi
    systemctl daemon-reload 2>/dev/null || true
fi

# ── Hand off to the setup service ────────────────────────────────────────────
# It waits for the NVIDIA driver, enables MIG mode, recreates instances from the
# persisted mig.conf, and remaps app GPU UUIDs. It is bounded and never blocks
# boot.
if ! systemctl cat nvidia-mig-setup.service >/dev/null 2>&1; then
    log "WARN: nvidia-mig-setup.service not visible after merge — the MIG sysext may not be merged"
    log "Done"
    exit 0
fi

log "Starting nvidia-mig-setup.service"
systemctl start nvidia-mig-setup.service 2>/dev/null \
    || log "WARN: failed to start nvidia-mig-setup.service (see 'journalctl -u nvidia-mig-setup.service -b')"

log "Done"
exit 0

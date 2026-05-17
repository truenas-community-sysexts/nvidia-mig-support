#!/usr/bin/env bash
# Uninstall the nvidia-mig.raw sysext, and (if present) revert the custom
# nvidia.raw driver back to TrueNAS's stock. Auto-detects state:
#
#   - MIG only           → remove MIG sysext + PREINIT entry; stock driver
#                          untouched; no reboot.
#   - MIG + custom driver → revert driver to stock + remove MIG sysext +
#                          both PREINIT entries; REBOOT REQUIRED (kernel
#                          modules need to reload at the stock version).
#   - Neither            → print "nothing to do" and exit cleanly.
#
# This script is bundled into nvidia-mig.raw as /usr/bin/uninstall-nvidia-mig
# so users can run `sudo uninstall-nvidia-mig` without curl|bash. When
# invoked from the bundled location, `systemd-sysext unmerge` below will
# remove the merged copy of this very script mid-execution. That's safe —
# bash reads the script into memory at parse time. Do NOT add code below
# the unmerge that exec()s a binary or sources a file from the bundled
# sysext; only stable system binaries (cp, rm, systemctl, midclt, python3,
# zfs) are safe to use after unmerge.
#
# Usage:
#   sudo ./uninstall-mig-sysext.sh                     # auto-detect + undo
#   sudo ./uninstall-mig-sysext.sh --keep-persist      # don't remove files
#                                                       from /mnt/<pool>/.config/nvidia-gpu/
#   sudo ./uninstall-mig-sysext.sh --skip-backup-check # allow driver revert
#                                                       without nvidia-original.raw

set -euo pipefail

KEEP_PERSIST=false
SKIP_BACKUP_CHECK=false
for arg in "$@"; do
    case "$arg" in
        --keep-persist) KEEP_PERSIST=true ;;
        --skip-backup-check) SKIP_BACKUP_CHECK=true ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

[ "$(id -u 2>/dev/null)" = "0" ] || { echo "ERROR: must run as root" >&2; exit 1; }

SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
LIVE_NVIDIA="${SYSEXT_DIR}/nvidia.raw"

# ─────────────────────────────────────────────────────────────────────────
# State detection — what's actually installed?
# ─────────────────────────────────────────────────────────────────────────
# Driver signals: persistent backup of custom nvidia.raw, or the staged
#   driver PREINIT helper (both new `nvidia-preinit-driver.sh` and legacy
#   `nvidia-preinit-full.sh` names).
# MIG signals: persistent nvidia-mig.raw, or the /etc/extensions symlink.
PERSIST_DIR=""
ORIGINAL=""
HAS_MIG=false
HAS_DRIVER=false
for d in /mnt/*/.config/nvidia-gpu; do
    [ -d "$d" ] || continue
    PERSIST_DIR="$d"
    [ -f "$d/nvidia-original.raw" ] && ORIGINAL="$d/nvidia-original.raw"
    if [ -f "$d/nvidia.raw" ] \
       || [ -x "$d/nvidia-preinit-driver.sh" ] \
       || [ -x "$d/nvidia-preinit-full.sh" ]; then
        HAS_DRIVER=true
    fi
    [ -f "$d/nvidia-mig.raw" ] && HAS_MIG=true
    break
done
# /etc/extensions symlink is a secondary MIG signal — covers the case
# where someone already removed the persistent copy.
if [ -L /etc/extensions/nvidia-mig.raw ] || [ -e /etc/extensions/nvidia-mig.raw ]; then
    HAS_MIG=true
fi

echo "=== Uninstall plan ==="
echo "  Persist dir:             ${PERSIST_DIR:-<none found>}"
echo "  MIG sysext installed:    $HAS_MIG"
echo "  Custom driver installed: $HAS_DRIVER"
echo ""

if ! $HAS_MIG && ! $HAS_DRIVER; then
    echo "Nothing to uninstall — neither MIG sysext nor custom driver detected."
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────
# Pre-flight: driver revert needs a stock backup on hand.
# ─────────────────────────────────────────────────────────────────────────
if $HAS_DRIVER && [ -z "$ORIGINAL" ] && ! $SKIP_BACKUP_CHECK; then
    cat >&2 <<EOF
ERROR: nvidia-original.raw backup not found in /mnt/*/.config/nvidia-gpu/.
       Refusing to revert the driver without a stock copy on hand.
       Run scripts/recover-stock-nvidia.sh first (downloads + extracts
       stock nvidia.raw from the official TrueNAS .update). Or pass
       --skip-backup-check if you accept the risk.
EOF
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────
# Stop app services + wait for GPU drain — only when the driver is being
# reverted (live-swapping nvidia.raw must happen with no GPU consumers).
# ─────────────────────────────────────────────────────────────────────────
if $HAS_DRIVER; then
    echo "Stopping app services..."
    midclt call docker.update '{"nvidia": false}' >/dev/null \
        || echo "WARN: app services API call (docker.update) failed — continuing"
    if [ -x /usr/bin/nvidia-smi ]; then
        printf "  Waiting for GPU to be released... 0s/120s"
        for attempt in $(seq 1 24); do
            N=$(/usr/bin/nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l || echo 0)
            if [ "${N:-0}" -eq 0 ]; then
                printf "\r  GPU released                                            \n"
                break
            fi
            printf "\r  Waiting for %d GPU process(es)... %ds/120s" "$N" "$((attempt * 5))"
            sleep 5
        done
        [ "${attempt:-0}" -eq 24 ] && echo ""
    fi
fi

# ─────────────────────────────────────────────────────────────────────────
# Single unmerge → mutations → single re-merge. Cheaper than separate
# cycles for the driver and MIG paths and avoids leaving the system in
# a half-merged state between them.
# ─────────────────────────────────────────────────────────────────────────
echo "Unmerging sysext..."
systemd-sysext unmerge

# --- Revert driver to stock (if installed) ---
if $HAS_DRIVER; then
    if [ -n "$ORIGINAL" ]; then
        echo "Restoring stock nvidia.raw from $ORIGINAL"
        USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null)
        zfs set readonly=off "$USR_DATASET"
        cp "$ORIGINAL" "$LIVE_NVIDIA"
        [ -f "${LIVE_NVIDIA}.bak" ] && rm -f "${LIVE_NVIDIA}.bak" 2>/dev/null || true
        zfs set readonly=on "$USR_DATASET"
        mkdir -p /etc/extensions
        ln -sf "$LIVE_NVIDIA" /etc/extensions/nvidia.raw
    else
        echo "WARN: no nvidia-original.raw backup; leaving live nvidia.raw in place"
        echo "      (run recover-stock-nvidia.sh later to fetch one)"
    fi
fi

# --- Remove MIG symlink (if present) ---
if $HAS_MIG; then
    if [ -L /etc/extensions/nvidia-mig.raw ] || [ -e /etc/extensions/nvidia-mig.raw ]; then
        rm -f /etc/extensions/nvidia-mig.raw
        echo "Removed /etc/extensions/nvidia-mig.raw"
    fi
fi

echo "Re-merging sysext..."
systemd-sysext merge
systemctl daemon-reload

# ─────────────────────────────────────────────────────────────────────────
# Deregister PREINIT entries — matched independently so we only touch what
# we actually installed.
# ─────────────────────────────────────────────────────────────────────────
if $HAS_DRIVER; then
    DRIVER_PREINIT_ID=$(midclt call initshutdownscript.query 2>/dev/null \
        | python3 -c "
import sys, json
try:
    for s in json.load(sys.stdin):
        cmd = (s.get('command') or '') + ' ' + (s.get('script') or '')
        if 'nvidia-preinit-driver' in cmd or 'nvidia-preinit-full' in cmd:
            print(s['id'], end=''); break
except Exception:
    pass
" 2>/dev/null)
    if [ -n "$DRIVER_PREINIT_ID" ]; then
        midclt call initshutdownscript.delete "$DRIVER_PREINIT_ID" >/dev/null 2>&1 \
            && echo "Deregistered driver PREINIT entry (id $DRIVER_PREINIT_ID)" \
            || echo "WARN: deregister driver PREINIT failed"
    else
        echo "No driver PREINIT entry found"
    fi
fi

if $HAS_MIG; then
    # Match `nvidia-mig-setup` but explicitly exclude entries that also
    # contain 'preinit' (the driver PREINIT command happens to reference
    # the MIG service name indirectly in some legacy installs).
    MIG_PREINIT_ID=$(midclt call initshutdownscript.query 2>/dev/null \
        | python3 -c "
import sys, json
try:
    for s in json.load(sys.stdin):
        cmd = (s.get('command') or '') + ' ' + (s.get('script') or '')
        if 'nvidia-mig-setup' in cmd and 'preinit' not in cmd:
            print(s['id'], end=''); break
except Exception:
    pass
" 2>/dev/null)
    if [ -n "$MIG_PREINIT_ID" ]; then
        midclt call initshutdownscript.delete "$MIG_PREINIT_ID" >/dev/null 2>&1 \
            && echo "Deregistered MIG PREINIT entry (id $MIG_PREINIT_ID)" \
            || echo "WARN: deregister MIG PREINIT failed"
    else
        echo "No MIG PREINIT entry found"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────
# Cleanup persistent storage. nvidia-original.raw is always kept — it's
# expensive to re-fetch and the user may want to re-install later.
# ─────────────────────────────────────────────────────────────────────────
if ! $KEEP_PERSIST && [ -n "$PERSIST_DIR" ]; then
    if $HAS_DRIVER; then
        rm -f "$PERSIST_DIR/nvidia.raw" \
              "$PERSIST_DIR/nvidia-preinit-driver.sh" \
              "$PERSIST_DIR/nvidia-preinit-full.sh"
        echo "Removed custom nvidia.raw and driver PREINIT helper from $PERSIST_DIR"
    fi
    if $HAS_MIG; then
        rm -f "$PERSIST_DIR/nvidia-mig.raw"
        echo "Removed $PERSIST_DIR/nvidia-mig.raw"
    fi
    echo "  (nvidia-original.raw kept — pass --keep-persist to retain everything)"
fi

# ─────────────────────────────────────────────────────────────────────────
# Verification + mode-appropriate finishing banner.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Verification ==="
systemd-sysext status || true

# NOTE: we intentionally do NOT attempt to re-enable docker.config.nvidia
# here. TrueNAS resets it during boot and silently rejects re-enable for
# the first ~5–10 min while the docker subsystem initializes. So any
# pre-reboot set is futile in the driver-revert case (gets reset by
# the upcoming reboot); we surface the post-reboot instructions
# explicitly instead. See scripts/install-mig-sysext.sh for the long
# comment explaining the boot-window behavior.

if $HAS_DRIVER; then
    cat <<EOF

=== Uninstall complete — REBOOT REQUIRED ===

Kernel modules currently loaded are still the custom driver's. After
reboot, modules will load fresh from the stock sysext and match the
userspace libs (no more NVML mismatch).

Run: sudo reboot

>>> AFTER REBOOT — give it 5–10 minutes before flipping the Apps toggle <<<

TrueNAS resets the Apps' NVIDIA toggle to OFF during boot and silently
rejects re-enable attempts for the first ~5–10 minutes while the docker
subsystem initializes. App services were turned off during uninstall so
this state continues until you re-enable.

Once the box has been up for ~10 minutes, re-enable the toggle:

  sudo midclt call docker.update '{"nvidia": true}'

  -- or --

  Toggle the "Use NVIDIA GPU" switch on under TrueNAS UI →
  Apps → Settings → 'Use NVIDIA GPU' → Save

Verify it stuck (should print "nvidia = True"):

  sudo midclt call docker.config | python3 -c "import sys,json; print('nvidia =', json.load(sys.stdin).get('nvidia'))"
EOF
else
    cat <<EOF

=== Uninstall complete ===

No reboot needed. The stock NVIDIA driver was never touched, so the
running modules already match the userspace libs.
EOF
fi

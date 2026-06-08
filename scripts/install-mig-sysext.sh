#!/usr/bin/env bash
# Install the nvidia-mig sysext on TrueNAS.
#
# Installs nvidia-mig.raw (a lightweight MIG tooling + service sysext) on top
# of whatever NVIDIA driver is already present — it does NOT touch /usr or the
# driver. No reboot required.
#
#   sudo ./install-mig-sysext.sh
#
# The driver is handled by a separate project. To run a newer NVIDIA driver
# than TrueNAS ships (or any specific/legacy/custom one), install it first via
# nvidia-driver-support:
#   https://github.com/truenas-community-sysexts/nvidia-driver-support
# Then run this to layer MIG on top.
#
# MIG support requires a driver new enough to expose it. Anything at or above
# the driver shipped in the latest TrueNAS 25 (major >= 570) is treated as
# MIG-capable; older drivers are refused unless --force.
#
# Usage:
#   sudo ./install-mig-sysext.sh                              # install MIG
#   sudo ./install-mig-sysext.sh --check                      # status probe
#   sudo ./install-mig-sysext.sh --dry-run                    # validate, skip mutations
#   sudo ./install-mig-sysext.sh --release=v42                # pin a release tag
#   sudo ./install-mig-sysext.sh --sysext=/tmp/nvidia-mig.raw # local MIG sysext
#   sudo ./install-mig-sysext.sh --pool=fast
#
# Flags:
#   --sysext=PATH         Local nvidia-mig.raw (skips the download)
#   --release=TAG         Download nvidia-mig.raw from this exact release tag
#                         (default: the repo's latest release)
#   --pool=NAME           ZFS pool for persistent storage
#   --persist-path=PATH   Exact directory for persistent storage
#   --force               Bypass the MIG driver-support pre-flight (install
#                         even when the running driver is below major 570)
#   --check               Read-only probe of an existing install. Reports the
#                         state of: NVIDIA driver sysext, MIG sysext
#                         (file/symlink/merge), persist dir, PREINIT entry,
#                         service. Exits 1 on failure.
#   --dry-run             Validate URLs + downloaded sysext but skip every
#                         mutation. Each skipped step is logged as
#                         `[dry-run] would: ...`. Mutually exclusive with --check.
#   -h, --help            Show this help and exit
#
# Pool selection priority: --persist-path > --pool > existing config dir >
# only data pool > interactive prompt (multi-pool) > error (no tty + ambiguous).

set -euo pipefail

REPO="truenas-community-sysexts/nvidia-mig-support"
MIG_ASSET="nvidia-mig.raw"
SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
LIVE_NVIDIA="${SYSEXT_DIR}/nvidia.raw"
STOCK_NVIDIA="$LIVE_NVIDIA"
MIN_DRIVER_MAJOR=570

MIG_SRC=""
RELEASE_TAG=""
POOL_NAME=""
PERSIST_PATH=""
FORCE=false
CHECK_MODE=false
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --sysext=*) MIG_SRC="${arg#*=}" ;;
        --release=*) RELEASE_TAG="${arg#*=}" ;;
        --pool=*) POOL_NAME="${arg#*=}" ;;
        --persist-path=*) PERSIST_PATH="${arg#*=}" ;;
        --force) FORCE=true ;;
        --check) CHECK_MODE=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if $CHECK_MODE && $DRY_RUN; then
    echo "ERROR: --check and --dry-run are mutually exclusive" >&2
    exit 2
fi

# Run a command in real mode; print `[dry-run] would: …` in dry-run mode.
# For redirections or compound shell logic, gate manually with
# `if $DRY_RUN; then ... else ... fi`.
#
# The dry-run message goes to stderr so helpers whose stdout is captured don't
# end up with would-be log lines bleeding into their return value.
if_real() {
    if $DRY_RUN; then
        printf '[dry-run] would: %s\n' "$*" >&2
    else
        "$@"
    fi
}

# Read the driver version embedded in a sysext .raw via libnvidia-ml.so.X.Y.Z.
read_raw_driver_version() {
    [ -f "$1" ] || return 0
    unsquashfs -l "$1" 2>/dev/null \
        | grep -oE 'libnvidia-ml\.so\.[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1 \
        | sed 's/^libnvidia-ml\.so\.//' || true
}

# --- Resolve persistent storage location ---
# resolve_persist_dir is duplicated verbatim across install-mig-sysext.sh,
# configure-mig.sh, and uninstall-mig-sysext.sh. Inline (rather than sourced
# from a sibling file) so each script remains a self-contained curl|bash
# artifact. Keep these copies in sync when changing the function.
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

# --- Read-only check mode ---
do_check() {
    local pass=0 warn=0 fail=0
    local mark_ok="OK" mark_warn="--" mark_fail="!!"
    local -a status_lines=() hint_lines=()

    record_pass() { status_lines+=("  [${mark_ok}] $1"); pass=$((pass+1)); }
    record_warn() {
        status_lines+=("  [${mark_warn}] $1"); warn=$((warn+1))
        [ -n "${2:-}" ] && hint_lines+=("       → $2")
    }
    record_fail() {
        status_lines+=("  [${mark_fail}] $1"); fail=$((fail+1))
        [ -n "${2:-}" ] && hint_lines+=("       → $2")
    }

    echo "=== install-mig-sysext status ==="
    echo ""

    # NVIDIA driver sysext merged — MIG layers on it; without it nothing works.
    if systemd-sysext list 2>/dev/null | awk '{print $1}' | grep -qx nvidia; then
        record_pass "Sysext 'nvidia' merged into /usr"
    else
        record_fail "Sysext 'nvidia' not merged" \
            "MIG sysext layers on the driver — without it nothing works"
    fi

    # Driver version: gate on running/stock driver >= MIN_DRIVER_MAJOR.
    local sysext_drv=""
    if command -v unsquashfs >/dev/null 2>&1 && [ -f "$LIVE_NVIDIA" ]; then
        sysext_drv=$(read_raw_driver_version "$LIVE_NVIDIA")
    fi
    if [ -n "$sysext_drv" ]; then
        local drv_major=${sysext_drv%%.*}
        if [ "$drv_major" -ge "$MIN_DRIVER_MAJOR" ]; then
            record_pass "Driver ${sysext_drv} >= MIG minimum ${MIN_DRIVER_MAJOR}.x"
        else
            record_fail "Driver ${sysext_drv} < ${MIN_DRIVER_MAJOR}.x (MIG support starts at ${MIN_DRIVER_MAJOR}.x)" \
                "install a newer driver via the nvidia-driver-support repo"
        fi
    else
        record_warn "Could not detect driver version in ${LIVE_NVIDIA}" \
            "unsquashfs missing or sysext file unreadable"
    fi

    # Kernel module loaded.
    if lsmod 2>/dev/null | awk '{print $1}' | grep -qx nvidia; then
        record_pass "Kernel module 'nvidia' loaded"
    else
        record_fail "Kernel module 'nvidia' not loaded" \
            "reboot — a fresh install can't load a new module while the old one is in use"
    fi

    # MIG sysext file on persist dir
    if [ -n "${PERSIST_DIR:-}" ] && [ -f "${PERSIST_DIR}/nvidia-mig.raw" ]; then
        record_pass "MIG sysext present at ${PERSIST_DIR}/nvidia-mig.raw"
    elif [ -n "${PERSIST_DIR:-}" ]; then
        record_fail "MIG sysext missing at ${PERSIST_DIR}/nvidia-mig.raw" \
            "re-run install-mig-sysext.sh"
    fi

    # /etc/extensions/ symlink for MIG
    if [ -L /etc/extensions/nvidia-mig.raw ]; then
        local target
        target=$(readlink -f /etc/extensions/nvidia-mig.raw 2>/dev/null || true)
        if [ -n "$target" ] && [ -f "$target" ]; then
            record_pass "/etc/extensions/nvidia-mig.raw symlink resolves to ${target}"
        else
            record_fail "/etc/extensions/nvidia-mig.raw symlink dangling (target missing)" \
                "re-run install — persistent copy was removed"
        fi
    elif [ -f /etc/extensions/nvidia-mig.raw ]; then
        record_warn "/etc/extensions/nvidia-mig.raw is a regular file, not a symlink" \
            "install creates a symlink to the persistent copy — re-run install"
    else
        record_fail "/etc/extensions/nvidia-mig.raw missing" \
            "re-run install"
    fi

    # MIG sysext merged
    if systemd-sysext list 2>/dev/null | awk '{print $1}' | grep -qx nvidia-mig; then
        record_pass "MIG sysext 'nvidia-mig' merged into /usr"
    else
        record_fail "MIG sysext 'nvidia-mig' not currently merged" \
            "check 'systemctl status systemd-sysext' or re-run install"
    fi

    # Persist dir
    if [ -n "${PERSIST_DIR:-}" ] && [ -d "${PERSIST_DIR}" ]; then
        record_pass "Persistent config at ${PERSIST_DIR}"
    else
        record_fail "No persistent config under /mnt/*/.config/nvidia-gpu/" \
            "re-run install with --pool=NAME or --persist-path=PATH"
    fi

    # mig.conf (optional — only present if user ran configure-mig)
    if [ -n "${PERSIST_DIR:-}" ] && [ -f "${PERSIST_DIR}/mig.conf" ]; then
        record_pass "MIG profile config at ${PERSIST_DIR}/mig.conf"
    elif [ -n "${PERSIST_DIR:-}" ]; then
        record_warn "No ${PERSIST_DIR}/mig.conf yet" \
            "run 'sudo configure-mig' to set up MIG profiles"
    fi

    # PREINIT entry: nvidia-mig-setup service start.
    if command -v midclt >/dev/null 2>&1; then
        local mig_entry
        mig_entry=$(midclt call initshutdownscript.query 2>/dev/null \
            | python3 -c "
import sys, json
try:
    for s in json.load(sys.stdin):
        haystack = (s.get('command') or '') + ' ' + (s.get('script') or '')
        if 'nvidia-mig-setup' in haystack and 'preinit' not in haystack:
            print(f\"{s.get('when','?')}|{s.get('enabled','?')}\")
            break
except Exception:
    pass" 2>/dev/null || true)
        if [ -z "$mig_entry" ]; then
            record_fail "No PREINIT entry registered for nvidia-mig-setup.service" \
                "re-run install — middleware registration missing"
        else
            local when enabled
            IFS='|' read -r when enabled <<<"$mig_entry"
            if [ "$when" = "PREINIT" ] && [ "$enabled" = "True" ]; then
                record_pass "PREINIT 'nvidia-mig-setup' registered (PREINIT, enabled)"
            else
                record_warn "PREINIT entry for nvidia-mig-setup state: when=${when}, enabled=${enabled}" \
                    "re-run install to normalize"
            fi
        fi
    else
        record_warn "midclt not available — skipping middleware check" \
            "this script must run on TrueNAS SCALE"
    fi

    # nvidia-mig-setup.service status
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files nvidia-mig-setup.service >/dev/null 2>&1; then
        local svc_state
        svc_state=$(systemctl is-active nvidia-mig-setup.service 2>/dev/null || true)
        case "$svc_state" in
            active)
                record_pass "nvidia-mig-setup.service active"
                ;;
            inactive)
                record_warn "nvidia-mig-setup.service inactive" \
                    "service is oneshot — inactive after successful run is normal; check 'systemctl status' for details"
                ;;
            failed)
                record_fail "nvidia-mig-setup.service failed" \
                    "run 'journalctl -u nvidia-mig-setup.service -b' to investigate"
                ;;
            *)
                record_warn "nvidia-mig-setup.service state: ${svc_state:-unknown}"
                ;;
        esac
    else
        record_warn "nvidia-mig-setup.service not found" \
            "MIG sysext provides this unit — it may not be merged"
    fi

    # configure-mig command
    if command -v configure-mig >/dev/null 2>&1; then
        record_pass "configure-mig command available (bundled in nvidia-mig.raw)"
    else
        record_warn "configure-mig command not found in PATH" \
            "nvidia-mig.raw may not be currently merged"
    fi

    # Apps' NVIDIA toggle (docker.config.nvidia). Empirically the apps
    # subsystem doesn't accept this toggle for some time after boot —
    # we don't know why, but it typically resolves within ~10 min.
    # configure-mig handles the wait automatically; this check just
    # surfaces the current state as a warn (not a fail) so the user
    # knows whether they need to do anything before running configure-mig.
    if command -v midclt >/dev/null 2>&1; then
        local nvidia_toggle uptime_s
        nvidia_toggle=$(midclt call docker.config 2>/dev/null \
            | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('true' if d.get('nvidia') else 'false')
except Exception:
    pass" 2>/dev/null)
        uptime_s=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
        if [ "$nvidia_toggle" = "true" ]; then
            record_pass "Apps' NVIDIA toggle is on (docker.config.nvidia=true)"
        elif [ "$nvidia_toggle" = "false" ]; then
            if [ "${uptime_s:-0}" -lt 600 ]; then
                record_warn "Apps' NVIDIA toggle is off (uptime $((uptime_s / 60)) min — subsystem may not accept writes yet)" \
                    "configure-mig will wait for it; or set manually: sudo midclt call docker.update {\"nvidia\": true}"
            else
                record_warn "Apps' NVIDIA toggle is off (docker.config.nvidia=false)" \
                    "configure-mig will set it; or run 'sudo midclt call docker.update {\"nvidia\": true}' manually"
            fi
        else
            record_warn "Could not read docker.config.nvidia" \
                "midclt query returned unexpected output"
        fi
    fi

    echo "Checks: ${pass} pass, ${warn} warn, ${fail} fail"
    echo ""
    printf '%s\n' "${status_lines[@]}"
    if [ "${#hint_lines[@]}" -gt 0 ]; then
        echo ""
        printf '%s\n' "${hint_lines[@]}"
    fi
    [ "$fail" -eq 0 ]
}

# Resolve persist dir up front. In --check mode, swallow errors and continue
# with PERSIST_DIR="" so the check can still report all other items.
if $CHECK_MODE; then
    resolve_persist_dir 2>/dev/null || PERSIST_DIR=""
    do_check
    exit $?
fi

# ─────────────────────────────────────────────────────────────────────────
# Install path begins here.
# ─────────────────────────────────────────────────────────────────────────

command -v unsquashfs >/dev/null 2>&1 || { echo "ERROR: unsquashfs not found (squashfs-tools)" >&2; exit 1; }

[ "$(id -u 2>/dev/null)" = "0" ] || { echo "ERROR: must run as root" >&2; exit 1; }

# --- Pre-flight: driver present and new enough for MIG ---
# MIG layers on the running NVIDIA driver. We don't install or swap it — that's
# the nvidia-driver-support project's job — but MIG only works on a driver new
# enough to expose it (>= the one in the latest TrueNAS 25, major >= 570).
if [ ! -f "$STOCK_NVIDIA" ]; then
    echo "ERROR: $STOCK_NVIDIA not found — TrueNAS doesn't appear to have an NVIDIA sysext." >&2
    echo "       The MIG sysext depends on an NVIDIA driver being present." >&2
    exit 1
fi

DRIVER_VER=$(read_raw_driver_version "$STOCK_NVIDIA")
if [ -z "$DRIVER_VER" ]; then
    echo "WARN: could not detect driver version inside $STOCK_NVIDIA — proceeding (no support gate)."
else
    DRIVER_MAJOR=${DRIVER_VER%%.*}
    echo "NVIDIA driver in $STOCK_NVIDIA: $DRIVER_VER"
    if [ "$DRIVER_MAJOR" -lt "$MIN_DRIVER_MAJOR" ]; then
        echo "" >&2
        echo "ERROR: driver $DRIVER_VER is below the MIG-supported minimum $MIN_DRIVER_MAJOR.x." >&2
        echo "       MIG is only supported on $MIN_DRIVER_MAJOR.x and above (the driver shipped" >&2
        echo "       in the latest TrueNAS 25 and newer)." >&2
        echo "       Install a newer driver first via nvidia-driver-support:" >&2
        echo "         https://github.com/${REPO%/*}/nvidia-driver-support" >&2
        echo "       Or pass --force to install MIG anyway (it likely won't configure)." >&2
        $FORCE || exit 1
        echo "       --force given, continuing anyway." >&2
    fi
fi

# --- Resolve persist dir + ensure it exists ---
# Validate --persist-path shape: nvidia-mig-setup only finds its config under
# /mnt/*/.config/nvidia-gpu, so any other location silently breaks MIG
# persistence after a reboot or TrueNAS update. Refuse early. --pool resolves
# to this shape automatically.
if [ -n "$PERSIST_PATH" ]; then
    PERSIST_PATH_REAL=$(realpath -m "$PERSIST_PATH" 2>/dev/null || echo "$PERSIST_PATH")
    if [[ ! "$PERSIST_PATH_REAL" =~ ^/mnt/[^/]+/\.config/nvidia-gpu/?$ ]]; then
        echo "ERROR: --persist-path must be /mnt/<pool>/.config/nvidia-gpu (got: ${PERSIST_PATH})" >&2
        echo "  MIG persistence only scans /mnt/*/.config/nvidia-gpu," >&2
        echo "  so any other location silently breaks it after a reboot or update." >&2
        echo "  Pass --pool=<name> instead (it resolves to /mnt/<name>/.config/nvidia-gpu)." >&2
        exit 2
    fi
fi
resolve_persist_dir || exit 1
if_real mkdir -p "$PERSIST_DIR"

# --- Fetch nvidia-mig.raw if not provided ---
# No release tag → the repo's latest release via the redirecting download URL.
# --release=TAG → that exact tag.
MIG_TMP=""
if [ -z "$MIG_SRC" ]; then
    MIG_TMP=$(mktemp -t nvidia-mig.raw.XXXXXX)
    if [ -n "$RELEASE_TAG" ]; then
        MIG_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${MIG_ASSET}"
    else
        MIG_URL="https://github.com/${REPO}/releases/latest/download/${MIG_ASSET}"
    fi
    echo "Downloading ${MIG_URL}"
    curl -fL --retry 3 -o "$MIG_TMP" "$MIG_URL" \
        || { echo "ERROR: failed to download nvidia-mig.raw" >&2; rm -f "$MIG_TMP"; exit 1; }
    MIG_SRC="$MIG_TMP"
fi
[ -f "$MIG_SRC" ] || { echo "ERROR: MIG sysext source not found: $MIG_SRC" >&2; exit 1; }

# Single cleanup trap for any tempfile we created.
cleanup_tmp() {
    [ -n "${MIG_TMP:-}" ] && rm -f "$MIG_TMP"
}
trap cleanup_tmp EXIT INT TERM

# --- Sanity-check the MIG sysext contents ---
# Buffer the listing before grep -q — piping unsquashfs into `grep -q`
# SIGPIPEs the producer and trips pipefail's exit propagation.
if ! MIG_LISTING=$(unsquashfs -l "$MIG_SRC" 2>/dev/null); then
    echo "ERROR: unsquashfs -l failed on $MIG_SRC" >&2
    exit 1
fi
if ! printf '%s\n' "$MIG_LISTING" | grep -q 'extension-release.nvidia-mig'; then
    echo "ERROR: $MIG_SRC does not contain extension-release.nvidia-mig" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────
# Mutations begin here. Order:
#   1. Stage nvidia-mig.raw in PERSIST_DIR (safe — no system effect yet).
#   2. Symlink both sysexts into /etc/extensions, unmerge + re-merge.
#   3. Register the MIG service PREINIT.
# ─────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Install plan ==="
echo "Persist dir:    $PERSIST_DIR"
echo "MIG sysext:     $MIG_SRC"
echo ""

# Copy the MIG sysext to persistent storage so TrueNAS updates can be survived.
if_real cp "$MIG_SRC" "${PERSIST_DIR}/nvidia-mig.raw"
$DRY_RUN || echo "Copied MIG sysext to ${PERSIST_DIR}/nvidia-mig.raw"

# Ensure /etc/extensions/ symlinks for both sysexts. nvidia.raw is the driver
# already present (stock or installed via nvidia-driver-support); nvidia-mig.raw
# points at the persistent copy.
echo "Ensuring /etc/extensions/ symlinks..."
if_real mkdir -p /etc/extensions
if_real ln -sf "$LIVE_NVIDIA" /etc/extensions/nvidia.raw
if_real ln -sf "${PERSIST_DIR}/nvidia-mig.raw" /etc/extensions/nvidia-mig.raw

# Unmerge + re-merge so the refreshed nvidia-mig.raw is picked up. The driver
# sysext is left untouched (no /usr write, no driver swap).
echo "Unmerging sysext..."
if_real systemd-sysext unmerge
echo "Re-merging sysext..."
if_real systemd-sysext merge
if_real systemctl daemon-reload

# ─────────────────────────────────────────────────────────────────────────
# Register the MIG service PREINIT via midclt.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "Registering PREINIT entry..."

# Idempotent register-or-update for a midclt initshutdownscript command. Match
# against an existing entry whose `command` or `script` contains $1 (the
# match-token); update if found, else create.
register_preinit() {
    local match_token="$1" cmd="$2" comment="$3" timeout="$4"

    local existing_id
    # `match_token` to Python via env to avoid quote injection.
    export MATCH_TOKEN="$match_token"
    existing_id=$(midclt call initshutdownscript.query 2>/dev/null \
        | python3 -c "
import sys, json, os
tok = os.environ['MATCH_TOKEN']
try:
    scripts = json.load(sys.stdin)
    for s in scripts:
        haystack = (s.get('command') or '') + ' ' + (s.get('script') or '')
        if tok in haystack:
            print(s['id'], end='')
            break
except Exception:
    pass
" 2>/dev/null)

    local json
    json="{\"type\": \"COMMAND\", \"command\": \"${cmd}\", \"when\": \"PREINIT\", \"enabled\": true, \"timeout\": ${timeout}, \"comment\": \"${comment}\"}"

    if $DRY_RUN; then
        if [ -n "$existing_id" ]; then
            echo "[dry-run] would: midclt call initshutdownscript.update ${existing_id} '${json}'"
        else
            echo "[dry-run] would: midclt call initshutdownscript.create '${json}'"
        fi
    elif [ -n "$existing_id" ]; then
        echo "  Updating existing entry (id ${existing_id}): ${cmd}"
        midclt call initshutdownscript.update "$existing_id" "$json" >/dev/null \
            || echo "  WARN: PREINIT update failed for ${cmd}"
    else
        echo "  Creating entry: ${cmd}"
        midclt call initshutdownscript.create "$json" >/dev/null \
            || echo "  WARN: PREINIT create failed for ${cmd}"
    fi
}

# MIG service start. Match against the literal "nvidia-mig-setup.service"
# command form so the matcher is unambiguous.
register_preinit "nvidia-mig-setup.service" \
    "/usr/bin/systemctl start nvidia-mig-setup.service" \
    "Start nvidia-mig-setup service (MIG instance recreation)" \
    120

# NOTE on the Apps' NVIDIA toggle (docker.config.nvidia):
#
# We don't touch the docker.config.nvidia toggle here. The current state is
# whatever the user (or a previous uninstall) left it at — typically True on a
# system that's been using GPU apps. If it's False, configure-mig's precheck
# will set it to True before doing anything else.
#
# Hardware testing also showed that immediately after a fresh boot the apps
# subsystem doesn't accept docker.update writes for some time — the call
# returns success but the value doesn't persist. configure-mig's precheck polls
# through that window automatically.

# ─────────────────────────────────────────────────────────────────────────
# Done.
# ─────────────────────────────────────────────────────────────────────────

if $DRY_RUN; then
    echo ""
    echo "=== Dry-run complete; no system changes applied ==="
    echo ""
    echo "URL reachability, sysext sanity, midclt query, and PERSIST_DIR"
    echo "resolution all ran for real. Every mutation was logged as"
    echo "'[dry-run] would: ...' but not executed."
    echo ""
    echo "Re-run without --dry-run to apply."
    exit 0
fi

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
    echo "OK:   NVIDIA driver available, version ${DRIVER}"
else
    echo "FAIL: /usr/bin/nvidia-smi not available — nvidia sysext may not be merged"
    OK=false
fi

echo ""
if $OK; then
    cat <<EOF
=== Install complete — ready to configure NOW (no reboot needed) ===

The NVIDIA driver is still running, so MIG can be set up immediately. The
config helper is bundled in the sysext at /usr/bin/configure-mig:

  sudo configure-mig                       # interactive prompt
  sudo configure-mig --mig=14,14,14,14     # non-interactive

It writes /mnt/<pool>/.config/nvidia-gpu/mig.conf, runs the MIG service,
and walks you through assigning MIG devices to your TrueNAS apps.
EOF
else
    echo "=== Install completed with errors — see FAIL lines above ==="
    exit 1
fi

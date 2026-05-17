#!/usr/bin/env bash
# Install nvidia-mig (and optionally a custom NVIDIA driver) on TrueNAS.
#
# Two install variants, one script:
#
#   sudo ./install-sysext.sh                          # default: MIG only
#   sudo ./install-sysext.sh --with-driver            # custom driver + MIG
#
# Default mode:
#   - Downloads nvidia-mig.raw (lightweight MIG sysext) from the latest
#     v<truenas>-nvidia<driver>-r<run> release.
#   - Layers on TrueNAS's stock NVIDIA driver — does NOT touch /usr.
#   - Refuses if stock driver < 570.x (validated minimum) unless --force.
#   - No reboot required.
#
# --with-driver mode:
#   - Downloads BOTH nvidia.raw (driver-only) AND nvidia-mig.raw.
#   - Swaps TrueNAS's stock nvidia.raw with the custom driver — requires
#     `/usr` r/w briefly (zfs readonly toggle).
#   - Installs nvidia-mig.raw alongside.
#   - Registers TWO PREINIT entries (driver restore + MIG service start).
#   - **Reboot required** — live-swapping the driver leaves stale kernel
#     modules in memory; NVML reports driver/library version mismatch
#     until you reboot.
#
# Override release with --release=TAG or pre-staged files with --sysext /
# --driver-sysext. Use --check to probe an existing install or --dry-run
# to walk through without mutating anything.
#
# Usage:
#   sudo ./install-sysext.sh                              # MIG only
#   sudo ./install-sysext.sh --with-driver                # driver + MIG
#   sudo ./install-sysext.sh --check                      # status probe
#   sudo ./install-sysext.sh --dry-run                    # validate, skip mutations
#   sudo ./install-sysext.sh --release=v25.10.3.1-nvidia580.126.18-r5
#   sudo ./install-sysext.sh --sysext=/tmp/nvidia-mig.raw # local MIG sysext
#   sudo ./install-sysext.sh --with-driver \
#       --driver-sysext=/tmp/nvidia.raw \
#       --sysext=/tmp/nvidia-mig.raw                       # both local
#   sudo ./install-sysext.sh --pool=fast
#
# Flags:
#   --with-driver         Also install the custom-driver nvidia.raw
#                         (default is MIG-only on top of stock driver)
#   --sysext=PATH         Local nvidia-mig.raw (skips MIG download)
#   --driver-sysext=PATH  Local nvidia.raw (only with --with-driver;
#                         skips driver download)
#   --release=TAG         Download from this exact release tag
#   --pool=NAME           ZFS pool for persistent storage
#   --persist-path=PATH   Exact directory for persistent storage
#   --force               Default mode: bypass the stock-driver-version
#                         pre-flight check (refuses on stock driver
#                         major <570 without --force)
#   --skip-backup-check   --with-driver only: don't refuse if the
#                         nvidia-original.raw backup is missing. Use at
#                         your own risk — you may be unable to recover
#                         the stock driver later.
#   --check               Read-only probe of an existing install.
#                         Reports state of: MIG sysext (file/symlink/merge),
#                         persist dir, PREINIT entries, plus (when a
#                         custom-driver install is detected) sysext file,
#                         kernel module, driver version match, stock backup,
#                         nvidia-preinit-driver helper. Exits 1 on failure.
#   --dry-run             Validate URLs + downloaded sysext but skip every
#                         mutation. Each skipped step is logged as
#                         `[dry-run] would: ...`. Mutually exclusive with --check.
#   -h, --help            Show this help and exit
#
# Pool selection priority: --persist-path > --pool > existing config dir >
# only data pool > interactive prompt (multi-pool) > error (no tty + ambiguous).

set -euo pipefail

REPO="truenas-community-sysexts/nvidia-mig-support"
TAG_PREFIX_SUFFIX="-nvidia"  # full prefix is v<truenas>-nvidia
DRIVER_ASSET="nvidia.raw"
MIG_ASSET="nvidia-mig.raw"
SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
LIVE_NVIDIA="${SYSEXT_DIR}/nvidia.raw"
STOCK_NVIDIA="$LIVE_NVIDIA"
MIN_DRIVER_MAJOR=570

WITH_DRIVER=false
MIG_SRC=""
DRIVER_SRC=""
RELEASE_TAG=""
POOL_NAME=""
PERSIST_PATH=""
FORCE=false
SKIP_BACKUP_CHECK=false
CHECK_MODE=false
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --with-driver) WITH_DRIVER=true ;;
        --sysext=*) MIG_SRC="${arg#*=}" ;;
        --driver-sysext=*) DRIVER_SRC="${arg#*=}" ;;
        --release=*) RELEASE_TAG="${arg#*=}" ;;
        --pool=*) POOL_NAME="${arg#*=}" ;;
        --persist-path=*) PERSIST_PATH="${arg#*=}" ;;
        --force) FORCE=true ;;
        --skip-backup-check) SKIP_BACKUP_CHECK=true ;;
        --check) CHECK_MODE=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            sed -n '2,69p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if $CHECK_MODE && $DRY_RUN; then
    echo "ERROR: --check and --dry-run are mutually exclusive" >&2
    exit 2
fi
if [ -n "$DRIVER_SRC" ] && ! $WITH_DRIVER; then
    echo "ERROR: --driver-sysext requires --with-driver" >&2
    exit 2
fi
if $SKIP_BACKUP_CHECK && ! $WITH_DRIVER; then
    echo "WARN: --skip-backup-check has no effect without --with-driver (default mode never touches the stock driver)" >&2
fi

# Run a command in real mode; print `[dry-run] would: …` in dry-run mode.
# For redirections or compound shell logic, gate manually with
# `if $DRY_RUN; then ... else ... fi`.
if_real() {
    if $DRY_RUN; then
        printf '[dry-run] would: %s\n' "$*"
    else
        "$@"
    fi
}

resolve_release_tag() {
    # Returns the release tag on stdout.
    # If --release=TAG was passed, echoes it verbatim.
    # Otherwise: detect local TrueNAS version, query /releases, filter tags
    # by `v<version>${TAG_PREFIX_SUFFIX}` prefix, pick newest by published_at.
    if [ -n "$RELEASE_TAG" ]; then
        printf '%s\n' "$RELEASE_TAG"
        return
    fi

    local version
    version=$(midclt call system.info 2>/dev/null | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin)["version"])
except Exception:
    pass' 2>/dev/null) || true
    if [ -z "$version" ]; then
        echo "ERROR: could not detect TrueNAS version (midclt call system.info failed)" >&2
        exit 1
    fi
    echo "Detected TrueNAS version: ${version}" >&2

    local prefix="v${version}${TAG_PREFIX_SUFFIX}"
    local tag
    # `?per_page=100`: GitHub defaults to 30 results; once the repo crosses
    #   30 releases, installs for older TrueNAS versions would silently
    #   fail to find a matching tag.
    # `curl -sS` (not -sf): let curl surface transport errors AND let Python
    #   see the API error body for rate-limit diagnostics.
    # `PREFIX` via env: avoids shell-interpolated quote injection into the
    #   Python literal — defense in depth.
    export PREFIX="$prefix"
    tag=$(curl -sS --max-time 30 "https://api.github.com/repos/${REPO}/releases?per_page=100" \
        | python3 -c "
import sys, json, os
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    print('Failed to parse GitHub API response', file=sys.stderr)
    sys.exit(1)
if isinstance(data, dict) and 'message' in data:
    msg = data['message']
    if 'rate limit' in msg.lower():
        print('GitHub API rate limit exceeded (60 requests/hour for unauthenticated calls).', file=sys.stderr)
        print('Wait a few minutes and try again.', file=sys.stderr)
    else:
        print(f'GitHub API error: {msg}', file=sys.stderr)
    sys.exit(1)
prefix = os.environ['PREFIX']
matches = [r for r in data if r.get('tag_name', '').startswith(prefix)]
if not matches:
    print(f\"No release found with tag prefix '{prefix}'\", file=sys.stderr)
    tags = [r.get('tag_name', '?') for r in data]
    if tags:
        print('Available releases:', file=sys.stderr)
        for t in tags:
            print(f'  {t}', file=sys.stderr)
    sys.exit(1)
matches.sort(key=lambda r: r.get('published_at') or r.get('created_at') or '', reverse=True)
print(matches[0]['tag_name'], end='')
") || {
        echo "       If you need a specific build, pass --release=TAG explicitly." >&2
        exit 1
    }
    printf '%s\n' "$tag"
}

[ "$(id -u 2>/dev/null)" = "0" ] || { echo "ERROR: must run as root" >&2; exit 1; }

# --- Resolve persistent storage location ---
# resolve_persist_dir is duplicated verbatim across install-sysext.sh,
# configure-mig.sh, and recover-stock-nvidia.sh. Inline (rather than sourced
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

    # Detect whether --with-driver was previously used. Signal: persistent
    # nvidia-preinit-driver.sh staged in PERSIST_DIR. (Also covers the
    # legacy nvidia-preinit-full.sh name from before the rename.)
    local driver_installed=false
    if [ -n "${PERSIST_DIR:-}" ] && {
        [ -x "${PERSIST_DIR}/nvidia-preinit-driver.sh" ] \
        || [ -x "${PERSIST_DIR}/nvidia-preinit-full.sh" ]
    }; then
        driver_installed=true
    fi

    echo "=== install-sysext status ==="
    if $driver_installed; then
        echo "Mode detected: --with-driver (custom driver + MIG)"
    else
        echo "Mode detected: default (MIG on stock driver)"
    fi
    echo ""

    # Stock NVIDIA driver merged (always required — driver-only nvidia.raw
    # in --with-driver mode lives at the same path).
    if systemd-sysext list 2>/dev/null | awk '{print $1}' | grep -qx nvidia; then
        record_pass "Sysext 'nvidia' merged into /usr"
    else
        record_fail "Sysext 'nvidia' not merged" \
            "MIG sysext layers on the driver — without it nothing works"
    fi

    # Driver version reporting (different expectations per mode)
    local sysext_drv="" runtime_drv=""
    if command -v unsquashfs >/dev/null 2>&1 && [ -f "$LIVE_NVIDIA" ]; then
        sysext_drv=$(unsquashfs -l "$LIVE_NVIDIA" 2>/dev/null \
            | grep -oE 'libnvidia-ml\.so\.[0-9]+\.[0-9]+\.[0-9]+' \
            | head -1 | sed 's/^libnvidia-ml\.so\.//' || true)
    fi
    if command -v nvidia-smi >/dev/null 2>&1; then
        runtime_drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null \
            | head -1 | tr -d '[:space:]' || true)
    fi

    if $driver_installed; then
        if [ -n "$sysext_drv" ] && [ -n "$runtime_drv" ]; then
            if [ "$sysext_drv" = "$runtime_drv" ]; then
                record_pass "Driver versions match: sysext=${sysext_drv}, runtime=${runtime_drv}"
            else
                record_fail "Driver mismatch: sysext=${sysext_drv} but runtime=${runtime_drv}" \
                    "reboot to pick up the new kernel module from the sysext"
            fi
        elif [ -n "$sysext_drv" ]; then
            record_warn "Sysext driver=${sysext_drv}; could not query nvidia-smi" \
                "no GPU detected, or driver not loaded — reboot may be required"
        else
            record_warn "Could not read sysext driver version" \
                "unsquashfs missing or sysext file unreadable"
        fi
    else
        # Default mode: gate on stock driver >= MIN_DRIVER_MAJOR
        if [ -n "$sysext_drv" ]; then
            local stock_major=${sysext_drv%%.*}
            if [ "$stock_major" -ge "$MIN_DRIVER_MAJOR" ]; then
                record_pass "Stock driver ${sysext_drv} >= minimum ${MIN_DRIVER_MAJOR}.x"
            else
                record_fail "Stock driver ${sysext_drv} < ${MIN_DRIVER_MAJOR}.x (MIG validated only on >= ${MIN_DRIVER_MAJOR}.x)" \
                    "wait for TrueNAS to ship a newer driver, or use --with-driver"
            fi
        else
            record_warn "Could not detect stock driver version in ${LIVE_NVIDIA}" \
                "unsquashfs missing or sysext file unreadable"
        fi
    fi

    # Kernel module loaded (matters whichever mode we're in)
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
            "re-run install-sysext.sh"
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

    # PREINIT entries: always expect mig-setup; expect preinit-driver iff
    # --with-driver was used.
    if command -v midclt >/dev/null 2>&1; then
        local mig_entry driver_entry
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

        if $driver_installed; then
            driver_entry=$(midclt call initshutdownscript.query 2>/dev/null \
                | python3 -c "
import sys, json
try:
    for s in json.load(sys.stdin):
        haystack = (s.get('command') or '') + ' ' + (s.get('script') or '')
        if 'nvidia-preinit-driver' in haystack or 'nvidia-preinit-full' in haystack:
            print(f\"{s.get('when','?')}|{s.get('enabled','?')}\")
            break
except Exception:
    pass" 2>/dev/null || true)
            if [ -z "$driver_entry" ]; then
                record_fail "No PREINIT entry registered for nvidia-preinit-driver" \
                    "re-run install --with-driver — middleware registration missing"
            else
                local when2 enabled2
                IFS='|' read -r when2 enabled2 <<<"$driver_entry"
                if [ "$when2" = "PREINIT" ] && [ "$enabled2" = "True" ]; then
                    record_pass "PREINIT 'nvidia-preinit-driver' registered (PREINIT, enabled)"
                else
                    record_warn "PREINIT entry for nvidia-preinit-driver state: when=${when2}, enabled=${enabled2}" \
                        "re-run install to normalize"
                fi
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

    # --with-driver-only checks
    if $driver_installed; then
        # Stock backup (warn — install allows --skip-backup-check)
        if [ -n "${PERSIST_DIR:-}" ] && [ -f "${PERSIST_DIR}/nvidia-original.raw" ]; then
            record_pass "Stock backup ${PERSIST_DIR}/nvidia-original.raw present"
        elif [ -n "${PERSIST_DIR:-}" ]; then
            record_warn "No stock backup ${PERSIST_DIR}/nvidia-original.raw" \
                "you may be unable to recover the stock driver — run recover-stock-nvidia.sh"
        fi

        # Persistent custom nvidia.raw
        if [ -n "${PERSIST_DIR:-}" ] && [ -f "${PERSIST_DIR}/nvidia.raw" ]; then
            record_pass "Custom-driver backup ${PERSIST_DIR}/nvidia.raw present"
        elif [ -n "${PERSIST_DIR:-}" ]; then
            record_fail "Custom-driver backup ${PERSIST_DIR}/nvidia.raw missing" \
                "re-run install-sysext.sh --with-driver"
        fi

        # PREINIT helper staged
        if [ -n "${PERSIST_DIR:-}" ] && [ -x "${PERSIST_DIR}/nvidia-preinit-driver.sh" ]; then
            record_pass "PREINIT helper ${PERSIST_DIR}/nvidia-preinit-driver.sh staged and executable"
        elif [ -n "${PERSIST_DIR:-}" ] && [ -x "${PERSIST_DIR}/nvidia-preinit-full.sh" ]; then
            record_warn "Legacy PREINIT helper ${PERSIST_DIR}/nvidia-preinit-full.sh present (pre-rename)" \
                "re-run install-sysext.sh --with-driver to upgrade to nvidia-preinit-driver.sh"
        elif [ -n "${PERSIST_DIR:-}" ]; then
            record_fail "PREINIT helper missing in ${PERSIST_DIR}" \
                "re-run install-sysext.sh --with-driver"
        fi
    fi

    # configure-mig command
    if command -v configure-mig >/dev/null 2>&1; then
        record_pass "configure-mig command available (bundled in nvidia-mig.raw)"
    else
        record_warn "configure-mig command not found in PATH" \
            "nvidia-mig.raw may not be currently merged"
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

# --- Default-mode pre-flight: stock driver version >= MIN_DRIVER_MAJOR ---
# Skipped in --with-driver mode (we're swapping the driver, so stock version
# is irrelevant) and in --check (handled by do_check).
if ! $WITH_DRIVER; then
    if [ ! -f "$STOCK_NVIDIA" ]; then
        echo "ERROR: $STOCK_NVIDIA not found — TrueNAS doesn't appear to have an NVIDIA sysext." >&2
        echo "       The lightweight MIG sysext depends on the stock driver being present." >&2
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
            echo "       Either pass --with-driver to install a custom driver, or pass --force to bypass this check." >&2
            $FORCE || exit 1
            echo "       --force given, continuing anyway." >&2
        fi
    fi
fi

# --- Resolve persist dir + ensure it exists ---
resolve_persist_dir || exit 1
if_real mkdir -p "$PERSIST_DIR"

# --- --with-driver pre-flight: stock backup required for revert ---
if $WITH_DRIVER && ! $SKIP_BACKUP_CHECK; then
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

# --- Resolve release tag (only if we'll be downloading something) ---
RESOLVED_TAG=""
need_tag=false
[ -z "$MIG_SRC" ] && need_tag=true
if $WITH_DRIVER && [ -z "$DRIVER_SRC" ]; then need_tag=true; fi
if $need_tag; then
    RESOLVED_TAG=$(resolve_release_tag)
fi

# --- Fetch nvidia-mig.raw if not provided ---
MIG_TMP=""
if [ -z "$MIG_SRC" ]; then
    MIG_TMP=$(mktemp -t nvidia-mig.raw.XXXXXX)
    MIG_URL="https://github.com/${REPO}/releases/download/${RESOLVED_TAG}/${MIG_ASSET}"
    echo "Downloading ${MIG_URL}"
    curl -fL --retry 3 -o "$MIG_TMP" "$MIG_URL" \
        || { echo "ERROR: failed to download nvidia-mig.raw" >&2; rm -f "$MIG_TMP"; exit 1; }
    MIG_SRC="$MIG_TMP"
fi
[ -f "$MIG_SRC" ] || { echo "ERROR: MIG sysext source not found: $MIG_SRC" >&2; exit 1; }

# --- Fetch nvidia.raw if --with-driver and not provided ---
DRIVER_TMP=""
if $WITH_DRIVER && [ -z "$DRIVER_SRC" ]; then
    DRIVER_TMP=$(mktemp -t nvidia.raw.XXXXXX)
    DRIVER_URL="https://github.com/${REPO}/releases/download/${RESOLVED_TAG}/${DRIVER_ASSET}"
    echo "Downloading ${DRIVER_URL}"
    curl -fL --retry 3 -o "$DRIVER_TMP" "$DRIVER_URL" \
        || { echo "ERROR: failed to download nvidia.raw" >&2; rm -f "$DRIVER_TMP" "$MIG_TMP"; exit 1; }
    DRIVER_SRC="$DRIVER_TMP"
fi
$WITH_DRIVER && { [ -f "$DRIVER_SRC" ] || { echo "ERROR: driver sysext source not found: $DRIVER_SRC" >&2; exit 1; }; }

# Single cleanup trap for any tempfiles we created.
cleanup_tmp() {
    [ -n "${MIG_TMP:-}" ] && rm -f "$MIG_TMP"
    [ -n "${DRIVER_TMP:-}" ] && rm -f "$DRIVER_TMP"
    [ -n "${PREINIT_DRY_TMP:-}" ] && rm -f "$PREINIT_DRY_TMP"
}
trap cleanup_tmp EXIT

# --- Sanity-check the MIG sysext contents ---
# Buffer the listing before grep -q — see fix/unsquashfs-grep-pipefail
# branch: piping unsquashfs into `grep -q` SIGPIPEs the producer and trips
# pipefail's exit propagation.
if ! MIG_LISTING=$(unsquashfs -l "$MIG_SRC" 2>/dev/null); then
    echo "ERROR: unsquashfs -l failed on $MIG_SRC" >&2
    exit 1
fi
if ! printf '%s\n' "$MIG_LISTING" | grep -q 'extension-release.nvidia-mig'; then
    echo "ERROR: $MIG_SRC does not contain extension-release.nvidia-mig" >&2
    exit 1
fi

# --- Sanity-check the driver sysext contents (--with-driver) ---
if $WITH_DRIVER; then
    if ! DRIVER_LISTING=$(unsquashfs -l "$DRIVER_SRC" 2>/dev/null); then
        echo "ERROR: unsquashfs -l failed on $DRIVER_SRC" >&2
        exit 1
    fi
    if ! printf '%s\n' "$DRIVER_LISTING" | grep -q 'extension-release.nvidia$'; then
        echo "ERROR: $DRIVER_SRC missing extension-release.nvidia" >&2
        exit 1
    fi
    NEW_DRIVER_VER=$(printf '%s\n' "$DRIVER_LISTING" \
        | grep -oE 'libnvidia-ml\.so\.[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1 | sed 's/^libnvidia-ml\.so\.//' || true)
    echo "Driver sysext version: ${NEW_DRIVER_VER:-unknown}"
fi

# ─────────────────────────────────────────────────────────────────────────
# Mutations begin here. Order:
#   1. Stage everything in PERSIST_DIR (safe — no system effect yet).
#   2. (--with-driver) Stop docker, unmerge, swap nvidia.raw, register
#      driver PREINIT.
#   3. Stage + symlink MIG sysext, re-merge, register MIG PREINIT.
#   4. (--with-driver) Re-enable docker, prompt reboot.
# ─────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Install plan ==="
echo "Persist dir:    $PERSIST_DIR"
echo "MIG sysext:     $MIG_SRC"
if $WITH_DRIVER; then
    echo "Driver sysext:  $DRIVER_SRC (custom-driver install — reboot required)"
fi
echo ""

# Copy both raws to persistent storage so TrueNAS updates can be survived.
if_real cp "$MIG_SRC" "${PERSIST_DIR}/nvidia-mig.raw"
$DRY_RUN || echo "Copied MIG sysext to ${PERSIST_DIR}/nvidia-mig.raw"

if $WITH_DRIVER; then
    if_real cp "$DRIVER_SRC" "${PERSIST_DIR}/nvidia.raw"
    $DRY_RUN || echo "Copied driver sysext to ${PERSIST_DIR}/nvidia.raw"

    # Stage nvidia-preinit-driver.sh BEFORE any /usr mutations so a failed
    # download fails fast instead of leaving the host half-installed.
    # Fetched from main (durable), not the current branch.
    SCRIPT_URL_BASE="https://raw.githubusercontent.com/${REPO}/main/scripts"
    PREINIT_LOCAL="${PERSIST_DIR}/nvidia-preinit-driver.sh"
    # `${BASH_SOURCE[0]:-}` (not bare) so curl|bash doesn't trip set -u —
    # when reading from stdin BASH_SOURCE[0] is unset.
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd 2>/dev/null || true)"
    if $DRY_RUN; then
        PREINIT_DRY_TMP=$(mktemp -t nvidia-preinit-driver.XXXXXX.sh)
        PREINIT_STAGE="$PREINIT_DRY_TMP"
    else
        PREINIT_STAGE="$PREINIT_LOCAL"
    fi
    if [ -n "${SCRIPT_DIR:-}" ] && [ -f "${SCRIPT_DIR}/nvidia-preinit-driver.sh" ]; then
        cp "${SCRIPT_DIR}/nvidia-preinit-driver.sh" "$PREINIT_STAGE"
        echo "Staged PREINIT helper from local checkout"
    else
        echo "Downloading PREINIT helper from ${SCRIPT_URL_BASE}/nvidia-preinit-driver.sh"
        curl -fL --retry 3 -o "$PREINIT_STAGE" "${SCRIPT_URL_BASE}/nvidia-preinit-driver.sh" \
            || { echo "ERROR: failed to download PREINIT helper — aborting BEFORE system changes" >&2; exit 1; }
    fi
    if $DRY_RUN; then
        [ -s "$PREINIT_STAGE" ] || { echo "ERROR: PREINIT helper downloaded empty" >&2; exit 1; }
        echo "[dry-run] would: install staged preinit to ${PREINIT_LOCAL} (chmod 0755)"
    else
        chmod 0755 "$PREINIT_LOCAL"
        echo "Staged: $PREINIT_LOCAL"
    fi

    # Remove any legacy nvidia-preinit-full.sh — pre-rename relic.
    if [ -e "${PERSIST_DIR}/nvidia-preinit-full.sh" ]; then
        if $DRY_RUN; then
            echo "[dry-run] would: rm ${PERSIST_DIR}/nvidia-preinit-full.sh (pre-rename relic)"
        else
            rm -f "${PERSIST_DIR}/nvidia-preinit-full.sh"
            echo "Removed legacy ${PERSIST_DIR}/nvidia-preinit-full.sh"
        fi
    fi

    # Stop app services (TrueNAS's containerized app runtime) so the GPU
    # is free, then wait for any running compute processes to drain.
    # User-facing strings say "app services"; the actual middleware API
    # endpoint is still called `docker.update` (kept in code as the literal
    # API name).
    echo ""
    echo "Stopping app services (releasing the GPU)..."
    if $DRY_RUN; then
        echo "[dry-run] would: midclt call docker.update '{\"nvidia\": false}'"
    else
        midclt call docker.update '{"nvidia": false}' >/dev/null \
            || echo "WARN: app services API call (docker.update) failed — middleware may be transitionally down; continuing"
    fi

    if $DRY_RUN; then
        echo "[dry-run] would: wait up to 120s for running GPU processes to drain"
    elif [ -x /usr/bin/nvidia-smi ]; then
        # Always print a first line so the user sees a counter even when
        # the GPU is released within the first poll interval. Then either
        # the carriage-return progress overwrites it, or "GPU released"
        # supersedes it.
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
        # Newline-after-progress guard in case we exited the loop on the
        # max iteration without a "released" message.
        [ "${attempt:-0}" -eq 24 ] && echo ""
    fi
fi

# Unmerge sysext — happens whether or not we're doing --with-driver. In
# default mode it lets us drop in a refreshed nvidia-mig.raw symlink. In
# --with-driver mode it's a prerequisite for swapping nvidia.raw.
echo "Unmerging sysext..."
if_real systemd-sysext unmerge

if $WITH_DRIVER; then
    USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null)
    echo "Setting ${USR_DATASET:-<unknown>} writable..."
    if_real zfs set readonly=off "$USR_DATASET"

    # Stash current (likely stock) as .bak unless we already have one.
    if $DRY_RUN; then
        echo "[dry-run] would: cp ${LIVE_NVIDIA} ${LIVE_NVIDIA}.bak (unless .bak already present)"
    elif [ ! -f "${LIVE_NVIDIA}.bak" ]; then
        cp "$LIVE_NVIDIA" "${LIVE_NVIDIA}.bak" 2>/dev/null \
            && echo "Backed up current to ${LIVE_NVIDIA}.bak" \
            || echo "WARN: could not back up to .bak"
    fi

    if_real cp "$DRIVER_SRC" "$LIVE_NVIDIA"
    $DRY_RUN || echo "Installed custom nvidia.raw at $LIVE_NVIDIA"

    if_real zfs set readonly=on "$USR_DATASET"
fi

# Ensure /etc/extensions/ symlinks for both sysexts. nvidia.raw is always
# present (stock or custom); nvidia-mig.raw points at the persistent copy.
echo "Ensuring /etc/extensions/ symlinks..."
if_real mkdir -p /etc/extensions
if_real ln -sf "$LIVE_NVIDIA" /etc/extensions/nvidia.raw
if_real ln -sf "${PERSIST_DIR}/nvidia-mig.raw" /etc/extensions/nvidia-mig.raw

echo "Re-merging sysext..."
if_real systemd-sysext merge
if_real systemctl daemon-reload

# ─────────────────────────────────────────────────────────────────────────
# Register PREINIT entries via midclt.
# ─────────────────────────────────────────────────────────────────────────
#
# Two separate entries because they have different concerns:
#   - nvidia-mig-setup.service start — always registered (MIG sysext is
#     always installed).
#   - nvidia-preinit-driver.sh — only registered with --with-driver
#     (handles nvidia.raw restore + kernel-mismatch detection).
# The two have no ordering dependency: nvidia-mig-setup itself waits for
# the driver to become responsive (see sysext/usr/bin/nvidia-mig-setup),
# so PREINIT firing order doesn't matter.
echo ""
echo "Registering PREINIT entries..."

# Helper: idempotent register-or-update for a midclt initshutdownscript
# command. Match against an existing entry whose `command` or `script`
# contains $1 (the match-token); update if found, else create.
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

if $WITH_DRIVER; then
    # Driver-side restore + kernel-mismatch detection.
    register_preinit "nvidia-preinit-driver" \
        "${PERSIST_DIR}/nvidia-preinit-driver.sh" \
        "Custom NVIDIA driver restore + kernel-mismatch detection" \
        180
fi

# MIG service start — always.
# Match against the literal "nvidia-mig-setup.service" command form rather
# than just "nvidia-mig-setup", so the matcher doesn't accidentally pick
# up a `nvidia-preinit-*` script that happens to grep for the same token.
register_preinit "nvidia-mig-setup.service" \
    "/usr/bin/systemctl start nvidia-mig-setup.service" \
    "Start nvidia-mig-setup service (MIG instance recreation)" \
    120

# Attempt to re-enable Apps' NVIDIA toggle. We do query → set → verify
# (rather than fire-and-forget) because at this point in the --with-driver
# flow NVML is in driver/library mismatch (libs in /usr are the new
# driver's, kernel modules in RAM are still the previous driver's). Recent
# TrueNAS middleware validates docker.update against NVML and silently
# rejects when probing fails, persisting nvidia=false. A blind call would
# appear to succeed but actually leave the Apps toggle off after reboot.
# Some TrueNAS versions DON'T validate, in which case the re-enable does
# stick — so we try, then verify, and only warn if it didn't stick.
#
# (Inlined helper rather than sourced; uninstall-nvidia-sysext.sh has the
# same function — keep these copies in sync.)
NVIDIA_REENABLE_OK=false
attempt_nvidia_reenable() {
    if $DRY_RUN; then
        echo "[dry-run] would: query docker.config, set nvidia=true if false, verify"
        return 0
    fi
    if ! command -v midclt >/dev/null 2>&1; then
        echo "  midclt not available — skipping app-services re-enable"
        return 1
    fi

    local current
    current=$(midclt call docker.config 2>/dev/null \
        | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('true' if d.get('nvidia') else 'false')
except Exception:
    pass" 2>/dev/null)

    if [ "$current" = "true" ]; then
        echo "  app services nvidia toggle already on — no change needed"
        return 0
    fi

    midclt call docker.update '{"nvidia": true}' >/dev/null 2>&1 || true

    local after
    after=$(midclt call docker.config 2>/dev/null \
        | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('true' if d.get('nvidia') else 'false')
except Exception:
    pass" 2>/dev/null)

    if [ "$after" = "true" ]; then
        echo "  app services nvidia toggle re-enabled (verified)"
        return 0
    fi
    return 1
}

if $WITH_DRIVER; then
    echo ""
    echo "Re-enabling Apps' NVIDIA toggle..."
    if attempt_nvidia_reenable; then
        NVIDIA_REENABLE_OK=true
    fi
fi

# ─────────────────────────────────────────────────────────────────────────
# Done. Mode-appropriate finishing messages.
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
    if $WITH_DRIVER; then
        echo "OK:   /usr/bin/nvidia-smi present (running driver still old until reboot)"
    else
        DRIVER=$(/usr/bin/nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo unknown)
        echo "OK:   stock driver still available, version ${DRIVER}"
    fi
else
    echo "FAIL: /usr/bin/nvidia-smi not available — nvidia sysext may not be merged"
    OK=false
fi

echo ""
if $WITH_DRIVER; then
    if $OK; then
        cat <<EOF
=== --with-driver install complete — REBOOT REQUIRED ===

The kernel modules currently loaded are the previous driver's; userspace
libraries are now the new driver's. Until you reboot:

  nvidia-smi will report "Driver/library version mismatch"

After reboot:
  - new kernel modules load from /usr/lib/modules/<kernel>/video/
  - userspace libs match
  - both PREINITs run (driver restore + MIG service start)
  - if you have mig.conf in $PERSIST_DIR, MIG instances are recreated

Run: sudo reboot

EOF
        if $NVIDIA_REENABLE_OK; then
            cat <<EOF
Apps' NVIDIA toggle: already re-enabled and verified above (nothing
extra to do after reboot for that).

EOF
        else
            cat <<EOF
>>> AFTER REBOOT — one-time step to make Apps see the GPU again <<<

App services were turned off during install (so we could swap the
driver). Auto re-enable was attempted but did NOT stick — TrueNAS
middleware likely validated the call against NVML, which is in
"driver/library mismatch" right now, so it rejected.

Once the box is back up and 'nvidia-smi' shows the new driver, run:

  sudo midclt call docker.update '{"nvidia": true}'

  -- or --

  Toggle the "Use NVIDIA GPU" switch on under TrueNAS UI →
  Apps → Settings → Configure → check 'Use NVIDIA GPU' → Save

EOF
        fi
        cat <<EOF
DO NOT run configure-mig before rebooting — it will refuse with a
driver/library-mismatch error. After the box is back up:

  sudo configure-mig                       # interactive prompt
  sudo configure-mig --mig=14,14,14,14     # non-interactive
EOF
    else
        echo "=== Install completed with errors — see FAIL lines above ==="
        exit 1
    fi
else
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
fi

#!/usr/bin/env bash
# Install nvidia-mig (and optionally a custom NVIDIA driver) on TrueNAS.
#
# Two install variants, one script:
#
#   sudo ./install-mig-sysext.sh                          # default: MIG only
#   sudo ./install-mig-sysext.sh --with-driver            # custom driver + MIG
#
# Default mode:
#   - Downloads nvidia-mig.raw (lightweight MIG sysext) from the latest
#     v<truenas>-nvidia<driver>-r<run> release.
#   - Layers on TrueNAS's stock NVIDIA driver — does NOT touch /usr.
#   - Refuses if stock driver < 570.x (validated minimum) unless --force.
#   - No reboot required.
#
# --with-driver mode:
#   - Builds nvidia.raw on this TrueNAS host inside a transient ubuntu:24.04
#     docker container (NVIDIA's EULA prohibits us redistributing the
#     proprietary userspace, so the artifact is never published on releases —
#     it's assembled on your machine, where you accept NVIDIA's EULA when
#     the .run installer runs with --silent).
#   - Downloads nvidia-mig.raw (lightweight, ours, MIT-licensed) from the
#     same v<truenas>-nvidia<driver>-r<run> release.
#   - Swaps TrueNAS's stock nvidia.raw with the freshly built custom driver —
#     requires `/usr` r/w briefly (zfs readonly toggle).
#   - Installs nvidia-mig.raw alongside.
#   - Registers TWO PREINIT entries (driver restore + MIG service start).
#   - **Reboot required** — live-swapping the driver leaves stale kernel
#     modules in memory; NVML reports driver/library version mismatch
#     until you reboot.
#   - Subsequent installs reuse the cached nvidia.raw if it matches the
#     running kernel + target driver version (skip rebuild). Pass --rebuild
#     to force.
#
# Override release with --release=TAG, pre-staged sysext with --sysext, or
# pre-built driver with --driver-sysext. Use --check to probe an existing
# install or --dry-run to walk through without mutating anything.
#
# Usage:
#   sudo ./install-mig-sysext.sh                              # MIG only
#   sudo ./install-mig-sysext.sh --with-driver                # build + install driver + MIG
#   sudo ./install-mig-sysext.sh --check                      # status probe
#   sudo ./install-mig-sysext.sh --dry-run                    # validate, skip mutations
#   sudo ./install-mig-sysext.sh --release=v25.10.3.1-nvidia580.126.18-r5
#   sudo ./install-mig-sysext.sh --sysext=/tmp/nvidia-mig.raw # local MIG sysext
#   sudo ./install-mig-sysext.sh --with-driver --rebuild      # ignore cached driver, rebuild
#   sudo ./install-mig-sysext.sh --with-driver \
#       --custom-run=/path/to/NVIDIA-Linux-x86_64-590.44.01-no-compat32.run
#   sudo ./install-mig-sysext.sh --with-driver \
#       --driver-sysext=/tmp/nvidia.raw \
#       --sysext=/tmp/nvidia-mig.raw                       # both local, no build
#   sudo ./install-mig-sysext.sh --pool=fast
#
# Flags:
#   --with-driver         Also build + install the custom-driver nvidia.raw
#                         (default is MIG-only on top of stock driver)
#   --sysext=PATH         Local nvidia-mig.raw (skips MIG download)
#   --driver-sysext=PATH  Local nvidia.raw (only with --with-driver; skips
#                         the docker build — use for a .raw you built elsewhere)
#   --custom-run=PATH     Local NVIDIA .run installer (only with --with-driver;
#                         skips the NVIDIA download inside the build container)
#   --rebuild             --with-driver only: ignore any cached nvidia.raw in
#                         the persist dir and rebuild from scratch
#   --kmod=open|proprietary
#                         --with-driver only: kernel-module flavor (default
#                         open — required for Turing+ to use the open path;
#                         proprietary needed for Maxwell/Pascal/Volta cards)
#   --release=TAG         Download nvidia-mig.raw from this exact release tag
#                         (driver version is parsed from the tag for the build)
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
MIG_ASSET="nvidia-mig.raw"
SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
LIVE_NVIDIA="${SYSEXT_DIR}/nvidia.raw"
STOCK_NVIDIA="$LIVE_NVIDIA"
MIN_DRIVER_MAJOR=570

WITH_DRIVER=false
MIG_SRC=""
DRIVER_SRC=""
CUSTOM_RUN=""
REBUILD=false
KMOD_TYPE="open"
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
        --custom-run=*) CUSTOM_RUN="${arg#*=}" ;;
        --rebuild) REBUILD=true ;;
        --kmod=*) KMOD_TYPE="${arg#*=}" ;;
        --release=*) RELEASE_TAG="${arg#*=}" ;;
        --pool=*) POOL_NAME="${arg#*=}" ;;
        --persist-path=*) PERSIST_PATH="${arg#*=}" ;;
        --force) FORCE=true ;;
        --skip-backup-check) SKIP_BACKUP_CHECK=true ;;
        --check) CHECK_MODE=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            sed -n '2,84p' "$0" | sed 's/^# \{0,1\}//'
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
if [ -n "$CUSTOM_RUN" ] && ! $WITH_DRIVER; then
    echo "ERROR: --custom-run requires --with-driver" >&2
    exit 2
fi
if [ -n "$CUSTOM_RUN" ] && [ -n "$DRIVER_SRC" ]; then
    echo "ERROR: --custom-run and --driver-sysext are mutually exclusive (--custom-run feeds the build; --driver-sysext skips the build)" >&2
    exit 2
fi
if $REBUILD && ! $WITH_DRIVER; then
    echo "WARN: --rebuild has no effect without --with-driver" >&2
fi
if $REBUILD && [ -n "$DRIVER_SRC" ]; then
    echo "WARN: --rebuild has no effect when --driver-sysext is passed (no build is performed)" >&2
fi
case "$KMOD_TYPE" in
    open|proprietary) ;;
    *) echo "ERROR: --kmod must be 'open' or 'proprietary' (got: $KMOD_TYPE)" >&2; exit 2 ;;
esac
if $SKIP_BACKUP_CHECK && ! $WITH_DRIVER; then
    echo "WARN: --skip-backup-check has no effect without --with-driver (default mode never touches the stock driver)" >&2
fi

# Run a command in real mode; print `[dry-run] would: …` in dry-run mode.
# For redirections or compound shell logic, gate manually with
# `if $DRY_RUN; then ... else ... fi`.
#
# The dry-run message goes to stderr so helpers whose stdout is captured
# (e.g. `stage_dir=$(stage_build_helpers)`) don't end up with would-be
# log lines bleeding into their return value.
if_real() {
    if $DRY_RUN; then
        printf '[dry-run] would: %s\n' "$*" >&2
    else
        "$@"
    fi
}

# Live-elapsed wrapper for blocking midclt -j calls. Same pattern used in
# configure-mig.sh and uninstall-mig-sysext.sh — spawns a background
# ticker that prints "<label>... Ns" once a second, runs the command
# with combined stdout/stderr captured, clears the line on return. Sets
# ELAPSED and CAPTURED_OUT in caller scope.
ELAPSED=0
CAPTURED_OUT=""
run_with_elapsed_capture() {
    local label="$1"; shift
    local start outfile ticker_pid rc
    start=$(date +%s)
    outfile=$(mktemp)
    (
        while sleep 1; do
            printf "\r%s... %ds" "$label" "$(($(date +%s) - start))"
        done
    ) &
    ticker_pid=$!
    "$@" >"$outfile" 2>&1
    rc=$?
    kill "$ticker_pid" 2>/dev/null
    wait "$ticker_pid" 2>/dev/null
    ELAPSED=$(($(date +%s) - start))
    CAPTURED_OUT=$(cat "$outfile")
    rm -f "$outfile"
    printf "\r%80s\r" ""
    return $rc
}

# Detect the running TrueNAS version via midclt. Retries on transient
# failures — observed: midclt sporadically returns nothing on the first
# call after a `sudo` invocation, succeeds on retry within ~1s. The
# pattern is reproducible enough that letting the script die on the
# first miss is hostile UX. Echoes the version; returns 1 on persistent
# failure.
detect_truenas_version() {
    local v i
    for i in 1 2 3; do
        v=$(midclt call system.info 2>/dev/null | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin)["version"])
except Exception:
    pass' 2>/dev/null) || true
        if [ -n "$v" ]; then
            printf '%s\n' "$v"
            return 0
        fi
        [ "$i" -lt 3 ] && sleep 1
    done
    return 1
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
    version=$(detect_truenas_version) || {
        echo "ERROR: could not detect TrueNAS version (midclt call system.info failed after 3 retries)" >&2
        exit 1
    }
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

# Parse NVIDIA driver version from a release tag.
# Format: v25.10.3.1-nvidia595.58.03-r18 → 595.58.03
parse_nvidia_version_from_tag() {
    printf '%s\n' "$1" \
        | sed -nE 's/^v[0-9.]+-nvidia([0-9]+\.[0-9]+\.[0-9]+)-r[0-9]+$/\1/p'
}

# Parse TrueNAS version from a release tag.
# Format: v25.10.3.1-nvidia595.58.03-r18 → 25.10.3.1
parse_truenas_version_from_tag() {
    printf '%s\n' "$1" \
        | sed -nE 's/^v([0-9.]+)-nvidia[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$/\1/p'
}

# TrueNAS codename for build-nvidia-sysext.sh's .update URL construction.
# Mirrors build-nvidia-sysext.sh's auto-detect default; centralized here so
# the install script can pass an explicit value (build script's auto-detect
# is fine, but being explicit avoids divergence later).
resolve_truenas_codename() {
    case "$1" in
        25.*) echo "Goldeye" ;;
        *)    echo "" ;;
    esac
}

# Parse NVIDIA driver version out of an NVIDIA .run filename. Returns empty
# on no match.
# Format: NVIDIA-Linux-x86_64-X.Y.Z-no-compat32.run → X.Y.Z
parse_nvidia_version_from_run_file() {
    basename "$1" \
        | sed -nE 's/^NVIDIA-Linux-x86_64-([0-9]+\.[0-9]+\.[0-9]+)-no-compat32\.run$/\1/p'
}

# Read the driver version embedded in a sysext .raw via libnvidia-ml.so.X.Y.Z.
read_raw_driver_version() {
    [ -f "$1" ] || return 0
    unsquashfs -l "$1" 2>/dev/null \
        | grep -oE 'libnvidia-ml\.so\.[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1 \
        | sed 's/^libnvidia-ml\.so\.//' || true
}

# Read the kernel version a sysext .raw was built for (single subdir of
# usr/lib/modules/).
#
# `unsquashfs -l` prints rooted paths like `squashfs-root/usr/lib/modules/<kver>`
# with no separator before `usr/`, so the regex anchors on the substring
# (an earlier `.* usr/lib/modules/` form silently never matched and made
# cache_valid_for_target always miss, forcing a rebuild on every re-install).
read_raw_kernel_version() {
    [ -f "$1" ] || return 0
    unsquashfs -l "$1" 2>/dev/null \
        | sed -nE 's|.*usr/lib/modules/([^/[:space:]]+)$|\1|p' \
        | sort -u | head -1
}

# 0 if PERSIST_DIR/nvidia.raw matches the target NVIDIA version AND the
# currently running kernel; 1 otherwise. Hot path on re-installs.
cache_valid_for_target() {
    local target_drv="$1"
    local cached="${PERSIST_DIR}/nvidia.raw"
    [ -f "$cached" ] || return 1
    local cached_drv cached_kver running_kver
    cached_drv=$(read_raw_driver_version "$cached")
    cached_kver=$(read_raw_kernel_version "$cached")
    running_kver=$(uname -r)
    [ -n "$cached_drv" ] && [ "$cached_drv" = "$target_drv" ] || return 1
    [ -n "$cached_kver" ] && [ "$cached_kver" = "$running_kver" ] || return 1
    return 0
}

# Stage build helpers to ${PERSIST_DIR}/scripts/ so the user has a stable
# invocation point for ad-hoc kernel-bump rebuilds (no need to re-run the
# full install one-liner). Prefer local checkout when this script is run
# from one; else fetch from main. Echoes the staged dir on stdout.
stage_build_helpers() {
    local stage_dir="${PERSIST_DIR}/scripts"
    if_real mkdir -p "$stage_dir"
    local f
    for f in build-on-host.sh build-nvidia-sysext.sh; do
        if [ -n "${SCRIPT_DIR:-}" ] && [ -f "${SCRIPT_DIR}/${f}" ]; then
            if_real cp "${SCRIPT_DIR}/${f}" "${stage_dir}/${f}"
        else
            local url="https://raw.githubusercontent.com/${REPO}/main/scripts/${f}"
            if $DRY_RUN; then
                echo "[dry-run] would: curl -fL -o ${stage_dir}/${f} ${url}" >&2
            else
                curl -fL --retry 3 -o "${stage_dir}/${f}" "$url" \
                    || { echo "ERROR: failed to download build helper: $f" >&2; return 1; }
            fi
        fi
        if_real chmod 0755 "${stage_dir}/${f}"
    done
    printf '%s\n' "$stage_dir"
}

# Invoke build-on-host.sh inside a transient ubuntu:24.04 container to
# produce nvidia.raw. Caches to ${PERSIST_DIR}/cache so the TrueNAS .update
# (~1.5 GB) and NVIDIA .run (~400 MB) survive between rebuilds. Echoes the
# path of the built .raw on stdout.
build_driver_sysext_on_host() {
    local nvidia_ver="$1" truenas_ver="$2" stage_dir="$3"
    local codename out_dir built_raw
    codename=$(resolve_truenas_codename "$truenas_ver")
    out_dir="${PERSIST_DIR}/build"
    if_real mkdir -p "$out_dir"
    built_raw="${out_dir}/nvidia.raw"

    local args=(
        --nvidia-version="$nvidia_ver"
        --truenas-version="$truenas_ver"
        --kernel-module-type="$KMOD_TYPE"
        --cache-dir="${PERSIST_DIR}/cache"
        --scripts-dir="$stage_dir"
        --out="$built_raw"
    )
    [ -n "$codename" ] && args+=(--truenas-codename="$codename")
    [ -n "$CUSTOM_RUN" ] && args+=(--run-file="$CUSTOM_RUN")

    if $DRY_RUN; then
        echo "[dry-run] would: ${stage_dir}/build-on-host.sh ${args[*]}" >&2
        echo "[dry-run] would: produce $built_raw" >&2
        # Synthesize a path so downstream sanity-check gates can skip cleanly
        # under DRY_RUN without NPE-ing on an unset variable.
        printf '%s\n' "$built_raw"
        return 0
    fi

    # Redirect to stderr: build-on-host.sh's info/banner lines and the
    # docker run's container stdout all use fd 1. This function returns
    # the built path via stdout for $(…) capture by callers, so the build
    # log would otherwise be appended to the captured path and break the
    # downstream `[ -f "$DRIVER_SRC" ]` check.
    "${stage_dir}/build-on-host.sh" "${args[@]}" >&2 \
        || { echo "ERROR: build-on-host.sh failed" >&2; return 1; }
    [ -f "$built_raw" ] \
        || { echo "ERROR: build-on-host claimed success but $built_raw is missing" >&2; return 1; }
    printf '%s\n' "$built_raw"
}

# Path to this script's own directory if invoked from a checkout; empty when
# piped from stdin (curl|bash). Used both for staging build helpers and the
# PREINIT script. `BASH_SOURCE[0]:-` to dodge set -u when reading from stdin.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd || true)"

[ "$(id -u 2>/dev/null)" = "0" ] || { echo "ERROR: must run as root" >&2; exit 1; }

# --- Resolve persistent storage location ---
# resolve_persist_dir is duplicated verbatim across install-mig-sysext.sh,
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

    echo "=== install-mig-sysext status ==="
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
                "re-run install-mig-sysext.sh --with-driver"
        fi

        # PREINIT helper staged
        if [ -n "${PERSIST_DIR:-}" ] && [ -x "${PERSIST_DIR}/nvidia-preinit-driver.sh" ]; then
            record_pass "PREINIT helper ${PERSIST_DIR}/nvidia-preinit-driver.sh staged and executable"
        elif [ -n "${PERSIST_DIR:-}" ] && [ -x "${PERSIST_DIR}/nvidia-preinit-full.sh" ]; then
            record_warn "Legacy PREINIT helper ${PERSIST_DIR}/nvidia-preinit-full.sh present (pre-rename)" \
                "re-run install-mig-sysext.sh --with-driver to upgrade to nvidia-preinit-driver.sh"
        elif [ -n "${PERSIST_DIR:-}" ]; then
            record_fail "PREINIT helper missing in ${PERSIST_DIR}" \
                "re-run install-mig-sysext.sh --with-driver"
        fi
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
# Validate --persist-path shape: the boot-time PREINIT (nvidia-preinit-driver.sh)
# only scans /mnt/*/.config/nvidia-gpu, so any other location silently breaks
# persistence after a reboot or TrueNAS update. Refuse early. --pool resolves
# to this shape automatically.
if [ -n "$PERSIST_PATH" ]; then
    PERSIST_PATH_REAL=$(realpath -m "$PERSIST_PATH" 2>/dev/null || echo "$PERSIST_PATH")
    if [[ ! "$PERSIST_PATH_REAL" =~ ^/mnt/[^/]+/\.config/nvidia-gpu/?$ ]]; then
        echo "ERROR: --persist-path must be /mnt/<pool>/.config/nvidia-gpu (got: ${PERSIST_PATH})" >&2
        echo "  The boot-time PREINIT script only scans /mnt/*/.config/nvidia-gpu," >&2
        echo "  so any other location silently breaks persistence after a reboot or update." >&2
        echo "  Pass --pool=<name> instead (it resolves to /mnt/<name>/.config/nvidia-gpu)." >&2
        exit 2
    fi
fi
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

# --- Acquire nvidia.raw (--with-driver only) ---
# Priority:
#   1. --driver-sysext=PATH       — use as-is, skip build entirely
#   2. cached PERSIST_DIR/nvidia.raw matches target driver + running kernel
#      — reuse it (skip the ~8 min build) unless --rebuild was passed
#   3. otherwise — build on this host via build-on-host.sh
#
# DRIVER_ASSET is no longer a release asset; the repo doesn't publish
# nvidia.raw (NVIDIA EULA — see README License section). The release tag
# still encodes the recommended-tested driver version for the install
# script to target.
if $WITH_DRIVER; then
    if [ -n "$DRIVER_SRC" ]; then
        echo "Using pre-built driver sysext: $DRIVER_SRC (--driver-sysext given; skipping build)"
    else
        # Resolve target NVIDIA version: from --custom-run filename if given,
        # else parsed from the resolved release tag.
        TARGET_NV_VER=""
        if [ -n "$CUSTOM_RUN" ]; then
            TARGET_NV_VER=$(parse_nvidia_version_from_run_file "$CUSTOM_RUN")
            if [ -z "$TARGET_NV_VER" ]; then
                echo "ERROR: cannot parse version from --custom-run filename '$CUSTOM_RUN'" >&2
                echo "       Expected: NVIDIA-Linux-x86_64-<X.Y.Z>-no-compat32.run" >&2
                exit 1
            fi
            echo "Custom .run version: $TARGET_NV_VER ($(basename "$CUSTOM_RUN"))"
        else
            TARGET_NV_VER=$(parse_nvidia_version_from_tag "$RESOLVED_TAG")
            if [ -z "$TARGET_NV_VER" ]; then
                echo "ERROR: cannot parse NVIDIA version from release tag '$RESOLVED_TAG'" >&2
                echo "       Pass --custom-run=PATH to specify an installer explicitly." >&2
                exit 1
            fi
            echo "Target NVIDIA driver (from release tag): $TARGET_NV_VER"
        fi

        # Resolve target TrueNAS version. Prefer parsed-from-tag (matches
        # what the release was tested against); fall back to live midclt.
        TARGET_TN_VER=$(parse_truenas_version_from_tag "$RESOLVED_TAG")
        if [ -z "$TARGET_TN_VER" ]; then
            TARGET_TN_VER=$(detect_truenas_version || true)
            if [ -z "$TARGET_TN_VER" ]; then
                echo "ERROR: cannot determine TrueNAS version for the build" >&2
                exit 1
            fi
        fi

        if ! $REBUILD && cache_valid_for_target "$TARGET_NV_VER"; then
            DRIVER_SRC="${PERSIST_DIR}/nvidia.raw"
            echo "Reusing cached driver sysext (driver=$TARGET_NV_VER, kernel=$(uname -r))"
            echo "  $DRIVER_SRC"
            echo "  (pass --rebuild to force a fresh build)"
        else
            if $REBUILD; then
                echo "--rebuild given; ignoring any cached nvidia.raw"
            else
                echo "No valid cached nvidia.raw for driver=$TARGET_NV_VER + kernel=$(uname -r); building on host"
                echo "(first run takes ≈ 8 min; cached for subsequent installs)"
            fi
            STAGED_SCRIPTS_DIR=$(stage_build_helpers) \
                || { echo "ERROR: failed to stage build helpers" >&2; exit 1; }
            DRIVER_SRC=$(build_driver_sysext_on_host "$TARGET_NV_VER" "$TARGET_TN_VER" "$STAGED_SCRIPTS_DIR") \
                || exit 1
            echo "Built driver sysext: $DRIVER_SRC"
        fi
    fi

    # Existence check — skip in dry-run since the build path synthesizes a
    # not-yet-created path. --driver-sysext / cache-reuse paths produce a
    # real file even under dry-run.
    if ! $DRY_RUN && [ ! -f "$DRIVER_SRC" ]; then
        echo "ERROR: driver sysext source not found: $DRIVER_SRC" >&2
        exit 1
    fi
fi

# Track /usr writable state so the trap can put it back. Without this, a
# failure under set -e (or a SIGTERM) between `zfs set readonly=off` and the
# matching readonly=on would leave /usr writable until the next reboot.
USR_WAS_WRITABLE=0
USR_DATASET=""

# GPU-release rollback state (only ever set on a --with-driver run). Before the
# driver swap, --with-driver stops every GPU-bound app and disables the docker
# nvidia toggle to free the GPU. On a clean run those are restored later by the
# post-reboot configure-mig. On an aborted run nothing restored them: install
# was the only one of the four GPU scripts whose trap put /usr readonly back but
# left the apps stopped and the toggle off. uninstall-mig-sysext.sh and
# recover-stock-nvidia.sh already roll the toggle back in their restore_state
# trap (PR #55); this brings install in line and also restarts the apps.
TOGGLE_DISABLED=0       # 1 once we've written docker.update {"nvidia": false}
ORIG_NVIDIA_TOGGLE=""   # toggle value captured before we disabled it
STOPPED_APPS=""         # newline-separated apps we stopped, to restart on abort
STOPPING_APP=""         # app whose app.stop is in flight right now (mid-call abort)
SWAP_STARTED=0          # 1 once the driver teardown (unmerge/swap) has begun

# Cleanup trap: tempfiles + /usr readonly always; on abnormal exit, also undo
# the GPU release so an aborted install doesn't leave the host with its apps
# stopped and the nvidia toggle off.
cleanup_tmp() {
    rc=$?
    if [ "$USR_WAS_WRITABLE" = "1" ] && [ -n "$USR_DATASET" ]; then
        zfs set readonly=on "$USR_DATASET" 2>/dev/null || true
        USR_WAS_WRITABLE=0
    fi
    [ -n "${MIG_TMP:-}" ] && rm -f "$MIG_TMP"
    [ -n "${DRIVER_TMP:-}" ] && rm -f "$DRIVER_TMP"
    [ -n "${PREINIT_DRY_TMP:-}" ] && rm -f "$PREINIT_DRY_TMP"

    # Clean exit: the toggle-off and stopped apps are intentional. --with-driver
    # requires a reboot, and the post-reboot configure-mig re-enables the toggle
    # and restarts the apps. Nothing to undo.
    [ "$rc" -eq 0 ] && return

    # Died before/early in the GPU-release block, nothing was released yet.
    [ "$TOGGLE_DISABLED" = "1" ] || [ -n "$STOPPED_APPS" ] || return

    if [ "$SWAP_STARTED" = "1" ]; then
        # The driver teardown was already in flight, so the running driver may
        # be half-swapped. Restarting apps onto it could crash them, so point
        # the user at the dedicated recovery path instead of guessing.
        echo "" >&2
        echo "ABORTED after the driver swap began. The NVIDIA driver may be in a partial state." >&2
        echo "  Recover the stock driver (or re-run the install) before starting apps:" >&2
        if [ -n "${SCRIPT_DIR:-}" ]; then
            echo "    sudo ${SCRIPT_DIR}/recover-stock-nvidia.sh" >&2
        else
            echo "    sudo recover-stock-nvidia.sh" >&2
        fi
        if [ -n "$STOPPED_APPS" ]; then
            echo "  These apps were stopped and were NOT restarted:" >&2
            printf '%s\n' "$STOPPED_APPS" | while IFS= read -r a; do
                [ -n "$a" ] && echo "    $a" >&2
            done
        fi
        return
    fi

    # Pre-swap abort: the stock driver is still intact and merged, so fully roll
    # the GPU release back to the host's pre-install state. Restore the toggle
    # BEFORE restarting apps: with the toggle off, TrueNAS won't start docker
    # containers at all (GPU and non-GPU alike), so an app.start while it's still
    # false would no-op. Re-enable the runtime first, then bring the apps back.
    echo "" >&2
    echo "Install aborted before the driver swap, rolling back GPU release..." >&2
    if [ "$TOGGLE_DISABLED" = "1" ]; then
        want="${ORIG_NVIDIA_TOGGLE:-true}"
        echo "  Restoring docker nvidia toggle to ${want}..." >&2
        midclt call docker.update "{\"nvidia\": ${want}}" >/dev/null 2>&1 \
            || echo "    WARN: could not restore the toggle, set it in the Apps settings" >&2
    fi
    # Include any app whose app.stop was in flight when we aborted: it never
    # reached the success branch, so it's not in STOPPED_APPS, but the job may
    # have stopped it server-side. Restarting an app that's actually still up is
    # a harmless no-op.
    APPS_TO_RESTART="$STOPPED_APPS"
    [ -n "$STOPPING_APP" ] && APPS_TO_RESTART+="$STOPPING_APP"$'\n'
    if [ -n "$APPS_TO_RESTART" ]; then
        printf '%s\n' "$APPS_TO_RESTART" | while IFS= read -r a; do
            [ -z "$a" ] && continue
            echo "  Restarting $a..." >&2
            midclt call -j app.start "$a" >/dev/null 2>&1 \
                || echo "    WARN: could not restart $a, start it from the Apps UI" >&2
        done
    fi
}
# EXIT carries the real exit code (normal completion, a `set -e` failure, or an
# explicit `exit N`). Signals get their own traps that exit with a conventional
# code, so the EXIT trap runs exactly once with a non-zero rc. A combined
# `trap cleanup_tmp EXIT INT TERM` is wrong here: on a signal bash runs the
# handler but does NOT exit, so the script RESUMES past the interruption and the
# handler sees rc=0 — the rollback would be skipped and the install would carry
# on. INT/TERM are at default disposition in an interactive foreground run
# (sudo ./install-...), so these traps install and Ctrl-C rolls back correctly.
trap cleanup_tmp EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
# Skip under dry-run when the build path synthesized a not-yet-built path.
# --driver-sysext and cache-reuse always produce a real file, so we still
# validate in those cases even in dry-run.
if $WITH_DRIVER && { ! $DRY_RUN || [ -f "$DRIVER_SRC" ]; }; then
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
    # Cache-reuse branch (line ~920) sets DRIVER_SRC to ${PERSIST_DIR}/nvidia.raw
    # directly, so `cp src dst` would be `cp X X` and cp errors out. Skip
    # the copy when src and dst are already the same file. `-ef` handles
    # symlinks, relative paths, and hard links correctly.
    if [ "$DRIVER_SRC" -ef "${PERSIST_DIR}/nvidia.raw" ] 2>/dev/null; then
        $DRY_RUN || echo "Driver sysext already at ${PERSIST_DIR}/nvidia.raw (cache-reuse); skipping copy"
    else
        if_real cp "$DRIVER_SRC" "${PERSIST_DIR}/nvidia.raw"
        $DRY_RUN || echo "Copied driver sysext to ${PERSIST_DIR}/nvidia.raw"
    fi

    # Stage nvidia-preinit-driver.sh BEFORE any /usr mutations so a failed
    # download fails fast instead of leaving the host half-installed.
    # Fetched from main (durable), not the current branch.
    SCRIPT_URL_BASE="https://raw.githubusercontent.com/${REPO}/main/scripts"
    PREINIT_LOCAL="${PERSIST_DIR}/nvidia-preinit-driver.sh"
    # SCRIPT_DIR is resolved at script load to the dirname of $0 (empty when
    # curl|bash'd from stdin), used here and by stage_build_helpers.
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

    # Free the GPU so we can swap nvidia.raw safely. The docker.update
    # '{"nvidia": false}' toggle alone is NOT enough — it only reconfigures
    # the docker runtime for future container starts, leaving running
    # containers (Frigate's ffmpeg NVENC, Ollama CUDA, etc.) attached. They
    # hold the kernel module past the wait window and the swap proceeds
    # with stale handles still in memory. The reboot afterward usually
    # masks this, but only by accident.
    #
    # Mirrors configure-mig.sh's per-app stop (PR #48). Three steps:
    #   1. Identify apps with a *currently-valid* GPU UUID assignment
    #      (use_gpu=true AND uuid matches a device on the current GPU).
    #   2. app.stop -j each one — blocks on actual container teardown.
    #   3. docker.update toggle as belt-and-suspenders for any nvidia
    #      runtime container outside the per-app scan.
    # Drain check after that should be near-instant; on timeout we warn
    # and continue (reboot resolves any latent issue — install's required-
    # reboot semantics let us be lenient where configure-mig must abort).
    echo ""
    echo "Stopping GPU-bound apps to free the GPU..."

    # Capture the toggle's current value before we touch it, so an aborted
    # install restores exactly what was there. (uninstall/recover hardcode
    # `true`; here we keep the user's actual prior state in case they had it
    # off, e.g. no GPU apps.)
    if ! $DRY_RUN; then
        ORIG_NVIDIA_TOGGLE=$(midclt call docker.config 2>/dev/null \
            | python3 -c "import sys,json; print('true' if json.load(sys.stdin).get('nvidia') else 'false')" 2>/dev/null || true)
        [ -n "$ORIG_NVIDIA_TOGGLE" ] || ORIG_NVIDIA_TOGGLE="true"
    fi

    if $DRY_RUN; then
        echo "[dry-run] would: scan app.query for apps with use_gpu=true + a valid GPU UUID"
        echo "[dry-run] would: app.stop -j each match, then docker.update '{\"nvidia\": false}'"
        echo "[dry-run] would: wait up to 30s for GPU compute clients to release"
    elif [ -x /usr/bin/nvidia-smi ]; then
        VALID_UUIDS=$(/usr/bin/nvidia-smi -L 2>/dev/null \
            | sed -nE 's/.*\(UUID:[[:space:]]*((GPU|MIG)-[^)]+)\).*/\1/p' || true)

        # `|| true` on every middleware command substitution — `set -e` +
        # pipefail would abort the whole install if any single app's
        # config read fails (mid-deploy, crashed, transient middleware
        # error). Pattern carried over from uninstall + configure-mig.
        ALL_APPS=$(midclt call app.query 2>/dev/null | python3 -c "
import sys, json
try:
    for a in json.load(sys.stdin):
        n = a.get('name', '')
        s = a.get('state', '')
        if n: print(f'{n}|{s}')
except Exception:
    pass" 2>/dev/null || true)

        GPU_APPS_INFO=""
        if [ -n "$ALL_APPS" ]; then
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                app="${line%|*}"
                state="${line#*|}"
                config_json=$(midclt call app.config "$app" 2>/dev/null || true)
                is_gpu=$(printf '%s' "$config_json" | VALID_UUIDS="$VALID_UUIDS" python3 -c "
import sys, json, os
valid = set(os.environ.get('VALID_UUIDS', '').split())
try:
    d = json.load(sys.stdin)
    gpus = (d.get('resources', {}) or {}).get('gpus', {}) or {}
    sel = gpus.get('nvidia_gpu_selection', {}) or {}
    for slot, cfg in sel.items():
        if isinstance(cfg, dict):
            uuid = (cfg.get('uuid') or '').strip()
            # Two gates (same as configure-mig): use_gpu must be
            # explicitly true, AND uuid must reference a device on
            # the current hardware (filters stale GPU-swap UUIDs).
            if cfg.get('use_gpu') is True and uuid and uuid in valid:
                print('y')
                break
except Exception:
    pass" 2>/dev/null || true)
                if [ "$is_gpu" = "y" ]; then
                    GPU_APPS_INFO+="$app|$state"$'\n'
                fi
            done <<<"$ALL_APPS"
        fi

        if [ -z "$GPU_APPS_INFO" ]; then
            echo "  No GPU-bound apps found"
        else
            echo "  GPU-bound apps (will be stopped):"
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                IFS='|' read -r gapp gstate <<<"$line"
                echo "    $gapp (state=$gstate)"
            done <<<"$GPU_APPS_INFO"

            echo ""
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                IFS='|' read -r app state <<<"$line"
                if [ "$state" != "RUNNING" ]; then
                    echo "  $app: state=$state — no container to stop"
                    continue
                fi
                # Mark in-flight before the call. app.stop -j is a blocking job;
                # if a signal kills the client mid-call the middleware may still
                # finish stopping the app, so the rollback must know to restart
                # it even though we never reached the success branch below.
                STOPPING_APP="$app"
                if run_with_elapsed_capture "  Stopping $app" \
                    midclt call -j app.stop "$app"; then
                    echo "  Stopping $app... OK (${ELAPSED}s)"
                    # Record it so an aborted install restarts what it stopped.
                    STOPPED_APPS+="$app"$'\n'
                else
                    echo "  Stopping $app... WARN (${ELAPSED}s): $CAPTURED_OUT"
                fi
                # Call returned (success or clean failure): no longer in flight.
                # A clean failure means the app is still up, so we deliberately
                # leave it out of STOPPED_APPS — nothing to restart.
                STOPPING_APP=""
            done <<<"$GPU_APPS_INFO"
        fi

        echo ""
        echo "  Disabling nvidia toolkit for docker (belt-and-suspenders)..."
        TOGGLE_DISABLED=1
        midclt call docker.update '{"nvidia": false}' >/dev/null \
            || echo "  WARN: docker.update returned an error — middleware may be flapping"

        # Short drain — per-app stop already blocked on container teardown,
        # so this only catches the brief window before the driver releases
        # CUDA contexts. 30s is plenty when step 2 actually worked.
        printf "  Waiting for GPU compute clients to release... 0s/30s"
        for attempt in $(seq 1 10); do
            N=$(/usr/bin/nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l || echo 0)
            if [ "${N:-0}" -eq 0 ]; then
                printf "\r  GPU compute clients released                              \n"
                break
            fi
            printf "\r  Waiting for %d GPU process(es)... %ds/30s" "$N" "$((attempt * 3))"
            sleep 3
        done
        if [ "${N:-0}" -gt 0 ]; then
            echo ""
            echo "  WARN: $N GPU process(es) still attached after 30s — continuing anyway."
            echo "        Likely a non-app holder (bare CUDA, manual nvidia-smi, jail/VM passthrough)."
            echo "        --with-driver requires a reboot regardless, which will clear any stale state."
        fi
    else
        # No nvidia-smi (shouldn't happen on a --with-driver install with
        # stock driver present, but be defensive). Fall back to toggle only.
        echo "  nvidia-smi missing; toggling docker.nvidia=false only (no drain check)"
        TOGGLE_DISABLED=1
        midclt call docker.update '{"nvidia": false}' >/dev/null \
            || echo "  WARN: docker.update returned an error"
    fi
fi

# Unmerge sysext — happens whether or not we're doing --with-driver. In
# default mode it lets us drop in a refreshed nvidia-mig.raw symlink. In
# --with-driver mode it's a prerequisite for swapping nvidia.raw.
#
# Past this point, on a --with-driver run, the nvidia sysext is being torn down
# and the running driver is no longer trustworthy. Mark it so the abort path
# stops trying to restart apps onto a half-swapped driver and instead points at
# recover-stock-nvidia.sh.
if $WITH_DRIVER && ! $DRY_RUN; then SWAP_STARTED=1; fi
echo "Unmerging sysext..."
if_real systemd-sysext unmerge

if $WITH_DRIVER; then
    USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null)
    if [ -z "$USR_DATASET" ]; then
        echo "ERROR: could not determine the ZFS dataset for /usr; aborting before driver swap" >&2
        exit 1
    fi
    echo "Setting ${USR_DATASET} writable..."
    if_real zfs set readonly=off "$USR_DATASET"
    $DRY_RUN || USR_WAS_WRITABLE=1

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
    $DRY_RUN || USR_WAS_WRITABLE=0
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

# NOTE on the Apps' NVIDIA toggle (docker.config.nvidia):
#
# We don't touch the docker.config.nvidia toggle here. The current state
# is whatever the user (or the previous uninstall) left it at — typically
# True on a system that's been using GPU apps. If it's False (e.g. left
# that way by a prior uninstall that didn't restore it, or by the user
# explicitly turning it off), configure-mig's precheck will set it to
# True post-reboot before doing anything else.
#
# Hardware testing also showed that immediately after a fresh boot the
# apps subsystem doesn't accept docker.update writes for some time — the
# call returns success but the value doesn't persist. We don't know why;
# resolves within ~10 min. configure-mig's precheck polls through that
# window automatically.

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

>>> AFTER REBOOT — configure-mig waits for the app service automatically <<<

On a freshly-booted TrueNAS host the apps subsystem won't accept the
NVIDIA toggle for some time after boot. configure-mig now handles this:
it waits for the toggle to start accepting writes (up to 10 min) before
doing anything that touches app state, and exits with a clear error if
the wait runs out.

DO NOT run configure-mig before rebooting — it will refuse with a
driver/library-mismatch error. After the box is back up:

  sudo configure-mig                       # interactive prompt
  sudo configure-mig --mig=14,14,14,14     # non-interactive

If you want to flip the toggle yourself before running configure-mig
(e.g. to verify it accepts the write), this works too:

  sudo midclt call docker.update '{"nvidia": true}'
  sudo midclt call docker.config | python3 -c "import sys,json; print('nvidia =', json.load(sys.stdin).get('nvidia'))"
EOF
        if [ -n "$STOPPED_APPS" ]; then
            echo ""
            echo "Apps stopped to free the GPU (still stopped now):"
            printf '%s\n' "$STOPPED_APPS" | while IFS= read -r a; do
                [ -n "$a" ] && echo "  - $a"
            done
            echo ""
            echo "The post-reboot configure-mig re-enables the GPU toggle and"
            echo "restarts them. Run it after rebooting to bring your apps back"
            echo "with GPU access, not just to set up MIG."
        fi
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

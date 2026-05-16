#!/usr/bin/env bash
# Deploy the lightweight nvidia-mig sysext on TrueNAS.
#
# Adds MIG tooling alongside TrueNAS's stock NVIDIA driver. Copies
# nvidia-mig.raw to persistent storage, symlinks into /etc/extensions/,
# re-merges sysext, and registers a TrueNAS PREINIT entry so MIG instances
# are recreated on every boot. Does NOT configure MIG profiles or assign
# MIG devices to apps — run `sudo configure-mig` (bundled in the sysext)
# for that.
#
# Default: auto-detects the running TrueNAS version, then picks the most
# recently published release whose tag begins `v<version>-mig-` and
# downloads nvidia-mig.raw from it. Releases are append-only and tagged
# with a unique `-r<run_number>` suffix; the install script always pulls
# the newest matching one.
#
# Override with --release=TAG (specific tag) or --sysext=PATH (local file).
# Use --check to probe an existing install, or --dry-run to walk through the
# install without making changes.
#
# Usage:
#   sudo ./install-mig-sysext.sh                              # auto-detect + install
#   sudo ./install-mig-sysext.sh --check                      # read-only status probe
#   sudo ./install-mig-sysext.sh --dry-run                    # validate, skip mutations
#   sudo ./install-mig-sysext.sh --release=v25.10.3.1-mig-r5
#   sudo ./install-mig-sysext.sh --sysext=/tmp/nvidia-mig.raw # local file
#   sudo ./install-mig-sysext.sh --pool=fast
#
# Flags:
#   --sysext=PATH         Local nvidia-mig.raw to install (skips download)
#   --release=TAG         Download from this exact release tag
#   --pool=NAME           ZFS pool for persistent storage (skips auto-detect)
#   --persist-path=PATH   Exact directory for persistent storage (overrides --pool)
#   --force               Bypass the stock-driver-version pre-flight check
#                         (refuses on stock driver major <570 without --force)
#   --check               Read-only probe of an existing install. Reports the
#                         state of: stock driver merged + version, MIG sysext
#                         file/symlink/merge, persist dir, mig.conf, PREINIT
#                         registration, nvidia-mig-setup.service status.
#                         Exits 1 if anything fails.
#   --dry-run             Validate URL + downloaded sysext but skip every
#                         command that would mutate the running system.
#                         Each skipped mutation is logged as `[dry-run] would: ...`.
#                         Mutually exclusive with --check.
#   -h, --help            Show this help and exit
#
# Pool selection priority: --persist-path > --pool > existing config dir > only
# data pool > interactive prompt (multi-pool) > error (no tty + ambiguous).
#
# Assumes the stock TrueNAS nvidia.raw is already merged (provides drivers).

set -euo pipefail

REPO="truenas-community-sysexts/nvidia-mig-support"
ASSET="nvidia-mig.raw"
TAG_PREFIX_SUFFIX="-mig-"  # full prefix is v<truenas>-mig-
STOCK_NVIDIA="/usr/share/truenas/sysext-extensions/nvidia.raw"
MIN_DRIVER_MAJOR=570

SYSEXT_SRC=""
RELEASE_TAG=""
POOL_NAME=""
PERSIST_PATH=""
FORCE=false
CHECK_MODE=false
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --sysext=*) SYSEXT_SRC="${arg#*=}" ;;
        --release=*) RELEASE_TAG="${arg#*=}" ;;
        --pool=*) POOL_NAME="${arg#*=}" ;;
        --persist-path=*) PERSIST_PATH="${arg#*=}" ;;
        --force) FORCE=true ;;
        --check) CHECK_MODE=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'
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
    # `?per_page=100`: GitHub defaults to 30 results, so once the repo
    #   crosses 30 releases, installs for older TrueNAS versions would
    #   silently fail to find a matching tag.
    # `curl -sS` (not -sf): let curl surface transport errors AND let Python
    #   see the API error body. The original `-sf` swallowed HTTP error
    #   responses entirely, so rate-limit 403s presented as "no release
    #   found" with no hint at the real cause.
    # `PREFIX` via env (not `prefix = '${prefix}'`): a shell-interpolated
    #   single quote inside `prefix` would close the Python literal and
    #   inject arbitrary Python. Passing through the environment removes
    #   that injection point entirely. Defense in depth: today `prefix`
    #   is built from midclt + a hardcoded suffix, but future callers
    #   could route user input through it.
    # The error-path "Available releases" listing is folded into the same
    # Python call to avoid a duplicate API request (matters on rate-limit
    # failure modes).
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

if [ "$(id -u 2>/dev/null)" != "0" ]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

# --- Pre-flight: detect stock nvidia driver version inside the sysext on disk ---
# Doesn't require the driver to be loaded; reads the version directly from
# filenames inside /usr/share/truenas/sysext-extensions/nvidia.raw.
# Skipped under --check (do_check reports the same info as a check item
# instead of hard-exiting on missing stock).
if ! $CHECK_MODE; then
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
fi

# If no source given, fetch from the resolved release.
# Skipped under --check (no install happens; nothing to download).
if ! $CHECK_MODE; then
    if [ -z "$SYSEXT_SRC" ]; then
        SYSEXT_SRC=$(mktemp -t nvidia-mig.raw.XXXXXX)
        trap 'rm -f "$SYSEXT_SRC"' EXIT
        RESOLVED_TAG=$(resolve_release_tag)
        RELEASE_URL="https://github.com/${REPO}/releases/download/${RESOLVED_TAG}/${ASSET}"
        echo "Downloading ${RELEASE_URL}"
        curl -fL --retry 3 -o "$SYSEXT_SRC" "$RELEASE_URL"
    fi

    if [ ! -f "$SYSEXT_SRC" ]; then
        echo "ERROR: sysext source $SYSEXT_SRC does not exist" >&2
        exit 1
    fi
fi

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

    # 1. Explicit --persist-path wins
    if [ -n "${PERSIST_PATH:-}" ]; then
        PERSIST_DIR="$PERSIST_PATH"
        return 0
    fi
    # 2. Explicit --pool
    if [ -n "${POOL_NAME:-}" ]; then
        PERSIST_DIR="/mnt/${POOL_NAME}/.config/nvidia-gpu"
        return 0
    fi

    # Discover existing nvidia-gpu config dirs
    for d in /mnt/*/.config/nvidia-gpu; do
        [ -d "$d" ] && existing+=("$d")
    done

    # Discover data pools (boot-pool excluded)
    while IFS= read -r p; do
        [ -n "$p" ] && [ "$p" != "boot-pool" ] && pools+=("$p")
    done < <(zpool list -H -o name 2>/dev/null)

    if [ "${#pools[@]}" -eq 0 ]; then
        echo "ERROR: no data pool found (only boot-pool). Pass --pool=NAME or --persist-path=PATH." >&2
        return 1
    fi

    # 3. Exactly one existing config → silent reuse
    if [ "${#existing[@]}" -eq 1 ]; then
        PERSIST_DIR="${existing[0]}"
        echo "Using existing nvidia-gpu config: $PERSIST_DIR"
        return 0
    fi
    # 4. No existing config + exactly one data pool → silent auto
    if [ "${#existing[@]}" -eq 0 ] && [ "${#pools[@]}" -eq 1 ]; then
        PERSIST_DIR="/mnt/${pools[0]}/.config/nvidia-gpu"
        echo "Auto-selected pool: ${pools[0]} → $PERSIST_DIR"
        return 0
    fi

    # 5/6. Genuine ambiguity — prompt
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
do_check() {
    # Read-only probe of an existing MIG sysext install. Reports pass/warn/fail.
    # Returns 0 if all checks pass (warnings allowed), 1 if anything failed.
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

    echo "=== MIG sysext install status ==="
    echo ""

    # Stock NVIDIA driver merged (prereq for MIG)
    if systemd-sysext list 2>/dev/null | awk '{print $1}' | grep -qx nvidia; then
        record_pass "Stock 'nvidia' sysext merged (prereq for MIG sysext)"
    else
        record_fail "Stock 'nvidia' sysext not merged" \
            "MIG sysext layers on the stock driver — without it, MIG can't load"
    fi

    # Stock driver version >= MIN_DRIVER_MAJOR (570)
    local stock_drv="" stock_major=""
    if command -v unsquashfs >/dev/null 2>&1 && [ -f "$STOCK_NVIDIA" ]; then
        stock_drv=$(unsquashfs -l "$STOCK_NVIDIA" 2>/dev/null \
            | grep -oE 'libnvidia-ml\.so\.[0-9]+\.[0-9]+\.[0-9]+' \
            | head -1 | sed 's/^libnvidia-ml\.so\.//' || true)
    fi
    if [ -n "$stock_drv" ]; then
        stock_major=${stock_drv%%.*}
        if [ "$stock_major" -ge "$MIN_DRIVER_MAJOR" ]; then
            record_pass "Stock driver ${stock_drv} >= minimum ${MIN_DRIVER_MAJOR}.x"
        else
            record_fail "Stock driver ${stock_drv} < ${MIN_DRIVER_MAJOR}.x (MIG validated only on >= ${MIN_DRIVER_MAJOR}.x)" \
                "wait for TrueNAS to ship a newer driver, or install the full-driver sysext"
        fi
    else
        record_warn "Could not detect stock driver version in ${STOCK_NVIDIA}" \
            "unsquashfs missing or sysext file unreadable"
    fi

    # Bundled-MIG detection: the full-driver nvidia.raw can be built with
    # BUNDLE_MIG=true (default), which packs configure-mig + nvidia-mig-setup
    # service + binary directly into nvidia.raw. In that case the separate
    # MIG sysext is genuinely not needed — and the file/symlink/merge checks
    # below would all (correctly) fail, which is confusing. Detect the case
    # by: (a) nvidia merged, (b) /usr/bin/configure-mig present (provided
    # by the bundled sysext), (c) nvidia-mig NOT merged. Collapse the three
    # MIG-sysext-specific checks into one pass.
    local bundled_mig=false
    if systemd-sysext list 2>/dev/null | awk '{print $1}' | grep -qx nvidia \
        && [ -x /usr/bin/configure-mig ] \
        && ! systemd-sysext list 2>/dev/null | awk '{print $1}' | grep -qx nvidia-mig; then
        bundled_mig=true
    fi

    if $bundled_mig; then
        record_pass "MIG tooling provided by bundled full-driver sysext (nvidia.raw built with BUNDLE_MIG=true) — separate MIG sysext not needed"
    else
        # MIG sysext file on persist dir
        if [ -n "${PERSIST_DIR:-}" ] && [ -f "${PERSIST_DIR}/nvidia-mig.raw" ]; then
            record_pass "MIG sysext present at ${PERSIST_DIR}/nvidia-mig.raw"
        elif [ -n "${PERSIST_DIR:-}" ]; then
            record_fail "MIG sysext missing at ${PERSIST_DIR}/nvidia-mig.raw" \
                "re-run install-mig-sysext.sh"
        fi

        # /etc/extensions/ symlink
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

    # PREINIT registered with TrueNAS middleware
    if command -v midclt >/dev/null 2>&1; then
        local entry
        entry=$(midclt call initshutdownscript.query 2>/dev/null \
            | python3 -c "
import sys, json
try:
    for s in json.load(sys.stdin):
        haystack = (s.get('command') or '') + ' ' + (s.get('script') or '')
        if 'nvidia-mig-setup' in haystack or 'nvidia-preinit-full' in haystack:
            print(f\"{s.get('when','?')}|{s.get('enabled','?')}\")
            break
except Exception:
    pass" 2>/dev/null || true)
        if [ -z "$entry" ]; then
            record_fail "No PREINIT entry registered for nvidia-mig-setup" \
                "re-run install — middleware registration missing"
        else
            local when enabled
            IFS='|' read -r when enabled <<<"$entry"
            if [ "$when" = "PREINIT" ] && [ "$enabled" = "True" ]; then
                record_pass "PREINIT registered with TrueNAS middleware (PREINIT, enabled)"
            else
                record_warn "PREINIT entry exists but state is when=${when}, enabled=${enabled}" \
                    "re-run install to normalize"
            fi
        fi
    else
        record_warn "midclt not available — skipping middleware check" \
            "this script must run on TrueNAS SCALE"
    fi

    # nvidia-mig-setup.service status (reports current state regardless)
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

resolve_persist_dir || exit 1

echo "=== Install nvidia-mig sysext ==="
echo "Source:      $SYSEXT_SRC"
echo "Persist dir: $PERSIST_DIR"
echo ""

# --- Verify the source is a usable sysext ---
# Buffer the listing before grepping. `unsquashfs -l … | grep -q` is
# broken under `set -o pipefail`: grep -q exits early on first match,
# SIGPIPEs unsquashfs, pipefail propagates non-zero 141, the `||` block
# falsely fires even when the file IS present. See install-nvidia-sysext.sh
# for the same fix.
if command -v unsquashfs >/dev/null 2>&1; then
    if ! SYSEXT_LISTING=$(unsquashfs -l "$SYSEXT_SRC" 2>/dev/null); then
        echo "ERROR: unsquashfs -l failed on $SYSEXT_SRC" >&2
        exit 1
    fi
    if ! printf '%s\n' "$SYSEXT_LISTING" | grep -q 'extension-release.nvidia-mig'; then
        echo "ERROR: $SYSEXT_SRC does not contain extension-release.nvidia-mig" >&2
        exit 1
    fi
fi

# --- Copy to persistent storage ---
if_real mkdir -p "$PERSIST_DIR"
if_real cp "$SYSEXT_SRC" "${PERSIST_DIR}/nvidia-mig.raw"
$DRY_RUN || echo "Copied to ${PERSIST_DIR}/nvidia-mig.raw"

# --- Symlink into /etc/extensions/ alongside stock nvidia ---
if_real mkdir -p /etc/extensions
if_real ln -sf "${PERSIST_DIR}/nvidia-mig.raw" /etc/extensions/nvidia-mig.raw
$DRY_RUN || echo "Symlinked /etc/extensions/nvidia-mig.raw"

# --- Re-merge sysext to overlay the new extension ---
echo ""
echo "Re-merging systemd-sysext..."
if_real systemd-sysext unmerge
if_real systemd-sysext merge
if_real systemctl daemon-reload

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

if $DRY_RUN; then
    if [ -n "$EXISTING_ID" ]; then
        echo "[dry-run] would: midclt call initshutdownscript.update ${EXISTING_ID} '${PREINIT_JSON}'"
    else
        echo "[dry-run] would: midclt call initshutdownscript.create '${PREINIT_JSON}'"
    fi
elif [ -n "$EXISTING_ID" ]; then
    echo "PREINIT entry already exists (id: ${EXISTING_ID}), updating..."
    midclt call initshutdownscript.update "$EXISTING_ID" "$PREINIT_JSON" >/dev/null \
        || echo "WARNING: Failed to update PREINIT entry"
else
    midclt call initshutdownscript.create "$PREINIT_JSON" >/dev/null \
        || echo "WARNING: Failed to register PREINIT entry"
    echo "PREINIT entry registered"
fi

# --- Verify ---
# Skipped under --dry-run: no merge happened, so the verification would
# (correctly) flag everything as missing. Print a summary banner instead.
if $DRY_RUN; then
    echo ""
    echo "=== Dry-run complete; no system changes applied ==="
    echo ""
    echo "URL reachability, downloaded-sysext sanity, midclt-query, and"
    echo "PERSIST_DIR resolution all ran for real. Every mutation was"
    echo "logged as '[dry-run] would: ...' but not executed."
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

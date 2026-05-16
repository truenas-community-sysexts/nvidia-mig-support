#!/usr/bin/env bash
# Deploy the FULL-DRIVER nvidia.raw sysext on TrueNAS — replaces the stock
# /usr/share/truenas/sysext-extensions/nvidia.raw with a custom build that
# may ship a different driver version + bundled MIG tooling.
#
# Reboot REQUIRED after install: live-swapping nvidia.raw leaves the old
# kernel modules in memory, mismatching the new userspace libraries
# (NVML "driver/library version mismatch"). See agents.md memory.
#
# Default: auto-detects the running TrueNAS version, then picks the most
# recently published release whose tag begins `v<version>-nvidia` and
# downloads nvidia.raw from it. Releases are append-only and tagged with a
# unique `-r<run_number>` suffix; the install script always pulls the
# newest matching one.
#
# Override with --release=TAG (specific tag) or --sysext=PATH (local file).
# Use --check to probe an existing install, or --dry-run to walk through
# the install without making changes.
#
# Usage:
#   sudo ./install-nvidia-sysext.sh                                 # auto-detect + install
#   sudo ./install-nvidia-sysext.sh --check                         # read-only status probe
#   sudo ./install-nvidia-sysext.sh --dry-run                       # validate URLs/sysext, skip mutations
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
#   --check                Read-only probe of an existing install. Reports the
#                          state of: sysext file/merge, kernel module, driver
#                          version match (sysext vs nvidia-smi), persist dir,
#                          stock backup, PREINIT helper + middleware registration,
#                          configure-mig availability. Exits 1 if anything fails.
#   --dry-run              Validate every read/network step (release lookup,
#                          download, sysext content sanity) but skip every
#                          command that would mutate the running system.
#                          Each skipped mutation is logged as `[dry-run] would: ...`.
#                          Mutually exclusive with --check.
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
TAG_PREFIX_SUFFIX="-nvidia"  # full prefix is v<truenas>-nvidia
SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
LIVE_NVIDIA="${SYSEXT_DIR}/nvidia.raw"

SYSEXT_SRC=""
RELEASE_TAG=""
POOL_NAME=""
PERSIST_PATH=""
SKIP_BACKUP_CHECK=false
CHECK_MODE=false
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --sysext=*) SYSEXT_SRC="${arg#*=}" ;;
        --release=*) RELEASE_TAG="${arg#*=}" ;;
        --pool=*) POOL_NAME="${arg#*=}" ;;
        --persist-path=*) PERSIST_PATH="${arg#*=}" ;;
        --skip-backup-check) SKIP_BACKUP_CHECK=true ;;
        --check) CHECK_MODE=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if $CHECK_MODE && $DRY_RUN; then
    echo "ERROR: --check and --dry-run are mutually exclusive" >&2
    exit 2
fi

# Run a command in real mode; print `[dry-run] would: …` in dry-run mode.
# For redirections, heredocs, or compound shell logic, gate manually with
# `if $DRY_RUN; then ... else ... fi` since the shell evaluates redirections
# before any wrapper sees them.
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

[ "$(id -u 2>/dev/null)" = "0" ] || { echo "ERROR: must run as root" >&2; exit 1; }

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
do_check() {
    # Read-only probe of an existing install. Reports pass/warn/fail per check.
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

    echo "=== Full-driver nvidia.raw install status ==="
    echo ""

    # Sysext file present
    if [ -f "$LIVE_NVIDIA" ]; then
        record_pass "Sysext file present at ${LIVE_NVIDIA}"
    else
        record_fail "Sysext file missing at ${LIVE_NVIDIA}" \
            "re-run install-nvidia-sysext.sh"
    fi

    # Sysext merged into /usr
    if systemd-sysext list 2>/dev/null | awk '{print $1}' | grep -qx nvidia; then
        record_pass "Sysext 'nvidia' merged into /usr"
    else
        record_fail "Sysext 'nvidia' not currently merged" \
            "check 'systemctl status systemd-sysext' or re-run install"
    fi

    # Kernel module loaded
    if lsmod 2>/dev/null | awk '{print $1}' | grep -qx nvidia; then
        record_pass "Kernel module 'nvidia' loaded"
    else
        record_fail "Kernel module 'nvidia' not loaded" \
            "reboot — a fresh install can't load a new module while the old one is in use"
    fi

    # Driver version match (sysext libnvidia-ml vs nvidia-smi)
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

    # Persist dir
    if [ -n "${PERSIST_DIR:-}" ] && [ -d "${PERSIST_DIR}" ]; then
        record_pass "Persistent config at ${PERSIST_DIR}"
    else
        record_fail "No persistent config under /mnt/*/.config/nvidia-gpu/" \
            "re-run install with --pool=NAME or --persist-path=PATH"
    fi

    # Stock backup (warn not fail — install allows --skip-backup-check)
    if [ -n "${PERSIST_DIR:-}" ] && [ -f "${PERSIST_DIR}/nvidia-original.raw" ]; then
        record_pass "Stock backup ${PERSIST_DIR}/nvidia-original.raw present"
    elif [ -n "${PERSIST_DIR:-}" ]; then
        record_warn "No stock backup ${PERSIST_DIR}/nvidia-original.raw" \
            "you may be unable to recover the stock driver — run recover-stock-nvidia.sh"
    fi

    # PREINIT helper staged
    if [ -n "${PERSIST_DIR:-}" ] && [ -x "${PERSIST_DIR}/nvidia-preinit-full.sh" ]; then
        record_pass "PREINIT helper ${PERSIST_DIR}/nvidia-preinit-full.sh staged and executable"
    elif [ -n "${PERSIST_DIR:-}" ]; then
        record_fail "PREINIT helper missing or not executable in ${PERSIST_DIR}" \
            "re-run install"
    fi

    # PREINIT registered with TrueNAS middleware (mirrors install registration logic)
    if command -v midclt >/dev/null 2>&1; then
        local entry
        entry=$(midclt call initshutdownscript.query 2>/dev/null \
            | python3 -c "
import sys, json
try:
    for s in json.load(sys.stdin):
        haystack = (s.get('command') or '') + ' ' + (s.get('script') or '')
        if 'nvidia-preinit-full' in haystack:
            print(f\"{s.get('when','?')}|{s.get('enabled','?')}\")
            break
except Exception:
    pass" 2>/dev/null || true)
        if [ -z "$entry" ]; then
            record_fail "No PREINIT entry registered for nvidia-preinit-full" \
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

    # configure-mig command (bundled in sysext when BUNDLE_MIG=true)
    if command -v configure-mig >/dev/null 2>&1; then
        record_pass "configure-mig command available (bundled in sysext)"
    else
        record_warn "configure-mig command not found in PATH" \
            "either BUNDLE_MIG=false at build time, or the sysext isn't currently merged"
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
if_real mkdir -p "$PERSIST_DIR"

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
    RESOLVED_TAG=$(resolve_release_tag)
    RELEASE_URL="https://github.com/${REPO}/releases/download/${RESOLVED_TAG}/${ASSET}"
    echo "Downloading ${RELEASE_URL}"
    curl -fL --retry 3 -o "$SYSEXT_SRC" "$RELEASE_URL" \
        || { echo "ERROR: download failed" >&2; exit 1; }
fi
[ -f "$SYSEXT_SRC" ] || { echo "ERROR: sysext source not found: $SYSEXT_SRC" >&2; exit 1; }

# --- Sanity-check the sysext contents ---
# Capture the listing into a variable BEFORE grepping. The previous form
# `unsquashfs -l ... | grep -q PATTERN` is broken under `set -o pipefail`:
# grep -q exits as soon as it finds the first match, which SIGPIPEs the
# still-running unsquashfs, the pipeline's exit is then 141, pipefail
# propagates non-zero, and the `||` block falsely fires "missing
# extension-release.nvidia" even when the file IS present. Buffering the
# listing first eliminates the live pipe to grep entirely.
if command -v unsquashfs >/dev/null 2>&1; then
    if ! SYSEXT_LISTING=$(unsquashfs -l "$SYSEXT_SRC" 2>/dev/null); then
        echo "ERROR: unsquashfs -l failed on $SYSEXT_SRC" >&2
        exit 1
    fi
    if ! printf '%s\n' "$SYSEXT_LISTING" | grep -q 'extension-release.nvidia$'; then
        echo "ERROR: $SYSEXT_SRC missing extension-release.nvidia" >&2
        exit 1
    fi
    NEW_DRIVER=$(printf '%s\n' "$SYSEXT_LISTING" \
        | grep -oE 'libnvidia-ml\.so\.[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1 | sed 's/^libnvidia-ml\.so\.//' || true)
    echo "Sysext driver version: ${NEW_DRIVER:-unknown}"
fi

echo "=== Install full-driver nvidia.raw ==="
echo "Source:      $SYSEXT_SRC"
echo "Persist dir: $PERSIST_DIR"
echo ""

# --- Stash to persistent storage so TrueNAS updates can be survived ---
if_real cp "$SYSEXT_SRC" "${PERSIST_DIR}/nvidia.raw"
$DRY_RUN || echo "Copied custom nvidia.raw to ${PERSIST_DIR}/nvidia.raw"

# --- Stage PREINIT helper BEFORE any system mutations ---
# If the download fails (e.g. transient network issue), we want it to fail
# NOW — not after Docker is stopped and nvidia.raw has been swapped, which
# would leave the box half-installed. Fetched from main (durable), not the
# refactor branch (deleted post-merge).
#
# Under --dry-run, we still validate the URL is reachable (download to a
# tmpfile) but don't place anything in PERSIST_DIR.
SCRIPT_URL_BASE="https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts"
PREINIT_LOCAL="${PERSIST_DIR}/nvidia-preinit-full.sh"
# Use `${BASH_SOURCE[0]:-}` (not bare ${BASH_SOURCE[0]}) so the curl|bash
# code path doesn't trip `set -u`: when read from stdin, BASH_SOURCE[0]
# is unset, and a bare reference prints a noisy "unbound variable"
# diagnostic before the surrounding `|| true` salvages the assignment.
# With the default-empty, SCRIPT_DIR ends up empty silently and the
# branch below falls through to the download path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd 2>/dev/null || true)"
if $DRY_RUN; then
    PREINIT_STAGE=$(mktemp -t nvidia-preinit-full.XXXXXX.sh)
    trap '[ -n "${SYSEXT_SRC:-}" ] && rm -f "$SYSEXT_SRC"; rm -f "$PREINIT_STAGE"' EXIT
else
    PREINIT_STAGE="$PREINIT_LOCAL"
fi
if [ -n "${SCRIPT_DIR:-}" ] && [ -f "${SCRIPT_DIR}/nvidia-preinit-full.sh" ]; then
    cp "${SCRIPT_DIR}/nvidia-preinit-full.sh" "$PREINIT_STAGE"
    echo "Staged PREINIT helper from local checkout"
else
    echo "Downloading PREINIT helper from ${SCRIPT_URL_BASE}/nvidia-preinit-full.sh"
    curl -fL --retry 3 -o "$PREINIT_STAGE" "${SCRIPT_URL_BASE}/nvidia-preinit-full.sh" \
        || { echo "ERROR: failed to download PREINIT helper — aborting BEFORE system changes" >&2; exit 1; }
fi
if $DRY_RUN; then
    [ -s "$PREINIT_STAGE" ] || { echo "ERROR: PREINIT helper downloaded empty" >&2; exit 1; }
    echo "[dry-run] would: install staged preinit to ${PREINIT_LOCAL} (chmod 0755)"
else
    chmod 0755 "$PREINIT_LOCAL"
    echo "Staged: $PREINIT_LOCAL"
fi

# --- Stop Docker so the GPU is free, wait for processes to drain ---
echo ""
echo "Stopping Docker (releasing GPU)..."
# Manual if/else (not if_real) because the trailing `>/dev/null` would
# otherwise eat the `[dry-run] would: …` line that if_real prints.
if $DRY_RUN; then
    echo "[dry-run] would: midclt call docker.update '{\"nvidia\": false}'"
else
    midclt call docker.update '{"nvidia": false}' >/dev/null \
        || echo "WARN: docker.update failed (middleware may be transitionally down — continuing)"
fi

if $DRY_RUN; then
    echo "[dry-run] would: wait up to 120s for running GPU processes to drain"
elif [ -x /usr/bin/nvidia-smi ]; then
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
if_real systemd-sysext unmerge

USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null)
echo "Setting ${USR_DATASET:-<unknown>} writable..."
if_real zfs set readonly=off "$USR_DATASET"

# Stash current (likely stock) as .bak unless we already have nvidia-original.raw
if $DRY_RUN; then
    echo "[dry-run] would: cp ${LIVE_NVIDIA} ${LIVE_NVIDIA}.bak (unless .bak already present)"
elif [ ! -f "${LIVE_NVIDIA}.bak" ]; then
    cp "$LIVE_NVIDIA" "${LIVE_NVIDIA}.bak" 2>/dev/null \
        && echo "Backed up current to ${LIVE_NVIDIA}.bak" \
        || echo "WARN: could not back up to .bak"
fi

if_real cp "$SYSEXT_SRC" "$LIVE_NVIDIA"
$DRY_RUN || echo "Installed custom nvidia.raw"

if_real zfs set readonly=on "$USR_DATASET"

echo "Ensuring /etc/extensions/nvidia.raw symlink..."
if_real mkdir -p /etc/extensions
if_real ln -sf "$LIVE_NVIDIA" /etc/extensions/nvidia.raw

echo "Re-merging sysext..."
if_real systemd-sysext merge
if_real systemctl daemon-reload

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

if $DRY_RUN; then
    if [ -n "$EXISTING_ID" ]; then
        echo "[dry-run] would: midclt call initshutdownscript.update ${EXISTING_ID} '${JSON}'"
    else
        echo "[dry-run] would: midclt call initshutdownscript.create '${JSON}'"
    fi
elif [ -n "$EXISTING_ID" ]; then
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
if $DRY_RUN; then
    echo "[dry-run] would: midclt call docker.update '{\"nvidia\": true}'"
else
    midclt call docker.update '{"nvidia": true}' >/dev/null \
        || echo "WARN: docker.update re-enable failed"
fi

echo ""
if $DRY_RUN; then
    echo "=== Dry-run complete; no system changes applied ==="
    echo ""
    echo "Every download and sanity check ran for real (URL reachability,"
    echo "sysext content validation, midclt query). Every mutation was"
    echo "logged as '[dry-run] would: ...' but not executed."
    echo ""
    echo "Re-run without --dry-run to apply."
else
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
fi

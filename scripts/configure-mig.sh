#!/usr/bin/env bash
# Configure MIG layout + map MIG devices to TrueNAS apps.
#
# Runs after install-sysext.sh (default path: no reboot) or after the
# reboot following install-sysext.sh --with-driver. Either path is fine —
# by the time configure-mig.sh runs, /usr/bin/nvidia-smi must work and
# middleware must be up.
#
# Usage:
#   sudo ./configure-mig.sh                        # interactive: prompt for profiles
#   sudo ./configure-mig.sh --mig=14,14,14,14
#   sudo ./configure-mig.sh --mig=14,14,14,14 --skip-app-mapping
#
# Flags:
#   --mig=LIST            Comma-separated MIG profile IDs (e.g. 14,14,14,14).
#                         Alias: --mig-profiles=LIST
#   --pool=NAME           ZFS pool for mig.conf (skips auto-detect)
#   --persist-path=PATH   Exact directory for mig.conf (overrides --pool)
#   --skip-app-mapping    Create MIG instances but don't prompt for app
#                         assignment. Useful for headless / scripted runs.
#   -h, --help            Show this help and exit
#
# Pool selection priority: --persist-path > --pool > existing config dir > only
# data pool > interactive prompt (multi-pool) > error (no tty + ambiguous).
#
# Writes /mnt/<pool>/.config/nvidia-gpu/mig.conf and triggers
# nvidia-mig-setup.service to create the MIG instances now.
# Then offers an interactive loop to map MIG devices to TrueNAS apps.

set -euo pipefail

MIG_PROFILES=""
POOL_NAME=""
PERSIST_PATH=""
SKIP_APP_MAPPING=false

for arg in "$@"; do
    case "$arg" in
        --mig-profiles=*|--mig=*) MIG_PROFILES="${arg#*=}" ;;
        --pool=*) POOL_NAME="${arg#*=}" ;;
        --persist-path=*) PERSIST_PATH="${arg#*=}" ;;
        --skip-app-mapping) SKIP_APP_MAPPING=true ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

[ "$(id -u 2>/dev/null)" = "0" ] || { echo "ERROR: must run as root" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Helpers (defined before any call site)
# ─────────────────────────────────────────────────────────────────────────────

# Returns 0 if the comma-separated profile list is plausibly valid, 1 otherwise.
# Catches the cheap-to-check foot-guns:
#   - total slice budget > 4
#   - per-profile instance count exceeds NVIDIA's max for that profile
#   - +me.all mixed with profiles that need media engines
#   - more than one OFA-claiming profile (only 1 OFA on the GPU)
# Subtler placement conflicts fall through to nvidia-smi at MIG creation time.
validate_mig_profiles() {
    local profiles="$1"
    local arr p slices total=0 ok=true
    IFS=',' read -ra arr <<< "$profiles"
    [ "${#arr[@]}" -gt 0 ] || { echo "ERROR: empty profile list" >&2; return 1; }

    declare -A count_of
    for p in "${arr[@]}"; do
        case "$p" in
            14|21|47|65|67) slices=1 ;;
            5|35|64|66)     slices=2 ;;
            0|32)           slices=4 ;;
            *) echo "ERROR: unknown profile ID '$p' (valid: 0 5 14 21 32 35 47 64 65 66 67)" >&2; ok=false; continue ;;
        esac
        total=$((total + slices))
        count_of[$p]=$((${count_of[$p]:-0} + 1))
    done

    if [ "$total" -gt 4 ]; then
        echo "ERROR: slice budget exceeded — your list uses $total slices, max is 4" >&2
        ok=false
    fi

    # Per-profile max instances per nvidia-smi mig -lgip on Blackwell
    declare -A max_of=(
        [0]=1  [21]=1 [32]=1 [64]=1 [65]=1
        [5]=2  [35]=2 [66]=2
        [14]=4 [47]=4 [67]=4
    )
    for p in "${!count_of[@]}"; do
        if [ "${count_of[$p]}" -gt "${max_of[$p]:-99}" ]; then
            echo "ERROR: profile $p allows max ${max_of[$p]} instance(s); your list has ${count_of[$p]}" >&2
            ok=false
        fi
    done

    # Media-engine constraint: RTX PRO 6000 Blackwell has 4 NVDEC, 4 NVENC,
    # 4 NVJPG, 1 OFA. The +me.all profiles (64, 65) grab ALL of them, so any
    # other instance in the same config must be -me (66, 67).
    local has_me_all=false
    for p in "${arr[@]}"; do
        case "$p" in 64|65) has_me_all=true ;; esac
    done
    if $has_me_all; then
        for p in "${arr[@]}"; do
            case "$p" in
                64|65|66|67) ;;
                *) echo "ERROR: profile $p cannot coexist with +me.all (64 or 65) — that variant grabs all media engines, so other instances must be -me (66 or 67)" >&2; ok=false ;;
            esac
        done
    fi

    # OFA is single — only one OFA engine on the GPU, claimed by profiles
    # 21 (+me), 64 (+me.all), 65 (+me.all). At most one of those can appear.
    local ofa_count=0
    for p in "${arr[@]}"; do
        case "$p" in 21|64|65) ofa_count=$((ofa_count + 1)) ;; esac
    done
    if [ "$ofa_count" -gt 1 ]; then
        echo "ERROR: only 1 OFA engine on the GPU, but $ofa_count profiles in the list claim it (21/64/65). Pick one." >&2
        ok=false
    fi

    $ok
}

# --- Live-elapsed wrappers for long-blocking commands ---
# midclt's `app.stop` / `app.update` / `app.start` and `systemctl restart`
# of the MIG service can each take 5–60 s; without a counter the screen
# looks frozen. These wrappers spawn a background ticker that prints
# "<label>... Ns" once a second, run the command, and clear the line on
# return. `ELAPSED` (and `CAPTURED_OUT` for the _capture variant) is set
# in the caller's scope so it can print a final "OK (Ns)" / "FAILED (Ns)"
# line.
ELAPSED=0
CAPTURED_OUT=""

run_with_elapsed() {
    # Args: label (with own indent), then command...
    # Command's stdout/stderr pass through. Sets ELAPSED.
    local label="$1"; shift
    local start ticker_pid rc
    start=$(date +%s)
    (
        while sleep 1; do
            printf "\r%s... %ds" "$label" "$(($(date +%s) - start))"
        done
    ) &
    ticker_pid=$!
    "$@"
    rc=$?
    kill "$ticker_pid" 2>/dev/null
    wait "$ticker_pid" 2>/dev/null
    ELAPSED=$(($(date +%s) - start))
    # Clear the live line so the caller's print replaces it.
    printf "\r%80s\r" ""
    return $rc
}

run_with_elapsed_capture() {
    # Like run_with_elapsed but captures combined stdout+stderr into
    # CAPTURED_OUT (so the caller can echo error text on failure).
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

profile_label() {
    # Engine counts straight from `nvidia-smi mig -lgip` on Blackwell.
    # "1 dec/enc/jpg" = 1 NVDEC + 1 NVENC + 1 NVJPG per instance.
    case "$1" in
        14) echo "1g.24gb           — 1 dec/enc/jpg, no OFA" ;;
        21) echo "1g.24gb+me        — 1 dec/enc/jpg + OFA" ;;
        47) echo "1g.24gb+gfx       — 1 dec/enc/jpg, no OFA, +graphics" ;;
        65) echo "1g.24gb+me.all    — ALL 4 dec/enc/jpg + OFA (claims them all)" ;;
        67) echo "1g.24gb-me        — pure compute, no media, no OFA" ;;
        5)  echo "2g.48gb           — 2 dec/enc/jpg, no OFA" ;;
        35) echo "2g.48gb+gfx       — 2 dec/enc/jpg, no OFA, +graphics" ;;
        64) echo "2g.48gb+me.all    — ALL 4 dec/enc/jpg + OFA (claims them all)" ;;
        66) echo "2g.48gb-me        — pure compute, no media, no OFA" ;;
        0)  echo "4g.96gb           — whole GPU: 4 dec/enc/jpg + OFA" ;;
        32) echo "4g.96gb+gfx       — whole GPU: 4 dec/enc/jpg + OFA + graphics" ;;
        *)  echo "profile $1" ;;
    esac
}

# --- Resolve persistent dir ---
# resolve_persist_dir is duplicated verbatim across install-sysext.sh,
# configure-mig.sh, and recover-stock-nvidia.sh. Inline (rather than
# sourced from a sibling file) so each script remains a self-contained
# curl|bash artifact. Keep these copies in sync when changing the function.
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

# --- Pre-flight ---
[ -x /usr/bin/nvidia-smi ] || { echo "ERROR: /usr/bin/nvidia-smi missing (sysext not merged?)" >&2; exit 1; }

# nvidia-smi can fail in two distinct ways here:
#   1. Driver/library mismatch — user installed the full-driver sysext but
#      hasn't rebooted yet; kernel modules are still the previous version
#      while userspace libs are the new one.
#   2. Any other init failure (no GPU, driver not loaded, etc.).
#
# Wrap the call in an explicit if-test so a failure produces a visible
# error. The previous form `DRIVER_VER=$(... 2>&1 | head -1)` could be
# silently killed by `set -euo pipefail` on a non-zero nvidia-smi exit
# (the pipeline returns non-zero, pipefail propagates it, and bash
# terminates the script before the case statement is reached).
if DRIVER_VER=$(/usr/bin/nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null); then
    echo "Driver: $DRIVER_VER"
else
    NVIDIA_ERR=$(/usr/bin/nvidia-smi 2>&1 || true)
    if echo "$NVIDIA_ERR" | grep -qi "version mismatch"; then
        echo "" >&2
        echo "ERROR: kernel modules and userspace libraries are different driver versions." >&2
        echo "       This is expected immediately after 'install-sysext.sh --with-driver'" >&2
        echo "       and resolves itself after a reboot loads matching kernel modules." >&2
        echo "" >&2
        echo "       Reboot first, then re-run configure-mig:" >&2
        echo "" >&2
        echo "         sudo reboot" >&2
        echo "" >&2
        echo "       (nvidia-smi reported: $(echo "$NVIDIA_ERR" | head -1))" >&2
    else
        echo "ERROR: /usr/bin/nvidia-smi failed to query the GPU:" >&2
        echo "$NVIDIA_ERR" | sed 's/^/       /' >&2
    fi
    exit 1
fi

[ -x /usr/bin/nvidia-mig-setup ] || { echo "ERROR: /usr/bin/nvidia-mig-setup missing — run install-{mig,nvidia}-sysext.sh first." >&2; exit 1; }

# --- MIG profile selection ---
if [ -z "$MIG_PROFILES" ]; then
    EXISTING=""
    if [ -f "$PERSIST_DIR/mig.conf" ]; then
        EXISTING=$(grep -E '^MIG_PROFILES=' "$PERSIST_DIR/mig.conf" | sed -E 's/^MIG_PROFILES=//; s/^"//; s/"$//')
    fi
    cat <<'EOF'

=== MIG profile selection ===

Profile IDs (RTX PRO 6000 Blackwell, 96 GB total, 4 slices).
GPU has 4 NVDEC, 4 NVENC, 4 NVJPG, 1 OFA total — distributed below.

Suffix     Meaning
(none)     compute + 1 of each media engine
+gfx       adds OpenGL / Vulkan / DirectX support
+me        compute + media engines including OFA (max 1 per GPU)
+me.all    grabs all media engines exclusively (max 1, mutually exclusive)
-me        pure compute, no media engines

  ID  Profile         DEC ENC JPG OFA GFX  Max
  14  1g.24gb          1   1   1   -   -    4
  21  1g.24gb+me       1   1   1   1   -    1
  47  1g.24gb+gfx      1   1   1   -   Y    4
  65  1g.24gb+me.all   4   4   4   1   -    1
  67  1g.24gb-me       -   -   -   -   -    4
   5  2g.48gb          2   2   2   -   -    2
  35  2g.48gb+gfx      2   2   2   -   Y    2
  64  2g.48gb+me.all   4   4   4   1   -    1
  66  2g.48gb-me       -   -   -   -   -    2
   0  4g.96gb          4   4   4   1   -    1
  32  4g.96gb+gfx      4   4   4   1   Y    1

Slice budget: 1g = 1 slice, 2g = 2 slices, 4g = 4 slices. Total ≤ 4.

Enter a comma-separated list, e.g. 14,14,14,14 for four 1g.24gb slices.
See docs/mig-profiles.md for the full reference.

EOF
    if [ -n "$EXISTING" ]; then
        echo "Existing mig.conf: MIG_PROFILES=$EXISTING"
        printf "Use existing profiles? [Y/n] "
        read -r ans </dev/tty || ans="y"
        case "$ans" in
            [nN]*) ;;
            *) MIG_PROFILES="$EXISTING" ;;
        esac
    fi
    if [ -z "$MIG_PROFILES" ]; then
        printf "MIG profiles: "
        read -r MIG_PROFILES </dev/tty
    fi
    [ -n "$MIG_PROFILES" ] || { echo "ERROR: no profiles given" >&2; exit 1; }
fi

echo "Using MIG_PROFILES=$MIG_PROFILES"

# --- Validate before writing anything ---
if ! validate_mig_profiles "$MIG_PROFILES"; then
    echo "" >&2
    echo "Refusing to apply. See docs/mig-profiles.md for the slice budget and per-profile limits." >&2
    exit 1
fi

# --- Write mig.conf ---
cat > "$PERSIST_DIR/mig.conf" <<EOF
# Written by configure-mig.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
MIG_PROFILES="$MIG_PROFILES"
EOF
echo "Wrote $PERSIST_DIR/mig.conf"

# --- Stop app services so GPU is free ---
# "App services" is the user-facing name for what TrueNAS calls Docker
# internally; the middleware endpoint is still `docker.update`.
echo ""
echo "Stopping app services to free the GPU..."
midclt call docker.update '{"nvidia": false}' >/dev/null \
    || echo "WARN: app services API call (docker.update) returned an error — middleware may be flapping"

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

# --- Run nvidia-mig-setup.service (destroys + creates MIG instances) ---
# Must use 'restart', not 'start'. The service is Type=oneshot with
# RemainAfterExit=yes; once it's run this boot, `systemctl start` becomes
# a no-op and the old MIG instances remain. `restart` forces re-execution,
# which re-reads mig.conf and applies the new profile list.
echo "Restarting nvidia-mig-setup.service (re-running with new profiles)..."
if run_with_elapsed "  elapsed" systemctl restart nvidia-mig-setup.service; then
    echo "  done (${ELAPSED}s)"
else
    echo "ERROR: systemctl restart failed after ${ELAPSED}s"
    exit 1
fi
systemctl status nvidia-mig-setup.service --no-pager -n 0 | head -3 || true

# --- Re-enable app services ---
echo ""
echo "Re-enabling app services..."
midclt call docker.update '{"nvidia": true}' >/dev/null \
    || echo "WARN: app services API call (docker.update) re-enable failed"

# --- Wait for apps to come back so we can list them ---
echo "Waiting for app services to come back (60-90s)..."
APP_COUNT=0
printf "  Waiting... 0s/90s"
for attempt in $(seq 1 18); do
    APP_COUNT=$(midclt call app.query 2>/dev/null \
        | python3 -c "import sys,json
try: print(len(json.load(sys.stdin)))
except: print(0)" 2>/dev/null)
    if [ "${APP_COUNT:-0}" -gt 0 ]; then
        printf "\r  App services ready (${APP_COUNT} apps)                  \n"
        break
    fi
    printf "\r  Waiting... %ds/90s" "$((attempt * 5))"
    sleep 5
done
[ "${attempt:-0}" -eq 18 ] && echo ""

# --- Enumerate created MIG instances ---
mapfile -t MIG_UUIDS < <(/usr/bin/nvidia-smi -L 2>/dev/null \
    | grep 'MIG' | sed -n 's/.*UUID: \(MIG-[^)]*\)).*/\1/p')

if [ "${#MIG_UUIDS[@]}" -eq 0 ]; then
    echo "ERROR: no MIG UUIDs found after instance creation. Check journalctl -u nvidia-mig-setup." >&2
    exit 1
fi
echo "MIG devices created: ${#MIG_UUIDS[@]}"

IFS=',' read -ra PROFILE_ARRAY <<< "$MIG_PROFILES"

# Sanity check: profile list and MIG instance count must match exactly.
# Otherwise the service didn't re-run with the new mig.conf (e.g. start
# vs. restart bug), or someone hand-modified instances outside the
# service. Either way, the assignment labels will be wrong — bail out.
if [ "${#PROFILE_ARRAY[@]}" -ne "${#MIG_UUIDS[@]}" ]; then
    echo "" >&2
    echo "ERROR: profile list has ${#PROFILE_ARRAY[@]} entries (${MIG_PROFILES})" >&2
    echo "       but the GPU has ${#MIG_UUIDS[@]} MIG instance(s) right now." >&2
    echo "       Counts must match. Likely causes:" >&2
    echo "         - nvidia-mig-setup.service didn't re-run with the new mig.conf" >&2
    echo "         - MIG instances were created/destroyed outside the service" >&2
    echo "       Inspect: journalctl -u nvidia-mig-setup.service -n 80 --no-pager" >&2
    echo "       Recover: sudo systemctl restart nvidia-mig-setup.service" >&2
    exit 1
fi

if $SKIP_APP_MAPPING || [ "${APP_COUNT:-0}" -eq 0 ]; then
    echo ""
    echo "=== MIG Devices ==="
    for i in "${!MIG_UUIDS[@]}"; do
        printf "  [%d] %s\n        %s\n" \
            "$((i+1))" "$(profile_label "${PROFILE_ARRAY[$i]:-unknown}")" "${MIG_UUIDS[$i]}"
    done
    echo ""
    echo "Skipping app↔MIG mapping (no apps found or --skip-app-mapping given)."
    echo "Assign in TrueNAS UI or via midclt call app.update."
    exit 0
fi

# --- App list + PCI slot ---
mapfile -t APP_NAMES < <(midclt call app.query 2>/dev/null \
    | python3 -c "import sys,json
for app in json.load(sys.stdin):
    n = app.get('name','')
    if n: print(n)" 2>/dev/null)

PCI_SLOT=$(midclt call app.gpu_choices 2>/dev/null \
    | python3 -c "import sys,json
for slot, info in (json.load(sys.stdin) or {}).items():
    v = (info.get('vendor') or '').upper() if isinstance(info, dict) else ''
    d = (info.get('description') or '').upper() if isinstance(info, dict) else ''
    s = info.upper() if isinstance(info, str) else ''
    if 'NVIDIA' in v or 'NVIDIA' in d or 'NVIDIA' in s:
        print(slot, end=''); break" 2>/dev/null)

[ -n "$PCI_SLOT" ] || { echo "ERROR: could not detect GPU PCI slot via midclt"; exit 1; }
echo "GPU PCI slot: $PCI_SLOT"

# --- Interactive device→app assignment loop ---
echo ""
echo "=== Assign MIG devices to TrueNAS apps ==="
echo "Pick a MIG device, then pick an app. Enter 0 at any prompt to finish."

STAGED_APP=()
STAGED_UUID=()
STAGED_DEV=()
STAGED_DTYPE=()

while true; do
    echo ""
    echo "--- MIG Devices ---"
    for i in "${!MIG_UUIDS[@]}"; do
        dtype=$(profile_label "${PROFILE_ARRAY[$i]:-unknown}")
        assigned_to=""
        for j in "${!STAGED_UUID[@]}"; do
            if [ "${STAGED_UUID[$j]}" = "${MIG_UUIDS[$i]}" ]; then
                if [ -n "$assigned_to" ]; then
                    assigned_to="${assigned_to}, ${STAGED_APP[$j]}"
                else
                    assigned_to="${STAGED_APP[$j]}"
                fi
            fi
        done
        if [ -n "$assigned_to" ]; then
            echo "  [$((i+1))] ${dtype}  -->  ${assigned_to}"
        else
            echo "  [$((i+1))] ${dtype}"
        fi
        echo "        ${MIG_UUIDS[$i]}"
    done

    printf "\nSelect MIG device number (0 to finish): "
    read -r dev_num </dev/tty || break
    [ "$dev_num" = "0" ] && break
    [[ "$dev_num" =~ ^[0-9]+$ ]] || { echo "  Invalid input."; continue; }

    dev_idx=$((dev_num - 1))
    if [ "$dev_idx" -lt 0 ] || [ "$dev_idx" -ge "${#MIG_UUIDS[@]}" ]; then
        echo "  Invalid device number: $dev_num"; continue
    fi

    sel_uuid="${MIG_UUIDS[$dev_idx]}"
    sel_dtype=$(profile_label "${PROFILE_ARRAY[$dev_idx]:-unknown}")

    echo ""
    echo "--- Apps ---"
    for i in "${!APP_NAMES[@]}"; do
        app_dtype=""
        for j in "${!STAGED_APP[@]}"; do
            if [ "${STAGED_APP[$j]}" = "${APP_NAMES[$i]}" ]; then
                app_dtype="${STAGED_DTYPE[$j]}"
            fi
        done
        if [ -n "$app_dtype" ]; then
            echo "  [$((i+1))] ${APP_NAMES[$i]}  <--  ${app_dtype}"
        else
            echo "  [$((i+1))] ${APP_NAMES[$i]}"
        fi
    done

    printf "\nAssign device %s (%s) to app number (0 to cancel): " "$dev_num" "$sel_dtype"
    read -r app_num </dev/tty || break
    [ "$app_num" = "0" ] && continue
    [[ "$app_num" =~ ^[0-9]+$ ]] || { echo "  Invalid input."; continue; }

    app_idx=$((app_num - 1))
    if [ "$app_idx" -lt 0 ] || [ "$app_idx" -ge "${#APP_NAMES[@]}" ]; then
        echo "  Invalid app number: $app_num"; continue
    fi
    sel_app="${APP_NAMES[$app_idx]}"

    # Replace any prior staging for this app
    NEW_APP=(); NEW_UUID=(); NEW_DEV=(); NEW_DTYPE=()
    for j in "${!STAGED_APP[@]}"; do
        if [ "${STAGED_APP[$j]}" != "$sel_app" ]; then
            NEW_APP+=("${STAGED_APP[$j]}")
            NEW_UUID+=("${STAGED_UUID[$j]}")
            NEW_DEV+=("${STAGED_DEV[$j]}")
            NEW_DTYPE+=("${STAGED_DTYPE[$j]}")
        fi
    done
    STAGED_APP=("${NEW_APP[@]+"${NEW_APP[@]}"}")
    STAGED_UUID=("${NEW_UUID[@]+"${NEW_UUID[@]}"}")
    STAGED_DEV=("${NEW_DEV[@]+"${NEW_DEV[@]}"}")
    STAGED_DTYPE=("${NEW_DTYPE[@]+"${NEW_DTYPE[@]}"}")

    STAGED_APP+=("$sel_app")
    STAGED_UUID+=("$sel_uuid")
    STAGED_DEV+=("$dev_num")
    STAGED_DTYPE+=("$sel_dtype")

    echo "  Staged: device $dev_num ($sel_dtype) --> $sel_app"
done

if [ "${#STAGED_APP[@]}" -eq 0 ]; then
    echo ""; echo "No assignments staged. Done."
    exit 0
fi

echo ""
echo "=== Assignment Summary ==="
for i in "${!STAGED_APP[@]}"; do
    echo "  Device ${STAGED_DEV[$i]} (${STAGED_DTYPE[$i]})  -->  ${STAGED_APP[$i]}"
    echo "    ${STAGED_UUID[$i]}"
done
printf "\nApply? [Y/n] "
read -r confirm </dev/tty || confirm="y"
case "$confirm" in
    [nN]*) echo "Discarded."; exit 0 ;;
esac

# --- Apply via midclt: stop → update → restore-to-original-state, per app ---
# Stop before update because app.update implicitly runs `compose up
# --force-recreate`. Against an already-running container that can fail
# with a "container name already in use" conflict, after which middleware
# silently rolls back the config change (app.get_instance then returns
# gpus: null even though the job reported SUCCESS). See agents.md.
# Use `midclt call -j` so the call waits for the underlying job and
# propagates its exit status. Capture stderr (instead of >/dev/null'ing
# it) so a real failure surfaces to the user.
#
# Record original state first so a stopped app stays stopped after we
# apply its GPU config — don't unexpectedly start an app the user chose
# to disable.
for i in "${!STAGED_APP[@]}"; do
    app="${STAGED_APP[$i]}"
    echo "  ${app} <-- device ${STAGED_DEV[$i]} (${STAGED_DTYPE[$i]})"

    orig_state=$(midclt call app.get_instance "$app" 2>/dev/null \
        | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('state',''))
except: print('')" 2>/dev/null)
    echo "    Original state: ${orig_state:-unknown}"
    was_running=false
    [ "$orig_state" = "RUNNING" ] && was_running=true

    if $was_running; then
        if run_with_elapsed_capture "    Stopping" midclt call -j app.stop "$app"; then
            echo "    Stopping... OK (${ELAPSED}s)"
        else
            echo "    Stopping... WARN (continuing, ${ELAPSED}s): $CAPTURED_OUT"
        fi
    fi

    payload="{\"values\":{\"resources\":{\"gpus\":{\"use_all_gpus\":false,\"nvidia_gpu_selection\":{\"$PCI_SLOT\":{\"use_gpu\":true,\"uuid\":\"${STAGED_UUID[$i]}\"}}}}}}"
    if run_with_elapsed_capture "    Applying GPU config" midclt call -j app.update "$app" "$payload"; then
        echo "    Applying GPU config... OK (${ELAPSED}s)"
    else
        echo "    Applying GPU config... FAILED (${ELAPSED}s):"
        echo "$CAPTURED_OUT" | sed 's/^/      /'
        # Restore the app to its original state on failure — only start it
        # back up if it was actually running before we touched it.
        if $was_running; then
            midclt call -j app.start "$app" >/dev/null 2>&1 || true
        fi
        continue
    fi

    if $was_running; then
        if run_with_elapsed_capture "    Starting" midclt call -j app.start "$app"; then
            echo "    Starting... OK (${ELAPSED}s)"
        else
            echo "    Starting... WARN (${ELAPSED}s): $CAPTURED_OUT"
        fi
    else
        echo "    Leaving stopped (was not running originally)"
    fi
done

echo ""
echo "=== Done ==="

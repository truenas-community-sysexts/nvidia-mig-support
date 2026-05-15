#!/usr/bin/env bash
# Configure MIG layout + map MIG devices to TrueNAS apps.
#
# Runs after install-mig-sysext.sh (lightweight path) or after the reboot
# following install-nvidia-sysext.sh (full-driver path). Either path is
# fine — by the time configure-mig.sh runs, /usr/bin/nvidia-smi must work
# and middleware must be up.
#
# Usage:
#   sudo ./configure-mig.sh                        # interactive: prompt for profiles
#   sudo ./configure-mig.sh --mig-profiles=14,14,14,14
#   sudo ./configure-mig.sh --mig-profiles=14,14,14,14 --skip-app-mapping
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
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root" >&2; exit 1; }

# --- Resolve persistent dir ---
if [ -n "$PERSIST_PATH" ]; then
    PERSIST_DIR="$PERSIST_PATH"
elif [ -n "$POOL_NAME" ]; then
    PERSIST_DIR="/mnt/${POOL_NAME}/.config/nvidia-gpu"
else
    POOL_NAME=$(zpool list -H -o name 2>/dev/null | grep -v '^boot-pool$' | head -1 || true)
    [ -n "$POOL_NAME" ] || { echo "ERROR: no ZFS pool found. Pass --pool=NAME." >&2; exit 1; }
    PERSIST_DIR="/mnt/${POOL_NAME}/.config/nvidia-gpu"
    echo "Pool: $POOL_NAME  ($PERSIST_DIR)"
fi
mkdir -p "$PERSIST_DIR"

# --- Pre-flight ---
[ -x /usr/bin/nvidia-smi ] || { echo "ERROR: /usr/bin/nvidia-smi missing (sysext not merged?)" >&2; exit 1; }

DRIVER_VER=$(/usr/bin/nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>&1 | head -1)
case "$DRIVER_VER" in
    *"version mismatch"*|*"Failed"*)
        echo "ERROR: nvidia-smi reports driver/library mismatch — reboot is required first." >&2
        echo "       $DRIVER_VER" >&2
        exit 1
        ;;
esac
echo "Driver: $DRIVER_VER"

[ -x /usr/bin/nvidia-mig-setup ] || { echo "ERROR: /usr/bin/nvidia-mig-setup missing — run install-{mig,nvidia}-sysext.sh first." >&2; exit 1; }

# --- MIG profile selection ---
if [ -z "$MIG_PROFILES" ]; then
    EXISTING=""
    if [ -f "$PERSIST_DIR/mig.conf" ]; then
        EXISTING=$(grep -E '^MIG_PROFILES=' "$PERSIST_DIR/mig.conf" | sed -E 's/^MIG_PROFILES=//; s/^"//; s/"$//')
    fi
    cat <<'EOF'

=== MIG profile selection ===

Profile IDs (RTX PRO 6000 Blackwell, 96 GB total, 4 slices):

  ID  Profile           Notes
  14  1g.24gb           compute + media       (4 fit)   ← most common
   5  2g.48gb           compute + media       (2 fit)
   0  4g.96gb           compute + media       (whole GPU)
  47  1g.24gb+gfx       adds graphics APIs    (4 fit)
  35  2g.48gb+gfx       adds graphics APIs    (2 fit)
  32  4g.96gb+gfx       adds graphics APIs    (whole GPU)
  21  1g.24gb+me        adds OFA engine       (1 inst max)
  65  1g.24gb+me.all    grabs all media engs  (1 inst max)
  64  2g.48gb+me.all    grabs all media engs  (1 inst max — known foot-gun, see agents.md)
  67  1g.24gb-me        pure compute, no media (4 fit)
  66  2g.48gb-me        pure compute, no media (2 fit)

Enter a comma-separated list, e.g. 14,14,14,14 for four 1g.24gb slices.
See docs/mig-profiles.md for the full table + slice budgeting rules.

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

# --- Stop Docker so GPU is free ---
echo ""
echo "Stopping Docker to free the GPU..."
midclt call docker.update '{"nvidia": false}' >/dev/null \
    || echo "WARN: docker.update returned an error (middleware may be flapping)"

for attempt in $(seq 1 24); do
    N=$(/usr/bin/nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l || echo 0)
    [ "${N:-0}" -eq 0 ] && { echo "GPU released"; break; }
    printf "\r  Waiting for %d GPU process(es)... %ds/120s" "$N" "$((attempt * 5))"
    sleep 5
done
echo ""

# --- Run nvidia-mig-setup.service (creates instances) ---
echo "Starting nvidia-mig-setup.service (creates MIG instances)..."
systemctl start nvidia-mig-setup.service || { echo "ERROR: systemctl start failed"; exit 1; }
systemctl status nvidia-mig-setup.service --no-pager -n 0 | head -3 || true

# --- Re-enable Docker ---
echo ""
echo "Re-enabling Docker..."
midclt call docker.update '{"nvidia": true}' >/dev/null || echo "WARN: docker.update re-enable failed"

# --- Wait for apps to come back so we can list them ---
echo "Waiting for app service to come back (60-90s)..."
APP_COUNT=0
for attempt in $(seq 1 18); do
    APP_COUNT=$(midclt call app.query 2>/dev/null \
        | python3 -c "import sys,json
try: print(len(json.load(sys.stdin)))
except: print(0)" 2>/dev/null)
    if [ "${APP_COUNT:-0}" -gt 0 ]; then
        echo "App service ready (${APP_COUNT} apps)"
        break
    fi
    printf "\r  Waiting... %ds/90s" "$((attempt * 5))"
    sleep 5
done
echo ""

# --- Enumerate created MIG instances ---
mapfile -t MIG_UUIDS < <(/usr/bin/nvidia-smi -L 2>/dev/null \
    | grep 'MIG' | sed -n 's/.*UUID: \(MIG-[^)]*\)).*/\1/p')
mapfile -t MIG_NAMES < <(/usr/bin/nvidia-smi -L 2>/dev/null \
    | grep 'MIG' | sed 's/.*MIG /MIG /' | sed 's/[[:space:]]*Device.*//')

if [ "${#MIG_UUIDS[@]}" -eq 0 ]; then
    echo "ERROR: no MIG UUIDs found after instance creation. Check journalctl -u nvidia-mig-setup." >&2
    exit 1
fi
echo "MIG devices created: ${#MIG_UUIDS[@]}"

IFS=',' read -ra PROFILE_ARRAY <<< "$MIG_PROFILES"

# Returns 0 if the comma-separated profile list is plausibly valid, 1 otherwise.
# Catches the two cheap-to-check foot-guns:
#   - total slice budget > 4
#   - per-profile instance count exceeds NVIDIA's max for that profile
# Subtler placement conflicts (media-engine partitioning, OFA-in-multiple-instances)
# fall through to nvidia-smi at MIG creation time.
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
    # other instance in the same config must be -me (66, 67) — otherwise
    # that instance asks for media engines that have been taken.
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
    # 21 (+me), 64 (+me.all), 65 (+me.all). At most one of those three can
    # appear in a config.
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

profile_label() {
    case "$1" in
        47) echo "gfx + compute (1g.24gb)" ;;
        35) echo "gfx + compute (2g.48gb)" ;;
        32) echo "gfx + compute (4g.96gb)" ;;
        14) echo "compute only (1g.24gb)" ;;
        5)  echo "compute only (2g.48gb)" ;;
        0)  echo "compute only (4g.96gb)" ;;
        64) echo "compute + all media engines (2g.48gb)" ;;
        21) echo "compute + media + OFA (1g.24gb)" ;;
        65) echo "compute + all media engines (1g.24gb)" ;;
        67) echo "compute, no media (1g.24gb)" ;;
        66) echo "compute, no media (2g.48gb)" ;;
        *)  echo "profile $1" ;;
    esac
}

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

# --- Apply via midclt + redeploy each ---
APPLIED=()
for i in "${!STAGED_APP[@]}"; do
    printf "  Assigning device %s to %s..." "${STAGED_DEV[$i]}" "${STAGED_APP[$i]}"
    if midclt call app.update "${STAGED_APP[$i]}" \
        "{\"values\":{\"resources\":{\"gpus\":{\"use_all_gpus\":false,\"nvidia_gpu_selection\":{\"$PCI_SLOT\":{\"use_gpu\":true,\"uuid\":\"${STAGED_UUID[$i]}\"}}}}}}" \
        >/dev/null 2>&1; then
        echo " OK"
        APPLIED+=("${STAGED_APP[$i]}")
    else
        echo " WARNING: app.update failed"
    fi
done

if [ "${#APPLIED[@]}" -gt 0 ]; then
    echo ""
    echo "Restarting assigned apps so they pick up the new GPU config..."
    for n in "${APPLIED[@]}"; do
        printf "  Restarting %s..." "$n"
        midclt call app.redeploy "$n" >/dev/null 2>&1 && echo " OK" || echo " WARN: redeploy failed"
    done
fi

echo ""
echo "=== Done ==="

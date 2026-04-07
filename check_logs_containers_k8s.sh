#!/bin/sh

# =========================================================================
# Script: check_k8s_pod_logs.sh (optimized with manifest)
# Description: 
#   - Checks logs of running pods using path /wrkdata/{ns}-*/{pod}.log
#   - Uses hash-based offset files (stored in OFFSET_DIR)
#   - Maintains manifest.txt to map hash -> original log path
#   - Only writes to OUTPUT_LOG when any pattern occurs >= THRESHOLD times
# =========================================================================

# ----------------------------- Configuration ----------------------------------
NAMESPACES="default app backend"
PATTERNS="${1:-error|timeout}"
THRESHOLD=3
BASE_LOG_DIR="/wrkdata"
OFFSET_DIR="/var/log/k8s_log_offsets"
OUTPUT_LOG=""
SPECIAL_LOG_PATHS=""
# ----------------------------------------------------------------------------

if [ ! -d "$OFFSET_DIR" ]; then
    mkdir -p "$OFFSET_DIR" || exit 1
fi

MANIFEST_FILE="$OFFSET_DIR/manifest.txt"

# ----------------------------- Helper functions ------------------------------
get_pod_log_path() {
    ns="$1"
    pod_name="$2"
    pattern="${BASE_LOG_DIR}/${ns}-*/${pod_name}.log"
    for f in $pattern; do
        [ -f "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}

get_offset_file() {
    log_file="$1"
    hash=$(printf "%s" "$log_file" | sha256sum | cut -d' ' -f1)
    echo "$OFFSET_DIR/$hash.off"
}

# Update manifest if new log file is seen
update_manifest() {
    log_file="$1"
    hash=$(printf "%s" "$log_file" | sha256sum | cut -d' ' -f1)
    if ! grep -q "^$hash " "$MANIFEST_FILE" 2>/dev/null; then
        echo "$hash $log_file" >> "$MANIFEST_FILE"
    fi
}

# Read new lines using offset
read_new_lines() {
    log_file="$1"
    offset_file=$(get_offset_file "$log_file")
    last_offset=0
    [ -f "$offset_file" ] && last_offset=$(cat "$offset_file")

    current_size=$(stat -c%s "$log_file" 2>/dev/null)
    [ -z "$current_size" ] && return 1

    [ "$current_size" -lt "$last_offset" ] && last_offset=0

    if [ "$current_size" -gt "$last_offset" ]; then
        # First time seeing this file? update manifest
        [ ! -f "$offset_file" ] && update_manifest "$log_file"
        # Read new data
        tail -c +$((last_offset + 1)) "$log_file" 2>/dev/null
        echo "$current_size" > "$offset_file"
        return 0
    fi
    return 1
}

# Process a single log file
check_log_file() {
    log_file="$1"
    label="$2"

    new_logs=$(read_new_lines "$log_file")
    [ -z "$new_logs" ] && return

    all_matches=$(printf "%s" "$new_logs" | grep -iE "$PATTERNS")
    [ -z "$all_matches" ] && return

    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    old_ifs="$IFS"; IFS='|'; set -- $PATTERNS; patterns_list="$*"; IFS="$old_ifs"

    if [ -z "$OUTPUT_LOG" ]; then
        printf "[%s] %s | File: %s\n%s\n" "$timestamp" "$label" "$log_file" "$all_matches"
    else
        threshold_reached=false
        for pat in $patterns_list; do
            count=$(printf "%s" "$all_matches" | grep -iE "$pat" | wc -l)
            if [ "$count" -ge "$THRESHOLD" ]; then
                threshold_reached=true
                break
            fi
        done
        if [ "$threshold_reached" = true ]; then
            printf "[%s] %s | File: %s\n%s\n" "$timestamp" "$label" "$log_file" "$all_matches" >> "$OUTPUT_LOG"
            for pat in $patterns_list; do
                count=$(printf "%s" "$all_matches" | grep -iE "$pat" | wc -l)
                [ "$count" -ge "$THRESHOLD" ] && printf "[%s] THRESHOLD_REACHED: pattern '%s' appeared %d times (threshold=%d) in %s | File: %s\n" "$timestamp" "$pat" "$count" "$THRESHOLD" "$label" "$log_file" >> "$OUTPUT_LOG"
            done
        fi
    fi
}

# ----------------------------- Main loops ------------------------------------
check_pod_logs() {
    for ns in $NAMESPACES; do
        kubectl get namespace "$ns" >/dev/null 2>&1 || {
            printf "Warning: Namespace '%s' does not exist. Skipping.\n" "$ns" >&2
            continue
        }
        pods=$(kubectl get pods -n "$ns" --field-selector status.phase=Running -o jsonpath='{.items[*].metadata.name}')
        [ -z "$pods" ] && continue
        for pod in $pods; do
            log_file=$(get_pod_log_path "$ns" "$pod")
            [ -n "$log_file" ] && [ -f "$log_file" ] && check_log_file "$log_file" "Namespace: $ns | Pod: $pod"
        done
    done
}

check_special_logs() {
    for log_file in $SPECIAL_LOG_PATHS; do
        [ -f "$log_file" ] && check_log_file "$log_file" "Log with path: $log_file"
    done
}

check_pod_logs
check_special_logs

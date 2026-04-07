#!/bin/sh

# =========================================================================
# Optimized Script: check_k8s_pod_logs.sh
# Description: 
#   1. Checks logs of running pods in namespaces (default, app, backend)
#      using path: /wrkdata/{ns}-*/{pod}.log
#   2. Also checks explicit special log files.
#   3. Uses byte offsets (stored) and `tail -c` for efficient incremental reads.
#   4. PATTERNS is a pipe-separated list (e.g., "error|timeout|fatal").
#   5. Writes to OUTPUT_LOG only when any pattern occurs >= THRESHOLD times.
#   6. If OUTPUT_LOG is empty, prints all matches to stdout (always).
# Cron: */5 * * * * /path/to/check_k8s_pod_logs.sh
# =========================================================================

# ----------------------------- Configuration ----------------------------------
NAMESPACES="default app backend"          # Namespaces to check for dynamic pod logs
PATTERNS="${1:-error|timeout}"            # Pipe-separated list of patterns
THRESHOLD=3                               # Minimum occurrences (per pattern) to log
BASE_LOG_DIR="/wrkdata"                   # Root directory for pod logs
OFFSET_DIR="/var/log/k8s_log_offsets"     # Stores byte offsets per log file
OUTPUT_LOG=""                             # Empty -> always print to stdout; set path to log to file
SPECIAL_LOG_PATHS=""                      # Space-separated absolute paths to extra log files
# ----------------------------------------------------------------------------

# Create offset directory if missing
if [ ! -d "$OFFSET_DIR" ]; then
    mkdir -p "$OFFSET_DIR" || exit 1
fi

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
    echo "$OFFSET_DIR/$(printf "%s" "$1" | sha256sum | cut -d' ' -f1).off"
}

# Read new lines from a log file using saved offset
read_new_lines() {
    log_file="$1"
    offset_file=$(get_offset_file "$log_file")
    last_offset=0
    [ -f "$offset_file" ] && last_offset=$(cat "$offset_file")

    current_size=$(stat -c%s "$log_file" 2>/dev/null)
    [ -z "$current_size" ] && return 1

    # Log rotated -> reset offset
    [ "$current_size" -lt "$last_offset" ] && last_offset=0

    if [ "$current_size" -gt "$last_offset" ]; then
        # Efficiently read from offset+1 to end
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

    # Extract all lines matching the combined patterns
    all_matches=$(printf "%s" "$new_logs" | grep -iE "$PATTERNS")
    [ -z "$all_matches" ] && return

    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Split PATTERNS by '|'
    old_ifs="$IFS"; IFS='|'; set -- $PATTERNS; patterns_list="$*"; IFS="$old_ifs"

    if [ -z "$OUTPUT_LOG" ]; then
        # No file logging: always print matches
        printf "[%s] %s | File: %s\n%s\n" "$timestamp" "$label" "$log_file" "$all_matches"
    else
        # Count occurrences per pattern from the matched lines (efficient, small subset)
        threshold_reached=false
        for pat in $patterns_list; do
            # Count lines matching this specific pattern
            count=$(printf "%s" "$all_matches" | grep -iE "$pat" | wc -l)
            if [ "$count" -ge "$THRESHOLD" ]; then
                threshold_reached=true
                break
            fi
        done
        if [ "$threshold_reached" = true ]; then
            printf "[%s] %s | File: %s\n%s\n" "$timestamp" "$label" "$log_file" "$all_matches" >> "$OUTPUT_LOG"
            # Optional: per-pattern summary
            for pat in $patterns_list; do
                count=$(printf "%s" "$all_matches" | grep -iE "$pat" | wc -l)
                [ "$count" -ge "$THRESHOLD" ] && printf "[%s] THRESHOLD_REACHED: pattern '%s' appeared %d times (threshold=%d) in %s | File: %s\n" "$timestamp" "$pat" "$count" "$THRESHOLD" "$label" "$log_file" >> "$OUTPUT_LOG"
            done
        fi
    fi
}

# ----------------------------- Dynamic pod logs -------------------------------
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

# ----------------------------- Special static logs ----------------------------
check_special_logs() {
    for log_file in $SPECIAL_LOG_PATHS; do
        [ -f "$log_file" ] && check_log_file "$log_file" "Log with path: $log_file"
    done
}

# ----------------------------- Main -------------------------------------------
check_pod_logs
check_special_logs

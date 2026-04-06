#!/bin/sh

# =========================================================================
# Script: check_k8s_pod_logs.sh
# Description: 
#   1. Checks logs of running pods in namespaces (default, app, backend)
#      using path: /wrkdata/{ns}-*/{pod}.log (wildcard matches any suffix)
#   2. Also checks any explicitly provided special log files.
#   Uses byte offsets to read only new lines.
#   Searches for patterns (error|timeout by default).
# Output: echo -e with tee -a (prints to screen and optionally appends to file)
# Usage: ./check_k8s_pod_logs.sh [pattern]
# Cron: */5 * * * * /path/to/check_k8s_pod_logs.sh
# =========================================================================

# ----------------------------- Configuration ----------------------------------
NAMESPACES="default app backend"                           # Namespaces to check for dynamic pod logs
PATTERNS="${1:-error|timeout}"                             # Regex pattern (case-insensitive)
BASE_LOG_DIR="/wrkdata"                                    # Root directory for pod logs
OFFSET_DIR="/home/scem/test-check-log/k8s_log_offsets"     # Stores byte offsets per log file
OUTPUT_LOG="/home/scem/test-check-log/test-sw.log"         # Empty -> print to stdout; set path to log to file

# ---------------------------------------------------------------
# EXPLICIT SPECIAL LOG FILES (full absolute paths)
# Add any fixed log files you want to monitor, space-separated.
# Example:
# SPECIAL_LOG_PATHS="/wrkdata/default-some-suffix/GLOBAL.log /wrkdata/app-other/error.log"
SPECIAL_LOG_PATHS=""
# ---------------------------------------------------------------

if [ ! -d "$OFFSET_DIR" ]; then
    mkdir -p "$OFFSET_DIR"
fi

# ----------------------------- Helper functions ------------------------------
# Get the actual log file path using wildcard: /wrkdata/{ns}-*/{pod}.log
# Returns the first matching file path, or empty string if none found.
get_pod_log_path() {
    ns="$1"
    pod_name="$2"
    pattern="${BASE_LOG_DIR}/${ns}-*/${pod_name}.log"
    # Expand wildcard and return first match
    for f in $pattern; do
        if [ -f "$f" ]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# Offset management
get_offset_file() {
    echo "$OFFSET_DIR/$(echo "$1" | sha256sum | cut -d' ' -f1).off"
}

# Read only new lines from a log file (using byte offset)
process_new_lines() {
    log_file="$1"
    offset_file=$(get_offset_file "$log_file")
    last_offset=0
    [ -f "$offset_file" ] && last_offset=$(cat "$offset_file")

    current_size=$(stat -c%s "$log_file" 2>/dev/null)
    [ -z "$current_size" ] && return 1

    # Log rotated -> reset offset
    [ "$current_size" -lt "$last_offset" ] && last_offset=0

    if [ "$current_size" -gt "$last_offset" ]; then
        new_data=$(dd if="$log_file" bs=1 skip="$last_offset" 2>/dev/null)
        echo "$current_size" > "$offset_file"
        echo "$new_data"
        return 0
    fi
    return 1
}

# Check a single log file (print matches)
check_log_file() {
    log_file="$1"
    label="$2"          # Description for output (e.g., "Namespace: default | Pod: nginx")
    new_logs=$(process_new_lines "$log_file")
    [ -z "$new_logs" ] && return

    matches=$(echo "$new_logs" | grep -iE "$PATTERNS")
    if [ -n "$matches" ]; then
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        report="[$timestamp] $label | File: $log_file\n$matches\n"
        if [ -n "$OUTPUT_LOG" ]; then
            echo -e "$report" | sudo tee -a "$OUTPUT_LOG"
        else
            echo -e "$report"
        fi
    fi
}

# ----------------------------- Dynamic pod logs -------------------------------
check_pod_logs() {
    for ns in $NAMESPACES; do
        # Check if namespace exists
        kubectl get namespace "$ns" >/dev/null 2>&1 || {
            echo "Warning: Namespace '$ns' does not exist. Skipping." >&2
            continue
        }

        # Get all running pods in this namespace
        pods=$(kubectl get pods -n "$ns" --field-selector status.phase=Running -o jsonpath='{.items[*].metadata.name}')
        [ -z "$pods" ] && continue

        for pod in $pods; do
            log_file=$(get_pod_log_path "$ns" "$pod")
            if [ -n "$log_file" ] && [ -f "$log_file" ]; then
                check_log_file "$log_file" "Namespace: $ns | Pod: $pod"
            fi
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

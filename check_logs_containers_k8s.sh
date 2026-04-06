#!/bin/sh

# =========================================================================
# Script: check_k8s_pod_logs.sh
# Description: Check logs of running pods in specific namespaces.
#              Log path: /wrkdata/{ns}-{pvc}-{volume}/{pod}.log
#              Only reads new log lines (using offsets) to avoid re-reading.
#              Searches for patterns: error, timeout (case-insensitive).
#              Uses echo -e and tee -a for output.
# Usage: ./check_k8s_pod_logs.sh [pattern]
# Cron: */5 * * * * /path/to/check_k8s_pod_logs.sh
# =========================================================================

# ----------------------------- Configuration ----------------------------------
#NAMESPACES="default app backend"          # Namespaces to check
NAMESPACES=""
PATTERNS="${1:-error|timeout}"            # Regex pattern, can be overridden when calling
BASE_LOG_DIR="/wrkdata"                   # Root directory containing logs
OFFSET_DIR="/var/log/k8s_log_offsets"     # Where to store file offsets
OUTPUT_LOG=""                             # Empty -> print to stdout; set path to log to file

# Build the log file path for a pod
# Input: namespace, pod_name, pvc_name, volume_name
# Output: absolute path to the log file
build_log_path() {
    ns="$1"
    pod_name="$2"
    pvc_name="$3"
    volume_name="$4"
    echo "${BASE_LOG_DIR}/${ns}-${pvc_name}-${volume_name}/${pod_name}.log"
}

# Get PVC and volume info from pod (only the first PVC volume)
# If pod does not use PVC, returns empty string
get_pvc_and_volume() {
    ns="$1"
    pod_name="$2"
    kubectl get pod "$pod_name" -n "$ns" -o jsonpath='{range .spec.volumes[?(@.persistentVolumeClaim)]}{.name}{"|"}{.persistentVolumeClaim.claimName}{"\n"}{end}' 2>/dev/null
}

# ----------------------------- Offset handling ----------------------------------
mkdir -p "$OFFSET_DIR"

get_offset_file() {
    log_file="$1"
    # Create a safe offset filename using sha256
    echo "$OFFSET_DIR/$(echo "$log_file" | sha256sum | cut -d' ' -f1).off"
}

process_new_lines() {
    log_file="$1"
    offset_file=$(get_offset_file "$log_file")
    last_offset=0
    [ -f "$offset_file" ] && last_offset=$(cat "$offset_file")

    current_size=$(stat -c%s "$log_file" 2>/dev/null)
    [ -z "$current_size" ] && return 1

    # If file is smaller than offset (log rotated) -> read from start
    [ "$current_size" -lt "$last_offset" ] && last_offset=0

    if [ "$current_size" -gt "$last_offset" ]; then
        # Read only the new data
        new_data=$(dd if="$log_file" bs=1 skip="$last_offset" 2>/dev/null)
        # Save the new offset
        echo "$current_size" > "$offset_file"
        # Return the new data
        echo "$new_data"
        return 0
    fi
    return 1
}

# ----------------------------- Check pod logs ----------------------------------
check_pod_log() {
    ns="$1"
    pod_name="$2"

    # Get PVC and volume info (volume name, pvc name)
    pvc_info=$(get_pvc_and_volume "$ns" "$pod_name")
    [ -z "$pvc_info" ] && return 0

    # Assume each pod has only one PVC volume, take the first pair
    volume_name=$(echo "$pvc_info" | cut -d'|' -f1)
    pvc_name=$(echo "$pvc_info" | cut -d'|' -f2)

    log_file=$(build_log_path "$ns" "$pod_name" "$pvc_name" "$volume_name")
    if [ ! -f "$log_file" ]; then
        # Fallback: maybe the directory structure is different; you can adjust build_log_path
        return 0
    fi

    new_logs=$(process_new_lines "$log_file")
    if [ -n "$new_logs" ]; then
        matches=$(echo "$new_logs" | grep -iE "$PATTERNS")
        if [ -n "$matches" ]; then
            timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            report="[$timestamp] Namespace: $ns | Pod: $pod_name | File: $log_file\n$matches\n"
            if [ -n "$OUTPUT_LOG" ]; then
                # Print to screen and append to file
                echo -e "$report" | tee -a "$OUTPUT_LOG"
            else
                echo -e "$report"
            fi
            # Send alert (optional) - uncomment if needed
            # curl -X POST -H 'Content-type: application/json' --data "{\"text\":\"$report\"}" <webhook_url>
        fi
    fi
}

# ----------------------------- Main --------------------------------------------
for ns in $NAMESPACES; do
    # Check if namespace exists
    kubectl get namespace "$ns" >/dev/null 2>&1 || {
        echo "Warning: Namespace '$ns' does not exist. Skipping." >&2
        continue
    }

    # Get list of Running pods
    pods=$(kubectl get pods -n "$ns" --field-selector status.phase=Running -o jsonpath='{.items[*].metadata.name}')
    [ -z "$pods" ] && continue

    for pod in $pods; do
        check_pod_log "$ns" "$pod"
    done
done

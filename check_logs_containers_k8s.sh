#!/bin/sh

# ============================================================
# Script: check_specific_namespaces.sh
# Description: Check logs of ALL pods in a fixed list of namespaces
#              for patterns like "error", "timeout"
# Usage: ./check_logs_containers_k8s.sh [patterns]
# ============================================================

# -------------------- Configuration --------------------
# List of namespaces to monitor
NAMESPACES="default app backend"

# Default patterns (extended regex, pipe-separated)
DEFAULT_PATTERNS="error|timeout"

# How many minutes back to look (must match cron interval)
SINCE_MINUTES=5

# Optional: log file to store matches (empty = print to stdout)
OUTPUT_LOG=""

# ------------------------------------------------------

PATTERNS="${1:-$DEFAULT_PATTERNS}"

# Function to check logs of a single container
check_container() {
    ns="$1"
    pod="$2"
    container="$3"

    # Fetch logs from last SINCE_MINUTES minutes
    logs=$(kubectl logs --since="${SINCE_MINUTES}m" -n "$ns" "$pod" -c "$container" 2>&1)
    [ -z "$logs" ] && return

    # Search for patterns (case-insensitive)
    matches=$(echo "$logs" | grep -iE "$PATTERNS")
    if [ -n "$matches" ]; then
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        report="[$timestamp] Namespace: $ns | Pod: $pod | Container: $container\n$matches\n"

        if [ -n "$OUTPUT_LOG" ]; then
            echo "$report" >> "$OUTPUT_LOG"
        else
            echo "$report"
        fi
    fi
}

# Iterate over each namespace
for ns in $NAMESPACES; do
    # Check if namespace exists
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
        echo "Warning: Namespace '$ns' does not exist. Skipping." >&2
        continue
    fi

    # Get all pods in the namespace
    pods=$(kubectl get pods -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    [ -z "$pods" ] && continue

    for pod in $pods; do
        # Get container names (excluding init containers)
        containers=$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)
        for container in $containers; do
            check_container "$ns" "$pod" "$container"
        done
    done
done
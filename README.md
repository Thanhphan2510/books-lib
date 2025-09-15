#!/bin/bash

# Configuration
VALKEY_HOST="${VALKEY_HOST:-localhost}"
VALKEY_PORT="${VALKEY_PORT:-6379}"
VALKEY_PASSWORD="${VALKEY_PASSWORD:-}"
MAX_OFFSET_DIFF="${MAX_OFFSET_DIFF:-100}"  # Maximum allowed offset difference

# Function to execute Valkey commands
valkey_cmd() {
    local cmd="$1"
    if [ -z "$VALKEY_PASSWORD" ]; then
        valkey-cli -h "$VALKEY_HOST" -p "$VALKEY_PORT" "$cmd"
    else
        valkey-cli -h "$VALKEY_HOST" -p "$VALKEY_PORT" -a "$VALKEY_PASSWORD" "$cmd"
    fi
}

# Function to extract value from INFO output
get_info_value() {
    echo "$1" | grep "^$2:" | cut -d ':' -f2 | tr -d '\r'
}

# Get replication info
REPLICATION_INFO=$(valkey_cmd "INFO replication")
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to connect to Valkey at $VALKEY_HOST:$VALKEY_PORT"
    exit 1
fi

# Parse replication information
ROLE=$(get_info_value "$REPLICATION_INFO" "role")

if [ "$ROLE" = "master" ]; then
    # Master node - check connected replicas
    CONNECTED_SLAVES=$(get_info_value "$REPLICATION_INFO" "connected_slaves")
    
    if [ -z "$CONNECTED_SLAVES" ] || [ "$CONNECTED_SLAVES" -eq 0 ]; then
        echo "WARNING: Master has no connected replicas"
        exit 0
    fi
    
    # Get master offset
    MASTER_OFFSET=$(get_info_value "$REPLICATION_INFO" "master_repl_offset")
    
    # Check each replica
    ALL_SYNCED=true
    for ((i=0; i<CONNECTED_SLAVES; i++)); do
        SLAVE_INFO=$(get_info_value "$REPLICATION_INFO" "slave$i")
        SLAVE_OFFSET=$(echo "$SLAVE_INFO" | grep -o 'offset=[0-9]*' | cut -d '=' -f2)
        SLAVE_HOST=$(echo "$SLAVE_INFO" | grep -o 'ip=[^,]*' | cut -d '=' -f2)
        SLAVE_PORT=$(echo "$SLAVE_INFO" | grep -o 'port=[0-9]*' | cut -d '=' -f2)
        
        if [ -z "$SLAVE_OFFSET" ]; then
            echo "ERROR: Could not get offset for replica $SLAVE_HOST:$SLAVE_PORT"
            ALL_SYNCED=false
            continue
        fi
        
        OFFSET_DIFF=$((MASTER_OFFSET - SLAVE_OFFSET))
        
        if [ "$OFFSET_DIFF" -le "$MAX_OFFSET_DIFF" ]; then
            echo "OK: Replica $SLAVE_HOST:$SLAVE_PORT is synced (offset diff: $OFFSET_DIFF)"
        else
            echo "WARNING: Replica $SLAVE_HOST:$SLAVE_PORT is lagging (offset diff: $OFFSET_DIFF)"
            ALL_SYNCED=false
        fi
    done
    
    if [ "$ALL_SYNCED" = true ]; then
        echo "SUCCESS: All replicas are synchronized with master"
        exit 0
    else
        echo "ERROR: Some replicas are not synchronized"
        exit 1
    fi

elif [ "$ROLE" = "slave" ]; then
    # Slave node - check sync status with master
    MASTER_OFFSET=$(get_info_value "$REPLICATION_INFO" "master_repl_offset")
    SLAVE_OFFSET=$(valkey_cmd "INFO replication" | grep "slave_repl_offset" | cut -d ':' -f2 | tr -d '\r')
    
    if [ -z "$MASTER_OFFSET" ] || [ -z "$SLAVE_OFFSET" ]; then
        echo "ERROR: Could not retrieve offset information"
        exit 1
    fi
    
    OFFSET_DIFF=$((MASTER_OFFSET - SLAVE_OFFSET))
    
    if [ "$OFFSET_DIFF" -le "$MAX_OFFSET_DIFF" ]; then
        echo "SUCCESS: Replica is synced with master (offset diff: $OFFSET_DIFF)"
        exit 0
    else
        echo "WARNING: Replica is lagging behind master (offset diff: $OFFSET_DIFF)"
        exit 1
    fi
else
    echo "ERROR: Unknown role '$ROLE'"
    exit 1
fi

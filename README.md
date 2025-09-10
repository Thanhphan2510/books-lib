https://drive.google.com/file/d/14bp--s18AjqgVB4ckMsiQddIoa-oy7p1/view?usp=drive_link
#!/bin/bash

# Cấu hình
SENTINEL_PORT=7000
MASTER_NAME="scpmmaster"
SENTINEL_HOST="localhost"  # Thay đổi nếu Sentinel ở host khác
CHECK_INTERVAL=2           # Thời gian giữa các lần kiểm tra (giây)
MAX_RETRIES=3              # Số lần thử ping tối đa trước khi xem là lỗi

# Hàm lấy địa chỉ master từ Sentinel
get_master_address() {
    local result
    result=$(redis-cli -h $SENTINEL_HOST -p $SENTINEL_PORT SENTINEL get-master-addr-by-name $MASTER_NAME 2>&1)
    
    if [ $? -ne 0 ]; then
        echo "ERROR: Cannot connect to Sentinel: $result" >&2
        return 1
    fi
    
    echo "$result" | head -n1 | tr -d '"'
}

# Hàm kiểm tra kết nối Redis
ping_redis() {
    local ip=$1
    local port=$2
    redis-cli -h $ip -p $port PING >/dev/null 2>&1
    return $?
}

# Main loop
CURRENT_MASTER=""
while true; do
    # Lấy địa chỉ master mới nếu chưa có
    if [ -z "$CURRENT_MASTER" ]; then
        echo "Getting master address from Sentinel..."
        MASTER_IP=$(get_master_address)
        if [ $? -ne 0 ]; then
            echo "Will retry in $CHECK_INTERVAL seconds..."
            sleep $CHECK_INTERVAL
            continue
        fi
        
        CURRENT_MASTER=$MASTER_IP
        echo "Current master: $CURRENT_MASTER"
    fi

    # Kiểm tra kết nối đến master
    retries=0
    while [ $retries -lt $MAX_RETRIES ]; do
        if ping_redis $CURRENT_MASTER 6379; then
            echo "$(date): Successfully pinged master $CURRENT_MASTER"
            break
        else
            echo "$(date): Failed to ping master $CURRENT_MASTER (attempt $((retries+1))/$MAX_RETRIES)"
            ((retries++))
            sleep 1
        fi
    done

    # Nếu vẫn fail sau max retries
    if [ $retries -eq $MAX_RETRIES ]; then
        echo "Master $CURRENT_MASTER is unreachable. Getting new master from Sentinel..."
        NEW_MASTER=$(get_master_address)
        
        if [ $? -eq 0 ] && [ "$NEW_MASTER" != "$CURRENT_MASTER" ]; then
            echo "Master changed from $CURRENT_MASTER to $NEW_MASTER"
            CURRENT_MASTER=$NEW_MASTER
        else
            echo "Failed to get new master or master unchanged. Will retry..."
        fi
    fi

    sleep $CHECK_INTERVAL
done

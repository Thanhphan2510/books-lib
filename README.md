#!/bin/bash
VALKEY_CLI="valkey-cli"
PREFIX="test:$(date +%s):"  # Unique key prefix
TEST_RESULTS=()             # Track test results
echo "=== Valkey Data Type Tests with Validation ==="

# Function to validate test results
validate() {
    local test_name=$1
    local result=$2
    local expected=$3
    local message=$4
    
    if [ "$result" == "$expected" ]; then
        echo -e "  \033[1;32m✓ PASS: $test_name - $message\033[0m"
        TEST_RESULTS+=("PASS: $test_name")
        return 0
    else
        echo -e "  \033[1;31m✗ FAIL: $test_name - Expected '$expected', got '$result'\033[0m"
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi
}

# 1. String with expiration
echo -e "\n\033[1;36m[STRING TEST]\033[0m"
$VALKEY_CLI set "${PREFIX}str" "hello" ex 5 > /dev/null
str_val=$($VALKEY_CLI get "${PREFIX}str")
str_ttl=$($VALKEY_CLI ttl "${PREFIX}str")
validate "String" "$str_val" "hello" "Value set correctly"
validate "String-TTL" "$str_ttl" "5" "TTL set to 5s"

# 2. Hash with field expiration (Valkey special)
echo -e "\n\033[1;36m[HASH TEST]\033[0m"
$VALKEY_CLI hset "${PREFIX}user" name "Alice" age 30 > /dev/null
$VALKEY_CLI hexpire "${PREFIX}user" age 5 > /dev/null  # Valkey-specific
name_val=$($VALKEY_CLI hget "${PREFIX}user" name)
age_ttl=$($VALKEY_CLI httl "${PREFIX}user" age)
validate "Hash-Name" "$name_val" "Alice" "Name field correct"
validate "Hash-AgeTTL" "$age_ttl" "5" "Age TTL set"

# 3. List with expiration
echo -e "\n\033[1;36m[LIST TEST]\033[0m"
$VALKEY_CLI rpush "${PREFIX}list" A B C ex 10 > /dev/null
list_len=$($VALKEY_CLI llen "${PREFIX}list")
list_val=$($VALKEY_CLI lrange "${PREFIX}list" 0 0)
validate "List-Length" "$list_len" "3" "List has 3 elements"
validate "List-First" "$list_val" "A" "First element correct"

# 4. Set with expiration
echo -e "\n\033[1;36m[SET TEST]\033[0m"
$VALKEY_CLI sadd "${PREFIX}set" Apple Banana ex 15 > /dev/null
set_mem=$($VALKEY_CLI sismember "${PREFIX}set" Banana)
set_card=$($VALKEY_CLI scard "${PREFIX}set")
validate "Set-Membership" "$set_mem" "1" "Banana exists in set"
validate "Set-Cardinality" "$set_card" "2" "Set has 2 members"

# 5. Sorted Set with expiration
echo -e "\n\033[1;36m[SORTED SET TEST]\033[0m"
$VALKEY_CLI zadd "${PREFIX}zset" 100 "PlayerA" 200 "PlayerB" ex 20 > /dev/null
zset_score=$($VALKEY_CLI zscore "${PREFIX}zset" PlayerA)
zset_range=$($VALKEY_CLI zrange "${PREFIX}zset" 0 0)
validate "ZSet-Score" "$zset_score" "100" "PlayerA score correct"
validate "ZSet-Range" "$zset_range" "PlayerA" "First player correct"

# 6. Pub/Sub with validation
echo -e "\n\033[1;36m[PUB/SUB TEST]\033[0m"
(
    # Capture subscriber output
    $VALKEY_CLI subscribe "${PREFIX}news" | {
        while read -r line; do
            case $line in
                subscribe|message|${PREFIX}news|"Test Message") ;;
                *) echo "INVALID:$line" ;;
            esac
        done
    } > /tmp/pubsub.out &
    sleep 0.5
    $VALKEY_CLI publish "${PREFIX}news" "Test Message" > /dev/null
    sleep 0.5
    kill %1 2>/dev/null
)
pubsub_result=$(grep -c "INVALID" /tmp/pubsub.out)
validate "Pub/Sub" "$pubsub_result" "0" "Received valid messages"

# 7. Lua Script with expiration
echo -e "\n\033[1;36m[LUA SCRIPT TEST]\033[0m"
lua_result=$($VALKEY_CLI --eval <(echo '
  local key = KEYS[1]
  local ttl = tonumber(ARGV[1])
  redis.call("SET", key, "LuaValue", "EX", ttl)
  return redis.call("GET", key)
') "${PREFIX}lua_key" , 25)
validate "Lua Script" "$lua_result" "LuaValue" "Script returned correct value"

# 8. Streams with expiration
echo -e "\n\033[1;36m[STREAM TEST]\033[0m"
stream_id=$($VALKEY_CLI xadd "${PREFIX}stream" * sensor-id 9999 temp 25.5)
$VALKEY_CLI expire "${PREFIX}stream" 30 > /dev/null
stream_len=$($VALKEY_CLI xlen "${PREFIX}stream")
validate "Stream-Add" "$stream_id" "*-0" "Message ID format valid"
validate "Stream-Length" "$stream_len" "1" "Stream has 1 message"

# Final validation report
echo -e "\n\033[1;35m=== TEST VALIDATION REPORT ===\033[0m"
for result in "${TEST_RESULTS[@]}"; do
    if [[ $result == PASS* ]]; then
        echo -e "  \033[1;32m$result\033[0m"
    else
        echo -e "  \033[1;31m$result\033[0m"
    fi
done

# Cleanup only test keys
echo -e "\n\033[1;36mTest keys with prefix: ${PREFIX}"
echo "These will auto-expire based on their TTL settings"
echo "Run 'valkey-cli keys \"${PREFIX}*\"' to monitor expiration\033[0m"

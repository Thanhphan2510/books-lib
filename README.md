#!/bin/bash
VALKEY_CLI="valkey-cli"

# Unique key prefix to avoid conflicts
PREFIX="test:$(date +%s):"

echo "=== Valkey Data Type Tests with Expiration ==="

# 1. String with expiration
echo -e "\n\033[1;32m[STRING TEST]\033[0m"
$VALKEY_CLI set "${PREFIX}string_key" "hello" ex 3
$VALKEY_CLI ttl "${PREFIX}string_key"

# 2. Hash with field expiration (Valkey special)
echo -e "\n\033[1;32m[HASH TEST]\033[0m"
$VALKEY_CLI hset "${PREFIX}user" name "John" age 30
$VALKEY_CLI hexpire "${PREFIX}user" age 5  # Valkey-specific field expiration
$VALKEY_CLI hgetall "${PREFIX}user"
echo "TTL for age field: $(valkey-cli httl ${PREFIX}user age)"

# 3. List with expiration
echo -e "\n\033[1;32m[LIST TEST]\033[0m"
$VALKEY_CLI rpush "${PREFIX}list" A B C ex 10
$VALKEY_CLI lrange "${PREFIX}list" 0 -1
echo "List TTL: $(valkey-cli ttl ${PREFIX}list)"

# 4. Set with expiration
echo -e "\n\033[1;32m[SET TEST]\033[0m"
$VALKEY_CLI sadd "${PREFIX}set" Apple Banana Cherry ex 15
$VALKEY_CLI smembers "${PREFIX}set"
echo "Set TTL: $(valkey-cli ttl ${PREFIX}set)"

# 5. Sorted Set with expiration
echo -e "\n\033[1;32m[SORTED SET TEST]\033[0m"
$VALKEY_CLI zadd "${PREFIX}zset" 100 "PlayerA" 200 "PlayerB" ex 20
$VALKEY_CLI zrange "${PREFIX}zset" 0 -1 withscores
echo "ZSet TTL: $(valkey-cli ttl ${PREFIX}zset)"

# 6. Pub/Sub with timeout
echo -e "\n\033[1;32m[PUB/SUB TEST]\033[0m"
(
  $VALKEY_CLI subscribe "${PREFIX}news" | head -n 6
) &
sleep 0.5
$VALKEY_CLI publish "${PREFIX}news" "Breaking news!" &> /dev/null
$VALKEY_CLI publish "${PREFIX}news" "Valkey 7.2.8 released!" &> /dev/null

# 7. Lua Script with expiration
echo -e "\n\033[1;32m[LUA SCRIPT TEST]\033[0m"
$VALKEY_CLI --eval <(echo '
  local key = KEYS[1]
  local ttl = tonumber(ARGV[1])
  redis.call("SET", key, "Lua-generated", "EX", ttl)
  return redis.call("GET", key)
') "${PREFIX}lua_key" , 25

# 8. Streams with expiration
echo -e "\n\033[1;32m[STREAM TEST]\033[0m"
$VALKEY_CLI xadd "${PREFIX}stream" * sensor-id 1234 temp 19.8
$VALKEY_CLI xadd "${PREFIX}stream" * sensor-id 5678 temp 22.1
$VALKEY_CLI expire "${PREFIX}stream" 30
$VALKEY_CLI xlen "${PREFIX}stream"
echo "Stream TTL: $(valkey-cli ttl ${PREFIX}stream)"

# 9. Print all test keys
echo -e "\n\033[1;35mAll test keys (will expire automatically):\033[0m"
$VALKEY_CLI keys "${PREFIX}*"

echo -e "\n\033[1;36mTests completed! Existing data preserved.\033[0m"
echo "Test keys with prefix: ${PREFIX}"
echo "Run 'valkey-cli keys \"${PREFIX}*\"' to monitor expiration"

#!/bin/bash

# Test all Valkey data types and features
echo "=== Valkey Data Type Test Script ==="

# Connect to Valkey (default: localhost:6379)
VALKEY_CLI="redis-cli"

# 1. String Tests
echo -e "\n\033[1;32m[STRING TESTS]\033[0m"
$VALKEY_CLI set my_string "Hello Valkey"
$VALKEY_CLI get my_string
$VALKEY_CLI incr counter
$VALKEY_CLI incr counter
$VALKEY_CLI get counter

# 2. Hash Tests
echo -e "\n\033[1;32m[HASH TESTS]\033[0m"
$VALKEY_CLI hset user:1000 name "John Doe" email "john@valkey.io" age 30
$VALKEY_CLI hgetall user:1000
$VALKEY_CLI hincrby user:1000 age 1
$VALKEY_CLI hexpire user:1000 email 300  # Valkey-specific: expire email field in 300s

# 3. List Tests
echo -e "\n\033[1;32m[LIST TESTS]\033[0m"
$VALKEY_CLI rpush my_list "A" "B" "C"
$VALKEY_CLI lrange my_list 0 -1
$VALKEY_CLI lpop my_list
$VALKEY_CLI rpop my_list

# 4. Set Tests
echo -e "\n\033[1;32m[SET TESTS]\033[0m"
$VALKEY_CLI sadd primes 2 3 5 7 11
$VALKEY_CLI smembers primes
$VALKEY_CLI sadd odds 1 3 5 7 9
$VALKEY_CLI sinter primes odds

# 5. Sorted Set Tests
echo -e "\n\033[1;32m[SORTED SET TESTS]\033[0m"
$VALKEY_CLI zadd leaderboard 100 "PlayerA" 200 "PlayerB" 150 "PlayerC"
$VALKEY_CLI zrange leaderboard 0 -1 withscores
$VALKEY_CLI zrevrange leaderboard 0 1 withscores

# 6. Pub/Sub Tests
echo -e "\n\033[1;32m[PUB/SUB TESTS]\033[0m"
# Run pub/sub in background
(
  sleep 1
  $VALKEY_CLI publish news "Valkey 7.2.8 released!"
) &
$VALKEY_CLI subscribe news | head -n 4

# 7. Lua Script Tests
echo -e "\n\033[1;32m[LUA SCRIPT TESTS]\033[0m"
$VALKEY_CLI --eval <(echo '
  local key = KEYS[1]
  local value = ARGV[1]
  redis.call("SET", key, value)
  return redis.call("GET", key)
') my_script_key , "Lua is powerful!"

# 8. Stream Tests
echo -e "\n\033[1;32m[STREAM TESTS]\033[0m"
$VALKEY_CLI xadd mystream * sensor-id 1234 temp 19.8
$VALKEY_CLI xadd mystream * sensor-id 5678 temp 22.1
$VALKEY_CLI xrange mystream - +

# 9. Valkey-specific Features
echo -e "\n\033[1;32m[VALKEY-SPECIFIC TESTS]\033[0m"
$VALKEY_CLI ACL SETUSER test-user +@all -DEBUG > /dev/null
$VALKEY_CLI --user test-user ping
$VALKEY_CLI FT.CREATE myIdx SCHEMA title TEXT WEIGHT 5.0 | head -n 2

# Cleanup
$VALKEY_CLI flushall > /dev/null
echo -e "\n\033[1;35mAll tests completed. Data cleared.\033[0m"

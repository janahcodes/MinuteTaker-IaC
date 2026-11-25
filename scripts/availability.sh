#!/usr/bin/env bash
# Measure availability while something risky happens (a bad deploy, a node
# being drained): sends ~5 requests/second to an endpoint that needs the api
# AND DynamoDB, and counts failures.
# Usage: scripts/availability.sh <base-url> <seconds> [output-file]
set -uo pipefail
URL="${1:?usage: availability.sh <base-url> <seconds> [out]}"
DURATION="${2:?seconds}"
OUT="${3:-/dev/stdout}"

ok=0; failed=0; slowest=0; end=$((SECONDS + DURATION))
first_fail=""; last_fail=""
while [ $SECONDS -lt $end ]; do
  read -r code t < <(curl -s -o /dev/null -m 5 -w '%{http_code} %{time_total}' "$URL/api/meetings")
  ms=$(awk -v t="$t" 'BEGIN{printf "%d", t*1000}')
  [ "$ms" -gt "$slowest" ] && slowest=$ms
  if [ "$code" = 200 ]; then ok=$((ok + 1)); else
    failed=$((failed + 1)); now=$(date -u +%T); last_fail="$now ($code)"; [ -z "$first_fail" ] && first_fail="$now ($code)"
  fi
  sleep 0.2
done
total=$((ok + failed))
{
  echo "endpoint=$URL/api/meetings duration=${DURATION}s"
  echo "requests=$total ok=$ok failed=$failed success=$(awk -v o=$ok -v t=$total 'BEGIN{printf "%.2f", (t ? 100*o/t : 0)}')% slowest=${slowest}ms"
  [ -n "$first_fail" ] && echo "first failure $first_fail, last failure $last_fail"
} | tee "$OUT"
[ "$failed" = 0 ]

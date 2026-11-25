#!/usr/bin/env bash
# End-to-end check of a deployed environment, run by the pipeline after every
# deploy and after a rebuild. Exercises the whole path:
#   HTTPS + DNS -> ALB -> web (nginx) -> api -> S3 + DynamoDB + SQS -> worker
#   (Whisper) -> DynamoDB -> api
# Exits non-zero (failing the pipeline) if any step is wrong.
# Usage: scripts/smoke-test.sh https://minutetaker.cloudscape.lol [audio.wav]
#        scripts/smoke-test.sh http://localhost:8080   (docker compose; the pipeline runs this before deploying)
set -euo pipefail
URL="${1:?usage: smoke-test.sh <base-url> [audio-file]}"
FILE="${2:-$(dirname "$0")/../tests/fixtures/standup.wav}"
TIMEOUT_S="${SMOKE_TIMEOUT_S:-300}"

step() { printf '\n== %s\n' "$*"; }
fail() { echo "SMOKE TEST FAILED: $*" >&2; exit 1; }

if [[ "$URL" == https://* ]]; then
  step "HTTP redirects to HTTPS"
  code=$(curl -s -o /dev/null -w '%{http_code}' "${URL/https:/http:}/")
  [ "$code" = 301 ] || fail "expected 301 from http://, got $code"
fi

step "web is healthy (and, on https, the TLS certificate is valid)"
curl -sf --retry 30 --retry-delay 5 --retry-all-errors "$URL/healthz" >/dev/null || fail "$URL/healthz"
# Capture first: piping into `grep -q` makes curl die of SIGPIPE when grep
# exits early, and pipefail then reports a false failure.
page=$(curl -sf "$URL/") || fail "UI page did not load"
grep -q "<title>MinuteTaker</title>" <<<"$page" || fail "UI page is not MinuteTaker"

step "api can reach the queue (proves pod-identity credentials work)"
curl -sf --retry 20 --retry-delay 5 --retry-all-errors "$URL/api/stats" | jq -e '.queue != null' >/dev/null \
  || fail "/api/stats"

step "upload a recording"
resp=$(curl -sf -F "title=Pipeline smoke test $(date -u +%FT%TZ)" -F "file=@$FILE;type=audio/wav" "$URL/api/meetings") \
  || fail "upload rejected"
id=$(jq -r .id <<<"$resp")
echo "meeting $id: $(jq -r .status <<<"$resp")"

step "worker transcribes it (timeout ${TIMEOUT_S}s)"
deadline=$((SECONDS + TIMEOUT_S))
while :; do
  m=$(curl -sf "$URL/api/meetings/$id") || fail "could not read meeting $id"
  status=$(jq -r .status <<<"$m")
  echo "  $(date +%T) $status"
  [ "$status" = DONE ] && break
  [ "$status" = FAILED ] && fail "worker marked it FAILED: $(jq -r .error <<<"$m")"
  [ $SECONDS -lt $deadline ] || fail "still $status after ${TIMEOUT_S}s"
  sleep 5
done

step "transcript and action items are correct"
jq -e '.transcript | test("stand-?up"; "i")' <<<"$m" >/dev/null || fail "transcript missing expected words"
n=$(jq '.action_items | length' <<<"$m")
jq -r '.action_items[] | "  - \(.owner // "?"): \(.task) (due \(.due // "-"))"' <<<"$m"
[ "$n" -ge 2 ] || fail "expected at least 2 action items, got $n"
jq -e '[.action_items[].owner] | index("Sarah") != null' <<<"$m" >/dev/null || fail "owner 'Sarah' not extracted"
echo "  transcribed by $(jq -r .processed_by <<<"$m") in $(jq -r .processing_s <<<"$m") s"

step "search finds it"
curl -sf "$URL/api/search?q=proposal" | jq -e --arg id "$id" '[.results[].id] | index($id) != null' >/dev/null \
  || fail "search did not return the meeting"

step "clean up"
curl -sf -X DELETE "$URL/api/meetings/$id" -o /dev/null -w '%{http_code}\n' || fail "delete"

echo
echo "SMOKE TEST PASSED: $URL"

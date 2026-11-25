#!/usr/bin/env bash
# Copy a pipeline run's record into evidence/ so it outlives GitHub's 90-day
# log retention: the job list with timings, plus the log lines that matter.
# Usage: scripts/save-evidence.sh <run-id> <name>
set -euo pipefail
RUN="${1:?run id}"; NAME="${2:?name}"
REPO="${REPO:-janahcodes/MinuteTaker-IaC}"
cd "$(dirname "$0")/.."
mkdir -p evidence

gh run view "$RUN" --repo "$REPO" --json displayTitle,event,headSha,conclusion,createdAt,updatedAt,url,jobs --jq '
  "run:      \(.url)",
  "title:    \(.displayTitle)",
  "trigger:  \(.event)   commit: \(.headSha[0:7])   result: \(.conclusion)",
  "time:     \(.createdAt) -> \(.updatedAt)  (\(((.updatedAt|fromdate)-(.createdAt|fromdate))/60*10|floor/10) min)",
  "",
  "job                                       result     seconds",
  (.jobs[] | "\(.name | .[0:40] | . + " " * (42 - length))\(.conclusion | . + " " * (11 - length))\(if .conclusion == "skipped" then "-" elif .completedAt and .startedAt then ((.completedAt|fromdate)-(.startedAt|fromdate)) else "-" end)")
' > "evidence/$NAME-jobs.txt"

# Key lines only: results, timings, errors, the smoke test and rollout output.
gh run view "$RUN" --repo "$REPO" --log 2>/dev/null \
  | perl -pe 's/\e\[[0-9;]*m//g; s/\^\[\[[0-9;]*m//g; s/^\x{FEFF}//; s/^([^\t]*)\t[^\t]*\t\S+ /$1 | /' \
  | grep -E '\| (Apply complete|Destroy complete|No changes|SMOKE TEST|== |  - [A-Z?][a-z]*: |  [0-9:]{8} [A-Z]+|  transcribed|gone |LEFT |Teardown|all [0-9]+ pods run|[a-z]+-[a-z0-9]+-[a-z0-9]+=[0-9]+\.dkr\.ecr|terraform (apply|destroy):|rollout:|##\[error\]|Error|error:|FAILED|[0-9]+ passed|Success!|Failure!|Waiting for deployment|deployment .* (successfully rolled out|exceeded)|rolled back|.*rolling back)' \
  | grep -v -E 'Retry AssumeRole|echo "' \
  > "evidence/$NAME-log.txt" || true

echo "saved evidence/$NAME-jobs.txt ($(wc -l < "evidence/$NAME-jobs.txt") lines), evidence/$NAME-log.txt ($(wc -l < "evidence/$NAME-log.txt") lines)"

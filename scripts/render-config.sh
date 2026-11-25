#!/usr/bin/env bash
# Write k8s/overlays/eks/config.env from the live Terraform outputs, so the
# pods are pointed at whatever the current environment's resources are called.
# Usage: scripts/render-config.sh
set -euo pipefail
cd "$(dirname "$0")/.."
out() { terraform -chdir=infra/live output -raw "$1"; }
cat > k8s/overlays/eks/config.env <<CFG
AWS_REGION=$(out region)
TABLE_NAME=$(out table_name)
BUCKET_NAME=$(out bucket_name)
QUEUE_URL=$(out queue_url)
CFG
cat k8s/overlays/eks/config.env

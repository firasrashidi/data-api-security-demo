#!/bin/bash
# Destroy the AWS demo resources. Does not delete Supabase or Cloudflare objects.
set -euo pipefail

if [[ "${1:-}" != "--yes" ]]; then
  cat <<'EOF'
This destroys the demo VPC, NAT Gateway, private instance, artifact bucket, and secret shells.
Secret values are not printed.

Re-run with --yes to continue.

After AWS is gone, also:
  1. Run supabase/cleanup.sql in the SQL editor.
  2. Delete the Workers VPC service, Cloudflare Tunnel, Worker, and Access application.
EOF
  exit 1
fi

root=$(cd "$(dirname "$0")/../.." && pwd)
tf_dir="$root/aws/terraform"

for tool in aws terraform jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required command: $tool" >&2
    exit 1
  fi
done

bucket=$(terraform -chdir="$tf_dir" output -raw artifact_bucket 2>/dev/null || true)
region=$(terraform -chdir="$tf_dir" output -raw aws_region 2>/dev/null || true)
if [[ -z "$region" || "$region" == "null" ]]; then
  region="${AWS_REGION:-us-east-1}"
fi

if [[ -n "$bucket" && "$bucket" != "null" ]]; then
  aws s3 rm "s3://${bucket}" --region "$region" --recursive >/dev/null || true
fi

terraform -chdir="$tf_dir" destroy -input=false -auto-approve

cat <<'EOF'
AWS resources were destroyed.

The Supabase project and Cloudflare account are unchanged.
Run supabase/cleanup.sql, then delete the tunnel, VPC service, Worker, and Access application.
EOF

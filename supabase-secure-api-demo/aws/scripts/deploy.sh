#!/bin/bash
# Upload the backend and start it on the private instance.
# Terraform must already have been applied. This script does not print secret values.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

if [[ -f .env ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key=${line%%=*}
    value=${line#*=}
    if [[ -z "${!key:-}" ]]; then
      export "$key=$value"
    fi
  done < .env
fi

require_env() {
  local name=$1
  if [[ -z "${!name:-}" ]]; then
    echo "Missing $name" >&2
    exit 1
  fi
}

for name in SUPABASE_URL SUPABASE_PUBLISHABLE_KEY SUPABASE_INTERNAL_API_KEY BACKEND_AUTH_TOKEN CLOUDFLARE_TUNNEL_TOKEN; do
  require_env "$name"
done

if [[ ${#SUPABASE_INTERNAL_API_KEY} -lt 32 || ${#BACKEND_AUTH_TOKEN} -lt 32 ]]; then
  echo "SUPABASE_INTERNAL_API_KEY and BACKEND_AUTH_TOKEN must each be at least 32 characters" >&2
  exit 1
fi

if [[ "$SUPABASE_INTERNAL_API_KEY" == "$BACKEND_AUTH_TOKEN" || "$SUPABASE_INTERNAL_API_KEY" == "$SUPABASE_PUBLISHABLE_KEY" || "$BACKEND_AUTH_TOKEN" == "$SUPABASE_PUBLISHABLE_KEY" ]]; then
  echo "The publishable key, internal API key, and backend auth token must be distinct" >&2
  exit 1
fi

case "$SUPABASE_URL" in
  https://*) ;;
  *)
    echo "SUPABASE_URL must use https" >&2
    exit 1
    ;;
esac

for tool in aws terraform jq tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required command: $tool" >&2
    exit 1
  fi
done

if [[ ! -f aws/backend/package-lock.json ]]; then
  echo "aws/backend/package-lock.json is missing. Run npm install in aws/backend first." >&2
  exit 1
fi

tf_dir="$root/aws/terraform"
AWS_REGION="${AWS_REGION:-$(terraform -chdir="$tf_dir" output -raw aws_region 2>/dev/null || true)}"
if [[ -z "$AWS_REGION" || "$AWS_REGION" == "null" ]]; then
  AWS_REGION=us-east-1
fi

output_value() {
  terraform -chdir="$tf_dir" output -raw "$1"
}

INSTANCE_ID=$(output_value instance_id)
BUCKET=$(output_value artifact_bucket)
PUBLIC_IP=$(output_value instance_public_ip || true)
SECRET_JSON=$(terraform -chdir="$tf_dir" output -json secret_arns)

if [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "null" ]]; then
  echo "Refusing to deploy because the instance has a public IP" >&2
  exit 1
fi

put_secret() {
  local arn=$1
  local value=$2
  local tmp
  tmp=$(mktemp)
  chmod 600 "$tmp"
  SECRET_VALUE=$value jq -n --arg id "$arn" '{SecretId:$id, SecretString:env.SECRET_VALUE}' > "$tmp"
  unset SECRET_VALUE
  aws secretsmanager put-secret-value --region "$AWS_REGION" --cli-input-json "file://$tmp" >/dev/null
  rm -f "$tmp"
}

put_secret "$(jq -r .supabase_url <<<"$SECRET_JSON")" "$SUPABASE_URL"
put_secret "$(jq -r .supabase_publishable_key <<<"$SECRET_JSON")" "$SUPABASE_PUBLISHABLE_KEY"
put_secret "$(jq -r .supabase_internal_api_key <<<"$SECRET_JSON")" "$SUPABASE_INTERNAL_API_KEY"
put_secret "$(jq -r .backend_auth_token <<<"$SECRET_JSON")" "$BACKEND_AUTH_TOKEN"
put_secret "$(jq -r .cloudflare_tunnel_token <<<"$SECRET_JSON")" "$CLOUDFLARE_TUNNEL_TOKEN"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -czf "$work/backend.tgz" \
  --exclude node_modules \
  --exclude dist \
  --exclude coverage \
  --exclude tests \
  --exclude .env \
  -C "$root/aws/backend" \
  Dockerfile .dockerignore compose.yaml package.json package-lock.json tsconfig.json tsconfig.build.json src
cp "$root/aws/scripts/remote-up.sh" "$work/remote-up.sh"

aws s3 cp "$work/backend.tgz" "s3://${BUCKET}/backend.tgz" --region "$AWS_REGION" >/dev/null
aws s3 cp "$work/remote-up.sh" "s3://${BUCKET}/remote-up.sh" --region "$AWS_REGION" >/dev/null

url_arn=$(jq -r .supabase_url <<<"$SECRET_JSON")
publishable_arn=$(jq -r .supabase_publishable_key <<<"$SECRET_JSON")
internal_arn=$(jq -r .supabase_internal_api_key <<<"$SECRET_JSON")
backend_arn=$(jq -r .backend_auth_token <<<"$SECRET_JSON")
tunnel_arn=$(jq -r .cloudflare_tunnel_token <<<"$SECRET_JSON")

remote_command=$(cat <<EOF
set -euo pipefail
aws s3 cp "s3://${BUCKET}/remote-up.sh" /tmp/remote-up.sh --region "$AWS_REGION"
aws s3 cp "s3://${BUCKET}/backend.tgz" /tmp/backend.tgz --region "$AWS_REGION"
bash /tmp/remote-up.sh /tmp/backend.tgz "$AWS_REGION" "$url_arn" "$publishable_arn" "$internal_arn" "$backend_arn" "$tunnel_arn"
rm -f /tmp/remote-up.sh /tmp/backend.tgz
EOF
)

command_id=$(aws ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "Start the private Data API demo" \
  --parameters "$(jq -n --arg command "$remote_command" '{commands:[$command]}')" \
  --query Command.CommandId \
  --output text)

echo "Waiting for the private instance to build and start the containers."
for _ in $(seq 1 90); do
  status=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$command_id" \
    --instance-id "$INSTANCE_ID" \
    --query Status \
    --output text 2>/dev/null || echo Pending)
  case "$status" in
    Success)
      echo "Backend and cloudflared were started on ${INSTANCE_ID}."
      echo "The instance has no public IP. Continue with the Workers VPC service and Worker deploy."
      exit 0
      ;;
    Failed|Cancelled|TimedOut)
      echo "Remote startup failed with status ${status}." >&2
      echo "Inspect the instance with: aws ssm start-session --target ${INSTANCE_ID} --region ${AWS_REGION}" >&2
      exit 1
      ;;
  esac
  sleep 10
done

echo "Timed out waiting for the instance. The SSM command may still be running." >&2
exit 1

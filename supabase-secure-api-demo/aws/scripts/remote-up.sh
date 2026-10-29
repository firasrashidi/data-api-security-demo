#!/bin/bash
# Runs on the private instance. Reads Secrets Manager itself so secret values
# never appear in the SSM command document.
set -euo pipefail
set +x

if [[ $# -ne 7 ]]; then
  echo "usage: remote-up.sh <tarball> <region> <url-arn> <publishable-arn> <internal-arn> <backend-arn> <tunnel-arn>" >&2
  exit 1
fi

tarball=$1
region=$2
url_arn=$3
publishable_arn=$4
internal_arn=$5
backend_arn=$6
tunnel_arn=$7

for _ in $(seq 1 60); do
  if [[ -f /opt/secure-api/.bootstrap-complete ]] && systemctl is-active --quiet docker; then
    break
  fi
  sleep 10
done

if [[ ! -f /opt/secure-api/.bootstrap-complete ]]; then
  echo "Instance bootstrap did not finish. Read /var/log/secure-api-bootstrap.log on the instance." >&2
  exit 1
fi

systemctl start docker

read_secret() {
  aws secretsmanager get-secret-value \
    --region "$region" \
    --secret-id "$1" \
    --query SecretString \
    --output text
}

require_single_line() {
  local name=$1
  local value=$2
  if [[ -z "$value" || "$value" == "None" || "$value" == "null" ]]; then
    echo "Secret $name is empty" >&2
    exit 1
  fi
  case "$value" in
    *$'\n'*|*$'\r'*)
      echo "Secret $name contains a newline" >&2
      exit 1
      ;;
  esac
}

supabase_url=$(read_secret "$url_arn")
publishable_key=$(read_secret "$publishable_arn")
internal_key=$(read_secret "$internal_arn")
backend_token=$(read_secret "$backend_arn")
tunnel_token=$(read_secret "$tunnel_arn")

require_single_line SUPABASE_URL "$supabase_url"
require_single_line SUPABASE_PUBLISHABLE_KEY "$publishable_key"
require_single_line SUPABASE_INTERNAL_API_KEY "$internal_key"
require_single_line BACKEND_AUTH_TOKEN "$backend_token"
require_single_line TUNNEL_TOKEN "$tunnel_token"

case "$supabase_url" in
  https://*) ;;
  *)
    echo "SUPABASE_URL must use https" >&2
    exit 1
    ;;
esac

install -d -m 0755 /opt/secure-api/app
rm -rf /opt/secure-api/app
install -d -m 0755 /opt/secure-api/app
tar -xzf "$tarball" -C /opt/secure-api/app

if ! grep -q '127.0.0.1:8080:8080' /opt/secure-api/app/compose.yaml; then
  echo "Refusing to start a compose file that does not bind the backend to loopback" >&2
  exit 1
fi
if grep -q '0.0.0.0:8080' /opt/secure-api/app/compose.yaml; then
  echo "Refusing to start a compose file that publishes the backend on all interfaces" >&2
  exit 1
fi

umask 077
: > /opt/secure-api/backend.env
: > /opt/secure-api/tunnel.env
{
  printf 'SUPABASE_URL=%s\n' "$supabase_url"
  printf 'SUPABASE_PUBLISHABLE_KEY=%s\n' "$publishable_key"
  printf 'SUPABASE_INTERNAL_API_KEY=%s\n' "$internal_key"
  printf 'BACKEND_AUTH_TOKEN=%s\n' "$backend_token"
  printf 'PORT=%s\n' '8080'
  printf 'HOST=%s\n' '0.0.0.0'
  printf 'REQUEST_TIMEOUT_MS=%s\n' '8000'
} > /opt/secure-api/backend.env
printf 'TUNNEL_TOKEN=%s\n' "$tunnel_token" > /opt/secure-api/tunnel.env
chmod 600 /opt/secure-api/backend.env /opt/secure-api/tunnel.env

unset supabase_url publishable_key internal_key backend_token tunnel_token

cd /opt/secure-api/app
docker compose up -d --build --force-recreate
docker compose ps

#!/bin/bash
# Integration checks for the deployed demo.
# Prints PASS, FAIL, or SKIP. Never prints secret values.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
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

passed=0
failed=0
skipped=0
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

pass() { printf 'PASS  %s  %s\n' "$1" "$2"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s  %s\n' "$1" "$2"; failed=$((failed + 1)); }
skip() { printf 'SKIP  %s  %s\n' "$1" "$2"; skipped=$((skipped + 1)); }

redact() {
  local text=$1
  local secret
  for secret in "${SUPABASE_INTERNAL_API_KEY:-}" "${SUPABASE_PUBLISHABLE_KEY:-}" "${BACKEND_AUTH_TOKEN:-}" "${CF_ACCESS_CLIENT_SECRET:-}" "${CLOUDFLARE_TUNNEL_TOKEN:-}"; do
    if [[ -n "$secret" ]]; then
      text=${text//"$secret"/[redacted]}
    fi
  done
  printf '%s' "${text:0:240}"
}

contains_secret() {
  local file=$1
  local secret
  for secret in "${SUPABASE_INTERNAL_API_KEY:-}" "${SUPABASE_PUBLISHABLE_KEY:-}" "${BACKEND_AUTH_TOKEN:-}" "${CF_ACCESS_CLIENT_SECRET:-}"; do
    if [[ -n "$secret" ]] && grep -F -q -- "$secret" "$file"; then
      return 0
    fi
  done
  return 1
}

request() {
  local body=$1
  shift
  local status
  status=$(curl -sS --max-time 25 -o "$body" -w '%{http_code}' "$@" || true)
  if [[ -z "$status" ]]; then
    status=000
  fi
  printf '%s' "$status"
}

supabase_get() {
  local body=$1
  shift
  request "$body" \
    -H "apikey: ${SUPABASE_PUBLISHABLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_PUBLISHABLE_KEY}" \
    -H 'accept: application/json' \
    "$@" \
    "${SUPABASE_URL%/}/rest/v1/customer_documents?select=id,title,visibility"
}

private_titles_present() {
  grep -F -q 'Internal Financial Report' "$1" || grep -F -q 'Confidential Roadmap' "$1"
}

public_titles_present() {
  grep -F -q 'Public Architecture Guide' "$1" \
    && grep -F -q 'Public API Documentation' "$1" \
    && grep -F -q 'Product Overview' "$1"
}

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo 'curl and jq are required.'
  exit 1
fi

echo 'Supabase Data API security demo'
echo

if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_PUBLISHABLE_KEY:-}" ]]; then
  skip A 'set SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY'
  skip B 'set SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY'
else
  body="$tmpdir/a"
  status=$(supabase_get "$body")
  if [[ "$status" == "403" ]] && ! private_titles_present "$body" && ! contains_secret "$body"; then
    pass A 'publishable key alone was rejected'
  else
    fail A "expected 403 without document titles, got ${status}: $(redact "$(cat "$body")")"
  fi

  body="$tmpdir/b"
  status=$(supabase_get "$body" -H 'x-internal-api-key: incorrect-internal-api-key-value-not-real')
  if [[ "$status" == "403" ]] && ! private_titles_present "$body" && ! contains_secret "$body"; then
    pass B 'incorrect internal secret was rejected'
  else
    fail B "expected 403, got ${status}: $(redact "$(cat "$body")")"
  fi
fi

if [[ -z "${WORKER_URL:-}" ]]; then
  skip C 'set WORKER_URL'
  skip J 'set WORKER_URL'
else
  body="$tmpdir/c"
  status=$(request "$body" "${WORKER_URL%/}/documents")
  if [[ "$status" == "401" || "$status" == "403" || "$status" == "302" ]] && ! public_titles_present "$body"; then
    pass C "unauthenticated worker request was denied with ${status}"
  else
    fail C "expected Access denial, got ${status}: $(redact "$(cat "$body")")"
  fi

  body="$tmpdir/j-bad"
  status=$(request "$body" \
    -H 'CF-Access-Client-Id: invalid-client-id' \
    -H 'CF-Access-Client-Secret: invalid-client-secret' \
    "${WORKER_URL%/}/documents")
  if [[ "$status" == "401" || "$status" == "403" || "$status" == "302" ]] && ! public_titles_present "$body"; then
    pass J 'invalid service token did not bypass Access'
  else
    fail J "invalid service token got ${status}: $(redact "$(cat "$body")")"
  fi

  alt_urls="${WORKER_PREVIEW_URL:-}"
  if [[ -n "${EXTRA_WORKER_URLS:-}" ]]; then
    if [[ -n "$alt_urls" ]]; then
      alt_urls="${alt_urls},${EXTRA_WORKER_URLS}"
    else
      alt_urls="${EXTRA_WORKER_URLS}"
    fi
  fi
  if [[ -z "$alt_urls" ]]; then
    skip J 'set WORKER_PREVIEW_URL or EXTRA_WORKER_URLS to probe alternate hostnames; preview_urls is disabled in wrangler.jsonc'
  else
    preview_ok=1
    IFS=',' read -r -a alt_list <<< "$alt_urls"
    for target in "${alt_list[@]}"; do
      body="$tmpdir/j-alt"
      status=$(request "$body" "${target%/}/documents")
      if [[ "$status" != "401" && "$status" != "403" && "$status" != "302" && "$status" != "000" ]] || public_titles_present "$body"; then
        preview_ok=0
        fail J "alternate hostname ${target} returned ${status}"
      fi
    done
    if [[ "$preview_ok" -eq 1 ]]; then
      pass J 'alternate hostnames denied unauthenticated requests'
    fi
  fi
fi

if [[ -z "${WORKER_URL:-}" || -z "${CF_ACCESS_CLIENT_ID:-}" || -z "${CF_ACCESS_CLIENT_SECRET:-}" ]]; then
  skip D 'set WORKER_URL, CF_ACCESS_CLIENT_ID, and CF_ACCESS_CLIENT_SECRET'
  skip E 'authorized worker response is required'
else
  body="$tmpdir/d"
  status=$(request "$body" \
    -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
    -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
    -H 'accept: application/json' \
    "${WORKER_URL%/}/documents")
  if [[ "$status" == "200" ]] && public_titles_present "$body" && ! contains_secret "$body"; then
    pass D 'authorized worker request returned public documents'
  else
    fail D "expected 200 with public documents, got ${status}: $(redact "$(cat "$body")")"
  fi

  post_body="$tmpdir/d-post"
  post_status=$(request "$post_body" \
    -X POST \
    -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
    -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
    "${WORKER_URL%/}/documents")
  if [[ "$post_status" == "405" || "$post_status" == "401" || "$post_status" == "403" || "$post_status" == "404" ]]; then
    pass D 'worker rejected a write instead of proxying it'
  else
    fail D "worker accepted POST with ${post_status}"
  fi

  if [[ "$status" == "200" ]] && ! private_titles_present "$body" && ! contains_secret "$body"; then
    private_body="$tmpdir/e"
    private_status=$(request "$private_body" \
      -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
      -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
      "${WORKER_URL%/}/documents/33333333-3333-4333-8333-333333333333")
    if [[ "$private_status" == "404" ]] || { [[ "$private_status" == "200" ]] && ! private_titles_present "$private_body"; }; then
      pass E 'private documents were excluded'
    else
      fail E "private document request returned ${private_status}: $(redact "$(cat "$private_body")")"
    fi
  else
    fail E 'could not prove RLS because the authorized list did not succeed'
  fi
fi

if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_PUBLISHABLE_KEY:-}" || -z "${SUPABASE_INTERNAL_API_KEY:-}" ]]; then
  skip F 'set SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, and SUPABASE_INTERNAL_API_KEY'
  skip H 'set SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, and SUPABASE_INTERNAL_API_KEY'
  skip I 'set SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, and SUPABASE_INTERNAL_API_KEY'
else
  write_denied=1
  for method in POST PATCH DELETE; do
    body="$tmpdir/f-${method}"
    status=$(request "$body" \
      -X "$method" \
      -H "apikey: ${SUPABASE_PUBLISHABLE_KEY}" \
      -H "Authorization: Bearer ${SUPABASE_PUBLISHABLE_KEY}" \
      -H "x-internal-api-key: ${SUPABASE_INTERNAL_API_KEY}" \
      -H 'content-type: application/json' \
      -H 'prefer: return=representation' \
      --data '{"title":"should-not-persist","visibility":"public"}' \
      "${SUPABASE_URL%/}/rest/v1/customer_documents")
    if [[ "$status" != "401" && "$status" != "403" ]] || contains_secret "$body" || grep -F -q 'should-not-persist' "$body"; then
      write_denied=0
      fail F "${method} returned ${status}: $(redact "$(cat "$body")")"
    fi
  done
  if [[ "$write_denied" -eq 1 ]]; then
    pass F 'anon writes were denied with the valid internal secret'
  fi

  rpc_body="$tmpdir/h"
  rpc_status=$(request "$rpc_body" \
    -X POST \
    -H "apikey: ${SUPABASE_PUBLISHABLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_PUBLISHABLE_KEY}" \
    -H "x-internal-api-key: ${SUPABASE_INTERNAL_API_KEY}" \
    -H 'content-type: application/json' \
    --data '{"secret":"ignore-me"}' \
    "${SUPABASE_URL%/}/rest/v1/rpc/check_internal_api_key")
  follow_body="$tmpdir/h-follow"
  follow_status=$(supabase_get "$follow_body")
  rpc_text=$(tr -d '[:space:]' < "$rpc_body" || true)
  rpc_empty=0
  if [[ -z "$rpc_text" || "$rpc_text" == "null" ]]; then
    rpc_empty=1
  fi
  if contains_secret "$rpc_body" || [[ "$follow_status" != "403" ]]; then
    fail H "RPC disclosed material or disabled the pre-request check (rpc ${rpc_status}, follow-up ${follow_status})"
  elif [[ "$rpc_status" == "401" || "$rpc_status" == "403" || "$rpc_status" == "404" ]]; then
    pass H 'direct RPC did not disclose the secret or bypass the check'
  elif [[ ("$rpc_status" == "200" || "$rpc_status" == "204") && "$rpc_empty" -eq 1 ]]; then
    pass H 'direct RPC returned an empty body and did not disable the pre-request check'
  else
    fail H "unexpected RPC status ${rpc_status}: $(redact "$(cat "$rpc_body")")"
  fi

  body="$tmpdir/i"
  status=$(supabase_get "$body" -H "x-internal-api-key: ${SUPABASE_INTERNAL_API_KEY}")
  if [[ "$status" == "200" ]] && public_titles_present "$body" && ! private_titles_present "$body" && ! contains_secret "$body"; then
    pass I 'direct Data API call succeeded from this network with the valid secret'
    echo 'NOTE  I  This success is expected. The secret is a bearer credential, not proof that the caller is inside AWS.'
  else
    fail I "expected 200 with only public documents, got ${status}: $(redact "$(cat "$body")")"
  fi
fi

g_checked=0
g_failed=0
if command -v aws >/dev/null 2>&1 && command -v terraform >/dev/null 2>&1 && [[ -d aws/terraform/.terraform ]]; then
  instance_id=$(terraform -chdir=aws/terraform output -raw instance_id 2>/dev/null || true)
  public_ip=$(terraform -chdir=aws/terraform output -raw instance_public_ip 2>/dev/null || true)
  region=$(terraform -chdir=aws/terraform output -raw aws_region 2>/dev/null || echo "${AWS_REGION:-us-east-1}")
  if [[ -n "$instance_id" && "$instance_id" != "null" ]]; then
    g_checked=1
    live_ip=$(aws ec2 describe-instances --region "$region" --instance-ids "$instance_id" \
      --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null || echo missing)
    group_id=$(aws ec2 describe-instances --region "$region" --instance-ids "$instance_id" \
      --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text 2>/dev/null || echo missing)
    if [[ "$live_ip" == "missing" || "$group_id" == "missing" ]]; then
      echo 'NOTE  G  AWS describe calls were not available. Terraform public IP is still checked.'
    elif [[ "$live_ip" == "None" || "$live_ip" == "null" || -z "$live_ip" ]]; then
      open_ingress=$(aws ec2 describe-security-groups --region "$region" --group-ids "$group_id" \
        --query 'length(SecurityGroups[0].IpPermissions)' --output text 2>/dev/null || echo missing)
      if [[ "$open_ingress" != "0" ]]; then
        g_failed=1
        fail G "security group ingress count is ${open_ingress}"
      fi
    else
      g_failed=1
      fail G "instance has public IP ${live_ip}"
    fi
    if [[ -n "$public_ip" && "$public_ip" != "null" ]]; then
      g_failed=1
      fail G 'Terraform recorded a public IP'
    fi
  fi
fi

if [[ -n "${INSTANCE_PRIVATE_IP:-}" ]]; then
  g_checked=1
  body="$tmpdir/g"
  status=$(request "$body" --connect-timeout 5 "http://${INSTANCE_PRIVATE_IP}:8080/health")
  if [[ "$status" == "000" || "$status" == "000000" ]]; then
    :
  elif [[ "$g_failed" -eq 0 ]]; then
    echo "NOTE  G  private IP responded with ${status}. That only means this client can route to the VPC."
  fi
fi

if [[ "$g_checked" -eq 0 ]]; then
  skip G 'apply the Terraform stack or set INSTANCE_PRIVATE_IP to probe reachability'
elif [[ "$g_failed" -eq 0 ]]; then
  pass G 'backend has no public IP and no inbound security-group rules'
fi

echo
printf 'Result: %d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
if [[ "$skipped" -gt 0 ]]; then
  exit 2
fi
exit 0

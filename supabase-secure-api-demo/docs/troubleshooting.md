# Troubleshooting

## Every Data API call returns 403

The hook is installed and the secret does not match, or the Vault row is missing.

```sql
select name, created_at, updated_at
from vault.secrets
where name = 'demo_data_api_gateway_secret';
```

Do not select `decrypted_secret` in a shared session. Compare by rotating both copies to a new `openssl rand -base64 32` value: update Vault, update Secrets Manager, and restart the backend with `aws/scripts/deploy.sh`.

If the SQL editor itself uses the Data API for a grid view, that grid will also be 403 while the hook is active. The SQL editor connection still runs SQL.

Confirm the setting:

```sql
select rolconfig
from pg_roles
where rolname = 'authenticator';
```

Look for `pgrst.db_pre_request=public.check_internal_api_key`. After `cleanup.sql`, that entry is gone and PostgREST needs the `NOTIFY` in that file, which is already included.

## permission denied for function check_internal_api_key

PostgREST switched into a role that lost `EXECUTE`. `004` grants it to `anon`, `authenticated`, and `service_role`. Re-run the grant section as the function owner, or re-run `004`. Do not grant `EXECUTE` to `PUBLIC`.

## 004 fails while creating the role or reading Vault

Run the migration as `postgres` in the SQL editor. `demo_vault_reader` must be able to `SELECT` `vault.decrypted_secrets`, and `extensions.digest(bytea, text)` must exist. Hosted projects install `pgcrypto` in `extensions`. If the digest check fails, enable `pgcrypto` in that schema and run `004` again.

If a later statement fails after `SET ROLE`, run `RESET ROLE;` before retrying.

## Worker returns 503 Access is not configured

`CF_ACCESS_TEAM_DOMAIN` or `CF_ACCESS_AUD` is still a placeholder. Re-run `cloudflare/worker/scripts/configure.mjs` and deploy. Also set `BACKEND_AUTH_TOKEN` with `wrangler secret put`. A token shorter than 32 characters is treated as not configured.

## Worker returns 401

Access did not attach a valid JWT, or the audience does not match. Service Auth policies must use the Service Token include rule. A normal Allow policy does not accept `CF-Access-Client-Id` by itself when strict service-token mode is on.

## Worker returns 502 about the backend credential

Fastify rejected `x-backend-auth`. The Worker secret and the Secrets Manager value `backend/worker-auth-token` differ. Update both and redeploy. This is separate from the Supabase secret.

## Workers VPC returns dns_error or the tunnel falls back to HTTP/2

Use `cloudflared` 2025.7.0 or newer. The compose file pins `2026.10.5` and sets QUIC. The security group must allow outbound UDP 7844. If that port is blocked, `cloudflared` can fall back to HTTP/2 on TCP 7844, and Workers VPC DNS resolution can fail. The TCP port is allowed as a fallback, but the connector is configured to require QUIC.

From an SSM session, a failed UDP check looks like a timeout to port 7844 on the Cloudflare edge address printed in the `cloudflared` log.

## Private service connects, then the HTTP call fails

The VPC service host must be `127.0.0.1` and the HTTP port must be `8080`, because Compose publishes Fastify on host loopback and `cloudflared` uses the host network. The port in the Worker URL is not the routing port.

## Backend container exits immediately

`docker compose logs backend` on the instance. Startup throws if any required variable is missing, if the URL is not HTTPS, if the publishable key is a secret or `service_role` key, or if the three credentials are not distinct. The read-only root filesystem can be relaxed if the Node process needs a writable home; `/tmp` and `/home/node` are already tmpfs mounts.

## Terraform destroy or Secrets Manager create fails

Some accounts reject `recovery_window_in_days = 0`. Set `secret_recovery_window_days = 7` in `terraform.tfvars` and apply again. Empty the artifact bucket before destroy if `force_destroy` is blocked by a policy.

## Integration tests

`tests/security-tests.sh` exits 2 when a required variable is missing. That is a skip, not a pass. Exit 1 means a live check failed. A SKIP for test J's alternate hostnames is expected until `WORKER_PREVIEW_URL` or `EXTRA_WORKER_URLS` is set. The primary hostname is still checked.

## PostgREST older than the hosted Data API

Hosted projects were upgraded to PostgREST 14. The `PGRST` SQLSTATE used here matches that generation. A project still on PostgREST 11 needs the legacy error shape documented in the [API security guide](https://supabase.com/docs/guides/api/securing-your-api). Check the version in the dashboard before changing the function.

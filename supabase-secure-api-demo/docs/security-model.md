# Security model

The control that rejects a direct Data API call is an application secret checked inside Postgres. It is not a private network path to Supabase.

Anyone who learns `x-internal-api-key` can call `https://<project-ref>.supabase.co/rest/v1/customer_documents` from any network, present the publishable key, and receive the rows `anon` is allowed to see. Test I is the demonstration. Do not describe a successful call as proof that the request originated in AWS.

## Layers

1. Cloudflare Access authenticates the client. The Worker verifies `Cf-Access-Jwt-Assertion` against the team JWKS and the application audience.
2. The Worker authenticates itself to Fastify with a different secret.
3. Fastify authenticates itself to PostgREST with a third secret, stored in Vault and in AWS Secrets Manager.
4. Postgres grants and RLS still apply after the secret matches.

A failure at one layer does not weaken the next. A stolen Access token cannot be replayed to Fastify or to Supabase. A stolen backend token cannot be replayed to Supabase. A stolen internal API key can be replayed to Supabase from anywhere, and RLS still hides private rows from `anon`.

## Public-schema pre-request function

Supabase recommends keeping `SECURITY DEFINER` functions out of exposed schemas. This demo cannot follow that recommendation because the function is required to live in `public`.

What was done instead:

| Control | Result |
| --- | --- |
| Owner | `demo_vault_reader`, not the migration superuser-equivalent role |
| Role attributes | `NOLOGIN`, `NOINHERIT`, `NOCREATEDB`, `NOCREATEROLE`, `NOBYPASSRLS` |
| Vault access | `SELECT` on `vault.decrypted_secrets` only. The function reads one named secret |
| `search_path` | Empty, with fully qualified references |
| Return value | `void`. No secret is selected into the result |
| Errors | Fixed `Forbidden` / 403. `SQLERRM` is not returned |
| Writes | None |
| Arguments | None. No user-controlled identifier is interpolated |
| `EXECUTE` | Revoked from `PUBLIC`. Granted to `anon`, `authenticated`, and `service_role` |
| Direct RPC | Rejected when `request.path` contains `rpc/check_internal_api_key` |
| Overloads | The migration aborts unless exactly one zero-argument function exists |

`EXECUTE` for `anon` cannot be removed. PostgREST runs `pgrst.db_pre_request` after `SET ROLE`. Without the grant, the hook fails with a permission error and the Data API is unusable. The integration test calls `/rest/v1/rpc/check_internal_api_key` and checks that the body does not contain the secret and that a later request without the secret is still 403.

`audit.sql` checks the owner, the hook setting, the table grants, and that `PUBLIC` does not have `EXECUTE`. It does not print `decrypted_secret`.

## Known limitations

- The Data API hostname stays public. The secret is a bearer credential.
- The hook applies to every Data API request in the project, not only `customer_documents`. Dashboard API browsing and other clients break until they send the header or `cleanup.sql` resets the role setting. Realtime, Storage, and Auth are outside this hook.
- The comparison hashes both values and then uses ordinary byte equality. That removes a length leak. It is not a cryptographic constant-time compare inside Postgres.
- There is no rate limit. The secret has to be high entropy.
- `demo_vault_reader` can read every Vault secret if code running as that role is changed. Only an administrator who can assume the role can replace the function. `anon` cannot.
- The table owner bypasses RLS because `FORCE ROW LEVEL SECURITY` is off. That is how `seed.sql` inserts private rows. `service_role` also bypasses RLS, which is why this table's grants for `service_role` are revoked. Re-granting `SELECT` to `service_role` would expose private rows to that key.
- A direct SQL session never runs the pre-request function.
- Statement logging can capture the secret when it is inserted with `set-vault-secret.sql`. The Vault dashboard is the better write path.
- Cloudflare Access is only as complete as the Worker-level policy. `wrangler.jsonc` sets `preview_urls` to false. The deployment still turns on Access for **All traffic**, which covers `workers.dev`, routes, custom domains, and previews.
- Workers VPC is a beta API. The binding shape used here matches the documentation reviewed on 2026-10-29.
- The AWS network is a single availability zone. The NAT Gateway has a public IP; the instance does not. Terraform state contains resource IDs and secret ARNs, not secret values. Keep the state file private.

## Header handling

The Worker builds a new request. It does not copy `apikey`, `authorization`, `x-internal-api-key`, Access client secrets, or cookies. Fastify ignores query strings and will not call any Supabase path except the demo collection. Both services redact configured secrets from error bodies and avoid logging headers.

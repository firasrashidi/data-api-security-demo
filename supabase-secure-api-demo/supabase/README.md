# Supabase setup

All demo objects are created in `public`. Do not add an `api` or `private` schema. Vault stays in its own system schema and is reached through `vault.create_secret` and `vault.decrypted_secrets`.

Apply the files in this order. The SQL editor is the preferred place to run them because it avoids putting the database password in a shell history. `psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f <file>` is the same SQL.

1. `migrations/001_create_tables.sql`
2. `migrations/002_permissions.sql`
3. `migrations/003_rls.sql`
4. Store the Vault secret, below.
5. `migrations/004_pre_request.sql`
6. `seed.sql`
7. `audit.sql`

`004` registers the pre-request hook immediately. Until the Vault secret exists, the Data API fails closed with 403. That is intentional. Direct SQL is unaffected, so you can still run `seed.sql` afterward.

## Table and grants

`public.customer_documents` has `id`, `title`, `visibility`, and `created_at`. Visibility is `public` or `private`.

`anon` receives `SELECT` only. `authenticated`, `service_role`, and `PUBLIC` have no privileges on this table. Projects that still auto-grant DML are cleaned up by the `REVOKE` statements. Projects that no longer auto-expose tables still get the explicit `SELECT` grant.

RLS allows `anon` to read rows where `visibility = 'public'`. There is no write policy. `FORCE ROW LEVEL SECURITY` is off so the table owner can seed from the SQL editor. The Data API roles are not the owner.

## Vault secret

Generate a value and keep it for the AWS backend. It must be at least 32 characters and different from the Worker-to-backend token.

```bash
openssl rand -base64 32
```

Preferred storage path:

1. Dashboard > Project Settings > Vault > Add new secret.
2. Name: `demo_data_api_gateway_secret`.
3. Paste the value. Do not also paste it into a migration file.

Automation path, with the caveat that the statement can appear in database logs:

```bash
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 \
  -v gateway_secret="$SUPABASE_INTERNAL_API_KEY" \
  -f supabase/scripts/set-vault-secret.sql
```

Re-running that script rotates the same named secret. After rotation, update Secrets Manager and restart the backend. Requests fail closed while the two copies differ.

## Pre-request function

`public.check_internal_api_key()` returns `void`, reads `x-internal-api-key` from `request.headers`, and compares a SHA-256 digest with the Vault secret. It raises PostgREST SQLSTATE `PGRST` with HTTP status 403. The message is the fixed string `Forbidden`.

The function is `SECURITY DEFINER` because `anon` cannot read Vault. Its owner is `demo_vault_reader`, a `NOLOGIN` role with `SELECT` on `vault.decrypted_secrets` and execute on `extensions.digest(bytea, text)`. It has no bypass RLS attribute and no write privileges.

PostgREST invokes the hook after `SET ROLE`, so `anon`, `authenticated`, and `service_role` need `EXECUTE`. `PUBLIC` does not. The function rejects a direct `/rpc/check_internal_api_key` call when `request.path` contains that name. See the security model for the limitation this cannot remove.

This setting is project-wide:

```sql
ALTER ROLE authenticator
  SET pgrst.db_pre_request = 'public.check_internal_api_key';
NOTIFY pgrst, 'reload config';
```

Every Data API request on the project requires the header while the setting is present. Realtime, Storage, Auth, and direct Postgres connections do not use it.

## Cleanup

`cleanup.sql` resets the authenticator setting, notifies PostgREST, drops the table and function, deletes the named Vault secret, and drops `demo_vault_reader`. Run it before deleting the Cloudflare and AWS resources if you still want the Data API to behave normally.

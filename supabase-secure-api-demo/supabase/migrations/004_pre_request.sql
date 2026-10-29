-- Pre-request authentication for the managed Data API.
--
-- The function stays in public because this demo cannot add an application schema.
-- That is a real limitation. The owner is narrowed to demo_vault_reader, which can
-- read Vault and do nothing else. See docs/security-model.md.
--
-- PostgREST runs pgrst.db_pre_request after SET ROLE. anon, authenticated, and
-- service_role therefore need EXECUTE. Revoking those grants makes every Data API
-- call fail before the secret is checked. Direct RPC is tested in tests/security-tests.sh.

DO $extension$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'supabase_vault') THEN
    RAISE EXCEPTION 'supabase_vault is not installed. Enable Vault on this Supabase project first.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgcrypto') THEN
    CREATE EXTENSION pgcrypto WITH SCHEMA extensions;
  END IF;

  IF to_regprocedure('extensions.digest(bytea, text)') IS NULL THEN
    RAISE EXCEPTION 'extensions.digest(bytea, text) is required. Install pgcrypto in the extensions schema.';
  END IF;
END
$extension$;

DO $role$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'demo_vault_reader') THEN
    CREATE ROLE demo_vault_reader
      NOLOGIN
      NOINHERIT
      NOCREATEDB
      NOCREATEROLE
      NOBYPASSRLS;
  END IF;
END
$role$;

GRANT USAGE ON SCHEMA vault TO demo_vault_reader;
GRANT SELECT ON vault.decrypted_secrets TO demo_vault_reader;
GRANT USAGE ON SCHEMA extensions TO demo_vault_reader;
GRANT EXECUTE ON FUNCTION extensions.digest(bytea, text) TO demo_vault_reader;
GRANT USAGE ON SCHEMA public TO demo_vault_reader;

DO $membership$
BEGIN
  EXECUTE format('GRANT demo_vault_reader TO %I', CURRENT_USER);
END
$membership$;

-- CREATE is granted only for the duration of CREATE OR REPLACE, then removed.
GRANT CREATE ON SCHEMA public TO demo_vault_reader;

SET ROLE demo_vault_reader;

CREATE OR REPLACE FUNCTION public.check_internal_api_key()
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  headers_text text;
  headers jsonb;
  path_text text;
  provided text := '';
  expected text;
  provided_digest bytea;
  expected_digest bytea;
  blocked_rpc boolean := false;
  failed boolean := true;
BEGIN
  headers_text := pg_catalog.current_setting('request.headers', true);
  IF headers_text IS NULL OR headers_text = '' THEN
    headers := '{}'::jsonb;
  ELSE
    headers := headers_text::jsonb;
  END IF;

  IF pg_catalog.jsonb_typeof(headers -> 'x-internal-api-key') = 'string' THEN
    provided := pg_catalog.btrim(headers ->> 'x-internal-api-key');
  END IF;

  path_text := pg_catalog.coalesce(pg_catalog.current_setting('request.path', true), '');
  IF pg_catalog.strpos(path_text, 'rpc/check_internal_api_key') > 0 THEN
    blocked_rpc := true;
  END IF;

  SELECT pg_catalog.btrim(ds.decrypted_secret)
    INTO expected
  FROM vault.decrypted_secrets AS ds
  WHERE ds.name = 'demo_data_api_gateway_secret'
  ORDER BY ds.created_at DESC
  LIMIT 1;

  IF expected IS NOT NULL AND provided <> '' AND pg_catalog.char_length(provided) <= 512 THEN
    provided_digest := extensions.digest(pg_catalog.convert_to(provided, 'UTF8'), 'sha256');
    expected_digest := extensions.digest(pg_catalog.convert_to(expected, 'UTF8'), 'sha256');
  END IF;

  failed := blocked_rpc
    OR expected IS NULL
    OR provided = ''
    OR pg_catalog.char_length(provided) > 512
    OR provided_digest IS NULL
    OR expected_digest IS NULL
    OR provided_digest IS DISTINCT FROM expected_digest;

  provided := NULL;
  expected := NULL;
  provided_digest := NULL;
  expected_digest := NULL;

  IF failed THEN
    RAISE SQLSTATE 'PGRST' USING
      message = pg_catalog.json_build_object(
        'message', 'Forbidden',
        'code', '403'
      )::text,
      detail = pg_catalog.json_build_object(
        'status', 403
      )::text;
  END IF;
EXCEPTION
  WHEN SQLSTATE 'PGRST' THEN
    RAISE;
  WHEN OTHERS THEN
    RAISE SQLSTATE 'PGRST' USING
      message = pg_catalog.json_build_object(
        'message', 'Forbidden',
        'code', '403'
      )::text,
      detail = pg_catalog.json_build_object(
        'status', 403
      )::text;
END;
$function$;

COMMENT ON FUNCTION public.check_internal_api_key() IS
  'Data API pre-request check. Returns void. Reads one Vault secret and raises 403 on failure. Does not return Vault data.';

REVOKE ALL ON FUNCTION public.check_internal_api_key() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_internal_api_key()
  TO anon, authenticated, service_role;

RESET ROLE;

REVOKE CREATE ON SCHEMA public FROM demo_vault_reader;

DO $verify$
DECLARE
  owner_name text;
  secdef boolean;
  config text[];
  overload_count integer;
  search_path_locked boolean;
BEGIN
  SELECT count(*)
    INTO overload_count
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'check_internal_api_key';

  IF overload_count <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one public.check_internal_api_key, found %', overload_count;
  END IF;

  SELECT r.rolname, p.prosecdef, p.proconfig
    INTO owner_name, secdef, config
  FROM pg_proc AS p
  JOIN pg_roles AS r ON r.oid = p.proowner
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'check_internal_api_key'
    AND pg_get_function_identity_arguments(p.oid) = '';

  IF owner_name IS DISTINCT FROM 'demo_vault_reader' THEN
    RAISE EXCEPTION 'check_internal_api_key owner is %, expected demo_vault_reader', owner_name;
  END IF;

  IF secdef IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'check_internal_api_key must be SECURITY DEFINER';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM pg_catalog.unnest(config) AS item
    WHERE item LIKE 'search_path=%'
      AND split_part(item, '=', 2) IN ('', '""')
  )
    INTO search_path_locked;

  IF search_path_locked IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'check_internal_api_key search_path is not empty: %', config;
  END IF;

  IF NOT has_table_privilege('demo_vault_reader', 'vault.decrypted_secrets', 'SELECT') THEN
    RAISE EXCEPTION 'demo_vault_reader cannot select vault.decrypted_secrets';
  END IF;

  IF NOT has_function_privilege('anon', 'public.check_internal_api_key()', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon cannot execute the pre-request function';
  END IF;
END
$verify$;

-- Project-wide. Every Data API request must present the gateway secret until cleanup.sql.
ALTER ROLE authenticator
  SET pgrst.db_pre_request = 'public.check_internal_api_key';

NOTIFY pgrst, 'reload config';

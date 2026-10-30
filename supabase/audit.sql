-- Read-only catalog checks for the demo. Raises if a required control is missing.
-- Does not print Vault material.
--
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/audit.sql

DO $audit$
DECLARE
  rls_on boolean;
  anon_select boolean;
  anon_insert boolean;
  authenticated_any boolean;
  service_any boolean;
  public_any boolean;
  public_execute boolean;
  anon_execute boolean;
  hook text;
  secret_exists boolean;
  owner_name text;
BEGIN
  SELECT c.relrowsecurity
    INTO rls_on
  FROM pg_class AS c
  JOIN pg_namespace AS n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'customer_documents';

  IF rls_on IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'RLS is not enabled on public.customer_documents';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policy AS pol
    JOIN pg_class AS c ON c.oid = pol.polrelid
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'customer_documents'
      AND pol.polname = 'customer_documents_anon_select_public'
      AND pol.polcmd = 'r'
  ) THEN
    RAISE EXCEPTION 'anon SELECT policy is missing';
  END IF;

  SELECT
    COALESCE(bool_or(grantee.rolname = 'anon' AND priv.privilege_type = 'SELECT'), false),
    COALESCE(bool_or(grantee.rolname = 'anon' AND priv.privilege_type <> 'SELECT'), false),
    COALESCE(bool_or(grantee.rolname = 'authenticated'), false),
    COALESCE(bool_or(grantee.rolname = 'service_role'), false),
    COALESCE(bool_or(priv.grantee = 0), false)
  INTO anon_select, anon_insert, authenticated_any, service_any, public_any
  FROM pg_class AS c
  JOIN pg_namespace AS n ON n.oid = c.relnamespace
  LEFT JOIN LATERAL aclexplode(c.relacl) AS priv ON true
  LEFT JOIN pg_roles AS grantee ON grantee.oid = priv.grantee
  WHERE n.nspname = 'public'
    AND c.relname = 'customer_documents';

  IF anon_select IS DISTINCT FROM true OR anon_insert IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'anon must have only SELECT on customer_documents';
  END IF;

  IF authenticated_any OR service_any OR public_any THEN
    RAISE EXCEPTION 'authenticated, service_role, or PUBLIC still has a grant on customer_documents';
  END IF;

  SELECT r.rolname
    INTO owner_name
  FROM pg_proc AS p
  JOIN pg_roles AS r ON r.oid = p.proowner
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'check_internal_api_key'
    AND pg_get_function_identity_arguments(p.oid) = '';

  IF owner_name IS DISTINCT FROM 'demo_vault_reader' THEN
    RAISE EXCEPTION 'pre-request function owner drifted from demo_vault_reader';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname = 'vault'
      AND p.proname = '_crypto_aead_det_decrypt'
      AND has_function_privilege('demo_vault_reader', p.oid, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'demo_vault_reader cannot execute vault._crypto_aead_det_decrypt';
  END IF;

  SELECT p.proacl IS NULL
    INTO public_execute
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'check_internal_api_key'
    AND pg_get_function_identity_arguments(p.oid) = '';

  IF public_execute THEN
    RAISE EXCEPTION 'check_internal_api_key still has the default PUBLIC execute ACL';
  END IF;

  SELECT has_function_privilege('anon', 'public.check_internal_api_key()', 'EXECUTE')
    INTO anon_execute;

  SELECT COALESCE(bool_or(priv.grantee = 0 AND priv.privilege_type = 'EXECUTE'), false)
    INTO public_execute
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  LEFT JOIN LATERAL aclexplode(p.proacl) AS priv ON true
  WHERE n.nspname = 'public'
    AND p.proname = 'check_internal_api_key'
    AND pg_get_function_identity_arguments(p.oid) = '';

  IF anon_execute IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'anon lost EXECUTE on check_internal_api_key. The pre-request hook runs after SET ROLE and needs this grant.';
  END IF;

  IF public_execute THEN
    RAISE EXCEPTION 'PUBLIC has EXECUTE on check_internal_api_key';
  END IF;

  SELECT cfg
    INTO hook
  FROM pg_roles AS role
  CROSS JOIN LATERAL unnest(role.rolconfig) AS cfg
  WHERE role.rolname = 'authenticator'
    AND cfg LIKE 'pgrst.db_pre_request=%';

  IF hook IS DISTINCT FROM 'pgrst.db_pre_request=public.check_internal_api_key' THEN
    RAISE EXCEPTION 'authenticator pre-request hook is %, expected public.check_internal_api_key', hook;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM vault.secrets
    WHERE name = 'demo_data_api_gateway_secret'
  )
    INTO secret_exists;

  IF secret_exists IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Vault secret demo_data_api_gateway_secret does not exist';
  END IF;

  RAISE NOTICE 'catalog audit passed';
  RAISE NOTICE 'FORCE ROW LEVEL SECURITY is off so the table owner can seed. API roles still honor RLS.';
  RAISE NOTICE 'anon EXECUTE on public.check_internal_api_key is required by PostgREST and is a known public-schema limitation.';
END
$audit$;

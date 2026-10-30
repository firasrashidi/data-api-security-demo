-- Remove the demo. Safe to re-run.
-- Reset the Data API hook before dropping the function. Otherwise every Data API
-- request fails closed until PostgREST reloads.

ALTER ROLE authenticator RESET pgrst.db_pre_request;
NOTIFY pgrst, 'reload config';

DROP POLICY IF EXISTS customer_documents_anon_select_public
  ON public.customer_documents;

DROP TABLE IF EXISTS public.customer_documents;
DROP FUNCTION IF EXISTS public.check_internal_api_key();

DO $cleanup$
DECLARE
  fn oid;
BEGIN
  IF to_regclass('vault.secrets') IS NOT NULL THEN
    DELETE FROM vault.secrets
    WHERE name = 'demo_data_api_gateway_secret';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'demo_vault_reader') THEN
    IF to_regclass('vault.decrypted_secrets') IS NOT NULL THEN
      REVOKE ALL ON vault.decrypted_secrets FROM demo_vault_reader;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'vault') THEN
      REVOKE USAGE ON SCHEMA vault FROM demo_vault_reader;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'extensions') THEN
      REVOKE USAGE ON SCHEMA extensions FROM demo_vault_reader;
    END IF;
    IF to_regprocedure('extensions.digest(bytea, text)') IS NOT NULL THEN
      REVOKE EXECUTE ON FUNCTION extensions.digest(bytea, text) FROM demo_vault_reader;
    END IF;
    FOR fn IN
      SELECT p.oid
      FROM pg_proc AS p
      JOIN pg_namespace AS n ON n.oid = p.pronamespace
      WHERE n.nspname = 'vault'
        AND p.proname = '_crypto_aead_det_decrypt'
    LOOP
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM demo_vault_reader', fn::regprocedure);
    END LOOP;
    REVOKE CREATE, USAGE ON SCHEMA public FROM demo_vault_reader;
    BEGIN
      EXECUTE format('REVOKE demo_vault_reader FROM %I', CURRENT_USER);
    EXCEPTION
      WHEN undefined_object OR insufficient_privilege THEN
        NULL;
    END;
    DROP ROLE demo_vault_reader;
  END IF;
END
$cleanup$;

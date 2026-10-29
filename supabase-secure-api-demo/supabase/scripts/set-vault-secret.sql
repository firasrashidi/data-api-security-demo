-- Store or rotate the Data API gateway secret in Supabase Vault.
--
-- Preferred: Dashboard -> Project Settings -> Vault -> Add new secret
--   Name: demo_data_api_gateway_secret
--   Secret: the value of SUPABASE_INTERNAL_API_KEY
-- The dashboard path does not put the secret in a SQL file.
--
-- Automation path (the statement sent to Postgres can appear in database logs):
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 \
--     -v gateway_secret="$SUPABASE_INTERNAL_API_KEY" \
--     -f supabase/scripts/set-vault-secret.sql
--
-- This file contains no secret. psql substitutes :'gateway_secret' on the client.

\if :{?gateway_secret}
\else
\echo 'Set the gateway_secret psql variable. Refusing to continue.'
\quit 1
\endif

DO $body$
DECLARE
  provided text := :'gateway_secret';
  existing uuid;
BEGIN
  IF provided IS NULL OR char_length(provided) < 32 THEN
    RAISE EXCEPTION 'gateway secret must be at least 32 characters';
  END IF;

  SELECT id
    INTO existing
  FROM vault.secrets
  WHERE name = 'demo_data_api_gateway_secret'
  ORDER BY created_at DESC
  LIMIT 1;

  IF existing IS NULL THEN
    PERFORM vault.create_secret(
      provided,
      'demo_data_api_gateway_secret',
      'Secret presented by the private AWS backend to the Data API'
    );
  ELSE
    PERFORM vault.update_secret(
      existing,
      provided,
      'demo_data_api_gateway_secret',
      'Secret presented by the private AWS backend to the Data API'
    );
  END IF;
END
$body$;

-- Removes the named Vault secret. Does not print secret material.
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/scripts/remove-vault-secret.sql

DELETE FROM vault.secrets
WHERE name = 'demo_data_api_gateway_secret';

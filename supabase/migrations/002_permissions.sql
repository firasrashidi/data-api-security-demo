-- Minimum grants for this demo table only.
-- Supabase may have already granted broad DML to anon, authenticated, and service_role.
-- Revoke those grants, then grant SELECT to anon. RLS still applies to anon.

REVOKE ALL PRIVILEGES ON TABLE public.customer_documents FROM PUBLIC;
REVOKE ALL PRIVILEGES ON TABLE public.customer_documents FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.customer_documents FROM authenticated;
REVOKE ALL PRIVILEGES ON TABLE public.customer_documents FROM service_role;

GRANT SELECT ON TABLE public.customer_documents TO anon;

-- authenticated has no privileges. There is no INSERT, UPDATE, DELETE, TRUNCATE,
-- REFERENCES, TRIGGER, or MAINTAIN grant for anon or authenticated.
-- service_role is also revoked on this table so BYPASSRLS cannot read it through the Data API.
-- This does not change privileges on any other relation.

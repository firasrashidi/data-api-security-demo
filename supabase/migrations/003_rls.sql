-- Row Level Security for anonymous Data API reads.
-- The table owner can still seed rows from the SQL editor because FORCE ROW LEVEL SECURITY
-- is intentionally not set. API roles do not own the table and cannot bypass these policies.

ALTER TABLE public.customer_documents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS customer_documents_anon_select_public
  ON public.customer_documents;

CREATE POLICY customer_documents_anon_select_public
  ON public.customer_documents
  FOR SELECT
  TO anon
  USING (visibility = 'public');

-- No INSERT, UPDATE, or DELETE policy exists.
-- authenticated has no policy. Combined with the missing grant, authenticated reads nothing.
-- A valid internal API secret does not change this policy.

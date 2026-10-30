-- Demo table for the managed Data API.
-- Everything in this demo lives in public. Do not add an application schema.

CREATE TABLE public.customer_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  visibility text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT customer_documents_visibility_check
    CHECK (visibility IN ('public', 'private'))
);

COMMENT ON TABLE public.customer_documents IS
  'Demo documents served by the managed Data API. Private rows are hidden from anon by RLS.';

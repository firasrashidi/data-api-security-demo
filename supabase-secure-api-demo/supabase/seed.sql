-- Seed five known documents. Safe to re-run.
-- Run this with the SQL editor or psql. It does not go through the Data API.

INSERT INTO public.customer_documents (id, title, visibility)
VALUES
  ('11111111-1111-4111-8111-111111111111', 'Public Architecture Guide', 'public'),
  ('22222222-2222-4222-8222-222222222222', 'Public API Documentation', 'public'),
  ('33333333-3333-4333-8333-333333333333', 'Internal Financial Report', 'private'),
  ('44444444-4444-4444-8444-444444444444', 'Confidential Roadmap', 'private'),
  ('55555555-5555-4555-8555-555555555555', 'Product Overview', 'public')
ON CONFLICT (id) DO UPDATE
SET
  title = EXCLUDED.title,
  visibility = EXCLUDED.visibility;

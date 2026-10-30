# Supabase Data API security demo

This proof of concept shows how a customer can keep using Supabase's managed Data API and still reject requests that do not come through their own application tier.

The Data API stays on the public internet. An extra secret, checked by Postgres before PostgREST runs the query, is what rejects unauthorized calls. Possession of that secret does not prove the caller is inside AWS or Cloudflare.

## What the demo proves

1. A direct Data API call with only the publishable key returns 403.
2. An authorized client can call a Cloudflare Worker protected by Cloudflare Access.
3. The Worker reaches a private Fastify service through a Workers VPC service binding and a Cloudflare Tunnel.
4. The Fastify service calls `https://<project-ref>.supabase.co/rest/v1/customer_documents`.
5. That call adds `x-internal-api-key`. `public.check_internal_api_key()` compares it with a Supabase Vault secret.
6. A valid secret does not reveal private rows. Row Level Security still limits `anon` to `visibility = 'public'`.
7. `anon` cannot insert, update, or delete.
8. The EC2 instance has no public IP, no inbound security-group rules, and no public hostname.

## Request path

```text
Client
  -> Cloudflare Access
  -> Cloudflare Worker
  -> Workers VPC service binding
  -> Cloudflare Tunnel
  -> private EC2 (cloudflared + Fastify on 127.0.0.1:8080)
  -> Supabase Data API
  -> public.check_internal_api_key()
  -> public.customer_documents
```

Three credentials stay separate:

| Hop | Credential |
| --- | --- |
| Client to Worker | Cloudflare Access service token, or a human Access login |
| Worker to Fastify | `x-backend-auth` |
| Fastify to Supabase | `x-internal-api-key`, plus the publishable key as `apikey` |

The publishable key is not one of those three private credentials. The backend refuses to start if it is a `service_role` or `sb_secret_` key.

## Layout

```text
supabase/           public schema migrations, Vault helper, seed, cleanup
aws/terraform/      private VPC, NAT, EC2, SSM, Secrets Manager
aws/backend/        Fastify service
aws/scripts/        deploy and teardown
cloudflare/worker/  Access-aware Worker and VPC binding
cloudflare/tunnel/  Tunnel setup, with no public hostname
tests/              unit-test runner and deployed integration tests
docs/               architecture, deployment, security model, demo script
```

## Local checks

These do not need cloud credentials:

```bash
tests/run-unit-tests.sh
```

The integration script reports SKIP until the stack is deployed:

```bash
tests/security-tests.sh
```

Hand-run the same cases with [docs/curl-commands.md](docs/curl-commands.md).

## Deploy

Follow [docs/deployment.md](docs/deployment.md) in order. The NAT Gateway is billable; run `aws/scripts/teardown.sh --yes` and `supabase/cleanup.sql` when you are finished.

Read [docs/security-model.md](docs/security-model.md) before treating the pre-request function as a network control. It is not one.

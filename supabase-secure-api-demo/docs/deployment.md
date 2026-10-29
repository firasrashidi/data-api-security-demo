# Deployment

Run the steps in order. Commands assume the repository root and a filled-in `.env` that is not committed. Placeholder angle brackets are values you copy from a dashboard. This guide does not contain a real project ref, token, or account ID.

The NAT Gateway starts billing at step 8. Tear it down when the demo is over.

## 1. Create a Supabase project

Create a hosted project and leave the Data API enabled on the default `public` schema. From **Project Settings > API**, copy:

- Project URL, for example `https://<project-ref>.supabase.co`
- The publishable key

Do not copy the secret key or the `service_role` key into this demo.

Generate two different private values:

```bash
openssl rand -base64 32   # SUPABASE_INTERNAL_API_KEY
openssl rand -base64 32   # BACKEND_AUTH_TOKEN
```

## 2. Create the public table

In the SQL editor, run `supabase/migrations/001_create_tables.sql`.

Or:

```bash
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/001_create_tables.sql
```

## 3. Apply grants

```bash
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/002_permissions.sql
```

## 4. Enable RLS

```bash
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/003_rls.sql
```

## 5. Store the Vault secret

Dashboard > Project Settings > Vault > Add new secret.

- Name: `demo_data_api_gateway_secret`
- Value: `SUPABASE_INTERNAL_API_KEY`

The SQL alternative is `supabase/scripts/set-vault-secret.sql`. See `supabase/README.md` for the logging caveat. Rotation is the same script run again, followed by an update in Secrets Manager and a backend restart.

## 6. Register the pre-request function

```bash
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/004_pre_request.sql
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/audit.sql
```

`audit.sql` raises if the hook, grants, or Vault name are wrong. It prints `catalog audit passed` and does not print the secret.

If `004` fails with `permission denied` while creating `demo_vault_reader` or altering `authenticator`, run it in the SQL editor as the `postgres` role. Then run `RESET ROLE;` before the next statement if the session was left as `demo_vault_reader`.

## 7. Test direct Supabase access

```bash
curl -sS -D - \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
  "$SUPABASE_URL/rest/v1/customer_documents?select=title,visibility"
```

Expect HTTP 403 and no document titles.

```bash
curl -sS -D - \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
  -H "x-internal-api-key: $SUPABASE_INTERNAL_API_KEY" \
  "$SUPABASE_URL/rest/v1/customer_documents?select=title,visibility"
```

Expect HTTP 200 and the three public titles. The private titles must be absent. This call is made from your own machine. That is the point of the second request: the endpoint is publicly reachable, and the secret is a bearer credential.

## 8. Provision AWS

Required local tools: Terraform 1.6 or newer, AWS CLI credentials with permission to create VPC, EC2, IAM, S3, and Secrets Manager resources.

```bash
cd aws/terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

Change `availability_zone` if `us-east-1a` is not enabled in the account. Do not put secret values in `terraform.tfvars`.

Useful outputs:

```bash
terraform output instance_id
terraform output instance_private_ip
terraform output instance_public_ip
terraform output artifact_bucket
terraform output secret_arns
terraform output ssm_session_command
```

`instance_public_ip` is empty. `secret_arns` lists ARNs only.

Operator permissions used by the next script, in addition to the Terraform permissions: `secretsmanager:PutSecretValue`, `s3:PutObject`, `ssm:SendCommand`, `ssm:GetCommandInvocation`, and `ssm:StartSession`.

## 9. Deploy the Fastify backend

From the repository root, with `.env` filled in:

```bash
aws/scripts/deploy.sh
```

The script writes the five secret values to Secrets Manager through a mode `0600` temporary file, uploads the backend bundle to the private bucket, and uses SSM to build the containers. Secret values are not command-line arguments of `aws secretsmanager put-secret-value`.

The instance role can read those secrets and the bucket. Its metadata hop limit is 1, so the containers cannot read instance-role credentials. Fastify listens on `0.0.0.0` inside the container network namespace, and Compose publishes `127.0.0.1:8080:8080` on the host.

## 10. Create the Cloudflare Tunnel

Follow `cloudflare/tunnel/README.md`. Create the remotely managed tunnel, store the token, and do not add a public hostname. Re-run `aws/scripts/deploy.sh` after `CLOUDFLARE_TUNNEL_TOKEN` is in `.env` if the first deploy happened before the token existed. The connector must show as healthy before the VPC service can forward traffic.

## 11. Configure Workers VPC

```bash
cd cloudflare/worker
npm install
npx wrangler vpc service create secure-api-backend \
  --type http \
  --tunnel-id "$CLOUDFLARE_TUNNEL_ID" \
  --ipv4 127.0.0.1 \
  --http-port 8080
```

Record the service UUID.

## 12. Deploy the Worker

```bash
node scripts/configure.mjs \
  --service-id "$VPC_SERVICE_ID" \
  --team-domain "$CF_ACCESS_TEAM_DOMAIN" \
  --aud "$CF_ACCESS_AUD"
npx wrangler secret put BACKEND_AUTH_TOKEN
npx wrangler deploy
```

You can fill the audience after step 13 and deploy again. `wrangler.jsonc` keeps `workers_dev` enabled and `preview_urls` disabled. The binding name is `PRIVATE_BACKEND`. `"remote": true` tells `wrangler dev` to use the real VPC service rather than a local simulation. Unit tests do not use that binding.

The Worker URL looks like `https://supabase-secure-api-demo.<account-subdomain>.workers.dev`.

## 13. Set up Cloudflare Access

Turn on Zero Trust for the account if it is not already on.

1. Workers & Pages > `supabase-secure-api-demo` > **Access**.
2. Choose **Protect this Worker behind Access**.
3. Choose **All traffic**. This covers the `workers.dev` hostname, routes, custom domains, and preview deployments.
4. Add a human policy, such as an email allow policy.
5. Zero Trust > Access > Service credentials > Service tokens > Create. Save the Client ID and Client Secret. The secret is shown once. New secrets use a `cfast_` prefix; older ones are 64 hex characters. Both work with the same headers.
6. Edit the Access application and add a separate policy: action **Service Auth**, include **Service Token**, and select the token you created. In the API this decision is `non_identity`.
7. Copy the application audience tag into `CF_ACCESS_AUD` and the team domain, such as `https://<team-name>.cloudflareaccess.com`, into `CF_ACCESS_TEAM_DOMAIN`.
8. Re-run `scripts/configure.mjs` and `npx wrangler deploy` if those values changed.
9. Put the same backend token used in AWS into the Worker with `npx wrangler secret put BACKEND_AUTH_TOKEN`.

Organizations created on or after 2026-10-05 use strict service-token authentication. A bad or missing service token returns 401 or 403 instead of a browser redirect. A browser without a session can still receive a 302 to the Access login page.

Example machine call:

```bash
curl -sS \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  "$WORKER_URL/documents"
```

## 14. Test authorized and unauthorized requests

```bash
tests/security-tests.sh
```

Exit 0 means every check ran and passed. Exit 2 means at least one check was skipped. Exit 1 means a check failed. The script never prints the secrets. Test I is expected to pass with HTTP 200; read the NOTE under that line before describing the result.

## 15. Clean up

```bash
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/cleanup.sql
```

Delete, in the Cloudflare dashboard or with Wrangler and the API:

- the Worker (`npx wrangler delete`)
- the VPC service
- the tunnel
- the Access application and service token

Then:

```bash
aws/scripts/teardown.sh --yes
```

That destroys the VPC, NAT Gateway, instance, private bucket, and secret shells. It does not delete the Supabase project.

## Environment variables

| Variable | Where it is used |
| --- | --- |
| `SUPABASE_URL` | Backend and integration tests |
| `SUPABASE_PUBLISHABLE_KEY` | Backend `apikey` header |
| `SUPABASE_INTERNAL_API_KEY` | Vault and `x-internal-api-key` |
| `SUPABASE_DB_URL` | `psql` only |
| `BACKEND_AUTH_TOKEN` | Worker secret and Fastify |
| `CF_ACCESS_TEAM_DOMAIN` | Worker JWT issuer |
| `CF_ACCESS_AUD` | Worker JWT audience |
| `CF_ACCESS_CLIENT_ID` | Integration tests and machine clients |
| `CF_ACCESS_CLIENT_SECRET` | Integration tests and machine clients |
| `WORKER_URL` | Integration tests |
| `WORKER_PREVIEW_URL`, `EXTRA_WORKER_URLS` | Optional test J targets |
| `CLOUDFLARE_TUNNEL_TOKEN` | `cloudflared` on EC2 |
| `CLOUDFLARE_TUNNEL_ID` | `wrangler vpc service create` |
| `VPC_SERVICE_ID` | `wrangler.jsonc` binding |
| `AWS_REGION` | Optional override; Terraform output is the default |

## What local tests do not prove

`tests/run-unit-tests.sh` proves the route allow-lists, header construction, secret rejection, and SQL text. It does not open a tunnel, call PostgREST, or evaluate RLS on a hosted database. Those require the credentials above and `tests/security-tests.sh`.

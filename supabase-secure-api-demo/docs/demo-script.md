# Demo script

Audience: a Supabase solutions architect walking a customer through the managed Data API. Keep a terminal and three dashboards open: Supabase SQL editor, Cloudflare Workers VPC, and the AWS EC2 instance page. Do not paste secrets into the notes.

Say this once at the start: the Data API hostname is still public. The demo rejects unauthorized operations. It does not make the API private to a VPC.

## 1. The table is an ordinary Data API relation

In the SQL editor:

```sql
select id, title, visibility
from public.customer_documents
order by title;
```

Point out five rows and that the SQL editor is a direct database session, so it can see private rows. The Data API will not.

## 2. A publishable key is not enough

```bash
curl -sS -i \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
  "$SUPABASE_URL/rest/v1/customer_documents?select=title,visibility"
```

Expect `HTTP/1.1 403` and a JSON body whose message is `Forbidden`. Open `supabase/migrations/004_pre_request.sql` and show `public.check_internal_api_key()` raising that status before PostgREST runs the query. Show the Vault page with the secret name `demo_data_api_gateway_secret`. Do not reveal the value.

## 3. Access sits in front of the Worker

```bash
curl -sS -o /dev/null -w '%{http_code}\n' "$WORKER_URL/documents"
```

Expect 401, 403, or 302. In the Worker **Access** tab, show that protection is set to **All traffic**, including `workers.dev`. `wrangler.jsonc` also has `"preview_urls": false`.

## 4. The Worker uses a VPC service binding

Open `cloudflare/worker/wrangler.jsonc` and the Worker source fetch of `env.PRIVATE_BACKEND`. In Workers VPC, open the service and show:

- the tunnel ID
- host `127.0.0.1`
- HTTP port `8080`
- no public hostname on the tunnel

Say that the URL inside the Worker does not choose a different machine. The binding does.

## 5. The private instance calls Supabase

On the EC2 page, show that the instance has a private IP and a blank public IP. The security group has no inbound rules.

```bash
aws ssm start-session --target "$(terraform -chdir=aws/terraform output -raw instance_id)"
```

From the session, show `sudo docker compose -f /opt/secure-api/app/compose.yaml ps`. Do not print the env files. Explain that Fastify adds `apikey` and `x-internal-api-key`, then calls `/rest/v1/customer_documents`.

## 6. The pre-request function accepts the backend

```bash
curl -sS \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  "$WORKER_URL/documents"
```

Expect 200 and the three public titles: Public Architecture Guide, Public API Documentation, and Product Overview.

## 7. RLS still hides private rows

In the same JSON, point out that Internal Financial Report and Confidential Roadmap are missing. Fetch one private id:

```bash
curl -sS -i \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  "$WORKER_URL/documents/33333333-3333-4333-8333-333333333333"
```

Expect 404. Explain that the backend does not add `visibility=eq.public`. The `anon` policy does.

Show `supabase/migrations/003_rls.sql`.

## 8. Grants still reject writes

```bash
curl -sS -i \
  -X POST \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
  -H "x-internal-api-key: $SUPABASE_INTERNAL_API_KEY" \
  -H 'content-type: application/json' \
  --data '{"title":"should-not-persist","visibility":"public"}' \
  "$SUPABASE_URL/rest/v1/customer_documents"
```

Expect 401 or 403. A valid gateway secret did not grant `INSERT`. `PATCH` and `DELETE` need `?id=eq.<uuid>` in this check. Without a filter, PostgREST returns 400 before it evaluates the grant.

## 9. Unauthorized calls keep failing

Repeat the publishable-key curl from step 2. Then call the Worker with a fake service token and show that it is still denied. If you have time, run `tests/security-tests.sh` and walk the PASS lines.

## 10. Close on the boundary

Repeat the successful direct Data API curl from deployment step 7, the one that includes `x-internal-api-key`, from the laptop rather than from EC2.

Say this explicitly:

> This request did not come from the VPC, and it still succeeded. The extra header is a bearer secret checked by Postgres. It is evidence that the caller knows the secret, not evidence that the caller is the private backend. The Worker, Access, and the tunnel protect our application path. RLS and grants protect the rows after the secret is accepted. The Data API itself remains reachable at its public hostname.

Mention the public-schema limitation in one sentence: the pre-request function is `SECURITY DEFINER` in `public` because this design cannot move it, the owner is a Vault-only role, and direct RPC must not be treated as a way to read Vault. `docs/security-model.md` has the audit.

# Curl cases

Run these from the repository root after the stack is deployed. Load `.env` first. The commands below use those variables and do not print secret values.

```bash
set -a
source .env
set +a
```

Three keys show up below.

| Door | What you send | Variable |
| --- | --- | --- |
| Cloudflare Access | `CF-Access-Client-Id` and `CF-Access-Client-Secret` | `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` |
| Private AWS machine | `x-backend-auth` | `BACKEND_AUTH_TOKEN` |
| Supabase | `x-internal-api-key` | `SUPABASE_INTERNAL_API_KEY` |

Your laptop sends only the Access headers. The Worker adds `x-backend-auth`. Fastify adds `x-internal-api-key` and the publishable key. The publishable key selects the `anon` role. It is not the door key.

Public titles, when a call succeeds: Public Architecture Guide, Public API Documentation, Product Overview. Private titles that must stay absent: Internal Financial Report, Confidential Roadmap.

## Door 1: Cloudflare Access

No Access token. Expect `302` to the login page, or `401` / `403`. The body must not contain the public titles.

```bash
curl -sS -D - -o /dev/null "$WORKER_URL/documents"
```

Wrong service token. Expect `401` or `403`. The body must not contain the public titles.

```bash
curl -sS -D - \
  -H "CF-Access-Client-Id: invalid-client-id" \
  -H "CF-Access-Client-Secret: invalid-client-secret" \
  "$WORKER_URL/documents"
```

Right service token. This also walks through doors 2 and 3. Expect `200` and the three public titles only.

```bash
curl -sS \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  "$WORKER_URL/documents"
```

Same token, one private document. Expect `404`, or `200` with an empty list. The body must not contain Internal Financial Report.

```bash
curl -sS \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  "$WORKER_URL/documents/33333333-3333-4333-8333-333333333333"
```

Same token, `POST`. The Worker does not forward writes. Expect `405`, or an Access denial (`401` / `403`).

```bash
curl -sS -D - \
  -X POST \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  "$WORKER_URL/documents"
```

Health through the same front door. Expect `200` and `"status":"ok"`.

```bash
curl -sS \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  "$WORKER_URL/health"
```

## Door 2: the private AWS machine

There is no curl for this door from your laptop. Fastify listens on `127.0.0.1:8080` on the instance, and the instance has no public IP. A call to the private address times out, which is the expected result:

```bash
curl -sS --max-time 5 "http://${INSTANCE_PRIVATE_IP}:8080/documents"
```

The successful Worker `GET /documents` above is the check that `x-backend-auth` was accepted. That header is `BACKEND_AUTH_TOKEN`. The Worker adds it. Your laptop does not send it.

## Door 3: Supabase, called directly

These skip Cloudflare and AWS. They talk to the public Data API.

Publishable key only. Expect `403` and no titles.

```bash
curl -sS -D - \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
  "$SUPABASE_URL/rest/v1/customer_documents?select=title,visibility"
```

Wrong internal key. Expect `403` and no titles.

```bash
curl -sS -D - \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
  -H "x-internal-api-key: incorrect-internal-api-key-value-not-real" \
  "$SUPABASE_URL/rest/v1/customer_documents?select=title,visibility"
```

Right internal key, from this laptop. Expect `200`, the three public titles, and neither private title. This success is expected. The secret is a bearer credential, not proof the caller is inside AWS.

```bash
curl -sS \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
  -H "x-internal-api-key: $SUPABASE_INTERNAL_API_KEY" \
  "$SUPABASE_URL/rest/v1/customer_documents?select=title,visibility"
```

Same key, one private id. Expect `200` with an empty list. The body must not contain Internal Financial Report.

```bash
curl -sS \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
  -H "x-internal-api-key: $SUPABASE_INTERNAL_API_KEY" \
  "$SUPABASE_URL/rest/v1/customer_documents?id=eq.33333333-3333-4333-8333-333333333333&select=title,visibility"
```

Writes with the valid key. `anon` has `SELECT` only. Expect `401` or `403`. The body must not contain `should-not-persist`. `PATCH` and `DELETE` include an id filter so PostgREST reaches the grant check. Without that filter it returns `400` first.

```bash
curl -sS -D - \
  -X POST \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
  -H "x-internal-api-key: $SUPABASE_INTERNAL_API_KEY" \
  -H "content-type: application/json" \
  --data '{"title":"should-not-persist","visibility":"public"}' \
  "$SUPABASE_URL/rest/v1/customer_documents"
```

```bash
curl -sS -D - \
  -X PATCH \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
  -H "x-internal-api-key: $SUPABASE_INTERNAL_API_KEY" \
  -H "content-type: application/json" \
  --data '{"title":"should-not-persist"}' \
  "$SUPABASE_URL/rest/v1/customer_documents?id=eq.11111111-1111-4111-8111-111111111111"
```

```bash
curl -sS -D - \
  -X DELETE \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
  -H "x-internal-api-key: $SUPABASE_INTERNAL_API_KEY" \
  "$SUPABASE_URL/rest/v1/customer_documents?id=eq.11111111-1111-4111-8111-111111111111"
```

Call the pre-request function by name. Expect `401`, `403`, or `404`, or an empty `200` / `204`. The body must not contain the secret. A follow-up read with no internal key must still be `403`.

```bash
curl -sS -D - \
  -X POST \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
  -H "x-internal-api-key: $SUPABASE_INTERNAL_API_KEY" \
  -H "content-type: application/json" \
  --data '{"secret":"ignore-me"}' \
  "$SUPABASE_URL/rest/v1/rpc/check_internal_api_key"
```

`tests/security-tests.sh` runs this set and prints PASS or FAIL without printing secrets.

import { afterEach, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/app.js';
import type { BackendConfig, FetchLike } from '../src/services/supabase.js';

const publishable = `sb_publishable_${'a'.repeat(40)}`;
const internal = `internal-${'i'.repeat(40)}`;
const backend = `backend-${'b'.repeat(40)}`;

const config: BackendConfig = {
  supabaseUrl: 'https://example.supabase.co',
  publishableKey: publishable,
  internalApiKey: internal,
  backendAuthToken: backend,
  requestTimeoutMs: 8000,
  host: '127.0.0.1',
  port: 8080,
};

const documents = [
  {
    id: '11111111-1111-4111-8111-111111111111',
    title: 'Public Architecture Guide',
    visibility: 'public',
    created_at: '2026-01-01T00:00:00Z',
  },
];

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

describe('backend routes', () => {
  let app: FastifyInstance | undefined;
  const calls: Array<{ url: string; init?: RequestInit }> = [];

  afterEach(async () => {
    calls.length = 0;
    await app?.close();
  });

  function start(fetchImpl: FetchLike): FastifyInstance {
    app = buildApp(config, { fetchImpl, logger: false });
    return app;
  }

  it('rejects a missing or incorrect worker credential before calling Supabase', async () => {
    const server = start(async () => {
      throw new Error('supabase should not be called');
    });

    const missing = await server.inject({ method: 'GET', url: '/documents' });
    expect(missing.statusCode).toBe(401);

    const wrong = await server.inject({
      method: 'GET',
      url: '/documents',
      headers: { 'x-backend-auth': 'n'.repeat(40) },
    });
    expect(wrong.statusCode).toBe(401);
    expect(calls).toHaveLength(0);
  });

  it('calls only the demo endpoint with the publishable key and internal secret', async () => {
    const server = start(async (url, init) => {
      calls.push({ url, init });
      return jsonResponse(documents);
    });

    const response = await server.inject({
      method: 'GET',
      url: '/documents?select=*&id=eq.33333333-3333-4333-8333-333333333333',
      headers: {
        'x-backend-auth': backend,
        'x-internal-api-key': 'client-supplied',
        apikey: 'client-supplied',
        authorization: 'Bearer client-supplied',
      },
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual(documents);
    expect(calls).toHaveLength(1);
    const called = new URL(calls[0].url);
    expect(called.pathname).toBe('/rest/v1/customer_documents');
    expect(called.searchParams.get('select')).toBe('id,title,visibility,created_at');
    expect(called.searchParams.has('visibility')).toBe(false);
    const headers = new Headers(calls[0].init?.headers);
    expect(headers.get('apikey')).toBe(publishable);
    expect(headers.get('authorization')).toBe(`Bearer ${publishable}`);
    expect(headers.get('x-internal-api-key')).toBe(internal);
    expect(headers.get('accept-profile')).toBeNull();
    expect(headers.get('x-backend-auth')).toBeNull();
  });

  it('returns one document and a not-found response for an unknown id', async () => {
    const server = start(async (url) => {
      calls.push({ url });
      const id = new URL(url).searchParams.get('id');
      return jsonResponse(id?.endsWith('11111111-1111-4111-8111-111111111111') ? documents : []);
    });

    const found = await server.inject({
      method: 'GET',
      url: '/documents/11111111-1111-4111-8111-111111111111',
      headers: { 'x-backend-auth': backend },
    });
    expect(found.statusCode).toBe(200);
    expect(found.json()).toMatchObject({ title: 'Public Architecture Guide' });

    const missing = await server.inject({
      method: 'GET',
      url: '/documents/99999999-9999-4999-8999-999999999999',
      headers: { 'x-backend-auth': backend },
    });
    expect(missing.statusCode).toBe(404);

    const invalid = await server.inject({
      method: 'GET',
      url: '/documents/not-a-uuid',
      headers: { 'x-backend-auth': backend },
    });
    expect(invalid.statusCode).toBe(400);
  });

  it('does not proxy writes or arbitrary paths', async () => {
    const server = start(async () => jsonResponse([]));
    const headers = { 'x-backend-auth': backend };

    expect((await server.inject({ method: 'POST', url: '/documents', headers })).statusCode).toBe(405);
    expect((await server.inject({ method: 'PATCH', url: '/documents/11111111-1111-4111-8111-111111111111', headers })).statusCode).toBe(405);
    expect((await server.inject({ method: 'DELETE', url: '/documents/11111111-1111-4111-8111-111111111111', headers })).statusCode).toBe(405);
    expect((await server.inject({ method: 'GET', url: '/rest/v1/customer_documents', headers })).statusCode).toBe(404);
  });

  it('redacts upstream secret material and maps timeouts', async () => {
    const leaking = start(async () => jsonResponse({ message: `denied ${internal}` }, 403));
    const forbidden = await leaking.inject({
      method: 'GET',
      url: '/documents',
      headers: { 'x-backend-auth': backend },
    });
    expect(forbidden.statusCode).toBe(403);
    expect(forbidden.body).not.toContain(internal);
    expect(forbidden.body).toContain('[redacted]');
    await leaking.close();
    app = undefined;

    const hanging = start(async () => {
      throw Object.assign(new Error('timed out'), { name: 'TimeoutError' });
    });
    const timeout = await hanging.inject({
      method: 'GET',
      url: '/documents',
      headers: { 'x-backend-auth': backend },
    });
    expect(timeout.statusCode).toBe(504);
  });
});

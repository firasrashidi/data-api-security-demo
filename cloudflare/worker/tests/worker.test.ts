import { describe, expect, it, vi } from 'vitest';
import { handleRequest, type Env } from '../src/index';

const backendToken = `backend-${'b'.repeat(40)}`;

function env(): Env {
  return {
    PRIVATE_BACKEND: { fetch: vi.fn() } as unknown as Fetcher,
    BACKEND_AUTH_TOKEN: backendToken,
    CF_ACCESS_TEAM_DOMAIN: 'https://example.cloudflareaccess.com',
    CF_ACCESS_AUD: 'audience-tag-demo',
  };
}

function authorized(path: string, init: RequestInit = {}): Request {
  const headers = new Headers(init.headers);
  headers.set('cf-access-jwt-assertion', 'header.payload.signature');
  headers.set('x-internal-api-key', 'client-supplied-secret');
  headers.set('apikey', 'client-supplied-key');
  headers.set('authorization', 'Bearer client-supplied');
  headers.set('cf-access-client-secret', 'client-secret');
  return new Request(`https://worker.example${path}`, { ...init, headers });
}

describe('worker gateway', () => {
  it('fails closed when Access is not configured or the JWT is missing', async () => {
    const unconfigured = env();
    unconfigured.CF_ACCESS_AUD = '__CF_ACCESS_AUD__';
    const blocked = await handleRequest(new Request('https://worker.example/documents'), unconfigured);
    expect(blocked.status).toBe(503);

    const missing = await handleRequest(new Request('https://worker.example/documents'), env(), {}, {
      verifyJwt: async () => undefined,
    });
    expect(missing.status).toBe(401);
  });

  it('forwards only the backend credential to the fixed private origin', async () => {
    const runtime = env();
    const calls: Array<{ url: string; method: string; headers: Headers }> = [];
    runtime.PRIVATE_BACKEND.fetch = (async (input: Request | string) => {
      const outbound = input instanceof Request ? input : new Request(input);
      calls.push({ url: outbound.url, method: outbound.method, headers: outbound.headers });
      return new Response(JSON.stringify([{ title: 'Public Architecture Guide' }]), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }) as unknown as Fetcher['fetch'];

    const response = await handleRequest(
      authorized('/documents?select=*'),
      runtime,
      { access: { aud: 'audience-tag-demo' } },
      { verifyJwt: async () => undefined },
    );

    expect(response.status).toBe(200);
    expect(calls).toHaveLength(1);
    const outbound = calls[0];
    expect(outbound.url).toBe('http://127.0.0.1:8080/documents');
    expect(outbound.method).toBe('GET');
    expect(outbound.headers.get('x-backend-auth')).toBe(backendToken);
    expect(outbound.headers.get('x-internal-api-key')).toBeNull();
    expect(outbound.headers.get('apikey')).toBeNull();
    expect(outbound.headers.get('authorization')).toBeNull();
    expect(outbound.headers.get('cf-access-client-secret')).toBeNull();
    expect(outbound.headers.get('cf-access-jwt-assertion')).toBeNull();
  });

  it('does not proxy arbitrary URLs and strips the backend token from responses', async () => {
    const runtime = env();
    runtime.PRIVATE_BACKEND.fetch = vi.fn(async () => new Response(
      JSON.stringify({ message: `leaked ${backendToken}` }),
      { status: 200 },
    )) as unknown as Fetcher['fetch'];

    const denied = await handleRequest(authorized('/rest/v1/customer_documents', { method: 'POST' }), runtime, {}, {
      verifyJwt: async () => undefined,
    });
    expect(denied.status).toBe(404);
    expect(runtime.PRIVATE_BACKEND.fetch).not.toHaveBeenCalled();

    const leaked = await handleRequest(authorized('/health'), runtime, {}, {
      verifyJwt: async () => undefined,
    });
    expect(await leaked.text()).not.toContain(backendToken);
    expect(leaked.headers.get('cache-control')).toBe('no-store');
  });

  it('maps backend authentication failure and connection errors', async () => {
    const rejected = env();
    rejected.PRIVATE_BACKEND.fetch = vi.fn(async () => new Response('{}', { status: 401 })) as unknown as Fetcher['fetch'];
    const auth = await handleRequest(authorized('/documents'), rejected, {}, { verifyJwt: async () => undefined });
    expect(auth.status).toBe(502);

    const down = env();
    down.PRIVATE_BACKEND.fetch = vi.fn(async () => {
      throw Object.assign(new Error('down'), { name: 'TimeoutError' });
    }) as unknown as Fetcher['fetch'];
    const timeout = await handleRequest(authorized('/documents'), down, {}, { verifyJwt: async () => undefined });
    expect(timeout.status).toBe(504);
  });
});

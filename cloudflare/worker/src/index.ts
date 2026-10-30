import { accessConfigured, verifyAccessJwt, type AccessEnv } from './access';
import { json, redact } from './http';
import { backendPath, matchRoute } from './routes';

// Workers VPC uses the service binding to choose the tunnel target.
// This origin only sets the Host header. The port in the URL is ignored;
// the VPC Service http port is 8080.
const BACKEND_ORIGIN = 'http://127.0.0.1:8080';
const REQUEST_TIMEOUT_MS = 8_000;
const MAX_UPSTREAM_BYTES = 1_000_000;

export interface Env extends AccessEnv {
  PRIVATE_BACKEND: Fetcher;
  BACKEND_AUTH_TOKEN: string;
}

export type RequestContext = {
  access?: {
    aud?: string;
  };
};

export type HandlerDependencies = {
  verifyJwt: typeof verifyAccessJwt;
};

const defaultDependencies: HandlerDependencies = {
  verifyJwt: verifyAccessJwt,
};

async function authorize(
  request: Request,
  env: Env,
  ctx: RequestContext,
  deps: HandlerDependencies,
): Promise<Response | null> {
  if (!accessConfigured(env) || env.BACKEND_AUTH_TOKEN.trim().length < 32) {
    return json({ message: 'Access is not configured' }, 503);
  }

  if (ctx.access?.aud && ctx.access.aud !== env.CF_ACCESS_AUD) {
    return json({ message: 'Unauthorized' }, 401);
  }

  const token = request.headers.get('cf-access-jwt-assertion');
  if (!token) {
    return json({ message: 'Unauthorized' }, 401);
  }

  try {
    await deps.verifyJwt(token, env);
  } catch {
    return json({ message: 'Unauthorized' }, 401);
  }

  return null;
}

async function forward(env: Env, path: string): Promise<Response> {
  const outbound = new Request(new URL(path, BACKEND_ORIGIN), {
    method: 'GET',
    headers: {
      accept: 'application/json',
      'x-backend-auth': env.BACKEND_AUTH_TOKEN.trim(),
    },
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });

  let response: Response;
  try {
    response = await env.PRIVATE_BACKEND.fetch(outbound);
  } catch (error) {
    if (error instanceof Error && (error.name === 'TimeoutError' || error.name === 'AbortError')) {
      return json({ message: 'Private backend timed out' }, 504);
    }
    return json({ message: 'Private backend is unavailable' }, 502);
  }

  if (response.status === 401) {
    return json({ message: 'The private backend rejected the worker credential' }, 502);
  }

  const declaredLength = Number(response.headers.get('content-length') ?? '0');
  if (Number.isFinite(declaredLength) && declaredLength > MAX_UPSTREAM_BYTES) {
    return json({ message: 'Upstream response was too large' }, 502);
  }

  const text = await response.text();
  if (text.length > MAX_UPSTREAM_BYTES) {
    return json({ message: 'Upstream response was too large' }, 502);
  }

  return new Response(redact(text, env.BACKEND_AUTH_TOKEN), {
    status: response.status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
    },
  });
}

export async function handleRequest(
  request: Request,
  env: Env,
  ctx: RequestContext = {},
  deps: HandlerDependencies = defaultDependencies,
): Promise<Response> {
  const denied = await authorize(request, env, ctx, deps);
  if (denied) {
    return denied;
  }

  const url = new URL(request.url);
  const route = matchRoute(request.method, url.pathname);
  if (route.kind === 'not_found') {
    return json({ message: 'Not found' }, 404);
  }
  if (route.kind === 'method_not_allowed') {
    return json({ message: 'Method not allowed' }, 405);
  }

  return forward(env, backendPath(route));
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    return handleRequest(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;

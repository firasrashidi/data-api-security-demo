import { redactSecrets } from './redact.js';

export type BackendConfig = {
  supabaseUrl: string;
  publishableKey: string;
  internalApiKey: string;
  backendAuthToken: string;
  requestTimeoutMs: number;
  host: string;
  port: number;
};

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export type DocumentRow = {
  id: string;
  title: string;
  visibility: string;
  created_at: string | null;
};

export type UpstreamResult = {
  status: number;
  body: unknown;
};

const DOCUMENT_COLUMNS = 'id,title,visibility,created_at';
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isUuid(value: string): boolean {
  return UUID_PATTERN.test(value);
}

export function assertPublishableKey(key: string): void {
  if (key.startsWith('sb_secret_')) {
    throw new Error('Refusing to start with a Supabase secret key');
  }

  const parts = key.split('.');
  if (parts.length !== 3) {
    return;
  }

  try {
    const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8')) as {
      role?: string;
    };
    if (payload.role === 'service_role') {
      throw new Error('Refusing to start with a service_role key');
    }
  } catch (error) {
    if (error instanceof Error && error.message.startsWith('Refusing')) {
      throw error;
    }
  }
}

export function documentsCollectionUrl(supabaseUrl: string): URL {
  const url = new URL('/rest/v1/customer_documents', supabaseUrl);
  url.searchParams.set('select', DOCUMENT_COLUMNS);
  url.searchParams.set('order', 'created_at.asc');
  return url;
}

export function documentByIdUrl(supabaseUrl: string, id: string): URL {
  if (!isUuid(id)) {
    throw new Error('Invalid document id');
  }
  const url = new URL('/rest/v1/customer_documents', supabaseUrl);
  url.searchParams.set('select', DOCUMENT_COLUMNS);
  url.searchParams.set('id', `eq.${id}`);
  return url;
}

export function healthProbeUrl(supabaseUrl: string): URL {
  const url = new URL('/rest/v1/customer_documents', supabaseUrl);
  url.searchParams.set('select', 'id');
  url.searchParams.set('limit', '1');
  return url;
}

function authHeaders(config: BackendConfig): Headers {
  const headers = new Headers();
  headers.set('accept', 'application/json');
  headers.set('apikey', config.publishableKey);
  headers.set('authorization', `Bearer ${config.publishableKey}`);
  headers.set('x-internal-api-key', config.internalApiKey);
  return headers;
}

function presentRow(value: unknown): DocumentRow | null {
  if (value === null || typeof value !== 'object') {
    return null;
  }
  const row = value as Record<string, unknown>;
  if (typeof row.id !== 'string' || typeof row.title !== 'string' || typeof row.visibility !== 'string') {
    return null;
  }
  return {
    id: row.id,
    title: row.title,
    visibility: row.visibility,
    created_at: typeof row.created_at === 'string' ? row.created_at : null,
  };
}

async function readUpstream(
  response: Response,
  config: BackendConfig,
): Promise<UpstreamResult> {
  const raw = await response.text();
  const text = redactSecrets(raw, [config.internalApiKey, config.publishableKey, config.backendAuthToken]);

  if (response.status < 200 || response.status >= 300) {
    let body: unknown = { message: 'Upstream request failed' };
    if (text) {
      try {
        const parsed = JSON.parse(text) as unknown;
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
          const record = parsed as Record<string, unknown>;
          body = {
            message: typeof record.message === 'string' ? record.message : 'Upstream request failed',
            code: typeof record.code === 'string' ? record.code : undefined,
          };
        }
      } catch {
        body = { message: 'Upstream request failed' };
      }
    }
    return { status: response.status, body };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(text) as unknown;
  } catch {
    return { status: 502, body: { message: 'Upstream returned an unreadable response' } };
  }

  if (!Array.isArray(parsed)) {
    return { status: 502, body: { message: 'Upstream returned an unexpected response' } };
  }

  const rows = parsed.map(presentRow);
  if (rows.some((row) => row === null)) {
    return { status: 502, body: { message: 'Upstream returned an unexpected document' } };
  }

  return { status: 200, body: rows };
}

export async function querySupabase(
  config: BackendConfig,
  url: URL,
  fetchImpl: FetchLike,
): Promise<UpstreamResult> {
  try {
    const response = await fetchImpl(url.toString(), {
      method: 'GET',
      headers: authHeaders(config),
      redirect: 'error',
      signal: AbortSignal.timeout(config.requestTimeoutMs),
    });
    return await readUpstream(response, config);
  } catch (error) {
    if (error instanceof Error && (error.name === 'TimeoutError' || error.name === 'AbortError')) {
      return { status: 504, body: { message: 'Upstream request timed out' } };
    }
    return { status: 502, body: { message: 'Upstream request failed' } };
  }
}

export async function listDocuments(
  config: BackendConfig,
  fetchImpl: FetchLike,
): Promise<UpstreamResult> {
  return querySupabase(config, documentsCollectionUrl(config.supabaseUrl), fetchImpl);
}

export async function getDocument(
  config: BackendConfig,
  id: string,
  fetchImpl: FetchLike,
): Promise<UpstreamResult> {
  if (!isUuid(id)) {
    return { status: 400, body: { message: 'Invalid document id' } };
  }

  const result = await querySupabase(config, documentByIdUrl(config.supabaseUrl, id), fetchImpl);
  if (result.status !== 200 || !Array.isArray(result.body)) {
    return result;
  }
  if (result.body.length === 0) {
    return { status: 404, body: { message: 'Not found' } };
  }
  if (result.body.length !== 1) {
    return { status: 502, body: { message: 'Upstream returned an unexpected response' } };
  }
  return { status: 200, body: result.body[0] };
}

export async function probeSupabase(
  config: BackendConfig,
  fetchImpl: FetchLike,
): Promise<UpstreamResult> {
  const result = await querySupabase(config, healthProbeUrl(config.supabaseUrl), fetchImpl);
  if (result.status === 200) {
    return { status: 200, body: { status: 'ok', service: 'backend' } };
  }
  if (result.status === 401 || result.status === 403) {
    return { status: 503, body: { message: 'Upstream rejected the request' } };
  }
  return { status: 503, body: { message: 'Upstream request failed' } };
}

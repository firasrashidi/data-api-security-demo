import { describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config.js';
import { secretsEqual } from '../src/services/auth.js';
import {
  documentByIdUrl,
  documentsCollectionUrl,
  healthProbeUrl,
} from '../src/services/supabase.js';

const publishable = `sb_publishable_${'a'.repeat(40)}`;
const internal = `internal-${'i'.repeat(40)}`;
const backend = `backend-${'b'.repeat(40)}`;

function env(overrides: Record<string, string> = {}): NodeJS.ProcessEnv {
  return {
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_PUBLISHABLE_KEY: publishable,
    SUPABASE_INTERNAL_API_KEY: internal,
    BACKEND_AUTH_TOKEN: backend,
    ...overrides,
  };
}

describe('config', () => {
  it('accepts a publishable key and distinct secrets', () => {
    const config = loadConfig(env());
    expect(config.supabaseUrl).toBe('https://example.supabase.co');
    expect(config.port).toBe(8080);
  });

  it('rejects a service role JWT and duplicate secrets', () => {
    const payload = Buffer.from(JSON.stringify({ role: 'service_role' })).toString('base64url');
    expect(() => loadConfig(env({ SUPABASE_PUBLISHABLE_KEY: `aaa.${payload}.bbb` }))).toThrow(/service_role/);
    expect(() => loadConfig(env({ SUPABASE_INTERNAL_API_KEY: backend }))).toThrow(/distinct/);
    expect(() => loadConfig(env({ SUPABASE_URL: 'http://example.supabase.co' }))).toThrow(/https/);
  });
});

describe('supabase query construction', () => {
  it('targets only the demo collection and leaves visibility to RLS', () => {
    const list = documentsCollectionUrl('https://example.supabase.co');
    expect(list.pathname).toBe('/rest/v1/customer_documents');
    expect(list.searchParams.get('select')).toBe('id,title,visibility,created_at');
    expect(list.searchParams.get('visibility')).toBeNull();
    expect(list.searchParams.get('apikey')).toBeNull();

    const one = documentByIdUrl('https://example.supabase.co', '11111111-1111-4111-8111-111111111111');
    expect(one.searchParams.get('id')).toBe('eq.11111111-1111-4111-8111-111111111111');
    expect(healthProbeUrl('https://example.supabase.co').searchParams.get('limit')).toBe('1');
    expect(() => documentByIdUrl('https://example.supabase.co', 'not-a-uuid')).toThrow(/Invalid/);
  });

  it('compares secrets without returning early on equal hashes', () => {
    expect(secretsEqual(internal, internal)).toBe(true);
    expect(secretsEqual(internal, backend)).toBe(false);
    expect(secretsEqual('', backend)).toBe(false);
  });
});

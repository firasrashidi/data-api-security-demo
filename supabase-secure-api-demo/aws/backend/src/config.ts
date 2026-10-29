import type { BackendConfig } from './services/supabase.js';
import { assertPublishableKey } from './services/supabase.js';

const MINIMUM_SECRET_LENGTH = 32;

function required(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name];
  if (!value || value.trim() === '') {
    throw new Error(`Missing required environment variable ${name}`);
  }
  return value.trim();
}

function parsePort(value: string | undefined): number {
  if (!value) {
    return 8080;
  }
  const port = Number(value);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('PORT must be an integer from 1 to 65535');
  }
  return port;
}

function parseTimeout(value: string | undefined): number {
  if (!value) {
    return 8000;
  }
  const timeout = Number(value);
  if (!Number.isInteger(timeout) || timeout < 1000 || timeout > 30000) {
    throw new Error('REQUEST_TIMEOUT_MS must be an integer from 1000 to 30000');
  }
  return timeout;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): BackendConfig {
  const supabaseUrl = new URL(required(env, 'SUPABASE_URL'));
  if (supabaseUrl.protocol !== 'https:') {
    throw new Error('SUPABASE_URL must use https');
  }
  if (supabaseUrl.username || supabaseUrl.password || supabaseUrl.search || supabaseUrl.hash) {
    throw new Error('SUPABASE_URL must be an origin without credentials or a query string');
  }
  if (supabaseUrl.pathname !== '/' && supabaseUrl.pathname !== '') {
    throw new Error('SUPABASE_URL must not include a path');
  }

  const publishableKey = required(env, 'SUPABASE_PUBLISHABLE_KEY');
  const internalApiKey = required(env, 'SUPABASE_INTERNAL_API_KEY');
  const backendAuthToken = required(env, 'BACKEND_AUTH_TOKEN');

  assertPublishableKey(publishableKey);

  if (internalApiKey.length < MINIMUM_SECRET_LENGTH || backendAuthToken.length < MINIMUM_SECRET_LENGTH) {
    throw new Error('Internal secrets must be at least 32 characters');
  }
  if (new Set([publishableKey, internalApiKey, backendAuthToken]).size !== 3) {
    throw new Error('The publishable key, internal API key, and backend auth token must be distinct');
  }

  return {
    supabaseUrl: supabaseUrl.origin,
    publishableKey,
    internalApiKey,
    backendAuthToken,
    requestTimeoutMs: parseTimeout(env.REQUEST_TIMEOUT_MS),
    host: env.HOST?.trim() || '0.0.0.0',
    port: parsePort(env.PORT),
  };
}

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');

function read(path: string): string {
  return readFileSync(resolve(repoRoot, path), 'utf8');
}

describe('supabase SQL', () => {
  const migrations = [
    'supabase/migrations/001_create_tables.sql',
    'supabase/migrations/002_permissions.sql',
    'supabase/migrations/003_rls.sql',
    'supabase/migrations/004_pre_request.sql',
    'supabase/seed.sql',
    'supabase/cleanup.sql',
    'supabase/audit.sql',
  ].map(read).join('\n');

  it('keeps demo objects in public and does not create an application schema', () => {
    expect(migrations.toLowerCase()).not.toContain('create schema');
    expect(read('supabase/migrations/001_create_tables.sql')).toContain('public.customer_documents');
    expect(read('supabase/migrations/004_pre_request.sql')).toContain('public.check_internal_api_key');
  });

  it('grants anon only select and enables the public-row policy', () => {
    const grants = read('supabase/migrations/002_permissions.sql');
    expect(grants).toContain('GRANT SELECT ON TABLE public.customer_documents TO anon');
    expect(grants).toContain('REVOKE ALL PRIVILEGES ON TABLE public.customer_documents FROM anon');
    expect(grants).toContain('FROM service_role');
    const rls = read('supabase/migrations/003_rls.sql');
    expect(rls).toContain('ENABLE ROW LEVEL SECURITY');
    expect(rls).toContain("visibility = 'public'");
    expect(rls).toContain('TO anon');
  });

  it('locks the pre-request function down without embedding a secret', () => {
    const preRequest = read('supabase/migrations/004_pre_request.sql');
    expect(preRequest).toContain('RETURNS void');
    expect(preRequest).toContain('SECURITY DEFINER');
    expect(preRequest).toContain("SET search_path = ''");
    expect(preRequest).toContain('vault.decrypted_secrets');
    expect(preRequest).toContain('demo_data_api_gateway_secret');
    expect(preRequest).toContain('demo_vault_reader');
    expect(preRequest).toContain('REVOKE ALL ON FUNCTION public.check_internal_api_key() FROM PUBLIC');
    expect(preRequest).toContain("SET pgrst.db_pre_request = 'public.check_internal_api_key'");
    expect(preRequest).not.toContain('SQLERRM');
    expect(preRequest).not.toContain('RETURN expected');
    expect(preRequest.toLowerCase()).not.toContain('create schema');
    const vaultScript = read('supabase/scripts/set-vault-secret.sql');
    expect(vaultScript).toContain(":'gateway_secret'");
    expect(vaultScript).not.toContain('vault.create_secret(\'');
  });

  it('seeds the five demo documents', () => {
    const seed = read('supabase/seed.sql');
    for (const title of [
      'Public Architecture Guide',
      'Public API Documentation',
      'Internal Financial Report',
      'Confidential Roadmap',
      'Product Overview',
    ]) {
      expect(seed).toContain(title);
    }
  });
});

#!/usr/bin/env node
// Replaces Worker placeholders. Does not print secret values.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const file = resolve(dirname(fileURLToPath(import.meta.url)), '../wrangler.jsonc');
const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index];
  const value = process.argv[index + 1];
  if (!key?.startsWith('--') || !value || value.startsWith('--')) {
    console.error('Usage: configure.mjs --service-id <uuid> --team-domain <url> --aud <aud>');
    process.exit(1);
  }
  args.set(key.slice(2), value);
}

const serviceId = args.get('service-id');
const teamDomain = args.get('team-domain');
const aud = args.get('aud');
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

if (!serviceId || !uuid.test(serviceId) || serviceId === '00000000-0000-4000-8000-000000000000') {
  console.error('A real VPC service UUID is required.');
  process.exit(1);
}
if (!teamDomain || !teamDomain.startsWith('https://') || teamDomain.includes('__')) {
  console.error('A https Access team domain is required.');
  process.exit(1);
}
if (!aud || aud.includes('__') || aud.length < 8) {
  console.error('An Access audience tag is required.');
  process.exit(1);
}
for (const value of [serviceId, teamDomain, aud]) {
  if (value.includes('"') || value.includes('\\') || value.includes('\n')) {
    console.error('Configuration values cannot contain quotes or newlines.');
    process.exit(1);
  }
}

const current = readFileSync(file, 'utf8');
const updated = current
  .replace(/"service_id":\s*"[^"]+"/, `"service_id": "${serviceId}"`)
  .replace(/"CF_ACCESS_TEAM_DOMAIN":\s*"[^"]+"/, `"CF_ACCESS_TEAM_DOMAIN": "${teamDomain}"`)
  .replace(/"CF_ACCESS_AUD":\s*"[^"]+"/, `"CF_ACCESS_AUD": "${aud}"`);

if (updated === current || !updated.includes(serviceId) || !updated.includes(aud)) {
  console.error('wrangler.jsonc did not change as expected.');
  process.exit(1);
}

writeFileSync(file, updated);
console.log('Updated the VPC service binding and Access audience. The backend auth token is still a Wrangler secret.');

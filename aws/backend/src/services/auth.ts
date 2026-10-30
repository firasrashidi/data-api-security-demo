import { createHash, timingSafeEqual } from 'node:crypto';

export function secretsEqual(provided: string, expected: string): boolean {
  const providedDigest = createHash('sha256').update(provided).digest();
  const expectedDigest = createHash('sha256').update(expected).digest();
  return timingSafeEqual(providedDigest, expectedDigest);
}

export function readBackendAuthHeader(header: string | string[] | undefined): string {
  if (typeof header !== 'string') {
    return '';
  }
  return header;
}

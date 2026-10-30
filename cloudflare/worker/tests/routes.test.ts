import { describe, expect, it } from 'vitest';
import { matchRoute } from '../src/routes';

describe('worker routes', () => {
  it('allows only the demo reads', () => {
    expect(matchRoute('GET', '/health')).toEqual({ kind: 'health' });
    expect(matchRoute('GET', '/documents')).toEqual({ kind: 'documents' });
    expect(matchRoute('GET', '/documents/11111111-1111-4111-8111-111111111111')).toEqual({
      kind: 'document',
      id: '11111111-1111-4111-8111-111111111111',
    });
  });

  it('rejects writes, traversal, and arbitrary paths', () => {
    expect(matchRoute('POST', '/documents').kind).toBe('method_not_allowed');
    expect(matchRoute('PATCH', '/documents/11111111-1111-4111-8111-111111111111').kind).toBe('method_not_allowed');
    expect(matchRoute('DELETE', '/health').kind).toBe('method_not_allowed');
    expect(matchRoute('GET', '/documents/not-a-uuid').kind).toBe('not_found');
    expect(matchRoute('GET', '/documents/../../admin').kind).toBe('not_found');
    expect(matchRoute('GET', '/rest/v1/customer_documents').kind).toBe('not_found');
    expect(matchRoute('GET', 'http://169.254.169.254/latest/meta-data').kind).toBe('not_found');
  });
});

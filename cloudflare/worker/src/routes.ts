const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type RouteMatch =
  | { kind: 'health' }
  | { kind: 'documents' }
  | { kind: 'document'; id: string }
  | { kind: 'not_found' }
  | { kind: 'method_not_allowed' };

export function matchRoute(method: string, pathname: string): RouteMatch {
  if (pathname.includes('\\') || pathname.includes('..')) {
    return { kind: 'not_found' };
  }

  const path = pathname.length > 1 && pathname.endsWith('/') ? pathname.slice(0, -1) : pathname;
  const known = path === '/health' || path === '/documents' || path.startsWith('/documents/');

  if (method !== 'GET') {
    return known ? { kind: 'method_not_allowed' } : { kind: 'not_found' };
  }

  if (path === '/health') {
    return { kind: 'health' };
  }
  if (path === '/documents') {
    return { kind: 'documents' };
  }
  if (path.startsWith('/documents/')) {
    const id = path.slice('/documents/'.length);
    if (!id || id.includes('/') || !UUID_PATTERN.test(id)) {
      return { kind: 'not_found' };
    }
    return { kind: 'document', id };
  }
  return { kind: 'not_found' };
}

export function backendPath(route: Exclude<RouteMatch, { kind: 'not_found' } | { kind: 'method_not_allowed' }>): string {
  switch (route.kind) {
    case 'health':
      return '/health';
    case 'documents':
      return '/documents';
    case 'document':
      return `/documents/${route.id}`;
  }
}

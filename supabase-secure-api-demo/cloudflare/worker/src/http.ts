export function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
    },
  });
}

export function redact(value: string, secret: string): string {
  if (secret.length < 8) {
    return value;
  }
  return value.split(secret).join('[redacted]');
}

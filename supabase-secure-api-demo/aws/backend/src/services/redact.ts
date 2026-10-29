const MINIMUM_SECRET_LENGTH = 8;

export function redactSecrets(value: string, secrets: readonly string[]): string {
  let output = value;
  for (const secret of secrets) {
    if (secret.length < MINIMUM_SECRET_LENGTH) {
      continue;
    }
    output = output.split(secret).join('[redacted]');
  }
  return output;
}

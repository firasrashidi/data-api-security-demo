import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from 'jose';

const jwksByIssuer = new Map<string, JWTVerifyGetKey>();

export type AccessEnv = {
  CF_ACCESS_TEAM_DOMAIN: string;
  CF_ACCESS_AUD: string;
};

export function issuerFromTeamDomain(teamDomain: string): string {
  const trimmed = teamDomain.trim().replace(/\/$/, '');
  const withScheme = trimmed.startsWith('https://') ? trimmed : `https://${trimmed}`;
  const url = new URL(withScheme);
  if (
    url.protocol !== 'https:' ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    (url.pathname !== '/' && url.pathname !== '')
  ) {
    throw new Error('Invalid Access team domain');
  }
  return url.origin;
}

export function accessConfigured(env: AccessEnv): boolean {
  return env.CF_ACCESS_TEAM_DOMAIN.trim() !== '' && env.CF_ACCESS_AUD.trim() !== ''
    && !env.CF_ACCESS_TEAM_DOMAIN.includes('__')
    && !env.CF_ACCESS_AUD.includes('__');
}

export async function verifyAccessJwt(token: string, env: AccessEnv): Promise<void> {
  const issuer = issuerFromTeamDomain(env.CF_ACCESS_TEAM_DOMAIN);
  let jwks = jwksByIssuer.get(issuer);
  if (!jwks) {
    jwks = createRemoteJWKSet(new URL(`${issuer}/cdn-cgi/access/certs`));
    jwksByIssuer.set(issuer, jwks);
  }
  await jwtVerify(token, jwks, {
    issuer,
    audience: env.CF_ACCESS_AUD,
  });
}

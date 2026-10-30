import type { FastifyInstance } from 'fastify';
import type { BackendConfig, FetchLike } from '../services/supabase.js';
import { probeSupabase } from '../services/supabase.js';

export function registerHealthRoute(
  app: FastifyInstance,
  config: BackendConfig,
  fetchImpl: FetchLike,
): void {
  app.get('/health', async (_request, reply) => {
    const result = await probeSupabase(config, fetchImpl);
    return reply.code(result.status).send(result.body);
  });
}

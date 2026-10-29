import type { FastifyInstance } from 'fastify';
import type { BackendConfig, FetchLike } from '../services/supabase.js';
import { getDocument, listDocuments } from '../services/supabase.js';

export function registerDocumentRoutes(
  app: FastifyInstance,
  config: BackendConfig,
  fetchImpl: FetchLike,
): void {
  app.get('/documents', async (_request, reply) => {
    const result = await listDocuments(config, fetchImpl);
    return reply.code(result.status).send(result.body);
  });

  app.get<{ Params: { id: string } }>('/documents/:id', async (request, reply) => {
    const result = await getDocument(config, request.params.id, fetchImpl);
    return reply.code(result.status).send(result.body);
  });
}

import Fastify, { type FastifyInstance } from 'fastify';
import { readBackendAuthHeader, secretsEqual } from './services/auth.js';
import type { BackendConfig, FetchLike } from './services/supabase.js';
import { registerDocumentRoutes } from './routes/documents.js';
import { registerHealthRoute } from './routes/health.js';

const DISALLOWED_METHODS = ['POST', 'PUT', 'PATCH', 'DELETE'] as const;

export type BuildAppOptions = {
  fetchImpl?: FetchLike;
  logger?: boolean;
};

export function buildApp(config: BackendConfig, options: BuildAppOptions = {}): FastifyInstance {
  const fetchImpl = options.fetchImpl ?? fetch;
  const app = Fastify({
    logger: options.logger
      ? {
          level: 'info',
          serializers: {
            req(request) {
              return { method: request.method, url: request.url.split('?')[0] };
            },
            res(reply) {
              return { statusCode: reply.statusCode };
            },
          },
        }
      : false,
    bodyLimit: 1024,
    trustProxy: false,
    requestIdHeader: false,
  });

  app.addHook('onRequest', async (request, reply) => {
    const provided = readBackendAuthHeader(request.headers['x-backend-auth']);
    if (!secretsEqual(provided, config.backendAuthToken)) {
      return reply.code(401).send({ message: 'Unauthorized' });
    }
  });

  registerHealthRoute(app, config, fetchImpl);
  registerDocumentRoutes(app, config, fetchImpl);

  for (const url of ['/health', '/documents', '/documents/:id']) {
    app.route({
      method: [...DISALLOWED_METHODS],
      url,
      handler: async (_request, reply) => reply.code(405).send({ message: 'Method not allowed' }),
    });
  }

  app.setNotFoundHandler((_request, reply) => {
    return reply.code(404).send({ message: 'Not found' });
  });

  app.setErrorHandler((error: Error & { statusCode?: number }, request, reply) => {
    request.log.error({ message: error.message }, 'request failed');
    const status = error.statusCode && error.statusCode >= 400 && error.statusCode < 500
      ? error.statusCode
      : 500;
    return reply.code(status).send({
      message: status === 500 ? 'Internal error' : 'Bad request',
    });
  });

  return app;
}

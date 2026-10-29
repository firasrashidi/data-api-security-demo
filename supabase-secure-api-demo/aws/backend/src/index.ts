import { buildApp } from './app.js';
import { loadConfig } from './config.js';

const config = loadConfig();
const app = buildApp(config, { logger: true });

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => {
    app.close().then(() => process.exit(0)).catch(() => process.exit(1));
  });
}

try {
  await app.listen({ host: config.host, port: config.port });
} catch (error) {
  app.log.error({ message: error instanceof Error ? error.message : 'listen failed' }, 'startup failed');
  process.exit(1);
}

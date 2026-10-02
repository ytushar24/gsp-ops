const { MongoClient } = require('mongodb');
const { createApp } = require('./app');
const { mongoStore } = require('./store');
const config = require('./config');
const log = require('./log');

async function main() {
  const cfg = config.load();

  const client = new MongoClient(cfg.mongoUri, {
    serverSelectionTimeoutMS: 5000,
    maxPoolSize: 20,
  });
  await client.connect();
  const db = client.db(cfg.dbName);
  await db.collection('notes').createIndex({ createdAt: -1 });

  let shuttingDown = false;
  const app = createApp({
    store: mongoStore(db),
    version: cfg.version,
    color: cfg.color,
    isShuttingDown: () => shuttingDown,
  });

  const server = app.listen(cfg.port, () => {
    log.info('listening', { port: cfg.port, version: cfg.version, color: cfg.color });
  });
  // Keep idle upstream connections from nginx a little longer than nginx's
  // own keepalive_timeout so nginx is always the side that closes them.
  server.keepAliveTimeout = 65_000;
  server.headersTimeout = 66_000;

  const shutdown = (signal) => {
    if (shuttingDown) return;
    shuttingDown = true;
    log.info('shutdown requested, draining', { signal });

    const force = setTimeout(() => {
      log.warn('drain timeout reached, forcing exit');
      process.exit(1);
    }, cfg.shutdownGraceMs);
    force.unref();

    // Stop accepting new connections, let in-flight requests finish.
    server.close(async () => {
      await client.close().catch(() => {});
      log.info('drained, exiting');
      process.exit(0);
    });
    server.closeIdleConnections();
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch((err) => {
  log.error('startup failed', { err: err.message });
  process.exit(1);
});

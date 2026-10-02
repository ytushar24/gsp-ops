const express = require('express');
const log = require('./log');

const MAX_TITLE = 200;
const MAX_BODY = 10_000;

function createApp({ store, version, color, isShuttingDown = () => false }) {
  const app = express();

  app.disable('x-powered-by');
  app.set('trust proxy', 'loopback, uniquelocal');
  app.use(express.json({ limit: '32kb' }));

  // Liveness: the process is up and the event loop is turning. Deliberately
  // does not touch Mongo, otherwise a DB blip gets the container restarted.
  app.get('/healthz', (_req, res) => {
    res.json({ status: 'ok', version, color });
  });

  // Readiness: can we actually serve traffic. Used by the deploy gate and the
  // external uptime check.
  app.get('/readyz', async (_req, res) => {
    if (isShuttingDown()) {
      return res.status(503).json({ status: 'draining', version, color });
    }
    try {
      await store.ping();
      res.json({ status: 'ready', version, color });
    } catch (err) {
      log.warn('readiness check failed', { err: err.message });
      res.status(503).json({ status: 'db_unavailable', version, color });
    }
  });

  app.get('/api/notes', async (req, res, next) => {
    try {
      const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 20, 1), 100);
      res.json(await store.list({ limit }));
    } catch (err) {
      next(err);
    }
  });

  app.get('/api/notes/:id', async (req, res, next) => {
    try {
      const note = await store.get(req.params.id);
      if (!note) return res.status(404).json({ error: 'not_found' });
      res.json(note);
    } catch (err) {
      next(err);
    }
  });

  app.post('/api/notes', async (req, res, next) => {
    const { title, body } = req.body || {};
    if (typeof title !== 'string' || !title.trim() || title.length > MAX_TITLE) {
      return res.status(400).json({ error: 'title is required (max 200 chars)' });
    }
    if (body !== undefined && (typeof body !== 'string' || body.length > MAX_BODY)) {
      return res.status(400).json({ error: 'body must be a string (max 10000 chars)' });
    }
    try {
      const note = await store.create({ title: title.trim(), body: body || '' });
      res.status(201).json(note);
    } catch (err) {
      next(err);
    }
  });

  app.use((_req, res) => res.status(404).json({ error: 'not_found' }));

  // Never leak stack traces or driver messages to the client.
  app.use((err, req, res, _next) => {
    if (err.type === 'entity.parse.failed') {
      return res.status(400).json({ error: 'invalid_json' });
    }
    if (err.type === 'entity.too.large') {
      return res.status(413).json({ error: 'payload_too_large' });
    }
    log.error('request failed', { path: req.path, err: err.message });
    res.status(500).json({ error: 'internal_error' });
  });

  return app;
}

module.exports = { createApp };

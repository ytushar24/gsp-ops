const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { createApp } = require('../src/app');

function memoryStore({ healthy = true } = {}) {
  const items = [];
  let n = 0;
  return {
    async ping() {
      if (!healthy) throw new Error('db down');
    },
    async create({ title, body }) {
      const note = { id: String(++n), title, body, createdAt: new Date() };
      items.unshift(note);
      return note;
    },
    async list({ limit }) {
      return { total: items.length, items: items.slice(0, limit) };
    },
    async get(id) {
      return items.find((i) => i.id === id) || null;
    },
  };
}

const build = (opts = {}) =>
  createApp({ store: memoryStore(opts), version: 'test', color: 'blue', ...opts });

describe('health endpoints', () => {
  test('healthz reports version and colour', async () => {
    const res = await request(build()).get('/healthz');
    assert.equal(res.status, 200);
    assert.deepEqual(res.body, { status: 'ok', version: 'test', color: 'blue' });
  });

  test('readyz is 200 when the store answers', async () => {
    const res = await request(build()).get('/readyz');
    assert.equal(res.status, 200);
    assert.equal(res.body.status, 'ready');
  });

  test('readyz is 503 when the store is down', async () => {
    const res = await request(build({ healthy: false })).get('/readyz');
    assert.equal(res.status, 503);
    assert.equal(res.body.status, 'db_unavailable');
  });

  test('readyz is 503 while draining', async () => {
    const res = await request(build({ isShuttingDown: () => true })).get('/readyz');
    assert.equal(res.status, 503);
    assert.equal(res.body.status, 'draining');
  });

  test('healthz stays 200 even if the db is down', async () => {
    const res = await request(build({ healthy: false })).get('/healthz');
    assert.equal(res.status, 200);
  });
});

describe('notes api', () => {
  test('create then fetch a note', async () => {
    const app = build();
    const created = await request(app).post('/api/notes').send({ title: ' hello ', body: 'x' });
    assert.equal(created.status, 201);
    assert.equal(created.body.title, 'hello');

    const fetched = await request(app).get(`/api/notes/${created.body.id}`);
    assert.equal(fetched.status, 200);
    assert.equal(fetched.body.body, 'x');
  });

  test('list returns total and respects limit', async () => {
    const app = build();
    for (let i = 0; i < 3; i++) {
      await request(app).post('/api/notes').send({ title: `n${i}` });
    }
    const res = await request(app).get('/api/notes?limit=2');
    assert.equal(res.body.total, 3);
    assert.equal(res.body.items.length, 2);
  });

  test('rejects missing title', async () => {
    const res = await request(build()).post('/api/notes').send({ body: 'no title' });
    assert.equal(res.status, 400);
  });

  test('rejects non-string body', async () => {
    const res = await request(build()).post('/api/notes').send({ title: 't', body: { $gt: '' } });
    assert.equal(res.status, 400);
  });

  test('malformed json gives 400, not a stack trace', async () => {
    const res = await request(build())
      .post('/api/notes')
      .set('content-type', 'application/json')
      .send('{"title":');
    assert.equal(res.status, 400);
    assert.deepEqual(res.body, { error: 'invalid_json' });
  });

  test('unknown id is 404', async () => {
    const res = await request(build()).get('/api/notes/nope');
    assert.equal(res.status, 404);
  });

  test('no x-powered-by header', async () => {
    const res = await request(build()).get('/healthz');
    assert.equal(res.headers['x-powered-by'], undefined);
  });
});

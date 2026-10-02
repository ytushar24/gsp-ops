// Runs against a real MongoDB when MONGO_TEST_URI is set (CI provides one as
// a service container). Skipped otherwise.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { MongoClient } = require('mongodb');
const { createApp } = require('../src/app');
const { mongoStore } = require('../src/store');

const uri = process.env.MONGO_TEST_URI;

test('round trip through a real mongo', { skip: !uri && 'MONGO_TEST_URI not set' }, async () => {
  const client = await MongoClient.connect(uri);
  try {
    const db = client.db(`it_${Date.now()}`);
    const app = createApp({ store: mongoStore(db), version: 'it', color: 'none' });

    assert.equal((await request(app).get('/readyz')).status, 200);

    const created = await request(app).post('/api/notes').send({ title: 'integration' });
    assert.equal(created.status, 201);
    // the driver's raw _id must not leak out alongside our own id
    assert.ok(created.body.id);
    assert.equal(created.body._id, undefined);

    const list = await request(app).get('/api/notes');
    assert.equal(list.body.total, 1);
    assert.equal(list.body.items[0]._id, undefined);

    await db.dropDatabase();
  } finally {
    await client.close();
  }
});

const { ObjectId } = require('mongodb');

// Thin wrapper so the HTTP layer never touches the driver directly and tests
// can pass an in-memory implementation.
function mongoStore(db) {
  const notes = db.collection('notes');

  return {
    async ping() {
      await db.command({ ping: 1 });
    },

    async create({ title, body }) {
      const doc = { title, body, createdAt: new Date() };
      // insertOne mutates doc to add _id, so spread the fields explicitly
      // rather than ...doc, which would leak _id alongside id.
      const res = await notes.insertOne(doc);
      return { id: res.insertedId.toString(), title: doc.title, body: doc.body, createdAt: doc.createdAt };
    },

    async list({ limit }) {
      const [items, total] = await Promise.all([
        notes.find().sort({ createdAt: -1 }).limit(limit).toArray(),
        notes.countDocuments(),
      ]);
      return {
        total,
        items: items.map(({ _id, ...rest }) => ({ id: _id.toString(), ...rest })),
      };
    },

    async get(id) {
      if (!ObjectId.isValid(id)) return null;
      const doc = await notes.findOne({ _id: new ObjectId(id) });
      if (!doc) return null;
      const { _id, ...rest } = doc;
      return { id: _id.toString(), ...rest };
    },
  };
}

module.exports = { mongoStore };

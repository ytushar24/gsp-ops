const fs = require('node:fs');

// Secrets come in as files (docker secrets) in the stack. Plain env vars are
// accepted as a fallback so tests and local runs stay simple.
function readSecret(name) {
  const file = process.env[`${name}_FILE`];
  if (file) {
    return fs.readFileSync(file, 'utf8').trim();
  }
  return process.env[name];
}

function load() {
  const mongoUri = readSecret('MONGO_URI');
  if (!mongoUri) {
    throw new Error('MONGO_URI or MONGO_URI_FILE must be set');
  }
  return {
    port: Number(process.env.PORT || 3000),
    mongoUri,
    dbName: process.env.MONGO_DB || 'gsp',
    version: process.env.APP_VERSION || 'dev',
    color: process.env.APP_COLOR || 'none',
    shutdownGraceMs: Number(process.env.SHUTDOWN_GRACE_MS || 15000),
  };
}

module.exports = { load, readSecret };

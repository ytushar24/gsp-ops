#!/usr/bin/env node
// Minimal load generator for the zero-downtime check. Hits /readyz (which goes
// app -> mongo) at a fixed concurrency and records every non-200 and every
// connection error, plus which colour/version answered, so the report shows
// traffic moving from one release to the other.
//
//   node scripts/loadgen.js --url https://localhost:8443/readyz --seconds 60 --concurrency 20
//
// Exits 1 if anything failed. Keep-alive is off by default: a client reusing a
// socket that nginx is closing during reload can see a reset, which is a
// client retry concern rather than a dropped request. --keepalive turns it on.
const https = require('node:https');
const http = require('node:http');

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, arr) => {
    if (a.startsWith('--')) acc.push([a.slice(2), arr[i + 1]?.startsWith('--') ? 'true' : arr[i + 1] ?? 'true']);
    return acc;
  }, []),
);

const url = new URL(args.url || 'https://localhost:8443/readyz');
const seconds = Number(args.seconds || 60);
const concurrency = Number(args.concurrency || 20);
const keepAlive = args.keepalive === 'true';
const mod = url.protocol === 'https:' ? https : http;
const agent = new mod.Agent({ keepAlive, maxSockets: concurrency, rejectUnauthorized: false });

const stats = { total: 0, ok: 0, status: {}, errors: {}, seen: {} };
const timeline = [];
const deadline = Date.now() + seconds * 1000;
let lastSeen = null;

function once() {
  return new Promise((resolve) => {
    const req = mod.get(url, { agent, timeout: 10000 }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => {
        stats.total++;
        stats.status[res.statusCode] = (stats.status[res.statusCode] || 0) + 1;
        if (res.statusCode === 200) {
          stats.ok++;
          try {
            const { color, version } = JSON.parse(body);
            const key = `${color}:${version}`;
            stats.seen[key] = (stats.seen[key] || 0) + 1;
            if (key !== lastSeen) {
              timeline.push(`${new Date().toISOString()}  now answering: ${key}`);
              lastSeen = key;
            }
          } catch {
            // non-json 200 still counts as success
          }
        }
        resolve();
      });
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', (err) => {
      stats.total++;
      const k = err.code || err.message;
      stats.errors[k] = (stats.errors[k] || 0) + 1;
      resolve();
    });
  });
}

async function worker() {
  while (Date.now() < deadline) await once();
}

(async () => {
  const started = new Date();
  await Promise.all(Array.from({ length: concurrency }, worker));
  const failed = stats.total - stats.ok;
  const out = [
    `target       ${url.href}`,
    `started      ${started.toISOString()}`,
    `duration     ${seconds}s, concurrency ${concurrency}, keepalive ${keepAlive}`,
    `requests     ${stats.total} (${(stats.total / seconds).toFixed(1)} req/s)`,
    `succeeded    ${stats.ok}`,
    `failed       ${failed}`,
    `status codes ${JSON.stringify(stats.status)}`,
    `errors       ${JSON.stringify(stats.errors)}`,
    `answered by  ${JSON.stringify(stats.seen)}`,
    '',
    'switch timeline:',
    ...timeline.map((t) => `  ${t}`),
  ];
  console.log(out.join('\n'));
  process.exit(failed === 0 ? 0 : 1);
})();

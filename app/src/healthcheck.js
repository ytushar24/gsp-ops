// Used by the Docker HEALTHCHECK. The runtime image has no curl/wget on
// purpose, so this is plain node.
const http = require('node:http');

const port = process.env.PORT || 3000;
const req = http.get({ host: '127.0.0.1', port, path: '/readyz', timeout: 3000 }, (res) => {
  process.exit(res.statusCode === 200 ? 0 : 1);
});
req.on('timeout', () => req.destroy());
req.on('error', () => process.exit(1));

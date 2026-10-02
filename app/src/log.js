// One JSON object per line so docker logs / loki can parse it without regex.
function write(level, msg, extra) {
  const line = { ts: new Date().toISOString(), level, msg, ...extra };
  process.stdout.write(JSON.stringify(line) + '\n');
}

module.exports = {
  info: (msg, extra) => write('info', msg, extra),
  warn: (msg, extra) => write('warn', msg, extra),
  error: (msg, extra) => write('error', msg, extra),
};

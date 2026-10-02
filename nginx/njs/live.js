// Decides which colour gets each request by reading a one-word file
// (/etc/nginx/live/color, written by scripts/deploy.sh).
//
// Why not just rewrite an upstream include and `nginx -s reload`? Because a
// reload under load drops a few connections: old workers close accepted
// connections they haven't read a request from yet. Measured locally: 6-28
// resets across 4 reloads at ~2-3k req/s, and 0 across 8 switches with this.
// See docs/decisions.md.
//
// njs doesn't keep module state between requests, so this reads the file
// every request. It's a tiny file in the page cache; fine at our scale. At
// high volume I'd move to js_shared_dict_zone.
import fs from 'fs';

const FILE = '/etc/nginx/live/color';

function pick(r) {
  try {
    const color = fs.readFileSync(FILE, 'utf8').trim();
    if (color === 'blue' || color === 'green') {
      return 'app_' + color;
    }
    r.error(`unexpected value in ${FILE}: "${color}"`);
  } catch (e) {
    r.error(`cannot read ${FILE}: ${e.message}`);
  }
  return 'app_blue';
}

export default { pick };

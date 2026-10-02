# Decisions

Short notes on the choices that aren't obvious, so they can be argued with.

## A small purpose-built app rather than an off-the-shelf one

The application is not the interesting part here, the operations around it
are. A ~200 line service where I control the health endpoints and shutdown
behaviour made those easier to get right: `/readyz` that checks the DB and
goes 503 while draining, SIGTERM handling, secrets read from files. Something
like the RealWorld example app would have needed changes for all of those
anyway.

## Blue/green switch without reloading nginx

The obvious approach is to rewrite an `upstream` include and run
`nginx -s reload`. Measured against the load generator before building on
it, that drops requests:

| switch method | switches | requests | failed |
|---|---|---|---|
| upstream include + `nginx -s reload` | 4 | 80,304 | 27 (ECONNRESET) |
| njs reads `live/color` (what we use) | 8 | 72,872 | 0 |

Both runs: 60s, HTTPS, 20 concurrent clients, no keepalive, the same two app
containers, nginx 1.27-alpine. The reload variant is a second nginx on
:8444 with the colour in an `upstream` include; the njs variant is the real
stack on :8443. Reproduce with `scripts/loadgen.js` while switching colours.

On reload, old worker processes shut down gracefully, but "gracefully" means
they close connections that have been accepted and haven't sent a request
yet. A client whose request is on the wire at that moment gets a reset. Rare
at low traffic, but the target is a deploy that drops nothing at all, and
"rarely drops a few" isn't that.

So the upstreams for both colours are defined once, and a two-line njs
function picks one per request from a file. Switching is an atomic rename.
No reload, nothing to drain on the nginx side. The cost is a small file read
per request, which is fine at this scale.

Related: the upstreams use fixed IPs (set in compose) rather than container
names. nginx resolves names once at startup, so recreating a container
(new IP) would leave nginx pointing at the old address.

## Old colour stays running after a deploy

Rollback is then a file write. Stopping it would save ~100MB of RAM and make
rollback a full deploy of the previous image. For a platform with a 99.9%
target, fast rollback is worth more.

## age for backup encryption, public key only on the server

age is small, has no config and no keyring, and has a clean split between
public recipient and private identity. gpg can do the same but with a lot
more surface area to get wrong. The main point is the split: the backup host
can encrypt but not decrypt, so compromising it doesn't expose the backup
history. The private key lives offline and in one GitHub secret (for the
verify job).

## Backups: mongodump every hour

Simplest thing that meets RPO 1h and restores with one command. It is not
point-in-time recovery; see Known limitations in the README. For production
I'd move to a replica set and Percona Backup for MongoDB with oplog slicing,
as set out in the [operations plan](operations-plan.md).

## Server can't delete off-site backups

Retention on the bucket is a lifecycle rule, not a `delete` in the script,
and the server's key is write-only. Otherwise the most likely attacker (who
has the server) can wipe the backups before doing damage.

## Health checks: liveness vs readiness

`/healthz` doesn't touch Mongo. If it did, a DB outage would make every app
container unhealthy, and anything that restarts unhealthy containers would
turn one problem into a restart storm. `/readyz` does check Mongo, and is what
deploys and alerts use.

## Secrets as files, 0644 in a 0700 directory

Compose file-based secrets are bind mounts, so ownership and mode come from
the host. Mongo runs as uid 999 and node as uid 1000, so 0600 files owned by
the deploy user would be unreadable inside the containers. The files are
0644 and the `secrets/` directory is 0700, which keeps other host users out.
With Swarm or Kubernetes secrets you get per-container ownership; not worth
it for one host.

## Rate limiting writes only

A per-IP limit on reads would throttle users behind a shared NAT, and behind
Cloudflare every request comes from a handful of Cloudflare IPs until
`real_ip` is configured. Writes (POST etc.) are where abuse costs something.

## CI rehearses the whole stack

The ops scripts are the riskiest code here and the least tested by unit
tests. So CI brings the stack up in the runner and runs deploy, a deploy
under load, rollback, backup and the restore drill. If a script change breaks
restore, CI goes red before anyone needs the restore.

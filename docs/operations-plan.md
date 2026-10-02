# Taking over the GSP estate

The estate is Linode (primary) and DigitalOcean, behind Cloudflare, running a
MEAN stack that holds sensitive student documents. The targets are 99.9%
uptime (about 43 minutes a month), RTO 4h and RPO 1h. The external team that
built it is leaving and the documentation is thin.

This is the plan: what to secure first, how the backups should be arranged,
what to do when a provider region fails, and what to change so that recovery
needs less of me.

## The first two weeks

The order is driven by one question: what could I lose access to or be
unable to recover, that I can't get back later?

**Days 1-2: control of the accounts.** Registrar, Cloudflare, Linode,
DigitalOcean, GitHub, the email domain, any payment or SMS provider. Owner
access held by the company (not by me personally, and not by a vendor
engineer), MFA on everything, registrar lock on the domain. Before removing
any vendor account, list the API tokens and deploy keys tied to it; deleting
a person can quietly break a cron job or a pipeline that runs as them. If the
vendor owns the registrar account, everything else is secondary.

**Days 1-5, in parallel: get what's in the vendor's heads.** They're still
reachable, that ends soon. Recorded sessions on: how a deploy actually
happens, where backups go and when one was last restored, what breaks and how
they fix it, anything that runs on a schedule. I'd ask them to do a deploy
while I watch.

**Days 2-4: inventory.** Every server (role, size, OS version, open ports,
what runs on it, crontabs), the Cloudflare zone exported to a file, firewall
rules, TLS certs and their expiry, where uploaded documents are stored and
who can read them. This becomes the first version of the documentation.

**Days 3-5: prove a restore.** Take their latest backup and restore it on a
separate machine, database and documents. Until that works I assume there is
no backup, and fixing that goes to the top of the list.

**Days 5-8: lock down.** Rotate every credential the vendor knew: database
users, API keys, SSH keys, Cloudflare tokens. SSH keys only, no root login.
Origin firewalls accept 80/443 from Cloudflare's IP ranges only, so nobody
can go around the WAF. MongoDB not reachable from the internet (worth
checking on day 1, it's the most common way these get breached). Check
whether uploaded documents can be fetched without auth or by guessing URLs.
For student documents that's a data protection incident, not a tech debt
item.

**Week 2: see problems before users do.** External uptime check, alerts to
a place someone reads, disk and cert expiry alerts, backup freshness alert.
Then a short runbook and a staging copy so changes can be tested somewhere.

**Deliberately postponed:** infrastructure as code for everything, moving to
containers or Kubernetes, rebuilding CI/CD, cost optimisation. All worth
doing, none of them reduce risk in the first fortnight, and changing things I
don't understand yet is how new owners cause outages.

## Backup design: 3-2-1 for an RPO of one hour

Three copies, two different kinds of storage, one off-provider, and the
off-provider copy immutable so a compromised server can't delete it.

**MongoDB.** First change: run it as a replica set (a single-node one is
enough to start), because that gives an oplog. Then Percona Backup for
MongoDB: a nightly full snapshot plus continuous oplog chunks every few
minutes. That gives point-in-time restore and an RPO of minutes, not an hour.
Hourly `mongodump` would meet the 1h target, but only just, and each dump is
a full copy.

**Documents.** Hourly dumps are wrong for files. A document uploaded 59
minutes before a disk failure would be gone, and parents don't care that we
met our RPO. Better: have the app write uploads straight to object storage
(S3-compatible, private bucket, signed URLs). Then document RPO is roughly
zero, the app servers hold no state, and failover gets much easier (question
4). Until that change ships: `restic` every 15 minutes to the off-site bucket.

**Where the copies live:**

| copy | where | purpose |
|---|---|---|
| 1 | production (Linode) | live data |
| 2 | Linode Backup Service snapshots, daily | fast restore of a whole server, same provider |
| 3 | Backblaze B2 (EU region), Object Lock 30 days | off-provider, immutable. PBM snapshots + oplog, restic for documents |
| (4) | Cloudflare R2, weekly, separate credentials | a second off-provider copy for the case where B2 credentials are also compromised |

Everything encrypted before it leaves the server, with the decryption key
held offline. The servers get write-only keys; retention is lifecycle rules
on the bucket.

**Rough monthly cost.** Assumptions, since I don't know the real sizes:
MongoDB 20 GB (about 5 GB compressed), 300 GB of documents, 35 days
retention.

| item | size | approx. monthly |
|---|---|---|
| B2, Mongo snapshots (35 x 5 GB) + oplog | ~0.2 TB | ~$1.50 |
| B2, documents + old versions | ~0.35 TB | ~$2.50 |
| R2, weekly Mongo + document copy | ~0.35 TB | ~$5 |
| Linode Backup Service, 2 nodes | | ~$10-20 |
| **total** | | **~$20-30** |

B2 is $6.95 per TB per month with egress free up to 3x what's stored, R2
around $15 per TB with no egress fees. Prices to be rechecked before
committing. Storage isn't the expensive part; the time to run a restore test
every month is, and it's non-negotiable.

## When the Linode region goes down at 09:00 on a weekday

Timings are the plan for a warm start (backups off-site, DigitalOcean
account ready, no standby yet).

**09:00-09:10. Confirm and declare.** Is it Linode or us? Linode status page,
external checks, Cloudflare analytics showing origin errors. Declare an
incident in the team channel, name one person to run it (me) and ideally one
for comms. Start a timestamped log. Switch Cloudflare to a maintenance page
(a Worker or custom error page) so users see "we know, we're on it" rather
than a raw 5xx.

**09:10-09:20. Decide.** If Linode gives a credible fix time well inside our
window, waiting is fine, but I'd start rebuilding on DigitalOcean anyway. It
costs little and can be abandoned. The rule: no believable ETA by 09:30,
we're failing over. Tell stakeholders now: expected recovery around
11:00-12:00, data loss up to the last backup.

**09:20-10:30. Rebuild on DigitalOcean.** Droplets from our provisioning
script or Terraform (this is where the month-one DNS work below pays off),
same region as users (London). Firewall to Cloudflare ranges only. Pull
secrets from the password manager. Restore MongoDB from the latest B2 backup
(with PBM, to the latest oplog point). Restore or re-point documents. Start
the app.

**10:30-11:00. Test before switching traffic.** From my laptop with
`curl --resolve` pointing the domain at the new IP: log in, list documents,
upload one, download one. Check the data is as recent as expected and write
down the actual RPO.

**11:00-11:15. Switch.** In Cloudflare, change the origin A record(s) to
the DigitalOcean IPs. Because the records are proxied, clients only ever see
Cloudflare's IPs, so the change takes effect in seconds; TTL doesn't matter
here. Check SSL mode still validates (Origin CA cert on the new server),
remove the maintenance page, watch origin errors in Cloudflare analytics.
Also check anything that talks to the origin directly instead of through
Cloudflare: webhooks, payment callbacks, cron on other servers, and any
grey-clouded records.

**11:15-13:00. Stabilise.** Watch error rates and resources (the new
droplets may be smaller). Point monitoring and backups at the new servers;
backups need to be running again before I stop watching. Update
stakeholders.

**Before failing back:** when Linode returns, its servers still think they're
production. Firewall them off or stop the app first, so nothing writes to the
old database and we don't end up with two diverging copies. Failback later,
planned, as a normal migration.

Total about two hours, inside the 4h RTO with room for things going wrong.
Afterwards: timeline, what slowed us down, what to automate.

## Month-one changes to Cloudflare and DNS

In order of how much time each one takes off the failover above:

1. **Cloudflare Load Balancing with two origin pools** (Linode primary,
   DigitalOcean fallback) and health monitors on `/readyz`. Failover of
   traffic becomes automatic, no one edits DNS under pressure. Small monthly
   cost. Only useful once there's something to fail over to, which is next.
2. **A warm standby on DigitalOcean.** A small droplet running the app, with
   MongoDB as a replica set member (hidden or low priority) replicating from
   Linode. Failover becomes promoting a secondary, minutes instead of an
   hour-long restore. Needs documents in object storage, as above, so
   there's nothing on local disk to copy.
3. **Cloudflare Tunnel** (`cloudflared`) on the origins instead of open 443.
   No public origin IP to find and attack, no firewall allowlist to keep in
   sync, and a rebuilt server joins by starting the tunnel with no DNS
   change.
4. **Zone in Terraform.** The DNS records, page rules, WAF rules and load
   balancer in git, reviewed like code, and recoverable if someone deletes
   something at 09:05 in a panic.
5. **Audit the zone for leaks.** Grey-clouded records like `mail.`,
   `staging.` or `direct.` that expose origin IPs, and old records nobody can
   explain. Enable Authenticated Origin Pulls and Full (strict) SSL.
6. **Practise.** A planned failover to DigitalOcean each quarter, in a quiet
   hour. The first one will find the thing everybody forgot about.

What I'd skip in month one: multi-region active-active, Kubernetes, a service
mesh. For 99.9% on this stack, a tested warm standby with automatic traffic
failover is enough.

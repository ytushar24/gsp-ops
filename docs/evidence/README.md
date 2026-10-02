# Evidence

Output from real runs on the local docker-compose stack. The files are written
by the scripts, not edited by hand.

| file | produced by |
|---|---|
| `restore-drill-*.md` | `scripts/restore-drill.sh` |
| `zero-downtime-*.txt` | `scripts/zero-downtime-test.sh` |
| `alert-fired-*.txt` | `scripts/healthcheck.sh` against a local webhook receiver |

The alert file uses a local HTTP receiver in place of the Slack/Discord
endpoint so the exact payloads and the threshold behaviour are visible in
text. The code path is the same `notify()` the real webhook uses.

CI uploads the same reports from every run as the `rehearsal-evidence`
artifact, so there is a fresh set per push as well as the ones committed here.

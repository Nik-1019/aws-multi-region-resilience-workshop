# AWS Multi-Region Resilience Workshop

A complete, self-contained toolkit for running a hands-on AWS failover workshop.
Participants deploy an identical Flask application into two regions — an active
primary in `us-east-1` and a warm standby in `us-west-2` backed by a cross-region
RDS read replica — then deliberately break the primary and watch, live on screen,
as traffic moves. The application renders a colour-coded dashboard showing exactly
which region, availability zone and instance answered each request, so the moment
of failover is impossible to miss from the back of the room.

---

## Architecture

```
                                 ┌──────────────┐
                          users  │  CloudFront  │  (added during the workshop)
                            │    └──────┬───────┘
                            ▼           │  origin failover
                     ┌──────────────────┴──────────────────┐
                     │                                     │
        ═════════════▼═════════════          ══════════════▼════════════
        ║   PRIMARY   us-east-1   ║          ║  SECONDARY  us-west-2   ║
        ║                         ║          ║                        ║
        ║   ┌─────────────────┐   ║          ║  ┌─────────────────┐   ║
        ║   │       ALB       │◄──╬── chaos ─╬─►│       ALB       │   ║
        ║   │  (public 80/443)│   ║   .sh    ║  │  (public 80/443)│   ║
        ║   └────────┬────────┘   ║          ║  └────────┬────────┘   ║
        ║            │            ║          ║           │            ║
        ║   ┌────────▼────────┐   ║          ║  ┌────────▼────────┐   ║
        ║   │   ASG  1..2     │   ║          ║  │  ASG  0..2      │   ║
        ║   │   t3.micro      │   ║          ║  │  t3.micro       │   ║
        ║   │   Flask + gunic │   ║          ║  │  pilot light    │   ║
        ║   └────────┬────────┘   ║          ║  └────────┬────────┘   ║
        ║            │            ║          ║           │            ║
        ║   ┌────────▼────────┐   ║  async   ║  ┌────────▼────────┐   ║
        ║   │  RDS MySQL      │───╬─────────►╬─►│  RDS Read       │   ║
        ║   │  db.t3.micro    │   ║ replicat.║  │  Replica        │   ║
        ║   │  READ-WRITE     │   ║          ║  │  READ-ONLY      │   ║
        ║   └─────────────────┘   ║          ║  └─────────────────┘   ║
        ║                         ║          ║                        ║
        ║  VPC 10.10.0.0/16       ║          ║  VPC 10.20.0.0/16      ║
        ║  2 public + 2 private   ║          ║  2 public + 2 private  ║
        ║  1 NAT gateway          ║          ║  1 NAT gateway         ║
        ═══════════════════════════          ══════════════════════════
```

Each region is fully self-contained: its own VPC across two availability zones,
public subnets for the load balancer, private subnets for the application and
database, and a single NAT gateway (one per region, to keep the bill small).

---

## Repository layout

```
.
├── app.py                    Flask dashboard application
├── templates/index.html      the entire UI: HTML + CSS + JS, no build step
├── requirements.txt          pinned dependencies
├── Dockerfile                multi-stage build, gunicorn on port 80
├── userdata.sh               EC2 bootstrap for Amazon Linux 2023
├── cloudformation/
│   ├── primary.yaml          us-east-1: VPC, ALB, ASG, RDS MySQL
│   └── secondary.yaml        us-west-2: same plus a cross-region read replica
└── scripts/
    ├── preflight.sh          validate the account before deploying
    ├── deploy.sh             deploy both stacks, write .workshop-config
    ├── heartbeat.sh          once-a-second monitor with failover timing
    ├── chaos.sh              break / restore the primary region
    └── cleanup.sh            delete everything, in reverse order
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| AWS account | With permission to create VPC, EC2, ELB, ASG, RDS, IAM and CloudFormation resources |
| AWS CLI v2 | `aws configure` completed, or `AWS_PROFILE` exported |
| `bash` 3.2+ | Scripts are portable across macOS and Linux |
| `curl` | Required by `heartbeat.sh` and `chaos.sh` |
| `jq` | Optional; `heartbeat.sh` and `cleanup.sh` fall back to slower parsers |
| Both regions enabled | `us-east-1` and `us-west-2` |
| Quota headroom | One VPC and one Elastic IP free in each region |

Run `./scripts/preflight.sh` and it will check every one of these for you.

---

## Quick start

```bash
./scripts/preflight.sh                      # 1. verify the account is ready
./scripts/deploy.sh                         # 2. deploy both regions (~30 min)
./scripts/heartbeat.sh "$(sed -n 's/^PRIMARY_ALB_URL="\(.*\)"/\1/p' .workshop-config)"
```

Then, in a second terminal, break the primary region:

```bash
./scripts/chaos.sh break
```

Watch the heartbeat monitor. When you're done:

```bash
./scripts/chaos.sh restore
./scripts/cleanup.sh
```

---

## The application

`app.py` serves a single page that answers one question: **who is serving this
request right now?**

- The hero banner turns **deep green** for the primary region, **deep blue** for
  the secondary, and **red/amber** when the database is unreachable.
- Cards show the region, availability zone, instance id, database status
  (engine, round-trip latency, read-write vs read-only), process uptime, and the
  timestamp of the most recent failover the process has observed.
- The page refreshes every five seconds with a visible countdown, and animates
  the transition rather than flashing, so a projector audience can follow it.

On every status request the app writes a row into `health_check` and reads it
back, timing the pair. That round trip is what the latency figure reports. When
the write is rejected — which is what happens on a read replica — the app falls
back to a read-only probe and labels the database **Read-Only**. This is how the
secondary region announces that it is serving from a replica.

Instance identity comes from IMDSv2. If the metadata service is not reachable
(running on a laptop, in Docker, or anywhere outside EC2) the app switches to
**Local Development** mode with placeholder values instead of failing.

### Endpoints

| Path | Purpose |
|---|---|
| `/` | The dashboard |
| `/health` | ALB health check. `{"status","region","az","db","db_mode","uptime_seconds"}` |
| `/api/status` | Everything the UI renders, as JSON. `heartbeat.sh` parses this |

`/health` returns 200 whenever the process can serve, including when the database
is read-only or down. If it failed on database problems, the ALB would drain the
secondary region's instances at exactly the moment they are needed.

### Environment variables

| Variable | Purpose | Default |
|---|---|---|
| `DB_HOST` | Database endpoint | `localhost` |
| `DB_PORT` | Database port | `3306` |
| `DB_NAME` | Database name | `workshop` |
| `DB_USER` | Database username | `admin` |
| `DB_PASSWORD` | Database password | *(required)* |
| `DB_ENGINE` | `mysql` or `postgresql` | `mysql` |
| `PRIMARY_REGION` | Region treated as primary for the UI colour | `us-east-1` |
| `APP_PORT` | Port to serve on | `80` |
| `WORKSHOP_AUTHOR` | Name in the footer credit | `nyx - cajayon.nikko01@gmail.com` |
| `ESTIMATED_HOURLY_COST` | Footer cost display | `$0.18/hr` |

### Running it locally

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
APP_PORT=8080 DB_PASSWORD=unused python3 app.py
# http://127.0.0.1:8080 -- shows "Local Development" with the database degraded
```

With Docker:

```bash
docker build -t resilience-workshop .
docker run --rm -p 8080:80 -e APP_PORT=80 -e DB_PASSWORD=secret resilience-workshop
```

---

## Scripts

### `preflight.sh`

Read-only validation. Nothing is created or modified.

```bash
./scripts/preflight.sh
PROJECT_NAME=demo2 ./scripts/preflight.sh      # check a different name prefix
```

Checks the AWS CLI and credentials, that `PROJECT_NAME` is 22 characters or
fewer (AWS caps load balancer and target group names at 32, and the longest
name derived from it is the `<PROJECT_NAME>-secondary` load balancer),
EC2/CloudFormation/RDS permissions (using a
dry run), that both regions are enabled, VPC and Elastic IP quota headroom in
each region, that no stack from a previous run is in the way, and that
`GIT_REPO_URL` can actually be cloned anonymously. That last check matters most:
the Auto Scaling Group has no wait condition, so an unreachable repository still
produces a `CREATE_COMPLETE` stack whose ALB serves nothing but 503s. Pass the
same `GIT_REPO_URL` you intend to deploy with:

```bash
GIT_REPO_URL=https://github.com/Nik-1019/aws-multi-region-resilience-workshop.git ./scripts/preflight.sh
```

Prints a
PASS/FAIL table with a specific fix for every failure, then either **"Ready to
deploy!"** or **"Fix N issues before proceeding."** Exits non-zero on failure, so
it composes with `&&`.

### `deploy.sh`

```bash
./scripts/deploy.sh
PILOT_LIGHT_SIZE=0 ./scripts/deploy.sh         # true pilot light: no warm instances
GIT_REPO_URL=https://github.com/Nik-1019/aws-multi-region-resilience-workshop.git ./scripts/deploy.sh
```

Prompts for a database password (press Enter to generate a random 24-character
one), deploys `primary.yaml` and waits, reads the primary RDS ARN from the stack
outputs, deploys `secondary.yaml` with that ARN, waits again, then writes
`.workshop-config`.

Budget about 30 minutes end to end. The cross-region read replica is the slowest
resource by a wide margin.

### `heartbeat.sh`

```bash
./scripts/heartbeat.sh https://d111111abcdef8.cloudfront.net
INTERVAL=0.5 ./scripts/heartbeat.sh http://my-alb.us-east-1.elb.amazonaws.com
```

Polls `/api/status` once a second and prints a live table:

```
╔═══════════════════════════════════════════════════════════╗
║  HEARTBEAT MONITOR - Press Ctrl+C to stop                 ║
╠═══════════════════════════════════════════════════════════╣
║ [14:32:01] ✓ 200 │ us-east-1  │   45ms │ DB: Connected    ║
║ [14:32:02] ✓ 200 │ us-east-1  │   42ms │ DB: Connected    ║
║ [14:32:03] ✗ --- │ TIMEOUT    │    --- │ DB: ---          ║
║  >>> FAILOVER DETECTED - Recovery time: 2.1s <<<          ║
║     us-east-1 -> us-west-2                                ║
║ [14:32:04] ✓ 200 │ us-west-2  │   89ms │ DB: Connected    ║
╚═══════════════════════════════════════════════════════════╝
```

Green for `200`, red for errors, blue on the row where the region changed.
Ctrl+C prints a session summary: duration, total requests, success rate,
failovers detected, and fastest/average recovery time.

### `chaos.sh`

```bash
./scripts/chaos.sh status
./scripts/chaos.sh break        # asks "Are you sure...? (y/N)"
./scripts/chaos.sh restore
./scripts/chaos.sh break --yes  # skip the prompt for a scripted demo
```

`break` revokes the HTTP and HTTPS ingress rules on the primary ALB's security
group, which the internet experiences as a regional outage. `restore` puts them
back. `status` reports the rule state and probes the ALB so you can see what
clients actually get. The security group id comes from the primary stack's
outputs via `.workshop-config`; no resource is ever destroyed.

### `cleanup.sh`

```bash
./scripts/cleanup.sh
./scripts/cleanup.sh --yes
```

Deletes in reverse order, confirming each resource: CloudFront distribution
(disable, wait for the change to deploy, then delete), Route 53 health checks,
the secondary stack, then the primary stack. The order is not cosmetic — RDS
refuses to delete a database that still has a read replica attached.

If you create a CloudFront distribution or Route 53 health checks during the
workshop, add their ids to `.workshop-config` so cleanup picks them up:

```sh
CLOUDFRONT_DISTRIBUTION_ID="E1A2B3C4D5E6F7"
ROUTE53_HEALTH_CHECK_IDS="abcd1234-... efgh5678-..."   # space separated
```

---

## `.workshop-config`

Written by `deploy.sh` with mode `600`, read by `chaos.sh` and `cleanup.sh`. It
contains stack names, regions, ALB DNS names, security group ids, RDS endpoints,
the database password, and placeholders for the CloudFront and Route 53 ids you
add during the workshop. It is git-ignored — it holds a live credential.

---

## Cost estimate

Roughly **$0.18/hour**, dominated by the two NAT gateways.

| Resource | Qty | ~$/hr |
|---|---|---|
| NAT Gateway | 2 | 0.090 |
| RDS `db.t3.micro` (primary + replica) | 2 | 0.034 |
| Application Load Balancer | 2 | 0.045 |
| EC2 `t3.micro` | 2 | 0.021 |
| EBS + RDS storage | — | 0.006 |
| **Total** | | **≈ 0.196** |

A three-hour workshop costs well under a dollar. Leaving it running for a month
costs about $140 — which is why the footer nags you and why `cleanup.sh` exists.
Cross-region replication also incurs data transfer charges, negligible at this
scale.

---

## Troubleshooting

**The dashboard shows DEGRADED / the database is disconnected.**
Instances need a few minutes after the stack completes to clone the repo and
install dependencies. If it persists, connect with Session Manager (the instance
role includes it) and check `journalctl -u workshop -n 50` and
`/var/log/user-data.log`.

**Targets are unhealthy in the ALB target group.**
Almost always a bootstrap failure. `GitRepoURL` is the usual culprit: the default
is a placeholder, so pass your own fork's URL to `deploy.sh`. The instances have
no public IP and reach GitHub through the NAT gateway.

**The secondary stack fails on the read replica.**
The source database must have automated backups enabled — `primary.yaml` sets
`BackupRetentionPeriod: 1` for exactly this reason. Also confirm the ARN passed
as `SourceDBInstanceArn` is the full ARN, not the identifier, and that the
primary database reached `available` before the secondary deploy started.

**`chaos.sh` says "stack not found".**
`.workshop-config` is missing or points at a different stack. Re-run
`deploy.sh`, or set `WORKSHOP_CONFIG=/path/to/.workshop-config`.

**Deleting the primary stack fails.**
Delete the secondary stack first; RDS blocks deletion of a replication source.
`cleanup.sh` already does this in the right order.

**Stack creation fails with `AlreadyExists` or a quota error.**
Run `preflight.sh` — it catches conflicting stacks and exhausted VPC/EIP quotas
before you wait 30 minutes to discover them.

**The heartbeat shows the same region after `chaos.sh break`.**
Nothing is routing between the regions yet. Point `heartbeat.sh` at a CloudFront
distribution with origin failover, or at a Route 53 failover record — building
that is the workshop exercise. Pointed at an ALB directly, you will see timeouts
rather than a failover.

**Failover time never changes across runs.**
Recovery time is measured from the last good response to the first response from
the new region, so it is bounded below by the poll interval. Use
`INTERVAL=0.25` for finer resolution.

---

## Notes for facilitators

- The secondary region's application is intentionally backed by a read replica,
  so it renders **Read-Only**. Promoting the replica (`aws rds
  promote-read-replica`) flips it to **Read-Write** within a minute or two, and
  the app records that as a failover event — a good second act for the workshop.
- `PILOT_LIGHT_SIZE=0` gives a true pilot light: the secondary ALB returns 503
  until you scale the ASG out. This makes recovery time dramatically longer and
  makes the warm-standby trade-off concrete.
- Failover state lives in process memory, which is why gunicorn runs a single
  worker with eight threads: a second worker would answer some polls from a
  process that never observed the change, making the "Last Failover" card
  flicker. An instance replacement still resets it — persisting it properly
  would need a shared store the workshop deliberately doesn't have.

---

## License

MIT — see [LICENSE](LICENSE).

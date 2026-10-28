# Architecture

## One deployer, two hosts, three ways in

This repository is the only thing that configures the two servers (plan 023): **home**, a
dedicated PC on the owner's home LAN that runs only Home and what Home needs, over the tailnet
only; and **hetzner**, a Hetzner Cloud CAX server (Arm64) that runs the public portfolio and its
PostgreSQL behind Traefik, which only Cloudflare reaches. Each provisioning run and each release
names its host (`infra_host`), and a bundle holds only that host's stacks; the hosts share
nothing at run time. The application repositories (`portfolio`, `home`) are **build-only**:
their CI builds an image, pushes it to GHCR, and stops there. None of them can deploy, and none
of them knows how to reach a server.

```
              visitors                                    the owner's devices (tailnet)
                 │ HTTPS                                               │ HTTPS
                 ▼                                                     │
          Cloudflare edge (proxied A/AAAA, Full (strict))              │
                 │ HTTPS + Cloudflare's client certificate             │
┌────────────────▼──── hetzner (80/443 from Cloudflare only) ┐  ┌──────▼──── home (no inbound port) ───────────────────┐
│ edge-traefik ──▶ portfolio ──▶ postgresql                   │  │ home-tls ──▶ Home (home-server) ──▶ llama (GPU)       │
│ (roles/edge)  (stack/portfolio) (stack/database)            │  │           └▶ Beszel, Garage, SFTPGo (stack/media)    │
│ daily pg_dump ──▶ R2 (portfolio-backups); media in R2       │  │ media disk /srv/media, nightly backup /srv/backup    │
│ Watchtower; sshd :22 on tailscale0 only                     │  │ Watchtower; sshd :22 on tailscale0 only              │
└────────────────────────────▲────────────────────────────────┘  └───────────────────────▲──────────────────────────────┘
                             └─────────────── Tailscale (SSH, tcp 22) ──────────────────┘
          ┌───────────────────────────────────┴────────────────────────────────────┐
          │ provision.yml -e infra_host=… (owner's laptop, admin + sudo)            │
          │ Deploy workflow, host input → release bundle (deploy, forced command)   │
          └───────────────────────────── infra (this repo) ─────────────────────────┘

portfolio ─┐  build :latest → GHCR ┐   Watchtower (on each server) sees the new
home ──────┘  build :latest → GHCR ┘   digest → docker pull + recreate container
```

There are exactly three ways anything acts on a host, and one narrow request (home only):

| Who | How | Can do |
| --- | --- | --- |
| The owner | `admin` over the tailnet (or at the server's own console), sudo with a password | anything; runs `provision.yml` |
| The Deploy workflow | `deploy` over the tailnet, one key forced to `infra-deploy-gate` | `release` (a bundle on stdin) or `status`, nothing else |
| Watchtower | on each host, through a socket proxy, no login at all | pull a newer `:latest` of a labelled app container (`portfolio` on hetzner, `home-server` on home) and recreate it |
| Home (`home-server`) | an HMAC-signed file in `/run/home-power`, read by the host's `home-power.path` | ask for `poweroff` or `reboot`, at most once per 10 minutes, nothing else ([host.md](host.md#power-requests-from-home)) |

`deploy` is in no group (not `docker`), its `authorized_keys` is owned by root, and sudo
lets it run only `/usr/local/sbin/infra-apply release` and `… status`. So the release key
can replace app containers from a checked bundle, but cannot open a shell, copy files, or
run Docker directly. Provisioning holds no app secrets; releases hold no host access beyond
`infra-apply`.

The consequence to remember: **while an app follows `:latest`, pushing an image deploys
it.** There is no approval step between a merge in an app repo and that code serving
traffic, so the GHCR token's scope and who can push to those repositories are the real
boundary. A rollback pins an app to a digest, which pauses that for the pinned app until
`resume`.

## Outside the stacks: Snowflake and CI retirement

Tor's Snowflake proxy (`roles/snowflake`; [host notes](host.md#snowflake)) is provisioned
outside the release stacks. The current host-network deployment is fenced from private networks;
its planned isolation in its own Incus container is separate work.

The home `ci-runners` Incus container is **retired from the desired architecture** by owner
decision, 2026-10-19, and was removed on 2026-10-20 ([RUNBOOK section 13](../RUNBOOK.md#13-retire-the-home-ci-runners)). CI moves to
GitHub-hosted infrastructure; no replacement home runner or runner capacity expansion is planned.
Do not confuse this removal with the `tag:infra-ci` access used by the retained Deploy workflow.

## Provision and release

- **`provision.yml -e infra_host=<host>`** runs the roles `common`, `tailscale`, `docker`,
  `host`, `watchtower`, `autoheal` on both hosts, `gpu`, `quiet`, `beszel` and `snowflake` on
  home, `edge` on hetzner, then the SSH login policy. Facts about the hosts (`infra_hosts`:
  tailnet names and stacks; Ubuntu release, Docker major, reboot time, swap, published ports,
  Cloudflare's ranges, domains, app image repositories) are in `production.yml`. The first run
  bootstraps a fresh Ubuntu install over the LAN (home) or the public address (hetzner) as the
  installer's account; every later one runs as `admin` over the tailnet
  ([host.md](host.md#the-bootstrap)). See [host.md](host.md), [edge.md](edge.md),
  [agents.md](agents.md).
- **A release** is rendered on the GitHub runner by `release.yml` and `build-bundle.sh`, and
  applied on the host by `infra-apply`. See [deploying.md](deploying.md#releases).

## Stacks and their order

A stack is a directory under `stack/` holding a `docker-compose.yml` and the env templates
`release.yml` renders: on hetzner `database` and `portfolio` (and `stack/edge`, the template of
Traefik's TLS settings, which is not a stack), on home `ai`, `media` and `home`. Each is its own
Compose project with fixed project, container and volume names, so a release recreates
containers in place and never moves data. On a fresh host the first release creates the
volumes empty (`pgdata-v18` and the hardened stacks' volumes come from provisioning) and the
apps initialise them; nothing ever deletes one.

`infra-apply` brings them up **in this order**:

```
hetzner: database (--wait) → provision.sql → edge/tls.yml → portfolio
home:    ai → media → home
```

On hetzner the order is load-bearing, and the reason is a limitation of Compose: `depends_on`
is scoped to a single project, so nothing outside the `database` stack can declare a dependency
on PostgreSQL. By the time `portfolio` starts, PostgreSQL is healthy and `provision.sql` has
created its role and database, so its credentials work the first time it tries them, on a
brand-new host. After that, `restart: always` handles a database that goes away and comes back.
See [database.md](database.md#roles-and-databases).

On home, `home` follows `media`, whose `home-tls` routes to it; `home-tls` answers 502 for Home's
name for the seconds in between, and verify waits for both. `ai` comes before `home` too, so
llama-server is already answering on `home-llm` when home-server starts (Home's AI card would
otherwise say "Unavailable" for its first health check).

## Releases on the host

```
/opt/infra/
  releases/<UTC time>-<sha12>/   one directory per release: the unpacked bundle
    <stack>/ (edge/ on hetzner)  compose file and env files per stack
    release.env                  RELEASE_MODE=latest|pinned, RELEASE_COMMIT=<sha>
    running-images.env           the digest each app container ran when verified
    .verified                    present once the release passed every check
  current  → releases/<id>       the release the stacks run from
  previous → releases/<id>       the last verified release before it
```

`previous` only ever points at a verified release, and only `current` and `previous` are
kept. A release that fails after the app stacks changed stays `current` without `.verified`,
and the failure message names the last verified one. See
[RUNBOOK.md](../RUNBOOK.md#releases-status-rollback-resume).

## Env files

Each container reads its secrets from its own env file (`postgres.env`, `portfolio.env`,
`sftpgo.env`, …), declared with `env_file:`, where the value
passes through untouched. Home's image reads its secrets only from files, so its one-shot
`home-keys` reads `home-keys.env` and writes each value into a file in the `home-keys` volume
for `home-server` ([stacks.md](stacks.md#home)). Each stack's `.env` is read by Compose only for `${VAR}`
interpolation in the compose file, and holds image references, domains, uids and the model —
never a secret. One interpolated value comes from the host instead: `TAILSCALE_IP`, which
`infra-apply` exports from `/etc/infra/host.env` for every Compose call.

The split matters because a value Compose interpolates is subject to its syntax (a `$` is
eaten), and because a single `.env` injected wholesale would hand every container every
secret of its stack. `release.yml` refuses any value with a `$`, quote, backtick, backslash,
`#`, line break or edge space, which the env file format would rewrite, and `infra-apply`
refuses any env line that is not `KEY=value`.

## Networks

| Network | Created by | Members |
| --- | --- | --- |
| `edge` | `roles/host` (hetzner) | Traefik and the portfolio |
| `data` | `roles/host` (hetzner) | PostgreSQL and the portfolio (and the daily dump's rclone container, which needs the way out) |
| `home-llm` | `roles/host` (home), `--internal` | llama-server (`llama`, the `ai` stack) and Home's `home-server`, nothing else; no route out |
| `media` | `roles/host` (home) | `home`, `home-tls`, Beszel, Garage, SFTPGo (their tailnet ports, `home-tls`'s certificate), and `home-server` and `home-keys` of the `home` stack (`home-tls` reaches Home there; Home's mail goes out through it) |
| `edge-socket`, `watchtower-socket`, `autoheal-socket` | their compose projects, `internal: true` | one agent and its socket proxy each |

The stacks declare these networks `external: true`, and the compose guard refuses a release
that adds or creates any other network, or puts a container on a network that is not its own
(`ai`, `media`, `home`; `home-server` is the one container in two stacks' networks,
`media` and `home-llm`). They are created by provisioning so they exist before any stack
or the edge proxy starts.

## Public and tailnet-only

Two audiences, two ways in, and nothing else:

| Service | Who | Way in | Address |
| --- | --- | --- | --- |
| portfolio (`arbikullakshi.com`, `www.`) | anyone | Cloudflare → the hetzner host's Traefik (443, Cloudflare's client certificate) | the public hostnames |
| the portfolio's media | anyone | Cloudflare R2's custom domain | `media.arbikullakshi.com` |
| SSH | the owner (`admin`), the Deploy workflow (`deploy`) | Tailscale, tcp 22 | `infra-host`, `infra-hetzner` |
| Home (`stack/home`, `home-server`, behind `home-tls`) | the owner (the grant below; family members need one of their own) | Tailscale, tcp 443 (`http://infra-host/` on 80 sends the browser there) | `https://home.arbikullakshi.com/` |
| Beszel, the status dashboard (`stack/media`) | the owner | Tailscale, tcp 8090 | `http://infra-host:8090` |
| Garage, S3 storage (`stack/media`) | the owner | Tailscale, tcp 3900 | `http://infra-host:3900` (S3, path-style, region `garage`) |
| SFTPGo, the file manager on Garage's `files` bucket (`stack/media`) | the owner | Tailscale, tcp 8091 (WebDAV: tcp 443 through `home-tls`) | `http://infra-host:8091/web/client`, WebDAV at `https://home.arbikullakshi.com/dav` |
| llama-server (home), PostgreSQL (hetzner) | containers only | Docker networks (`home-llm`, `data`) | none on the host |

Home has the only https name, `home.arbikullakshi.com`, on a Let's Encrypt certificate for
that name alone that `home-tls` serves on the Tailscale address; a DNS-only record points it
there. The other services have no name (the `*.home` record was deleted in plan 023): they
answer at `http://infra-host:<port>`.

A tailnet-only service publishes its port on the host's **Tailscale IPv4 alone**
(`"${TAILSCALE_IP}:<port>:<port>"`, the address provisioning reads with `tailscale ip -4` into
`/etc/infra/host.env`), never `0.0.0.0` or the LAN address, and never through Cloudflare. The ports are an allowlist in five places that `ci/check_access.py` keeps equal: the
compose guard's and `ci/check_templates.py`'s `TAILNET_PORTS`, `infra-apply`'s and
`roles/host`'s `tailnet_ports`, and `ufw_allowed` (on `tailscale0` only). On the tailnet, the
Tailscale policy grants these ports to the owner (`autogroup:admin`) alone
([RUNBOOK.md](../RUNBOOK.md#4-tailscale)). Plain HTTP is fine there: WireGuard encrypts every
packet between the owner's devices and the server.

## No public ports

**Nothing on the home server is reachable from the internet, and nothing is reachable from the
LAN but SSH until the tailnet takes over. On the hetzner host only Cloudflare reaches Traefik's
80 and 443** ([edge.md](edge.md#only-cloudflare-reaches-traefik)). Several layers make that
true:

- No release container publishes a port but the tailnet-only ones, and those only on the
  Tailscale address: the compose guard refuses any other `ports:` (and any other form or
  address for those) in every release stack, `ci/check_templates.py` (rule 9) in every compose
  file but the hetzner edge's, `infra-apply` reads each binding back from Docker after the
  start, and provisioning reads back that every published port on the host is an allowlisted
  one (on hetzner: Traefik's 80 and 443, nothing else).
- ufw denies everything inbound except 22 and the tailnet-only ports on `tailscale0` (and LAN
  22 only until the first run over the tailnet), plus, on hetzner, 80 and 443 from Cloudflare's
  ranges.
- Docker's published ports bypass ufw (they are NAT rules), so `infra-firewall` hooks a chain
  `INFRA-PUBLIC` first in `DOCKER-USER` that drops every new connection from the public
  interface to a container (home: `public_ports` empty; hetzner: all but 80 and 443 from
  Cloudflare's IPv4 ranges), and second for every new
  connection to a published port (conntrack `DNAT`) that did not arrive on `tailscale0`. So a
  port bound wider by mistake is still unreachable from the LAN, Wi-Fi or anything but the
  tailnet.
- The home router forwards no port to the home server, and its public IP is not in DNS. The
  Hetzner Cloud Firewall admits only ICMP and Cloudflare on 80 and 443 to the hetzner host.

PostgreSQL publishes nothing and is reachable only from containers on `data`. See
[edge.md](edge.md#only-cloudflare-reaches-traefik) and [host.md](host.md#firewall).

## Host keys and inventory

Host keys are checked everywhere. `ansible.cfg` sets `host_key_checking = True`, so the
owner's laptop must already know the server's key (its fingerprint read at the server's own
console), and the Deploy workflow connects with `StrictHostKeyChecking=yes` against the
`SSH_KNOWN_HOSTS` secret. A reinstalled server gets a new key, and both must be updated on
purpose ([RUNBOOK.md](../RUNBOOK.md#5-first-provision-over-the-lan)).

The inventory names two hosts, each in a group of its own (`[home]` `infra-host`, `[hetzner]`
`infra-hetzner`), by their tailnet names; `inventory/hosts` is gitignored and
`inventory/hosts.example` is the committed template. Only a bootstrap run points one at its LAN
or public address. No address is committed, and the workflow only ever uses the
tailnet name.

# Deploying

Two paths touch each server, and they never share credentials. Both name the host: `home`
(Home and what it needs, tailnet only) or `hetzner` (the public portfolio and its database).

- **Provisioning** (`provision.yml -e infra_host=<host>`) runs from the owner's machine as
  `admin` with a sudo password, over the tailnet. It sets up the host, the edge proxy (hetzner)
  and the agents, and holds no app secrets. Run it when a role changes.
- **Releases** run from GitHub Actions (**Actions → Deploy → Run workflow**, input `host`). The
  runner renders that host's bundle and hands it to the host's `deploy` account, which can only
  run `release` or `status`. Run one when a secret, a file under `stack/` or `production.yml`
  changes. Not for routine image updates: Watchtower deploys those within about a minute of a
  push.

First-time setup of the home server is in [RUNBOOK.md](../RUNBOOK.md) (sections 2–9), of the
hetzner host in its section 15.

## Releases

The workflow ([`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml)) runs only from
`master`, in the `production` Environment, one run at a time per host. Its inputs:

| Input | Values |
| --- | --- |
| `host` | `hetzner` (default): the portfolio and its database; `home`: Home |
| `action` | `release` (default), `resume`, `rollback`, `status` |
| `target` | rollback only, the host's app image: `previous` (default), `current`, `sha256:<digest>`, or for the portfolio a 40-character commit sha (`latest` is refused: that is `resume`) |
| `dry_run` | rollback only: print the resolved pin and stop |

What each action does, and how to read `status`, is in
[RUNBOOK.md](../RUNBOOK.md#releases-status-rollback-resume). The steps of a `release`:

1. Refuse any branch but `master`, a malformed input, and a `SERVER_USER` of `root` or `admin`.
2. Join the tailnet as an ephemeral `tag:infra-ci` node (`TS_OAUTH_CLIENT_ID`,
   `TS_OAUTH_SECRET`), and pin the host's key from `SSH_KNOWN_HOSTS` under its tailnet name
   (`HETZNER_SSH_HOST` or `SERVER_SSH_HOST`; `StrictHostKeyChecking=yes`).
3. Write the Environment's values to a JSON extra-vars file, and run
   [`build-bundle.sh`](../build-bundle.sh) `--host <host>`: it refuses an unpinned third-party image, runs
   [`release.yml`](../release.yml) on the runner to render that host's bundle (its stacks
   only; the other host's secrets never reach it), writes `release.env`
   (`RELEASE_MODE=latest|pinned`, `RELEASE_COMMIT=<sha>`) and `manifest.sha256`, and packs a
   deterministic tgz. The extra-vars file is deleted right after.
4. `ssh deploy@<host> release < bundle.tgz`. The forced command
   (`infra-deploy-gate`) runs `sudo -n /usr/local/sbin/infra-apply release` and nothing else.
5. Last, on hetzner, after the host has verified and marked the release, `infra-apply` asks
   the public names through Cloudflare, from the host itself, for up to 5 minutes: `2xx` for the
   portfolio's health, `301` from `www.` to the apex, and `301` from `http://` to `https://`;
   it prints "Cloudflare serves …". It runs on the host, not on the runner, because Cloudflare's bot protection
   answers GitHub's data-centre addresses with `403`. A failure here leaves the release current
   and verified and names the Cloudflare-side cause; there is nothing to roll back.

A rollback first reads `status`, logs in to GHCR, and turns the inputs into digest pins with
[`release-images.sh`](../release-images.sh) `resolve <host> <target>`; `build-bundle.sh --pin` applies it.
`resume` is a `release`.

## Secrets and variables

All live in the GitHub **`production` Environment** on `somethim-home/infrastructure`, not in repository
secrets. Secrets are set with `gh secret set <NAME> --env production`, variables with
`gh variable set <NAME> --env production --body <value>`. This list matches the workflow's
`env` blocks; keep the two in step.

`release.yml` asserts the formats on the runner, before anything reaches the host. Every value
that lands in an env file must also be free of `$`, `"`, `'`, `` ` ``, `\`, `#`, line breaks and
leading or trailing spaces, which Compose would rewrite.

### Secrets

| Secret | Meaning |
| --- | --- |
| `GHCR_TOKEN` | GHCR token for `GHCR_USERNAME`, `[A-Za-z0-9_]+`. Needs `read:packages` for the portfolio (`somethim`) and Home (`somethim-home`) images. The host logs in with it on every release, and Watchtower reuses that login |
| `POSTGRES_SUPERUSER_PASSWORD` | (hetzner) The cluster's own administrator, `postgres`, owned by no application |
| `PORTFOLIO_DB_PASSWORD` | (hetzner) the portfolio's role |
| `PORTFOLIO_ADMIN_PASSWORD` | The password the portfolio's bootstrap gives its only operator account when that account does not exist yet. Changing it later does **not** change an existing account — do that in `/admin` |
| `PORTFOLIO_RESEND_API_KEY` | *(optional)* Outgoing mail. Without it, messages are still recorded and only the notification is skipped |
| `PORTFOLIO_GOOGLE_CLIENT_ID` / `PORTFOLIO_GOOGLE_CLIENT_SECRET` | *(optional)* Google Cloud Console OAuth client backing the Calendar integration that mints a Meet link per booking. Without them, "Connect Google Calendar" just fails with a clear error instead of the server refusing to start. Create a "Web application" OAuth client, enable the Calendar API, and register `https://arbikullakshi.com/api/google/callback` as an authorized redirect URI exactly |
| `PORTFOLIO_TOTP_ENCRYPTION_KEY` | Encrypts enrolled TOTP secrets at rest. **Rotating or losing it makes every already-enrolled TOTP secret permanently unreadable** — re-enrollment is the only recovery. Generate with `openssl rand -base64 32`, not the `-hex 24` used below — the app expects exactly 32 raw bytes, base64-encoded |
| `R2_ACCOUNT_ID` | (hetzner) The Cloudflare account ID (32 hex digits); the R2 endpoint is `https://<id>.r2.cloudflarestorage.com`. In `portfolio/portfolio.env` and `database/backup.env` |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | (hetzner) The portfolio's R2 key (32 and 64 hex digits): Object Read & Write on its two media buckets only. Only in `portfolio/portfolio.env` |
| `R2_BACKUP_ACCESS_KEY_ID` / `R2_BACKUP_SECRET_ACCESS_KEY` | (hetzner) A second R2 key, Object Read & Write on `portfolio-backups` only, for the daily database dump; must differ from the portfolio's. Only in `database/backup.env`, read by `infra-pg-backup`'s rclone container ([database.md](database.md#backups)) |
| `CF_ORIGIN_CERT` / `CF_ORIGIN_KEY` | (hetzner) The Cloudflare Origin CA certificate for `arbikullakshi.com` and `*.arbikullakshi.com` and its private key, PEM. Rendered only into `edge/tls.yml`, which `infra-apply` installs for the edge Traefik ([edge.md](edge.md#tls)) |
| `SSH_PRIVATE_KEY` | Private half of the CI deploy key ([RUNBOOK.md](../RUNBOOK.md#5-first-provision-over-the-lan)). The public half is committed at `roles/common/files/deploy_key.pub` and installed for `deploy` only |
| `SSH_KNOWN_HOSTS` | The hosts' verified key lines under their tailnet names, one per host: `infra-host ssh-ed25519 AAAA…` and `infra-hetzner ssh-ed25519 AAAA…` ([RUNBOOK.md](../RUNBOOK.md#5-first-provision-over-the-lan), [15](../RUNBOOK.md#15-hetzner-host)) |
| `TS_OAUTH_SECRET` | Secret of the Tailscale OAuth client (scope Auth Keys: write, tag `tag:infra-ci`) |
| `HOME_TLS_CF_DNS_TOKEN` | Cloudflare API token with Zone Read and DNS Edit on arbikullakshi.com only, for `home-tls`'s Let's Encrypt DNS-01 challenge ([RUNBOOK.md](../RUNBOOK.md#the-links-page)). Rendered only into `media/home-tls.env`, read only by `home-tls`. Rotating it changes nothing but the next renewal's credentials |
| `BESZEL_PASSWORD` | The owner's Beszel dashboard password (`openssl rand -hex 16`, at least 16 letters and digits). Creates the login on the hub's first start only (`media/beszel.env`, `beszel`); `beszel-pair` signs in with it (`media/beszel-pair.env`). Change it in the dashboard first, then here |
| `BESZEL_AGENT_TOKEN` | The token Beszel's agent presents (`openssl rand -hex 24`, at least 32 letters, digits and `-`). Rendered into `media/beszel-agent.env` and `media/beszel-pair.env` (which registers it as the owner's universal token) |
| `GARAGE_RPC_SECRET` | Garage's RPC secret (`openssl rand -hex 32`, exactly 64 hex digits). Only in `media/garage.env`, read by `garage` |
| `GARAGE_ADMIN_TOKEN` | Garage's admin API token (`openssl rand -hex 32`, at least 32 letters and digits). In `media/garage.env` and `media/garage-setup.env` |
| `GARAGE_OWNER_ACCESS_KEY_ID` / `GARAGE_OWNER_SECRET_KEY` | The owner's S3 key (`GK` + `openssl rand -hex 12`; `openssl rand -hex 32`), imported by `garage-setup` (`media/garage-setup.env`) and used by `sftpgo` (`media/sftpgo.env`) for the files bucket. Rotate both together: Garage never reuses a deleted key ID |
| `HOME_SECRET_KEY` | Home's key for the HMAC of client addresses (`openssl rand -base64 32`, base64 of 32 bytes). Only in `home/home-keys.env`; `home-keys` writes it to `/run/keys/secret_key` (0400) for `home-server` |
| `HOME_DATA_KEY` | Home's key that encrypts TOTP secrets, passkey data and the AI chats' titles and messages at rest (`openssl rand -base64 32`, and different from `HOME_SECRET_KEY`). **Losing or rotating it makes every enrolled second factor and every chat unreadable**; home-server then refuses to start until the owner resets them (`reset-owner`). Kept out of the backups: 1Password and this secret are its only copies |
| `HOME_RESEND_API_KEY` | The Resend API key Home sends its mail with (setup, sign-in and invite links), as the SMTP password of `smtp.resend.com:465` (user `resend`). Sending access is enough. The `From` domain must be verified in Resend |
| `HOME_POWER_KEY` | *(optional)* The key Home signs its power requests to the host with: a **copy** of the host's `/etc/infra/home-power.key`, which provisioning makes once and never prints ([RUNBOOK.md](../RUNBOOK.md#homes-power-control) copies it without showing it). Base64 of 32 bytes, different from `HOME_SECRET_KEY` and `HOME_DATA_KEY`. Only in `home/home-keys.env`; `home-keys` writes it to `/run/keys/power_key`. `infra-apply` refuses a release whose value is not the host's. Empty: Home has no power control ([host.md](host.md#power-requests-from-home)) |
| `HOME_TMDB_READ_TOKEN` | *(optional, set in production)* TMDB's **API Read Access Token** for Media's online details (themoviedb.org → Settings → API; the long JWT, `eyJ…` with two dots, not the 32-character API key, which a release refuses). Only in `home/home-keys.env`; `home-keys` writes it to `/run/keys/tmdb_read_token` and home-server gets `HOME_TMDB_READ_TOKEN_FILE`. Home sends it only as `Authorization: Bearer` to TMDB's API, never logs it. Empty: no token file, Media uses Wikidata only (no pictures) |
| `HOME_BESZEL_PASSWORD` | *(optional)* The password of the read-only Beszel user `production.yml`'s `home_beszel_user` names (at least 16 letters and digits), for Home's Status card. Read only when that user is set ([RUNBOOK.md](../RUNBOOK.md#home)) |
| `FILES_PASSWORD` | The owner's file manager (SFTPGo web client and WebDAV) password (`openssl rand -hex 16`, at least 16 letters and digits). Only in `media/sftpgo.env`, read by `sftpgo`, which reloads its user from it on every start |

A release asks only for its own host's secrets. The two database passwords must be at least 32
letters and digits (`[A-Za-z0-9]{32,}`) and different: they are written into `provision.sql`
and the DSN as literals. Generate them with `openssl rand -hex 24`.
`PORTFOLIO_TOTP_ENCRYPTION_KEY` must be base64 of 32 bytes (`[A-Za-z0-9+/]{43}=`). The R2 and
origin certificate formats are in their rows above. `HOME_TLS_CF_DNS_TOKEN` must be 40 or more letters, digits, `_` and `-`. The Beszel, Garage, file manager and Home secrets' formats are in their rows above; `HOME_RESEND_API_KEY` must be 16 or more letters, digits, `_` and `-`; `HOME_TMDB_READ_TOKEN`, when set, `eyJ` and three dot-separated base64url parts. [RUNBOOK.md](../RUNBOOK.md#7-the-production-environment) generates every
value. `WEBUI_SECRET_KEY`, `SEARXNG_SECRET`, `IMMICH_DB_PASSWORD` and `IMMICH_ADMIN_PASSWORD`
belonged to the apps retired on 2026-10-20 and are no longer read; they can be deleted from the
Environment ([stacks.md](stacks.md#retired-apps-2026-10-20)). So can `CF_TUNNEL_TOKEN`,
`PRIZM_DB_PASSWORD`, `HYPERNOVA_SESSION_SECRET` and `HYPERNOVA_ADMIN_PASSWORD`, read by nothing
since plan 023 ([RUNBOOK.md, 15](../RUNBOOK.md#15-hetzner-host), step 11).

### Variables

| Variable | Meaning |
| --- | --- |
| `GHCR_USERNAME` | The GHCR account `GHCR_TOKEN` belongs to, `[A-Za-z0-9-]+` |
| `TS_OAUTH_CLIENT_ID` | ID of the Tailscale OAuth client |
| `SERVER_SSH_HOST` | The home server's tailnet name, `infra-host` |
| `HETZNER_SSH_HOST` | The hetzner host's tailnet name, `infra-hetzner`. With `SERVER_SSH_HOST`, the only addresses the workflow SSHes to |
| `R2_PUBLIC_BUCKET` / `R2_PRIVATE_BUCKET` | (hetzner) The portfolio's two media buckets (portfolio plan 011), different names |
| `MEDIA_PUBLIC_BASE` | (hetzner) The public bucket's https base URL, `https://media.arbikullakshi.com` |
| `SERVER_USER` | *(optional)* The forced-command account; defaults to `deploy`. The workflow refuses `root` and `admin` |
| `PORTFOLIO_GOOGLE_CLIENT_ID` | *(optional)* The client ID half of the Google OAuth pair in the secrets table; a variable, not a secret |
| `HOME_OWNER_EMAIL` | Home's owner account: setup and recovery links only ever go to this address. A **repository** variable (`gh variable set HOME_OWNER_EMAIL --body <address>`, no `--env`), which the workflow reads as `vars.HOME_OWNER_EMAIL` like the Environment's. A release refuses to render without it. Changing it later does not move an existing owner account |

### Everything production needs, and where it lives

As of 2026-10-21 (`gh secret list --env production`, `gh variable list`), every secret the
Deploy workflow reads is set. A reinstall changes `SSH_KNOWN_HOSTS` and `HOME_POWER_KEY` and may
make the generated ones fresh ([deploy-home.md](deploy-home.md#5-the-secrets)). "1P" is the 1Password item; "infra" is the
**"infra production secrets"** item in the **"Home Server"** vault, one field per secret, named
like it. [deploy-home.md](deploy-home.md#5-the-secrets) sets the Home ones without printing them.

| Name | Kind | Needed | State | Generate | 1P |
| --- | --- | --- | --- | --- | --- |
| `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS` | secret | yes | set | RUNBOOK section 5 | the key file `~/.ssh/infra-deploy` |
| `TS_OAUTH_SECRET` / `TS_OAUTH_CLIENT_ID` | secret / variable | yes | set | Tailscale OAuth client, RUNBOOK section 4 | Tailscale |
| `SERVER_SSH_HOST`, `HETZNER_SSH_HOST`, `GHCR_USERNAME` | variable | yes | `HETZNER_SSH_HOST` new | `infra-host`, `infra-hetzner`; the GHCR account | – |
| `GHCR_TOKEN` | secret | yes | set | classic token, `read:packages` | "GHCR read token (infra)" |
| `HOME_TLS_CF_DNS_TOKEN` | secret | yes | set | Cloudflare API token, DNS Edit on the zone | "Cloudflare DNS token (home TLS)" |
| `POSTGRES_SUPERUSER_PASSWORD`, `PORTFOLIO_DB_PASSWORD` | secret | yes (hetzner) | set | `openssl rand -hex 24` each | none (nobody types them) |
| `PORTFOLIO_TOTP_ENCRYPTION_KEY` | secret | yes (hetzner) | set | `openssl rand -base64 32` | none (generated straight into GitHub) |
| `PORTFOLIO_ADMIN_PASSWORD` | secret | yes (hetzner) | set | `openssl rand -hex 16` | your password manager |
| `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BACKUP_ACCESS_KEY_ID`, `R2_BACKUP_SECRET_ACCESS_KEY` / `R2_PUBLIC_BUCKET`, `R2_PRIVATE_BUCKET`, `MEDIA_PUBLIC_BASE` | secret / variable | yes (hetzner) | **new** | Cloudflare R2, RUNBOOK section 15 step 5 | your password manager |
| `CF_ORIGIN_CERT`, `CF_ORIGIN_KEY` | secret | yes (hetzner) | **new** | Cloudflare Origin CA, RUNBOOK section 15 step 5 | your password manager |
| `CF_TUNNEL_TOKEN`, `PRIZM_DB_PASSWORD`, `HYPERNOVA_SESSION_SECRET`, `HYPERNOVA_ADMIN_PASSWORD` | secret | no (plan 023) | set, unused | – | delete (RUNBOOK section 15 step 11) |
| `PORTFOLIO_RESEND_API_KEY`, `PORTFOLIO_GOOGLE_CLIENT_SECRET` / `PORTFOLIO_GOOGLE_CLIENT_ID` | secret / variable | optional | set | Resend; Google Cloud OAuth client | where you keep them |
| `BESZEL_PASSWORD`, `BESZEL_AGENT_TOKEN` | secret | yes | set | `openssl rand -hex 16`, `-hex 24` | infra |
| `GARAGE_RPC_SECRET`, `GARAGE_ADMIN_TOKEN` | secret | yes | set | `openssl rand -hex 32` each | infra |
| `GARAGE_OWNER_ACCESS_KEY_ID`, `GARAGE_OWNER_SECRET_KEY` | secret | yes | set | `GK$(openssl rand -hex 12)`, `openssl rand -hex 32` | infra |
| `FILES_PASSWORD` | secret | yes | set | `openssl rand -hex 16` | infra |
| `HOME_OWNER_EMAIL` | **repository** variable | yes | set | your address | – |
| `HOME_SECRET_KEY` | secret | yes | set | `openssl rand -base64 32` | infra |
| `HOME_DATA_KEY` | secret | yes | set | `openssl rand -base64 32`, unlike the one above | infra (its only copy besides GitHub) |
| `HOME_RESEND_API_KEY` | secret | yes | set | Resend → API Keys, sending access, "infra Home" | infra |
| `HOME_TMDB_READ_TOKEN` | secret | optional (production sets it) | set | themoviedb.org → Settings → API → API Read Access Token | infra |
| `HOME_POWER_KEY` | secret | optional (production sets it) | set | a copy of the host's `/etc/infra/home-power.key` after provisioning `--tags host` | infra |
| `HOME_BESZEL_PASSWORD` | secret | optional | set (read only with `home_beszel_user`) | `openssl rand -hex 16`, with `home_beszel_user` | infra |
| `HF_TOKEN` | **not** a GitHub secret | for the Gemma download only | – | Hugging Face → Access Tokens, read, after accepting Gemma's licence | infra |
| `IMMICH_ADMIN_PASSWORD`, `IMMICH_DB_PASSWORD`, `SEARXNG_SECRET`, `WEBUI_SECRET_KEY` | secret | no (retired apps) | set, unused | – | delete ([deploy-home.md](deploy-home.md#12-retire-the-old)) |

The domains (including `home_domain`, Home's tailnet-only https name),
the app image repositories, the `ai`, `media` and `home-server` accounts' uids and gids, Home's AI
models (`home_ai_models`), Home's Files pool (`home_files_capacity`) and Beszel user (`home_beszel_user`) and
the disks' UUIDs are in [`production.yml`](../production.yml), not in the Environment.

## Where each secret lands

`release.yml` renders one env file per container, so each secret reaches only the container
that reads it. A hetzner bundle holds 11 files, a home bundle 18; on the host the compose files
and `release.env` are mode 0644, the rest 0600:

| Bundle file | Holds | Read by |
| --- | --- | --- |
| `database/postgres.env` | superuser password | `postgresql` |
| `database/provision.sql` | the role password | `psql`, run by `infra-apply` |
| `database/backup.env` | the R2 backup key | `infra-pg-backup`'s rclone container |
| `portfolio/portfolio.env` | DSN, TOTP key, admin password, mail, Google, the R2 key and buckets | `portfolio` |
| `edge/tls.yml` | the origin certificate and key, Cloudflare's origin-pull CA | `edge-traefik` (installed as `/opt/edge/dynamic/tls.yml`) |
| `media/home-tls.env` | `CF_DNS_API_TOKEN`, the Cloudflare DNS token for the `home.` certificate | `home-tls` |
| `media/beszel.env` | `BESZEL_HUB_USER_PASSWORD`, the dashboard login's password | `beszel` |
| `media/beszel-pair.env` | `OWNER_PASSWORD`, `AGENT_TOKEN` | `beszel-pair` |
| `media/beszel-agent.env` | `TOKEN`, the agent's token | `beszel-agent` |
| `media/garage.env` | `GARAGE_RPC_SECRET`, `GARAGE_ADMIN_TOKEN` | `garage` |
| `media/garage-setup.env` | `GARAGE_ADMIN_TOKEN`, `OWNER_ACCESS_KEY_ID`, `OWNER_SECRET_ACCESS_KEY` | `garage-setup` |
| `media/sftpgo.env` | `FILES_PASSWORD`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | `sftpgo` |
| `home/home-keys.env` | `HOME_SECRET_KEY`, `HOME_DATA_KEY`, `HOME_SMTP_PASSWORD` (the Resend key), `HOME_BESZEL_PASSWORD`, `HOME_POWER_KEY`, `HOME_TMDB_READ_TOKEN` | `home-keys`, which writes each into its own file in the `home-keys` volume |
| `home/home-server.env` | Home's settings and the owner's address; no secret, only the paths of the key files | `home-server` |
| `ghcr.env` | GHCR login | `infra-apply`'s `docker login` |
| `<stack>/.env` | image references, domains, the `ai`, `media` and `home-server` uids and gids (and the `media` gid home-server joins), llama-server's model files, the ACME contact and the dashboard's login name only | Compose interpolation |
| `release.env`, `manifest.sha256`, `<stack>/docker-compose.yml` | no secrets | `infra-apply` |

See [architecture.md](architecture.md#env-files) for why the `.env` files carry no secrets.

## What `infra-apply` checks, in order

[`roles/common/files/infra-apply`](../roles/common/files/infra-apply) refuses a bundle before
anything changes ("…; the running release is untouched") unless all of this holds:

1. It runs as root, `/etc/infra/host.env` names the host (`INFRA_HOST`, `home` or `hetzner`,
   which picks the stacks, files and checks below), the host's app image repository, its
   Tailscale IPv4 (`TAILSCALE_IP`, in `100.64.0.0/10`) and on home the `ai`, `media` and
   `home-server` accounts (`AI_USER`, `MEDIA_USER`, `HOME_USER`, never root); no other release
   or status holds the lock; and on hetzner `/opt/edge/docker-compose.yml` (Traefik, written by
   provisioning) exists.
2. The bundle is at most 1 MiB, a gzip tar of exactly that host's expected names (11 on hetzner,
   18 on home; a bundle for the other host is refused as unexpected entries), regular files
   only, each at most 256 KiB.
3. `manifest.sha256` lists exactly those files, and every checksum matches.
4. Every env file is `KEY=value` lines only; `ghcr.env` sets exactly `GHCR_USERNAME` and
   `GHCR_TOKEN`; on hetzner `database/backup.env` sets exactly rclone's four R2 settings and
   `edge/tls.yml` holds a certificate and the client-certificate rule; on home
   `media/home-tls.env` sets exactly `CF_DNS_API_TOKEN`, and each Beszel, Garage and SFTPGo env file
   and `home/home-keys.env` sets exactly its keys in the formats of the secrets above; `release.env` sets exactly
   `RELEASE_MODE` and `RELEASE_COMMIT`. A non-empty `HOME_POWER_KEY` is the host's own
   `/etc/infra/home-power.key` (compared, never printed).
5. Each app image is `<repo>:latest` in a `latest` release, or `<repo>:<tag>@sha256:<digest>`
   in a `pinned` one, for the repository `/etc/infra/host.env` names.
6. `docker compose config` of each stack passes
   [`infra-compose-guard`](../roles/common/files/infra-compose-guard): the stack's own project
   name, container names, volumes and existing networks only (and, where it says so, per
   container: `llama` only `home-llm`, `home-server` only `media`
   and `home-llm`, `home-keys` only `media`); no privileged settings, added
   capabilities, devices, host namespaces or Docker socket; no host port but the tailnet-only
   ones (`home` 80, `home-tls` 443, `beszel` 8090, `garage` 3900, `sftpgo` 8091), each
   written exactly `"${TAILSCALE_IP}:<port>:<port>"` and resolved to the address `host.env`
   names; no bind mount but Garage's `/srv/media/s3`, Home's `/srv/media/home-files`,
   `/run/home-power` (its power requests), `/srv/media/movies` and `/srv/media/shows` (at
   `/data/media/films` and `/data/media/series`) and the two folders Beszel's agent sizes disks
   through, each in its own container at its fixed path, read-only except Garage's objects and
   Home's four, `create_host_path: false`; a GPU reservation only for `llama`,
   `beszel-agent` and `home-server`, and only the whole NVIDIA GPU; no extra group but the `media`
   gid (`MEDIA_USER`) for `home-server`; only the stack's own env files, each read by
   its one container; in `ai`,
   `media` and `home`, every service is named after its container and runs as `AI_USER`,
   `MEDIA_USER` or `HOME_USER` with a `mem_limit`, `cap_drop: [ALL]` and `no-new-privileges`;
   third-party images pinned by digest; no routing or agent labels on the database, only
   `autoheal` on `ai` and `media`, and only Watchtower's and `autoheal` on `home`.
7. `docker login ghcr.io` with `ghcr.env`, and a pull of every image.

Then it installs the bundle as `/opt/infra/releases/<UTC time>-<sha12>`. On hetzner it starts
`database` with `--wait`, runs `provision.sql` over the local socket and installs `edge/tls.yml`
as `/opt/edge/dynamic/tls.yml`. It points `current` at the new release (and `previous` at the
last verified one), starts the other stacks (hetzner `portfolio`; home `ai`, `media` and `home`;
Compose gets `TAILSCALE_IP` from `host.env` for every call), and verifies: every container
running and healthy within 10 minutes, each up for at least 30 s without a restart, judged only
on a poll that listed every stack and inspected every listed container (one that Watchtower
recreated in between counts as not ready yet). Then, on hetzner: Traefik, asked on its `edge`
address by name, redirecting `http` to `https` and refusing an `https` client without
Cloudflare's certificate in the handshake ([edge.md](edge.md#verifying-it)). On home: `home-tls`,
asked by name on the Tailscale address with a trusted certificate, answering `200` for
`https://home.<domain>/healthz` (home-server behind it) and `/app/` (Home's web app, through
`home-tls` untouched), and `2xx`, `3xx`, `401` or `403` for each service name; the one-shots
`beszel-pair`, `garage-setup` and `home-keys` exited `0`; each tailnet-only port bound by Docker
to the Tailscale address and nothing else (`docker inspect` of its `PortBindings`). On both: no
refused call in any socket proxy's log. Only then does it record the running digests
(`running-images.env`), mark the release `.verified`, and print `RELEASE OK` (on hetzner after
the public check through Cloudflare). It keeps only `current` and `previous`.

## Provisioning

```bash
cp inventory/hosts.example inventory/hosts       # [home] infra-host, [hetzner] infra-hetzner
ansible-playbook -e infra_host=home -u admin --ask-become-pass provision.yml
ansible-playbook -e infra_host=hetzner -u admin --ask-become-pass provision.yml
```

`ansible.cfg` points at `inventory/hosts` and checks host keys. The very first run is
different (the installer's account, over the LAN or the public address):
[RUNBOOK.md](../RUNBOOK.md#5-first-provision-over-the-lan), [RUNBOOK.md, 15](../RUNBOOK.md#15-hetzner-host),
[host.md](host.md#the-bootstrap). On hetzner every run also fetches Cloudflare's ranges first
(`tasks/cloudflare-ips.yml`).

The checks in `tasks/provision-checks.yml` and the SSH policy at the end
(`roles/common/tasks/ssh_access.yml`) run on every invocation, whatever the tags. Each role has
a tag of its own:

| Tag | Runs |
| --- | --- |
| `common` | packages, ufw, the `admin` and `deploy` accounts and the release scripts, fail2ban, patching, NTP, journald |
| `tailscale` | the tailnet join and its checks |
| `docker` | the pinned Engine, `daemon.json` (with the `nvidia` runtime when `gpu_enabled`), the prune timer |
| `gpu` | (home) the NVIDIA server driver of `nvidia_driver_major`, the Container Toolkit, the read-back (`nvidia-smi`, `docker info`) |
| `host` | `/etc/infra/host.env` (with `INFRA_HOST` and the Tailscale IPv4), non-local binds, the `INFRA-PUBLIC` firewall and its tailnet hook (on hetzner 80 and 443 from Cloudflare's ranges), swap, no sleep; on hetzner the `edge` and `data` networks, the `pgdata-v18` volume and the daily dump timer (`infra-pg-backup`); on home Wake-on-LAN on `lan_interface` (netplan, read back with `ethtool`), encrypted DNS (systemd-resolved over TLS to Cloudflare and Quad9, the LAN's resolver ignored from the next boot; [host.md](host.md#encrypted-dns)), Home's power requests (the key `/etc/infra/home-power.key`, the `/run/home-power` tmpfs, `home-power.path` and its service), the `home-llm` (internal) and `media` networks, the `ai`, `media` and `home-server` accounts and their volumes (`llama-models` among them), the disks at `/srv/media` and `/srv/backup` (with Home's Files folder and the film and series library), the nightly backup timer, the published-port read-back |
| `quiet` | (home) quiet hours: `/usr/local/sbin/infra-quiet`, its settings, the start and end timers and the boot check, the state for this time of day, the read-back |
| `edge` / `watchtower` / `autoheal` | that compose project and its verify tasks (`edge`, hetzner only: Traefik publishes exactly 80 and 443, and `/opt/edge/.env` names Cloudflare's ranges) |

No tags runs everything, in that order.

## Adding a project

The release path is deliberately explicit about which stacks, files, containers and images
exist, so a new project touches several places:

1. `stack/<name>/docker-compose.yml`, `env.j2` (images and domains only) and one env template
   per container that needs secrets. Give the public container the Traefik labels (unique
   router names, entrypoint `websecure`, no TLS labels — see [edge.md](edge.md)),
   `com.centurylinklabs.watchtower.enable=true` and, with a healthcheck, `autoheal=true`.
2. `production.yml`: its domain and image repository; `roles/host/tasks/main.yml`: the
   repository's key in `/etc/infra/host.env`.
3. `production.yml`'s `infra_hosts.<host>.stacks`; `release.yml`: the template loop, the
   secret asserts and `env_file_values`.
4. `roles/common/files/infra-apply`, `host_layout` for that host: `stacks`, `bundle_files`,
   `env_files`, `secret_files`, `image_specs`, and `route_targets`; `roles/common/files/infra-compose-guard`: its `STACKS`
   entry (networks, volumes, container names, env files). A port for the tailnet only goes in
   `TAILNET_PORTS` (the guard and `ci/check_templates.py`), `tailnet_ports` (infra-apply and
   `roles/host/defaults/main.yml`) and `ufw_allowed`, and in the Tailscale policy's grant;
   `ci/check_access.py` (rule 5) fails until all of them agree. Never a public port: the public
   arrives through the hetzner host's Traefik.
5. `build-bundle.sh` (`image_keys`, `env_file_for`) and `release-images.sh` (`resolve`), and
   the workflow's rollback inputs, if it should roll back.
6. If it needs a database: a consumer in `stack/database/provision.sql.j2`, its password
   secret, and the `data` network on the container.
7. The new secrets in the workflow's `env` block and `jq` call, in this file, and in the
   `production` Environment; then the fixtures in `ci/release-scripts.sh`.
8. Proxied `A` and `AAAA` records for the domain to the hetzner host, at Cloudflare (covered by
   the `*.arbikullakshi.com` Origin CA certificate). Then provision (for `host.env`) and
   release.

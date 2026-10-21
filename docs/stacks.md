# The application stacks

What is peculiar about each one. The mechanics they share are in
[architecture.md](architecture.md).

## hypernova

One hostname serves both halves: the web app at `/` and the provider's API at `/api`,
split by router priority with a `stripprefix` middleware. See [edge.md](edge.md#priorities).

The provider connects to PostgreSQL with its own `prizm` role. The role name predates the
stack name — `prizm-lodge` was the original project — which is why the container names
(`prizm-provider`, `prizm-web`), the database, and the role all say `prizm` while the stack
says `hypernova`. Its secrets are in `provider.env`; `prizm-web` has none, and starts only
once the provider reports healthy.

Its only image tag is `:latest`, so a rollback names a digest (see
[RUNBOOK.md](../RUNBOOK.md#releases-status-rollback-resume)).

## portfolio

A Rust/Leptos server rather than a static site, so it carries state the other stacks do
not.

**The `portfolio-media` volume** holds uploads and the previews generated beside them. It
is the only application state outside PostgreSQL, and the `media` table is a ledger of
what is on it — the two must be backed up and restored together. See
[operations.md](operations.md#backups).

**A 180-second healthcheck grace.** The image carries the same probe, but before the
server starts, the entrypoint runs `/app/portfolio-seed migrate` (schema plus the
operator account) on every start. PostgreSQL lives in another stack, so the bootstrap
retries up to 20 times, 3 seconds apart, while the database comes up, and then applies
the migrations. The image's 15-second grace does not cover that, and without the override
autoheal could restart the container mid-bootstrap.

The entrypoint never seeds content: a seed run re-creates entries the admin has deleted,
so seeding is a manual step, run on purpose:

```bash
sudo docker exec portfolio /app/portfolio-seed
```

(The comment in the portfolio repo's `docker/entrypoint.sh` says
`docker compose exec web`; the service and container here are both named `portfolio`.)

**`WEBAUTHN_ORIGIN` is load-bearing.** Passkeys are bound to that exact origin. Change it
and every enrolled credential stops working — there is no migration path, only
re-enrolment. It is also the base for links in outgoing mail.

**`CLIENT_IP_SOURCE=Cloudflare`** reads Cloudflare's `CF-Connecting-IP` header instead of
selecting an address from `X-Forwarded-For`. Every public request reaches Traefik through the
Cloudflare Tunnel, where Cloudflare's edge sets that header to the visitor's address and
overwrites any value a client sent; nothing else can reach Traefik, so the header cannot be
forged ([edge.md](edge.md#client-addresses-and-forwarded-headers)). This keys the rate limiter
by the actual visitor instead of the proxy.

**Mail is optional.** Without `RESEND_API_KEY` the site still runs: contact messages and
comments are recorded and only the notifications are skipped and logged. The `From`
domain must be verified in Resend or every send is rejected.

**`TOTP_ENCRYPTION_KEY` is required for TOTP to work at all**, and `release.yml` refuses
a release without it (base64 of 32 bytes) before the host is even touched. It can never be
rotated casually: losing it makes every already-enrolled TOTP secret
permanently unreadable, with no fallback to plaintext — re-enrollment is the only
recovery.

The operator account is created by that bootstrap when it does not exist yet, with
`ADMIN_PASSWORD` (`PORTFOLIO_ADMIN_PASSWORD`), because the site has no signup path — without
it nobody can sign in. An existing account keeps its password whatever that secret says;
change it in `/admin`.

The portfolio publishes `:latest` and `:<full commit sha>` for every `master` build, so a
rollback can name a commit.

### The legacy site

`legacy.arbikullakshi.com` served a preserved Next.js portfolio from a second tag of the
same GHCR package. It was retired in August 2026: the DNS record, the container, the
image and the stack entry are all gone.

## ai

Ollama, for hypernova's provider and, later, the owner's own apps. Nothing in this stack is
public or published: it is not on `edge`, has no Traefik label, publishes no port and is never
behind the tunnel.

- **`ollama`** serves models on `11434` inside Docker only: it publishes no port. It joins
  `ai` (a plain bridge, which it needs to download models) and `llm`, an **internal** network
  (no route out) whose only other member is hypernova's `prizm-provider`. Its models and key
  live in the external `ollama-models` volume (`HOME=/ollama`), on the SSD.
- **`ollama-pull`** is a one-shot on every release, once Ollama is healthy: `ollama pull` for
  each model in `ollama_models` (`production.yml`, passed as `OLLAMA_MODELS`), in order. A model
  Ollama already has costs a manifest check. Only when every pull finished does it remove the
  models the list no longer names (`ollama rm`), so the volume does not keep models nobody uses;
  a failed pull removes nothing. A model pulled by hand is removed by the next release unless it
  is added to the list. It exits; verify does not wait for it (restart `"no"`).
  `sudo docker logs ollama-pull` shows each pull and removal.

To add a model: append it to `ollama_models` (`<model>:<tag>`, sized for 12 GB) and release.
The 14B models in the list are kept for the owner's own apps.

**Hardening.** Both containers run as the `ai` account (`ai_uid:ai_gid` in `production.yml`,
`2001:2001`, created by `roles/host` with no login), never root, with `cap_drop: [ALL]`,
`no-new-privileges`, a `mem_limit` and a read-only root filesystem (`ollama` with a tmpfs
`/tmp`); the
compose guard refuses the stack otherwise. `ollama-models` is created by provisioning with its
root owned by that account (0700) and mounted with `nocopy`, so Docker never copies an image's
root-owned directory over it.

**hypernova.** The provider reaches Ollama on `llm` (`OLLAMA_HOST=http://ollama:11434`,
`OLLAMA_MODEL` = `hypernova_ollama_model`, which must be in `ollama_models`;
`AI_DISABLED=false` in `provider.env`). `prizm-web` is not on `llm`; the guard refuses it there.

**The GPU.** The RTX 2060 has 12 GB of VRAM. Ollama keeps **one** model loaded
(`OLLAMA_MAX_LOADED_MODELS=1`, one request at a time) and unloads it after **2 minutes** idle
(`OLLAMA_KEEP_ALIVE=2m`), with flash attention and a q8_0 KV cache, so a 14B model and a 16k
context take about 11 GB. The first request after 2 idle minutes waits a few seconds while the
model loads again. `ollama` reserves the GPU (`deploy.resources.reservations.devices`, driver
`nvidia`, `count: all`, `capabilities: [gpu]`); the guard allows that only to `ollama` and
`beszel-agent` (in `media`). `gpu_enabled: false` makes the release refuse to render, since the
stack could not start.

**Memory.** `mem_limit`: `ollama` 8 GiB (the model sits in VRAM; RAM covers the runner and what
does not fit), `ollama-pull` 128 MiB.

**Updates.** The images are pinned `<tag>@sha256:<digest>` and carry no Watchtower label, on
purpose: Ollama changes its model format now and then and should not change unattended. Move it
with a re-pin and a release ([agents.md](agents.md#re-pinning-third-party-images)); `autoheal`
restarts it if it turns unhealthy.

## media

The Beszel status dashboard, Garage (S3 storage) with SFTPGo as its file manager, for the owner
alone, and `home-tls` in front of them and of Home ([home](#home)), each at its own https name
(`https://home.arbikullakshi.com/` for Home, `https://files.home.arbikullakshi.com`, …, from
`home_hosts` in `production.yml`: `files`, `status` and `s3`). `home`, the old links page, is
now only `http://infra-host/`, which sends the browser on to Home, and the page of other ways
into the files bucket (`/files.html`). Like `ai`, nothing here is
public: no `edge`, no label for the edge Traefik, never behind the tunnel. A laptop or phone on
Tailscale talks to the server directly (or through a relay when it must), WireGuard-encrypted.

| Container | Port, on the Tailscale address only | Bind mount | Its data (volume, SSD) |
| --- | --- | --- | --- |
| `home` | 80 | none | none (the redirect page and `/files.html` are `HOME_HTML` and `FILES_HTML` in the compose file, written to tmpfs and served by busybox `httpd`) |
| `home-tls` | 443 | none | `home-tls-acme` (`/acme`: the Let's Encrypt account and certificate) |
| `beszel` | 8090 | none | `beszel-data` (`/beszel_data`: the hub's database, history, alerts) |
| `beszel-pair` | none (one-shot) | none | writes the hub's public key into `beszel-agent-data` |
| `beszel-agent` | none | `/srv/media/.beszel` → `/extra-filesystems/media` and `/srv/backup` → `/extra-filesystems/backup`, read-only, for the disks' sizes only | `beszel-agent-data` (`/var/lib/beszel-agent`: its fingerprint, the hub's key) |
| `garage-config` | none (one-shot) | none | writes `garage.toml` into `garage-meta` |
| `garage` | 3900 (S3; admin 3903 and RPC 3901 on the `media` network only) | `/srv/media/s3` → `/data`, read-write (the objects) | `garage-meta` (`/meta`: the config and the SQLite metadata) |
| `garage-setup` | none (one-shot) | none | none (Garage's admin API) |
| `sftpgo` | 8091 (web client; WebDAV on 8092, `media` network only, through `home-tls` at `/dav`) | none (its files are the `files` bucket, over S3) | `sftpgo-data` (`/var/lib/sftpgo`: its SQLite database, share links) |

**`beszel`, `beszel-pair`, `beszel-agent`** (Beszel 0.21). The hub creates the owner's login on
its first start from `BESZEL_HUB_USER_EMAIL` (`status_owner_email`, `media/.env`) and
`BESZEL_HUB_USER_PASSWORD` (`beszel.env`, the `BESZEL_PASSWORD` secret), so there is no sign-up
page. After it is healthy, `beszel-pair` (curl) signs in as the owner, makes
`BESZEL_AGENT_TOKEN` the owner's permanent *universal token* and writes the hub's ed25519 public
key into the agent's volume; the agent starts only after that (`service_completed_successfully`),
dials `http://beszel:8090` with the token, checks the hub with the key (`KEY_FILE`) and is added
as the system `infra-host` on its first connection, then recognised by its fingerprint. The agent
uses the `beszel-agent-nvidia` image and the GPU reservation for NVML (the GPU's use, memory and
power), reads CPU, memory and temperatures from the host's `/proc` and `/sys`, the SSD from its
own root, and the media and backup disks through two bind mounts that show it nothing (an empty
root-owned folder, and the backup disk's root-only mountpoint). Container stats come through
`beszel-socket-proxy` (`roles/beszel`, on the internal `beszel-socket` network, the only other
network the agent joins): `GET` version, info, the container list and one container's stats,
nothing else, so the dashboard's container details and logs stay empty (inspect would show
every container's environment, secrets included). No host network, so no host network totals;
no SSH listener (`DISABLE_SSH`); no image update checks; no update checks in the hub.

**`garage-config`, `garage`, `garage-setup`** (Garage 2.4). Garage's image has no shell, so
`garage-config` (busybox) writes its configuration (`GARAGE_TOML` in the compose file: one
node, `replication_factor = 1`, SQLite metadata in `/meta/db`, S3 on 3900 with region
`garage`) into `garage-meta` before it starts; the RPC secret and admin token come from
`garage.env` as environment variables, never into a file. After Garage is healthy (`garage
status`), `garage-setup` (curl) uses the admin API: it assigns the node its layout role once,
imports the owner's key (`GARAGE_OWNER_ACCESS_KEY_ID` and `_SECRET_KEY`, `garage-setup.env`;
Garage never reuses a deleted key ID, so a new secret needs a new ID, and keys named `owner`
under another ID are deleted), creates the buckets in `GARAGE_BUCKETS` (`files`) and grants the
key read, write and owner on them. It prints no secret and fails the release
(`check_one_shots`) when anything is refused. The objects are on the media disk, the metadata on
the SSD (Garage recommends fast storage for it). Garage's own community web UI is not used (no
release in a year, and it would need the full admin token); `sftpgo` is the interface.

**`sftpgo`** (SFTPGo 2.7, the `-alpine` image) is the file manager on the `files` bucket: its
web client (`https://files.home.arbikullakshi.com/web/client`, the Files tile) uploads by drag and drop, makes
folders, renames, moves, deletes, previews, downloads and makes share links, and its WebDAV
server (8092, on the `media` network only) is published at `https://files.home.arbikullakshi.com/dav` (and, for older mounts, `https://home.arbikullakshi.com/dav`)
by `home-tls`, with the real certificate, so a laptop or phone mounts the bucket as a drive. Its
one user, `owner`, is code: at every start `OWNER_JSON_SH` (compose file) writes it to tmpfs and
SFTPGo loads it with `LOADDATA_MODE=0` (added, or updated to match), with the password from
`FILES_PASSWORD` and an S3 filesystem (`http://garage:3900`, region `garage`, bucket `files`,
path-style) with the owner's key (`sftpgo.env`). SFTPGo sends every sign-in to its admin setup
page until an admin exists, so the same file adds one with a fresh random password at each
start; the admin web UI and the REST API are off, so nobody can use it. SFTP and FTP are off. It
starts after `garage-setup` has created the bucket and imported the key.

Its file list behaves like Google Drive: `FILES_UI_SH` (compose file) copies the image's templates
to `/tmp/templates` (SFTPGo serves them from there, `SFTPGO_HTTPD__TEMPLATES_PATH`) and inserts
`DRIVE_JS` into `webclient/files.html` right after its `extra_js` block opens. The script adds
click-to-select, double-click (tap on a phone) to open, a full-screen preview for PDF, images,
video, audio and text with previous/next and download, a right-click menu that drives SFTPGo's own
rename, move, share and delete, and a download button on each row in place of the eye. Images,
video, audio and text load from the normal file URL (an `<img>` or `<video>` ignores its
`Content-Disposition: attachment`); PDFs use SFTPGo's own `viewpdf` page. It patches only the
`files.html` whose sha256 is `FILES_HTML_SHA256`; on any other it logs a warning and serves the
stock page, and `ci/files-ui.sh` fails the checks when the pinned image's page and that hash part,
when `DRIVE_JS` holds a dollar sign (Compose would read it) or double braces (SFTPGo's template
engine would), or when it does not parse.

Sessions: `SFTPGO_HTTPD__COOKIE_LIFETIME=720` is SFTPGo's maximum (it ignores more than 720
minutes), renewed once half has passed, so a sign-in lasts 12 hours from the last visit. The
cookie has `Expires`/`Max-Age` (it outlives the browser), `HttpOnly`, `SameSite=Strict`, and
`Secure` under https: `PROXY_ALLOWED` (the private ranges Docker networks use) makes SFTPGo trust
`home-tls`'s `X-Forwarded-Proto`; a tailnet client on 8091 keeps its 100.x address and is not
trusted. `SFTPGO_HTTPD__SIGNING_PASSPHRASE_FILE` is `web-signing.key` in `sftpgo-data`, made once
by `OWNER_JSON_SH`, so a restart or release no longer signs everyone out.

**`home-tls`** is a second Traefik (the edge image and digest) that terminates TLS for
`home.arbikullakshi.com` and every `<label>.home.arbikullakshi.com` and routes each name to its
container over `media`: the apex to `home-server:8080` (stack `home`; `/dav` to `sftpgo:8092`
and `/files.html` to `home:80`), and `files.` (with `/dav`), `status.` and `s3.` to SFTPGo,
Beszel and Garage. The entrypoint has no read or write timeout (idle
connections close after 10 minutes) and no buffering or compression, so multi-gigabyte uploads
and websockets pass. Beszel, which knows its own address, is told it: its `APP_URL` is the https
name. It has no Docker socket: its
static and dynamic configuration are `HOME_TLS_STATIC` and `HOME_TLS_DYNAMIC` in the compose file,
written to tmpfs at start. One certificate, for `home.` and `*.home.`, comes from Let's Encrypt by DNS-01 through
Cloudflare's API with `CF_DNS_API_TOKEN` from `home-tls.env` (the `HOME_TLS_CF_DNS_TOKEN`
secret, Zone Read and DNS Edit on the zone only), which no other
container reads; nothing on the internet has to reach the host. Port 443 needs no capability
(Docker lets any user bind low ports inside the container's network namespace), so it runs as
the media account like the rest. `infra-apply` verify asks every name over https pinned to the
Tailscale address and requires a trusted certificate: 200 from home-server's `/healthz` on the
apex, and 2xx, 3xx, 401 or 403 from each service (a 404 is a missing route, a 502 a container `home-tls` cannot reach).

**The media disk** is the internal 1 TB HDD at `/srv/media` ([host.md](host.md#disks)); the
apps' own databases are in volumes on the SSD. Garage mounts only `/srv/media/s3` and the
Beszel agent only the empty `/srv/media/.beszel`, each at a fixed path,
`bind.create_host_path: false`, and the compose guard allows no other bind mount in any stack
but Home's `/srv/media/home-files` and `/run/home-power` ([home](#home)):
not `/srv/media` as a whole, not a folder at another path, not read-write where it says
read-only. With the media disk missing the folders do not exist (the mountpoint stays empty and
immutable), so the containers fail to start instead of writing to the SSD; Docker also starts
only after the disk's mount unit at boot.

**Hardening.** Every container runs as the `media` account (`media_uid:media_gid`,
`2000:2000`), which owns the folders on the media disk; `cap_drop: [ALL]`, `no-new-privileges`,
a `mem_limit`, a read-only root filesystem; the guard refuses the stack otherwise. Each secret is
in its own env file, read by its one container (`home-tls.env`, `beszel.env`, `beszel-pair.env`,
`beszel-agent.env`, `garage.env`, `garage-setup.env`, `sftpgo.env`); `media/.env` holds only the
uid and gid, Home's https name, each service's https name (`HOST_*`), the ACME contact and
the dashboard's login name.

**GPU.** `beszel-agent` reserves the GPU to read its state through NVML; it uses none of the
GPU's memory. The guard allows a GPU reservation to exactly `ollama` and `beszel-agent`.

**Memory.** `garage` 512 MiB, `sftpgo` 256 MiB, `beszel` 192 MiB, `beszel-agent` 128 MiB,
`home-tls` 128 MiB, `home` 32 MiB, the one-shots 16–32 MiB (and `home-server` 384 MiB in the
`home` stack). With `ollama` at 8 GiB, the stacks
fit a 16 GB machine with the swap file as a buffer; give Ollama less if the server has less RAM.

**Updates and backups.** Pinned images, no Watchtower label, as in `ai`. Re-pin, read the
release notes, make sure last night's backup ran, then release. The nightly backup copies each
app's volumes (Beszel's history and Garage's metadata included, each app stopped only while its
own data is copied) and mirrors Garage's `s3` in the same stop as its metadata, so the two match
([operations.md](operations.md#backups)).

## home

Home, the owner's own app (`ghcr.io/somethim-home/home-server`, built by the `somethim-home/home`
repository), over the tailnet only: its web pages, sign-in
(`/setup`, `/sign-in`, `/auth/…`), the dashboard API and Home Files (`/api/files`), the
family's end-to-end encrypted storage. The Tailscale policy grants 443 to the owner's devices
alone (`autogroup:admin`); a family member needs a grant of their own. It took over `https://home.arbikullakshi.com/` from the
links page. Its own stack rather than a service in `media`: it is an app image that follows
`:latest` with Watchtower and rolls back by digest like the portfolio, while `media` holds
pinned third-party images that never auto-update, and it runs as its image's account (65532),
not the media account.

| Container | Port | Bind mount | Its data (volume, SSD) |
| --- | --- | --- | --- |
| `home-keys` | none (one-shot) | none | writes the key and password files into `home-keys` |
| `home-server` | none: `home-tls` reaches it on `media`, port 8080 | `/srv/media/home-files` → `/files`, read-write (Home Files' ciphertext); `/run/home-power` → `/run/power`, read-write (power requests to the host) | `home-data` (`/data`: the SQLite database `home.db` and its WAL files); `home-keys` read-only at `/run/keys` |

**Networks.** `home-server` and `home-keys` join `media` alone (the compose guard refuses any
other): `home-tls` reaches `home-server` there, and so would `beszel:8090` for the Status card.
`media` is a plain bridge, which is also how `home-server` reaches `smtp.resend.com:465`. No
port is published, no edge or data network, no Traefik label: nothing public.

**Keys and mail.** The image (`FROM scratch`, no shell) reads its keys and passwords only from
files (`HOME_SECRET_KEY_FILE`, `HOME_DATA_KEY_FILE`, `HOME_SMTP_PASSWORD_FILE`,
`HOME_BESZEL_PASSWORD_FILE`, `HOME_POWER_KEY_FILE`), and the bundle's files are root's, 0600, and cannot be bind-mounted
(the release directory changes every time). So `home-keys` (busybox, as 65532, read-only, no
capability) runs on every release, reads `home-keys.env` (the only container that does) and
writes each value into its own file in the `home-keys` volume, 0400, replacing it atomically; an
empty value removes its file. `home-server` mounts that volume read-only and starts only after
`home-keys` exited 0 (`service_completed_successfully`), and `check_one_shots` fails a release
in which it did not. `home-server.env` holds Home's settings and the owner's address, never a
secret. The volume is not backed up: the release writes it again from the secrets, and
`HOME_DATA_KEY` stays out of the database's backups as Home asks.

Mail goes through Resend's SMTP: `smtp.resend.com`, implicit TLS on 465, user `resend`, the
password `HOME_RESEND_API_KEY`, from `Home <home@arbikullakshi.com>` (Resend must have that
domain verified).

**Settings** (`home-server.env`): `HOME_PUBLIC_ORIGIN=https://home.arbikullakshi.com` (passkeys
are bound to its host: changing it means re-enrolling them), `HOME_OWNER_EMAIL` from the
`HOME_OWNER_EMAIL` repository variable (setup links only go there), `HOME_DATABASE_PATH=/data/home.db`,
`HOME_TRUST_FORWARDED_FOR=1` (the client address is the last `X-Forwarded-For` entry, which
`home-tls` sets; it accepts none from clients), `HOME_FILES_ROOT=/files` and
`HOME_FILES_CAPACITY` from `home_files_capacity`.

**Home Files' pool.** `home_files_capacity` (`production.yml`, `600G` by default) is the storage
Files hands out as allocations. It is set explicitly because the media disk (1 TB) also holds
Garage's objects and the retired apps' kept folders: Home's own default, the disk's free space
at start, would promise space that others use. The folder holds only age-encrypted files and
the server's records; `home-server` must be its only writer.

**Power control.** With the `HOME_POWER_KEY` secret set (a copy of the host's
`/etc/infra/home-power.key`), `home-keys` writes it to `/run/keys/power_key` and
`home-server.env` sets `HOME_POWER_DIR=/run/power` and `HOME_POWER_KEY_FILE=/run/keys/power_key`:
Home may then ask the host for a poweroff or reboot by writing one HMAC-signed request into
`/run/power`, the host's `/run/home-power` (a 64 KiB tmpfs of its own, which the compose guard
binds into `home-server` alone). The host checks it and runs `systemctl poweroff` or `reboot`,
nothing else, at most once per 10 minutes. The request format and every check are in
[host.md](host.md#power-requests-from-home). Without the secret, `HOME_POWER_DIR` is empty and
Home offers no power control. A release refuses a `HOME_POWER_KEY` that is not the host's.

**Status card.** `HOME_BESZEL_URL` stays empty, so Home shows no Status card, until
`production.yml` names a read-only Beszel user in `home_beszel_user` and its password is the
`HOME_BESZEL_PASSWORD` secret; then it is `http://beszel:8090`. Creating that user is a manual
step in Beszel's admin pages ([RUNBOOK.md](../RUNBOOK.md#home)).

**Hardening.** Both containers run as `65532:65532` (`home_uid`/`home_gid`, the `home-server`
account `roles/host` creates and `/etc/infra/host.env` names as `HOME_USER`), with a read-only
root filesystem (a tmpfs `/tmp` for `home-server`), `cap_drop: [ALL]`, `no-new-privileges` and
a `mem_limit` (`home-server` 384 MiB, `home-keys` 16 MiB); the guard refuses the stack otherwise.
`home-data` and `home-keys` are created by provisioning, owned by 65532 (0700), and mounted
with `nocopy`. The healthcheck is the image's own `/home-server healthcheck`.

**Updates and rollback.** `home-server` carries the Watchtower and `autoheal` labels: a new
`:latest` is deployed within about a minute of the push, like the portfolio. Home publishes only
`:latest`, so the Deploy workflow's `home` rollback input takes `previous`, `current`, `latest`
or a digest.

**Backups.** The nightly backup stops `home-server` only while it copies `home-data` and
`/srv/media/home-files` into the same snapshot (SQLite must not change mid-copy, and the Files
records must match the database), then starts it again; Home is unreachable for those minutes.
The image has no shell, so `sqlite3 .backup` is not an option. `home-keys` is not copied.
Watchtower revives stopped labelled containers, so an update published in that window could
start `home-server` again mid-copy.

**Recovery.** `sudo docker exec home-server /home-server reset-owner` removes the owner's
password, factors and sessions so setup runs again ([RUNBOOK.md](../RUNBOOK.md#home)).

## Retired apps (2026-10-20)

Immich (`immich-server`, `immich-machine-learning`, `immich-postgres`, `immich-valkey`,
`immich-admin`), the media engine (the container `jellyfin`), Audiobookshelf, Kavita,
Open WebUI with `webui-presets`, SearXNG, and ComfyUI with `comfyui-fetch` were removed from the
stacks on 2026-10-20. The owner's own apps will replace them. Their `home_hosts` names
(`ai`, `photos`, `jellyfin`, `audiobooks`, `books`) and their secrets (`WEBUI_SECRET_KEY`,
`SEARXNG_SECRET`, `IMMICH_DB_PASSWORD`, `IMMICH_ADMIN_PASSWORD`) are no longer used; the owner
may delete those secrets from the GitHub `production` environment and 1Password. Provisioning
deletes their ufw rules (ports 2283, 5000, 8080, 8096 and 13378, `ufw_retired`); the Tailscale
policy may still grant those ports, which the owner can remove.

Their data is kept until the owner has audited it:

- **Volumes**, still created by provisioning: `open-webui-data`, `comfyui-data`,
  `jellyfin-config`, `jellyfin-cache`, `audiobookshelf-config`, `audiobookshelf-metadata`,
  `kavita-config`, `immich-pgdata` and `immich-ml-cache`. The nightly backup still copies
  `open-webui-data`, `jellyfin-config`, `audiobookshelf-config`, `audiobookshelf-metadata`,
  `kavita-config` and `immich-pgdata` (now as a stopped data folder instead of a database
  dump); `comfyui-data`, `jellyfin-cache` and `immich-ml-cache` hold downloads and caches and
  were never copied.
- **Library folders** under `/srv/media`: `shows`, `movies`, `audiobooks`, `podcasts`, `books`
  and `photos`, still created by provisioning. The backup still mirrors `audiobooks`, `books`,
  `podcasts` and `photos`; `shows` and `movies` were never copied.

Nothing deletes them: no stack mounts them any more, and removing them is a manual decision.

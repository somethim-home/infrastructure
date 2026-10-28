# Runbook

The owner's steps for the two production hosts (plan 023, 2026-10-28):

- **home** (`infra-host`): a dedicated PC at home, on the home LAN behind a consumer router.
  It runs only Home and what Home needs (`ai`, `media`, `home`), over the tailnet only; nothing
  on it is reachable from the internet. Sections 1 to 14 are about it.
- **hetzner** (`infra-hetzner`): a small Hetzner Cloud server (CAX, Arm64, Nuremberg) that runs
  the public portfolio and its PostgreSQL behind Traefik, which only Cloudflare reaches. Its
  setup and the move of the portfolio from the home server are
  [section 15, Hetzner host](#15-hetzner-host).

SSH to either works only over **Tailscale**. Every provisioning run and every release names its
host: `ansible-playbook -e infra_host=home|hetzner …`, and the Deploy workflow's `host` input.
[`README.md`](README.md) and [`docs/`](docs/README.md) explain how the pieces work; this file
only says what to do, in order. Every step that needs your accounts or your hands is marked
**Owner action**.

The values below are the ones in [`production.yml`](production.yml) and
[`roles/common/defaults/main.yml`](roles/common/defaults/main.yml): the tailnet names
`infra-host` and `infra-hetzner`, the tags `tag:infra-server` and `tag:infra-ci`, the accounts
`admin` and `deploy`, the domains `arbikullakshi.com` and `www.arbikullakshi.com`. If you
change one, change that file first (through `master`) and use your value throughout. `192.168.1.50` stands for the server's LAN address and `setup`
for the account the Ubuntu installer creates; use yours.

| Section | Where you are |
| --- | --- |
| [1. What you need](#1-what-you-need) | anywhere |
| [2. BIOS](#2-bios) | at the server, keyboard and monitor |
| [3. Install Ubuntu Server](#3-install-ubuntu-server) | at the server |
| [4. Tailscale](#4-tailscale) | Tailscale admin console |
| [5. First provision over the LAN](#5-first-provision-over-the-lan) | your laptop, on the home LAN |
| [6. Cloudflare Tunnel (retired)](#6-cloudflare-tunnel-retired) | nothing to do |
| [7. The production Environment](#7-the-production-environment) | GitHub (`gh`) |
| [8. Second provision over the tailnet](#8-second-provision-over-the-tailnet) | your laptop |
| [9. First release](#9-first-release) | GitHub Actions |
| [10. DNS switch-over (2026-10-15, done)](#10-dns-switch-over-2026-10-15-done) | nothing to do |
| [11. Day-2 operations](#11-day-2-operations) | from then on |
| [12. GPU, AI and media](#12-gpu-ai-and-media) | the server, Tailscale, GitHub, your devices |
| [15. Hetzner host](#15-hetzner-host) | Hetzner console, Tailscale, Cloudflare, GitHub, your laptop |

Restoring anything from the backup disk is in
[Restoring from the backup disk](#restoring-from-the-backup-disk) (section 11).

**Reinstalling the server from a blank machine** (a fresh OS, no users, no data, with the media
and backup disks kept) and bringing everything live, Home included (its web app, Files, Media,
Books, AI, live updates and power control, and the host's encrypted DNS), is one ordered
checklist of its own: [docs/deploy-home.md](docs/deploy-home.md). It links to the sections below
in the order a reinstall needs them.

Tailscale (4) comes before the first provision (5) because that run joins the server to the
tailnet and asks for the auth key made in 4.

## 1. What you need

**Owner action.**

- The server: a dedicated PC with wired Ethernet to the router (Wi-Fi works but is not
  recommended for a server), a USB stick of at least 4 GB, and a keyboard and monitor. The
  keyboard and monitor are the backstop for every lockout below
  ([Locked out](#locked-out)): the local console goes through neither sshd nor the tailnet.
- Your laptop, on the same LAN for section 5, with: `ansible-core`, `ssh`, `ssh-copy-id`,
  `ssh-keygen`, `ssh-keyscan`, `nc`, `openssl`, `gh` (logged in to `somethim-home/infrastructure`), `cf`
  (logged in to the Cloudflare account that holds `arbikullakshi.com`), and a checkout of
  `master`. The laptop must also be on the tailnet with MagicDNS on, so `infra-host`
  resolves.
- Admin access to the Tailscale tailnet, the Cloudflare account and the GitHub repository.
- The router's admin page, to give the server a fixed DHCP lease. The router forwards **no**
  port to the server; remove any forward that points at it.

## 2. BIOS

**Owner action**, at the server. Enter the firmware setup (usually `Del`, `F2` or `F10` at
power-on). Names differ per vendor:

1. **Restore on AC power loss** (also "AC Back", "After Power Failure", "Power On After
   Power Fail"): **Power On** (or **Last State**). The server then comes back by itself after
   a power cut. On this Gigabyte board: Settings → Platform Power → **AC BACK → Always On**.
2. **ErP** (also "EuP", "Deep Sleep"): **Disabled**. With it on, the board cuts standby power
   to the network card when the server is off, so Wake-on-LAN cannot work, and on some boards
   it also stops power-on after a power cut. Gigabyte: Settings → Platform Power → **ErP →
   Disabled**.
3. **Wake on LAN** (also "Resume by PCI-E Device", "Power On By PCI-E"): **Enabled**.
   Gigabyte: Settings → Platform Power → **Wake on LAN → Enabled**. A magic packet from another
   device on the LAN can then switch the server on after a shutdown from Home or `sudo
   poweroff` ([Wake-on-LAN](#wake-on-lan) tests it).
4. Boot order: the USB stick first for the install, the internal disk first afterwards.
5. Leave Secure Boot as it is (Ubuntu boots with it).

Provisioning makes sure the running system never sleeps (all sleep targets masked, lid and
sleep keys ignored) and that the network card listens for the magic packet (`Wake-on: g`,
[docs/host.md](docs/host.md#wake-on-lan)); the firmware settings are the part it cannot do.

## 3. Install Ubuntu Server

**Owner action.**

1. On the laptop, download Ubuntu Server 26.04 LTS (amd64) from
   <https://ubuntu.com/download/server> together with its `SHA256SUMS`, check it, and write it
   to the USB stick (replace `/dev/sdX` with the stick, `lsblk` shows it; everything on it is
   erased):

   ```bash
   sha256sum --check --ignore-missing SHA256SUMS
   sudo dd if=ubuntu-26.04-live-server-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync
   ```

2. Boot the server from the stick and choose, in the installer:
   - **Type of install**: Ubuntu Server (not minimized).
   - **Network**: the wired interface on DHCP. Note its MAC address and the address it gets.
   - **Storage**: use the entire disk, with LVM. On the summary screen, edit `ubuntu-lv` and
     set its size to the maximum: the installer leaves most of a large disk unallocated
     otherwise.
   - **Profile**: your name; server name `infra-host`; username **`setup`** (anything but
     `admin`, `deploy` or `root`: provisioning creates `admin` and `deploy` itself and removes
     this account once `admin` works); a strong password, kept in your password manager until
     section 8.
   - **Ubuntu Pro**: skip.
   - **SSH**: **Install OpenSSH server**: yes. Allow password authentication over SSH: yes (it
     is only for `ssh-copy-id` in section 5; provisioning turns it off). Importing your key
     from GitHub here works too, and replaces the `ssh-copy-id` step.
   - **Featured server snaps**: none. In particular **not** `docker`: provisioning installs
     Docker from Docker's own apt repository, pinned.
3. Reboot, remove the stick, and log in at the console as `setup`. **Confirm the host's
   facts** `production.yml` relies on, and write the fingerprint down; you compare against it
   twice:

   | Command | Expect |
   | --- | --- |
   | `lsb_release -cs` | `resolute`, the `ubuntu_release` in `production.yml` |
   | `command -v docker` | nothing (no Docker yet); provisioning installs major `docker_engine_major` (`29`) |
   | `ip -4 -brief address` | the LAN address of the wired interface |
   | `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` | `256 SHA256:… root@infra-host (ED25519)`: **write the `SHA256:` fingerprint down** |

   If the release differs, edit `production.yml` (through `master`) before anything else:
   provisioning stops with "Confirm the host's facts" when it does not match.
4. In the router's admin page, give the server's MAC address a **fixed DHCP lease**
   (sometimes "address reservation" or "static lease") on the address it has now, so the
   address in section 5 stays valid. Reboot the server once and check `ip -4 -brief address`
   shows the same address.

## 4. Tailscale

**Owner action**, in the Tailscale admin console (<https://login.tailscale.com/admin>).

1. **Access controls**: merge these into the policy file, and give nothing else access to
   `tag:infra-server`. Admins (you) reach the server on tcp 22 and the tailnet-only ports
   (the `http://infra-host/` redirect 80, `home-tls` 443 for Home and every https name, the Beszel status dashboard 8090, Garage's S3 API 3900, the SFTPGo
   file manager 8091, [section 12](#12-gpu-ai-and-media)); the CI runners on tcp 22 only;
   OpenSSH, not Tailscale SSH, is the login:

   ```json
   {
     "tagOwners": {
       "tag:infra-server": ["autogroup:admin"],
       "tag:infra-ci": ["autogroup:admin"]
     },
     "grants": [
       {"src": ["autogroup:admin"], "dst": ["tag:infra-server"], "ip": ["tcp:22"]},
       {"src": ["autogroup:admin"], "dst": ["tag:infra-server"], "ip": ["tcp:80", "tcp:443", "tcp:3900", "tcp:8090", "tcp:8091"]},
       {"src": ["tag:infra-ci"], "dst": ["tag:infra-server"], "ip": ["tcp:22"]}
     ]
   }
   ```

   If the policy still has the default allow-all rule (`{"src": ["*"], "dst": ["*"], "ip":
   ["*"]}` in `grants`, or the older `acls` equivalent), narrow it so it does not cover
   `tag:infra-server`, or every device on the tailnet can reach the server.
2. **Settings → Keys → Generate auth key**: one-off (not reusable), **pre-approved**, not
   ephemeral, tag `tag:infra-server`, expiry 1 day. Keep it for section 5; the first
   provision asks for it without showing or storing it. A tagged node's key does not expire,
   so the server stays on the tailnet.
3. **Settings → OAuth clients → Generate OAuth client**: scope **Auth Keys: write**, tag
   `tag:infra-ci` only. Keep the client ID and secret for section 7. The Deploy workflow
   joins the tailnet with them, for each run, as an ephemeral `tag:infra-ci` node.

Provisioning joins the server as `infra-host` with `--ssh=false --accept-dns=false
--accept-routes=false`, and on every run checks that it is on the tailnet as `infra-host`
with exactly `tag:infra-server`. A stop there with "Check the auth key's tag and the
policy's tagOwners" means the key was made without the tag, or the policy does not let you
own it.

## 5. First provision over the LAN

**Owner action**, on your laptop, on the home LAN.

1. **The CI deploy key.** The release path has its own key, used only by the Deploy workflow
   and only for the `deploy` user. Its public half is already committed in
   [`roles/common/files/deploy_key.pub`](roles/common/files/deploy_key.pub) (`… infra-deploy`)
   and the private half is `~/.ssh/infra-deploy` on your laptop. If you no longer have that
   private key (or the file is still the placeholder), make a **new CI deploy key** and commit
   its public line to `master` before going on:

   ```bash
   ssh-keygen -t ed25519 -N '' -C infra-deploy -f ~/.ssh/infra-deploy
   cp ~/.ssh/infra-deploy.pub roles/common/files/deploy_key.pub   # then commit and merge to master
   ```

   Provisioning installs the public half for `deploy` only, as one root-owned line
   `restrict,command="/usr/local/sbin/infra-deploy-gate" ssh-ed25519 AAAA… infra-deploy`, and
   refuses to run if `setup` or `admin` trusts it.
2. **Trust the server's host key**, compared with the fingerprint from section 3:

   ```bash
   ssh-keyscan -t ed25519 192.168.1.50 | ssh-keygen -lf -     # must print section 3's SHA256: fingerprint
   ssh-keyscan -t ed25519 192.168.1.50 >> ~/.ssh/known_hosts
   ```

3. **Install your key** for `setup` (skip if the installer imported it from GitHub). Use your
   own key, as a plain line, never the CI deploy key:

   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub setup@192.168.1.50
   ssh setup@192.168.1.50 true                                 # exits 0 without a password prompt
   ```

4. **Point the inventory at the LAN address** for this run only (the play needs exactly one
   host in `[home]`, so an inline `-i '192.168.1.50,'` does not work):

   ```bash
   cp inventory/hosts.example inventory/hosts
   sed -i 's/^infra-host ansible_host=.*/infra-host ansible_host=192.168.1.50/' inventory/hosts
   ansible-playbook -e infra_host=home -u setup --ask-become-pass provision.yml
   ```

   `BECOME password` is `setup`'s password. Enter the Tailscale auth key from section 4 at the
   prompt `Tailscale auth key for infra-host`.

Expect, in order: the checks pass (logged in as `setup`, Ubuntu `resolute`, no Docker yet);
packages are upgraded and `unattended-upgrades` and `chrony` installed; ufw admits 22 on
`tailscale0` **and still 22 on the LAN**, nothing else; `admin` is created with your keys
(copied once from `setup`) and sudo that asks for a password; `deploy` is created with the
forced command and the release scripts; fail2ban, patching, NTP and the journald cap are
set; the server joins the tailnet; Docker 29 comes from the pinned apt repository;
`/etc/infra/host.env`, the `INFRA-PUBLIC` firewall chain (no public port), swap, the sleep
masks and the `home-llm` and `media` networks are in place; Watchtower and autoheal start; last, password and
keyboard-interactive login are turned off and root login stays off. The run ends with:

```
setup stays until the first run as admin removes it.
Set the admin sudo password: ssh -t setup@192.168.1.50 sudo passwd admin
Then set ansible_host=infra-host in inventory/hosts and run: ansible-playbook -e infra_host=home -u admin --ask-become-pass provision.yml (RUNBOOK.md, "Second provision over the tailnet").
This run did not reach infra-host over the tailnet, so ufw keeps 22/tcp open on the LAN. ...
```

5. **Set the admin sudo password** (it asks for `setup`'s password first, then the new one
   twice). Keep it in your password manager; every later provision asks for it:

   ```bash
   ssh -t setup@192.168.1.50 sudo passwd admin
   ```

6. **Record the host key under the tailnet name**, for your laptop and for the Deploy
   workflow (which checks it strictly from `SSH_KNOWN_HOSTS`):

   ```bash
   ssh-keyscan -t ed25519 infra-host | ssh-keygen -lf -       # must print section 3's SHA256: fingerprint
   ssh-keyscan -t ed25519 infra-host > /tmp/kh && cat /tmp/kh >> ~/.ssh/known_hosts
   ssh admin@infra-host true                                   # exits 0, no prompt: the tailnet path works
   ```

   Keep `/tmp/kh` for section 7. A stop at "setup's authorized_keys … must hold only your own
   public keys" means a line there has options or is the CI key: fix the file and run again.

## 6. Cloudflare Tunnel (retired)

The home server has no public site since plan 023: the portfolio moved to the hetzner host,
which Cloudflare reaches directly ([section 15](#15-hetzner-host)), and hypernova was retired.
The tunnel `home-server` that carried `arbikullakshi.com`, `www` and `hypernova` to the home
server is deleted in section 15's clean-up, with its `CF_TUNNEL_TOKEN` secret. Nothing to do
here on a new home server.

## 7. The production Environment

**Owner action**, on your laptop, with `gh` in the checkout. Create the Environment first
(Settings → Environments → New environment → `production`; optionally restrict it to the
`master` branch and add yourself as a required reviewer). Every value is new: generate them
here. Every value must be free of `$`, `"`, `'`, `` ` ``, `\`, `#`, line breaks and leading
or trailing spaces; the generated ones are.

```bash
# Access: the CI deploy key, the host keys from section 5 (and section 15's for infra-hetzner:
# SSH_KNOWN_HOSTS holds one line per host), the Tailscale OAuth client from section 4
gh secret set SSH_PRIVATE_KEY --env production < ~/.ssh/infra-deploy
gh secret set SSH_KNOWN_HOSTS --env production < /tmp/kh && rm /tmp/kh
gh variable set SERVER_SSH_HOST --env production --body infra-host
gh variable set TS_OAUTH_CLIENT_ID --env production --body '<client id>'
gh secret set TS_OAUTH_SECRET --env production                     # paste the OAuth client secret

# GHCR: an account and a classic token with read:packages that can read
# ghcr.io/somethim/portfolio and ghcr.io/somethim-home/home-server
gh variable set GHCR_USERNAME --env production --body '<github user>'
# GitHub shows a token's value only once. If you don't have it saved, make a new one:
# GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic) →
# Generate new token (classic), scope read:packages only, expiry 1 year; store it in 1Password
# ("Home Server" vault, "GHCR read token (infra)"), then:
op item get "GHCR read token (infra)" --vault "Home Server" --fields label=password --reveal | gh secret set GHCR_TOKEN --env production

# The portfolio's secrets (its database, R2, the origin certificate) are the hetzner host's:
# section 15.
# The status dashboard and S3 storage: run the block in section 12, "The status dashboard and
# S3 secrets" (it keeps the values in 1Password: the dashboard password and the S3 key are yours to use)
# HOME_TLS_CF_DNS_TOKEN: a Cloudflare API token, created as in "The links page" (section 12)
# Home: its owner variable, two keys, the Resend key and the TMDB token, as in "Home" (section 12)
# and docs/deploy-home.md; its power key (HOME_POWER_KEY, optional) is a copy of one provisioning
# makes on the server, so it comes later, as in "Home's power control" (section 12)
```

Leave the `SERVER_USER` variable unset (the workflow uses `deploy` and refuses `root` and
`admin`). Delete what the old server used and nothing reads any more:

```bash
gh secret delete SERVER_HOST --env production      # "not found" is fine
gh secret list --env production; gh variable list --env production
```

The full list, with the format each value must have, is in
[docs/deploying.md](docs/deploying.md#secrets-and-variables). A missing or malformed value
stops the release on the runner, before the host is touched, with "Missing or invalid deploy
secrets" or "`<name>` holds a $, quote, …".

## 8. Second provision over the tailnet

**Owner action.** Point the inventory at the tailnet name and run as `admin`; every later
provision runs exactly like this:

```bash
cp inventory/hosts.example inventory/hosts      # [home] infra-host ansible_host=infra-host
ansible-playbook -e infra_host=home -u admin --ask-become-pass provision.yml
```

`BECOME password` is the admin password from section 5. Expect: "Close SSH on the LAN once
runs come in over the tailnet" reports `changed` (ufw's LAN 22 rule is deleted), the `setup`
account and its home directory are removed ("Remove the installer's account …"), and no "LAN"
message at the end. Then, from the laptop:

```bash
nc -z -w 5 192.168.1.50 22                      # times out or is refused (exit 1)
ssh admin@infra-host sudo ufw status            # Status: active; 22, 80, 443, 3900, 8090, 8091/tcp on tailscale0, nothing else
ssh admin@infra-host sudo docker ps --format '{{.Names}} {{.Ports}}'   # no "->": nothing is published
```

From now on the keyboard and monitor take the admin password if the tailnet is unreachable
([Locked out](#locked-out)).

## 9. First release

**Owner action.** GitHub → **Actions → Deploy → Run workflow**, "Use workflow from" `master`,
host `home`, action `release`, every other input at its default. The `ai` and `media` stacks
need the GPU, the status dashboard and S3 secrets and (for Garage's objects off the SSD) the
disks; set them up first ([section 12](#12-gpu-ai-and-media)), since a release refuses without
the first two. Expect in the "Release on the server" step:

```
infra-apply: compose model accepted: 1 service(s) in the ai stack, no privileged settings, no host port but none on the tailnet, ...
infra-apply: compose model accepted: 9 service(s) in the media stack, no privileged settings, no host port but beszel 100.x.y.z:8090, garage 100.x.y.z:3900, home 100.x.y.z:80, home-tls 100.x.y.z:443, sftpgo 100.x.y.z:8091 on the tailnet, ...
infra-apply: compose model accepted: 2 service(s) in the home stack, no privileged settings, no host port but none on the tailnet, no bind mount but home-server /srv/media/home-files, home-server /run/home-power, home-server /srv/media/movies, home-server /srv/media/shows, the GPU only for home-server, ...
infra-apply: bundle accepted: 18 files, manifest checksums match
infra-apply: Watchtower is stopped until the app stacks are up
infra-apply: pulling images
infra-apply: starting ai
infra-apply: starting media
infra-apply: starting home
infra-apply: Watchtower is running again
infra-apply: every container is running and healthy, and has run for at least 30s without a restart
infra-apply: the tailnet-only ports home:80 home-tls:443 beszel:8090 garage:3900 sftpgo:8091 are bound to 100.x.y.z alone
infra-apply: home-tls serves https with a trusted certificate on 100.x.y.z for home.arbikullakshi.com, and Home's web app at https://home.arbikullakshi.com/app/
infra-apply: beszel-pair garage-setup home-keys finished: the dashboard's agent is paired, S3 has its layout, the owner's key and the files bucket, Home has its key files
infra-apply: watchtower-socket-proxy watchtower autoheal-socket-proxy autoheal beszel-socket-proxy beszel-agent: each client reaches Docker through its socket proxy with no refused calls
infra-apply: RELEASE OK: <id> is current, following :latest, auto-updates on
```

## 10. DNS switch-over (2026-10-15, done)

On 2026-10-15 the public names moved from the first Hetzner server to the home server's
Cloudflare Tunnel, and that server was deleted. Plan 023 moves the portfolio back to a new
Hetzner server: [section 15](#15-hetzner-host) has that switch-over.

## 11. Day-2 operations

### Releases, status, rollback, resume

All four are **Actions → Deploy → Run workflow** from `master`, with the `host` input
(`hetzner`: the portfolio and its database; `home`: Home) and the `action` input. The `target`
and `dry_run` inputs apply only to `rollback`; the workflow refuses them with any other action.

**`release`** renders the bundle on the runner from `master` and the Environment, streams it to
`deploy`, and brings every stack up on `:latest`. Run it when a secret, a stack file under
`stack/`, or `production.yml` changes, and after a provision that changed `/etc/infra/host.env`.
It is not needed for app updates: while an app follows `:latest`, Watchtower deploys a new
image within about a minute of it being pushed. The release path is described in
[docs/deploying.md](docs/deploying.md#what-infra-apply-checks-in-order).

**`status`** prints, with no change to the host (each line starts with `infra-apply: `):

```
current release: <id> (verified|not verified), <summary>
previous release: <id> (verified), <summary>        or  previous release: none
image <container> ref=<image> digest=<sha256:…|unknown> created=<time|unknown>
known <repository> digest=<sha256:…> created=<time>
recorded <id> <container>=<repository>@<sha256:…>
```

then one `docker compose ps` table per stack. `<summary>` is `following :latest, auto-updates
on` or `pinned (<keys>), auto-updates paused for them`. `image` is what each app container
runs now, `known` every version of that repository still on the host, and `recorded` the
digest each container ran when that release was verified (`/opt/infra/releases/<id>/running-images.env`).

**`rollback`** pins the host's app image (the portfolio on hetzner, Home's `home-server` on
home) to a digest. The `target` input is:

| Input | Means |
| --- | --- |
| `previous` (default) | the first digest that differs from the running one: from the current release's `recorded` lines, then the previous release's, then the `known` images |
| `current` | the digest running now (freezes it) |
| `latest` | refused: that is `resume` |
| a 40-character commit sha | portfolio only: its `:<sha>` tag, by digest |
| `sha256:<64 hex>` | that digest, after checking GHCR has it |

Run it with `dry_run: true` first: it prints the status and the resolved pin (`RELEASE_MODE=pinned`
and one `PORTFOLIO_IMAGE=` or `HOME_IMAGE=` line) and stops. A pinned image is
`<repository>:latest@sha256:<digest>`, which Watchtower cannot move, so auto-updates stay paused
for it until `resume`. Home only publishes `:latest`, so its rollback needs a digest the host or
a release has seen; if none is known, pass one explicitly.

**`resume`** is a `release` again: every app back on `:latest`, auto-updates on. Run it once
the fix is published.

**When a release fails**, the output says where:

- "…; the running release is untouched": refused before any change (a bad bundle or
  compose model, a refused GHCR login, a failed pull).
- "FAILED: before the app stacks changed, …" then "release `<id>` is installed but not
  current; … a rollback cannot fix this …" (hetzner): the database did not come up healthy
  or `provision.sql` failed. The database runs the new definition, the portfolio the previous
  one, and `current` still names the previous release. A `rollback` does not help here: it
  only re-pins the app image and renders `stack/database`, `provision.sql`, `edge/tls.yml` and
  the secrets from `master` again. Revert the `stack/database` or secret change on `master` (or fix
  the secret in the `production` Environment) and run `release`.
- "release `<id>` is current but not verified; … (the last verified release was `<id>`:
  `<summary>`)": a stack did not start, or the release did not verify; the new release is
  `current`, and `previous` still names the last verified one. Read the failure line above it
  (which container was not healthy, which check answered what). Run `rollback` only when the app
  image is the cause: it changes nothing but the app image reference. A broken `stack/` file,
  env template or secret (a wrong `CF_ORIGIN_CERT` among them) comes back with a rollback (it is rendered
  from `master` again), so fix that on `master` or in the Environment and run `release`. The
  release kept in `/opt/infra/releases/` cannot be re-applied.

### Rotating a secret

Change it in the `production` Environment, then run `release` on the host that uses it
(hetzner for `POSTGRES_*`, `PORTFOLIO_*`, `R2_*` and `CF_ORIGIN_*`; home for `HOME_*`,
`BESZEL_*`, `GARAGE_*` and `FILES_PASSWORD`; both for `GHCR_TOKEN`). That is the whole
procedure for most values:

- **Database passwords**: `provision.sql` re-sets each role's password in the same release
  that renders the new DSN, so the two cannot drift. `POSTGRES_SUPERUSER_PASSWORD` is re-set
  the same way. Generate with `openssl rand -hex 24`.
- **`CF_ORIGIN_CERT` / `CF_ORIGIN_KEY`**: create a new Origin CA certificate (section 15,
  step 5), set both secrets, run `release` on hetzner (Traefik reloads `tls.yml` without a
  restart), then revoke the old certificate in Cloudflare.
- **`R2_*` keys**: create the new API token, set the secrets, `release` on hetzner, then delete
  the old token in Cloudflare.
- **`PORTFOLIO_ADMIN_PASSWORD`** is used only when the portfolio's operator account does not
  exist yet; changing it does not change an existing account. Change that password in
  `/admin`, then store the same value here.
- **`PORTFOLIO_TOTP_ENCRYPTION_KEY`**: never rotate it casually. A new key makes every enrolled
  TOTP secret permanently unreadable; re-enrolment is the only recovery.
- **`GHCR_TOKEN`**: a release logs in again, which also refreshes the credentials Watchtower
  reads from `/root/.docker`.
- **`SSH_PRIVATE_KEY`** (the CI deploy key): make a new pair as in section 5, commit the public
  half, provision (it replaces `deploy`'s one line), then set the secret.
- **`TS_OAUTH_SECRET`**: generate a new OAuth client as in section 4 and replace both values.
- **`HOME_TLS_CF_DNS_TOKEN`**: create a new token as in [The links page](#the-links-page), set
  it, `release`, then delete the old token (Cloudflare dashboard, My Profile → API Tokens).
  The certificate already issued keeps working; only renewals use the token.
- **`BESZEL_PASSWORD`** creates the dashboard login only on the hub's first start. To change
  it: change it in the dashboard (top right → Settings → Password), store the same value in
  1Password and here, then `release` (`beszel-pair` signs in with it; a mismatch fails the
  release at "beszel-pair exited with status 1").
- **`BESZEL_AGENT_TOKEN`**: `openssl rand -hex 24`, then `release`; `beszel-pair` makes the new
  value the universal token, and the agent, recognised by its fingerprint, keeps its history.
- **`GARAGE_ADMIN_TOKEN`**: `openssl rand -hex 32`, then `release`. Only the admin API uses it.
- **`GARAGE_RPC_SECRET`**: `openssl rand -hex 32`, then `release`. A single node only talks to itself.
- **`GARAGE_OWNER_ACCESS_KEY_ID` and `GARAGE_OWNER_SECRET_KEY`**: rotate **both together**
  (Garage never reuses a deleted key ID): `GK$(openssl rand -hex 12)` and `openssl rand -hex 32`,
  as in section 12, then `release`. `garage-setup` imports the new key, gives it the `files`
  bucket and deletes the old one, and `sftpgo` picks the new key up on its restart; update
  rclone and your S3 apps.
- **`HOME_RESEND_API_KEY`**: create a new key in Resend, set it, `release` (`home-keys`
  rewrites the file; home-server reads it at its next start, which the release brings), then
  revoke the old key in Resend.
- **`HOME_SECRET_KEY`**: `openssl rand -base64 32`, then `release`. It keys the HMAC of the
  client addresses Home stores, so older audit entries no longer match new ones; nothing else
  changes.
- **`HOME_DATA_KEY`**: never rotate it casually. It encrypts every enrolled TOTP secret and
  passkey, and the AI chats' titles and messages; home-server refuses to start with a key that
  does not open them. Only with `reset-owner` and every family member re-enrolling (see
  [Home](#home)); the chats are lost with the old key.
- **`HOME_TMDB_READ_TOKEN`**: on themoviedb.org, Settings → API, regenerate the API Read Access
  Token, set it ([docs/deploy-home.md](docs/deploy-home.md#5-the-secrets) has the command),
  `release` (`home-keys` rewrites `/run/keys/tmdb_read_token`, home-server reads it at its
  restart). Deleting the secret turns TMDB off: Media falls back to Wikidata, without pictures.
- **`HOME_BESZEL_PASSWORD`**: change the Beszel user's password in Beszel first, then here, then
  `release`.
- **`HOME_POWER_KEY`** is a copy of the host's `/etc/infra/home-power.key`, never generated here:
  on the server `sudo rm /etc/infra/home-power.key`, provision with `--tags host` (it makes a new
  one), copy it as in [Home's power control](#homes-power-control) step 2, then `release`. Until
  the release, Home's requests are refused (wrong hmac); nothing else changes.
- **`FILES_PASSWORD`**: `openssl rand -hex 16` (saved to "infra production secrets" as in
  section 12), then `release`. `sftpgo` reloads its user at start, so the new password works
  at once and the old one stops; update WebDAV mounts.

`WEBUI_SECRET_KEY`, `SEARXNG_SECRET`, `IMMICH_DB_PASSWORD` and `IMMICH_ADMIN_PASSWORD` belonged
to the apps retired on 2026-10-20 ([Retired apps](#retired-apps-2026-10-20)); nothing reads them,
so there is nothing to rotate. Delete them from the Environment and 1Password when it suits you.

Every value must pass the formats in [docs/deploying.md](docs/deploying.md#secrets-and-variables);
the render on the runner refuses one that does not, before the host is touched.

### Provisioning again

```bash
ansible-playbook -e infra_host=home -u admin --ask-become-pass provision.yml                 # everything
ansible-playbook -e infra_host=home -u admin --ask-become-pass provision.yml --tags edge     # one role
```

Run it when a role changes on `master`. It never touches the app stacks or their data.

### Encrypted DNS

The host resolves names through `systemd-resolved` over DNS-over-TLS only, to Cloudflare
(`1.1.1.1`, `1.0.0.1`) and then Quad9 (`9.9.9.9`, `149.112.112.112`), never through the resolver
the home router announces (the ISP's, which blocks some sites). `production.yml`'s
`dns_over_tls_enabled` and `dns_over_tls_servers`; `roles/host/tasks/dns.yml`; why and how in
[docs/host.md](docs/host.md#encrypted-dns).

**Turn it on** (or apply a change of the servers): provision with `--tags host`. The run looks a
name up over TLS right away and, if that fails, takes the setting out again and stops, so the host
never ends up resolving nothing. The LAN interface stops using the router's resolver at the next
boot; the run says so ("needs a reboot"). Then:

```bash
ssh -t admin@infra-host sudo reboot
ansible-playbook -e infra_host=home -u admin --ask-become-pass provision.yml --tags host   # verify: TLS on, the four servers, no LAN or tailnet resolver
ssh admin@infra-host resolvectl dnsovertls                              # Global: yes
ssh admin@infra-host resolvectl dns                                     # Global: the four servers; enp8s0 and tailscale0: none
ssh admin@infra-host resolvectl query www.gutenberg.org                 # an address, "Data was acquired via local or encrypted transport: yes"
```

**MagicDNS** is not affected: the server runs Tailscale with `--accept-dns=false`, so it never
used MagicDNS, and your devices keep theirs. Verify fails if `tailscale0` ever gets a DNS server
(someone ran `tailscale set --accept-dns=true`): DNS-over-TLS to Tailscale's `100.100.100.100`
cannot work; provisioning sets it back.

**Rollback**: set `dns_over_tls_enabled: false` in `production.yml` (through `master`), provision
with `--tags host` and reboot: the host uses the router's resolver again. Without a working DNS
(no provisioning, no `apt`, no image pulls), at the console or over SSH by address:

```bash
sudo rm /etc/systemd/resolved.conf.d/60-infra-dns-over-tls.conf /etc/systemd/network/10-netplan-*.network.d/60-infra-dns.conf
sudo systemctl restart systemd-resolved          # the host resolves again at once, through the router
sudo reboot                                      # the LAN interface takes the router's resolver again
```

### Locked out

The way in that depends on neither sshd, keys nor the tailnet is the **server's own keyboard
and monitor**: log in as `admin` with its password. From there:

- **The tailnet is down or the server left it**: `tailscale status`. If it is logged out,
  `sudo tailscale up --auth-key=<new one-off key, tag:infra-server> --hostname=infra-host
  --advertise-tags=tag:infra-server --ssh=false --accept-dns=false --accept-routes=false`
  (make the key as in section 4).
- **fail2ban banned you** (only possible from outside the tailnet, so only while LAN 22 is
  open; the tailnet range is never banned): `sudo fail2ban-client set sshd unbanip <your IP>`.
- **sshd refuses logins or will not start**: check
  `/etc/ssh/sshd_config.d/10-hardening.conf` and `sudo sshd -t`. Provisioning validates the
  file with `sshd -t` before installing it and reloads (never restarts) sshd, so a provision
  should not cause this; another drop-in in `/etc/ssh/sshd_config.d/` that overrides it would
  (provisioning stops with "Locked out" when `sshd -T` does not apply its policy).
- **You need SSH over the LAN for one run**: `sudo ufw allow 22/tcp` at the console, run
  provisioning with `ansible_host=<LAN address>` as `admin`, then once more over the tailnet,
  which deletes the rule again.
- **The server does not come back after a power cut**: the firmware setting of section 2 is
  off, or the board's deep power-saving mode overrides it. Press the power button, then fix it
  in the firmware.

### Wake-on-LAN

**Owner action**, once after the firmware settings of section 2 and a provision, and again
after a firmware update (which can reset them). You need a second device on the home LAN
(laptop or phone on the home Wi-Fi; not over Tailscale, which is down while the server is).

```bash
# 1. On the server: magic-packet wake is on (provisioning reads this back too)
ssh admin@infra-host sudo ethtool enp8s0 | grep Wake-on    # Supports Wake-on: pumbg / Wake-on: g

# 2. Switch it off: from Home (once the Home app has its power control), or
ssh admin@infra-host sudo systemctl poweroff

# 3. From the other device on the LAN, once the fans have stopped (about 30 s).
#    MAC is the LAN interface's address: `ip -br link show enp8s0` on the server (third column).
MAC=aa:bb:cc:dd:ee:ff
wakeonlan "$MAC"                                     # Debian/Ubuntu/Arch package wakeonlan
#   or: wol "$MAC"                                   # package wol
#   or: python3 -c 'import socket; m=bytes.fromhex("aabbccddeeff"); s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1); s.sendto(b"\xff"*6+m*16, ("255.255.255.255", 9))'
# A phone works too: any Wake-on-LAN app, MAC "$MAC", broadcast 255.255.255.255 (or the LAN's, 192.168.1.255), port 9.

# 4. The server powers on; about a minute later:
tailscale ping infra-host && curl -sI https://arbikullakshi.com/ | head -1
```

If it stays off: the network card's link light should stay lit while the server is off; when
it is dark, ErP is still on (section 2). If the light is on but the packet does nothing, check
`Wake on LAN` in the firmware, that the sender is on the same LAN segment (not a guest Wi-Fi
that isolates clients), and that `ethtool` still says `Wake-on: g` after a boot (provision with
`--tags host` if not). A power cut resets nothing here: with **AC BACK → Always On** the server
starts by itself when power returns.

### The site is down but the hetzner host is up

```bash
ssh admin@infra-hetzner sudo docker ps --format '{{.Names}} {{.Status}}'
ssh admin@infra-hetzner sudo docker logs --tail 50 edge-traefik
curl -sS -o /dev/null -w '%{http_code}\n' https://arbikullakshi.com/api/health
```

`521`/`522` from Cloudflare: it cannot reach the server (the Hetzner Cloud Firewall, the
record's address, or Traefik is down). `525`: the TLS handshake failed (Authenticated Origin
Pulls off for the zone, or `/opt/edge/dynamic/tls.yml` missing: run `release`). `526`: the
origin's certificate is not the Origin CA one. Traefik and the portfolio restart on their own
(`restart: always`, autoheal for the portfolio).

### The down page

A Cloudflare Worker answers the public site with a "server is down" page (503) while the
hetzner host is off or Traefik does not answer, and otherwise passes every request through
untouched ([docs/edge.md](docs/edge.md#the-down-page)). It is deployed **by hand, from your
laptop**: nothing in CI or on the server touches it, and it holds no secret. **Owner action**,
once, and again after any change in `cloudflare/down-page/`:

1. **Tools**: Rust with the `wasm32-unknown-unknown` target (`rustup target add
   wasm32-unknown-unknown`) and Node.js for `npx`. The build installs the pinned `worker-build`
   itself.
2. **Log in** to the Cloudflare account that holds `arbikullakshi.com` (opens the browser,
   keeps an OAuth token in `~/.config/.wrangler`):

   ```bash
   cd cloudflare/down-page
   npx wrangler@4.147.0 login
   npx wrangler@4.147.0 whoami        # the account that owns the zone
   ```

3. **Deploy** (builds with `worker-build --release`, uploads, and attaches the two routes in
   `wrangler.toml`; a deploy also drops the retired `hypernova.arbikullakshi.com/*` route):

   ```bash
   npx wrangler@4.147.0 deploy
   ```

4. **Fail open**: Cloudflare dashboard → Workers & Pages → `down-page` → Settings → set the
   *request limit failure mode* to **Fail open**, so a day past the free plan's 100,000 requests
   sends visitors straight to the sites (without the down page) instead of to an error.
5. **Check** that the sites still work (status, cookies, the admin sign-in, a redirect):

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' https://arbikullakshi.com/api/health            # 200
   curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://www.arbikullakshi.com/ # 301 https://arbikullakshi.com/
   ```

   and, at a quiet moment, that the page appears while Traefik is down and goes away after:

   ```bash
   ssh admin@infra-hetzner sudo docker stop edge-traefik
   curl -s -o /dev/null -w '%{http_code} %header{retry-after}\n' https://arbikullakshi.com/   # 503 120
   ssh admin@infra-hetzner sudo docker start edge-traefik
   ```

**Free plan**: 100,000 requests a day for the whole account (Workers & Pages → Overview shows
the count), 10 ms CPU per request, which this Worker stays far below. **Off**: `npx
wrangler@4.147.0 delete` (or remove its routes in the dashboard); the sites then show
Cloudflare's own error pages again. **Logs**: none are kept (Workers Logs are off); `npx
wrangler@4.147.0 tail` streams live requests only while you watch, and shows their URLs, so use
it only to debug.

### Re-pinning third-party images

Every non-app image (PostgreSQL, Traefik, the socket proxies, Watchtower, autoheal, and
rclone in `roles/host/files/infra-pg-backup`) is pinned `<image>:<tag>@sha256:<digest>`, one
version per repository across `stack/` and `roles/*/files/`, and the bundle build refuses
anything else. The hetzner host is Arm64: pin the **multi-arch index** digest (`docker buildx
imagetools inspect <image>:<tag>` must list `linux/arm64` and `linux/amd64`), never one
platform's manifest. To move one (a Watchtower that the Engine calls "too old", a Traefik or
PostgreSQL patch release), follow [docs/agents.md](docs/agents.md#re-pinning-third-party-images),
then provision with that role's tag, or run `release` on hetzner for `postgres` (a minor
version only; a major is a dump and restore, [docs/database.md](docs/database.md#upgrades)).

### Restoring from the backup disk

The external disk holds, under `/srv/backup/snapshots/` (root only), one folder per night,
`<YYYY-MM-DD>/`, and `latest` pointing at the newest:

```
snapshots/<date>/postgres.sql.gz       pg_dumpall of the old shared PostgreSQL, only while it still runs
                                       here (until section 15's clean-up)
snapshots/<date>/volumes/<volume>/     the apps' volumes as plain trees: beszel-data, garage-meta, sftpgo-data,
                                       home-data, and portfolio-media until section 15's clean-up deletes it,
                                       and the retired apps' kept volumes (jellyfin-config,
                                       audiobookshelf-config, audiobookshelf-metadata, kavita-config,
                                       open-webui-data)
snapshots/<date>/media/<name>/         s3 (Garage's objects, the Files bucket), home-files (Home Files'
                                       ciphertext), movies and shows (the films' and series'
                                       .nfo files, pictures and subtitle files only, never the
                                       videos), and the retired apps' kept folders audiobooks,
                                       books and podcasts
```

`home-data` holds all of Home's own state: `home.db` (accounts, sessions, factors), `media.db`
(Media's catalogue, progress, lists), `ai.db` (the chats, sealed) and `books/` (Books' library,
shelves and places); its `media-cache` (pictures, trickplay, HLS) and Books' catalog covers are
left out and come back by themselves.

Snapshots from before 2026-10-28 also hold Immich's leftovers (`immich.sql.gz`, `media/photos`,
`volumes/immich-pgdata`); they age out with those snapshots.

Kept: the last 14 nights, plus the first night of each of the last 8 weeks, so anything
deleted within about two months is still in an older snapshot. Unchanged files are hard links
between snapshots, so each night only costs what changed. The films' and series' videos and the
AI models (Home's `llama-models`) are not backed up: the videos would not fit, the
models download again ([Home's AI models](#homes-ai-models)). Check last night's run with
`ssh admin@infra-host journalctl -u infra-backup.service --since yesterday`; a failed one also
logs "the nightly backup FAILED" at error priority, and its unfinished
`snapshots/.<date>.partial` stays until the next run.

**A file from the retired apps' folders** (books, audiobooks and podcasts are plain
files): find it in a snapshot and copy it out:

```bash
ssh -t admin@infra-host
sudo ls /srv/backup/snapshots/
sudo find /srv/backup/snapshots/*/media/books -iname '*orwell*'
```

**A deleted file from Files (the S3 bucket):** Garage stores objects as hashed blocks, not as
plain files, so start a throwaway Garage on a copy of that night's metadata and blocks, and copy
the file out of it with rclone. On the server:

```bash
d=<date>; s=/srv/backup/snapshots/$d; t=/srv/media/restore-$d
sudo mkdir -p "$t"
sudo cp -a "$s/volumes/garage-meta" "$t/meta"     # small; Garage writes to its metadata
sudo cp -al "$s/media/s3" "$t/data"               # hard links: instant, no extra space
sudo tee "$t/meta/garage.toml" >/dev/null <<'TOML'
metadata_dir = "/meta/db"
data_dir = "/data"
db_engine = "sqlite"
replication_factor = 1
rpc_bind_addr = "127.0.0.1:3911"
rpc_public_addr = "127.0.0.1:3911"
[s3_api]
s3_region = "garage"
api_bind_addr = "127.0.0.1:3910"
TOML
sudo docker run -d --name garage-restore --network host --user "$(sudo stat -c %u:%g "$t/data")" \
  -e GARAGE_RPC_SECRET="$(openssl rand -hex 32)" -e GARAGE_CONFIG_FILE=/meta/garage.toml \
  -v "$t/meta:/meta" -v "$t/data:/data" \
  dxflrs/garage:v2.4.1@sha256:9c96caa2612d3411acc5b0e6701fb238dbfba33e533a6d7d3d811a4b12d0d020 /garage server
```

Then from the laptop, through an SSH tunnel, with the same key as the live bucket (it is in
that night's metadata):

```bash
ssh -N -L 3910:127.0.0.1:3910 admin@infra-host &
k="$(op item get 'infra production secrets' --vault 'Home Server' --fields label=GARAGE_OWNER_ACCESS_KEY_ID --reveal)"
p="$(op item get 'infra production secrets' --vault 'Home Server' --fields label=GARAGE_OWNER_SECRET_KEY --reveal)"
old=":s3,provider=Other,endpoint=http://127.0.0.1:3910,region=garage,force_path_style=true,access_key_id=$k,secret_access_key=$p:files"
rclone ls "$old/<folder>"                                   # find it
rclone copyto "$old/<folder>/<file>" "home:files/<folder>/<file>"   # back into the live bucket
unset k p old; kill %1
```

On the server, throw the copy away: `sudo docker rm -f garage-restore && sudo rm -rf /srv/media/restore-<date>`.

**One app's data** (here Beszel; the same for `sftpgo-data` with `sftpgo`): stop its
container, copy the volume back from a snapshot, start. The trees keep numeric owners. A
retired app's kept volume has no container to stop; only the `rsync` applies.

```bash
ssh -t admin@infra-host
sudo docker stop beszel
v="$(sudo docker volume inspect --format '{{.Mountpoint}}' beszel-data)"
sudo rsync -a --delete --numeric-ids /srv/backup/snapshots/<date>/volumes/beszel-data/ "$v/"
sudo docker start beszel
```

**All of Garage** (the whole `files` bucket as it was that night): its metadata and objects
must come from the same snapshot:

```bash
sudo docker stop garage sftpgo
v="$(sudo docker volume inspect --format '{{.Mountpoint}}' garage-meta)"
sudo rsync -a --delete --numeric-ids /srv/backup/snapshots/<date>/volumes/garage-meta/ "$v/"
sudo rsync -a --delete --numeric-ids /srv/backup/snapshots/<date>/media/s3/ /srv/media/s3/
sudo docker start garage sftpgo
```

**All of Home** (its accounts and Home Files as they were that night): `home-data` and
`/srv/media/home-files` must come from the same snapshot. Watchtower revives stopped labelled
containers, so stop it too. The keys are not in the backup: the release writes them from the
secrets, and `HOME_DATA_KEY` must be the one that night's database was made with.

```bash
sudo docker stop watchtower home-server
v="$(sudo docker volume inspect --format '{{.Mountpoint}}' home-data)"
sudo rsync -a --delete --numeric-ids /srv/backup/snapshots/<date>/volumes/home-data/ "$v/"
sudo rsync -a --delete --numeric-ids /srv/backup/snapshots/<date>/media/home-files/ /srv/media/home-files/
sudo docker start home-server watchtower
```

`--delete` empties Media's cache, which Home rebuilds. The films' and series' metadata (their
`.nfo` files and pictures) goes back without touching the videos, with no `--delete`:

```bash
sudo rsync -a --numeric-ids /srv/backup/snapshots/<date>/media/movies/ /srv/media/movies/
sudo rsync -a --numeric-ids /srv/backup/snapshots/<date>/media/shows/ /srv/media/shows/
```

**The database** is not on the home server any more: the portfolio's PostgreSQL is on the
hetzner host, dumped to R2 every day; restoring it is in
[section 15](#restoring-the-portfolio-database). A home snapshot's `postgres.sql.gz` is the
retired shared database (the old portfolio and hypernova), which nothing restores.

**Everything on the media disk**, after replacing the internal disk (format it as in
[Disks](#disks), put the new UUID in `production.yml`, provision):

```bash
sudo rsync -a --numeric-ids /srv/backup/snapshots/latest/media/ /srv/media/   # owners, groups and modes come back as they were
```

**A new server**: install and provision as in sections 3–9 with the same `production.yml`
(the backup disk's UUID included), release once so every volume exists, then restore each
app volume and Garage as above, all from the same snapshot.

**Before snapshots** (backups written before this layout): the first snapshot run deletes the
old `media/` mirror and `apps/` folder once a complete snapshot exists (it links to the old
mirror, so nothing is copied twice), and the old `postgres/` and `immich/` dumps once 14
snapshots exist.

### More recipes

PostgreSQL access, disk, backups, a major PostgreSQL upgrade, Watchtower and a hung site are
in [docs/operations.md](docs/operations.md).

## 12. GPU, AI and media

**Owner action.** Turns on what the rest of the hardware is for: llama-server for Home's AI on
the RTX 2060 (the only AI engine; Ollama was removed, [Removing Ollama's
models](#removing-ollamas-models)), the status dashboard, Files (S3 storage
on the 1 TB internal HDD) behind a links page, Home's film and series library, and a nightly
backup to the 1 TB external USB HDD. None of it is public: it is reachable
only over the tailnet, on the server's Tailscale address, and only by the Tailscale accounts the
policy names (you). Do the steps in this order; each one says how to check it.

The media and AI apps that used to be here (the media engine, Audiobookshelf, Kavita,
Open WebUI, SearXNG, ComfyUI, and Immich) were retired on 2026-10-20; their data (not Immich's) is kept and still backed
up. See [Retired apps](#retired-apps-2026-10-20).

Home has the only https name, `home.arbikullakshi.com`, with a real certificate for that name
alone (no wildcard), served by `home-tls` on the Tailscale address (443). The other services
have no name since the `*.home` record was deleted (plan 023): they answer on the server's
tailnet name and their own port, over plain http, which WireGuard encrypts.

| Service | Address (on the tailnet) | Container port |
| --- | --- | --- |
| Home (the owner's app: sign-in, dashboard, Home Files) | `https://home.arbikullakshi.com/` (`http://infra-host/` links there) | 8080 (`home-server`, no host port); 80 (`home`) |
| Files (SFTPGo, the file manager) | `http://infra-host:8091/web/client`; WebDAV at `https://home.arbikullakshi.com/dav` | 8091, 8092 (WebDAV, media network only) |
| Beszel (server status) | `http://infra-host:8090` | 8090 |
| Garage (S3 behind Files) | `http://infra-host:3900` (path-style, region `garage`) | 3900 |

### Disks

At the server's console (or `ssh admin@infra-host`), with both HDDs connected. **Formatting
erases the disk**: check the model, size, serial and transport twice, and never touch the SSD
that holds Ubuntu (the one with the `ubuntu-vg` partitions).

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINTS
```

The internal 1 TB HDD shows `TRAN` `sata`, the external one `usb`. Below, `/dev/sdX` is the
internal disk and `/dev/sdY` the external one; use the names `lsblk` printed. For each of the
two (here the internal one; the external one the same way with `-L backup`):

```bash
sudo wipefs -a /dev/sdX                          # removes every old partition table and signature
printf 'label: gpt\ntype=linux\n' | sudo sfdisk /dev/sdX   # one GPT partition over the whole disk: /dev/sdX1
sudo mkfs.ext4 -L media /dev/sdX1                # the external one: sudo mkfs.ext4 -L backup /dev/sdY1
sudo blkid /dev/sdX1 /dev/sdY1                   # UUID="…" of each
```

Copy the two `UUID="…"` values into `production.yml` and commit them to `master`:

```yaml
media_disk_uuid: "<UUID of /dev/sdX1>"
backup_disk_uuid: "<UUID of /dev/sdY1>"
```

Provisioning (below) mounts them by UUID at `/srv/media` and `/srv/backup`
(`nofail,x-systemd.device-timeout=10s`, so the server still boots in seconds with the external
disk unplugged), creates Garage's `s3` folder (the `media` account's alone), keeps the retired
apps' folders `shows`, `movies`, `audiobooks`, `podcasts` and `books` (owned by the `media`
account, setgid, group-writable; `movies` and `shows` are Home's film and series library now,
which home-server writes into as a member of the `media` group), creates Home's `home-files` (the `home-server` account's alone,
uid 65532), and
keeps the backup disk root-only. While a configured disk is missing its mountpoint stays empty and unwritable, so
nothing lands on the SSD in its place. Check after provisioning:

```bash
ssh admin@infra-host findmnt /srv/media /srv/backup        # both, ext4, by UUID
ssh admin@infra-host ls -l /srv/media                      # s3 drwx------ media media, home-files drwx------ home-server home-server, the other five drwxrwsr-x, media media
```

### Tailscale grants

In the Tailscale admin console, **Access controls**, add exactly this grant to the policy file
(section 4 already lists it for a new tailnet; an older policy needs it added) and nothing
else for `tag:infra-server`:

```json
{"src": ["autogroup:admin"], "dst": ["tag:infra-server"], "ip": ["tcp:80", "tcp:443", "tcp:3900", "tcp:8090", "tcp:8091"]}
```

An older policy may still grant the retired apps' ports (2283, 5000, 8080, 8096, 13378); ufw
no longer allows them, and you can remove them from the grant.

An existing policy gets the ports it lacks from `~/.cache/infra-tailscale-setup.sh links`
(shows the diff, asks before saving).

Home adds no port: it is served by `home-tls` on 443, which the grant already holds, and
`home-server` publishes nothing. `tag:infra-ci` gets no new port. Check from the laptop once the release below is done:
`nc -z -w 5 infra-host 8090` succeeds, and `nc -z -w 5 192.168.1.50 8090` (the LAN address)
times out.

### Provision, reboot and check the GPU

`production.yml` already has `gpu_enabled: true` and `nvidia_driver_major: 580`. On the server,
check that Ubuntu offers that branch for the card:

```bash
lspci | grep -i nvidia                       # the RTX 2060 (TU106)
ubuntu-drivers list --gpgpu                  # must include nvidia-driver-580-server
```

If it lists another `-server` branch instead, set `nvidia_driver_major` to it (through
`master`). Then provision from the laptop:

```bash
ansible-playbook -e infra_host=home -u admin --ask-become-pass provision.yml
```

The `gpu` role installs the driver and the NVIDIA Container Toolkit; `host` writes the
Tailscale address into `/etc/infra/host.env`, turns on non-local binds, adds the second
firewall hook, the `home-llm` and `media` networks, the `ai` and `media` accounts (and puts
`admin` in the `media` group) with their volumes, mounts the disks and installs the nightly
backup. A first run ends the `gpu` part with "The NVIDIA driver was installed or updated since the last boot
and is not loaded yet … Reboot when it suits you": the driver loads at the next boot. Reboot
(the sites are back when Docker has restarted the stacks, about a minute), then verify:

```bash
ssh -t admin@infra-host sudo reboot
ansible-playbook -e infra_host=home -u admin --ask-become-pass provision.yml --tags gpu,host
ssh admin@infra-host nvidia-smi                        # the RTX 2060, 12288MiB, driver 580.x
ssh admin@infra-host sudo docker info --format '{{json .Runtimes}}'    # includes "nvidia"
ssh admin@infra-host systemctl list-timers infra-backup.timer           # next run tonight, 02:30 UTC
```

The second run passes "Require nvidia-smi to see the GPU through the loaded driver". With
Secure Boot on, Ubuntu's signed modules load without any key enrolment; if `nvidia-smi` says it
cannot communicate with the driver, `sudo dmesg | grep -i nvidia` says why.

### Release

Run `release` (Actions → Deploy). Besides the usual lines, expect the `ai` and `media` stacks
accepted with their tailnet ports, bind mounts and GPU, "starting ai", "starting media", and
"the tailnet-only ports home:80 home-tls:443 beszel:8090 garage:3900 sftpgo:8091 are bound to
100.x.y.z alone".

```bash
ssh admin@infra-host sudo docker exec llama nvidia-smi -L   # GPU 0: NVIDIA GeForce RTX 2060 (inside the container)
ssh admin@infra-host sudo docker ps --format '{{.Names}} {{.Ports}}'   # ports only on 100.x.y.z
```

`llama` (llama-server, Home's AI) starts with no model loaded and answers `/health`; it
loads a model only when Home asks, from the files of [Home's AI models](#homes-ai-models):

```bash
ssh -t admin@infra-host sudo docker logs llama 2>&1 | grep -i missing   # nothing once the models are downloaded
```

### Home's AI models

llama-server (`stack/ai`, [docs/stacks.md](docs/stacks.md#ai)) serves the GGUF files that
`production.yml`'s `home_ai_models` names, from the `llama-models` volume, which provisioning
creates for the `ai` account. It has no route to the internet, so the owner downloads them
once, here, into the volume (about 23 GB on the SSD):

| Model id | File | Bytes | SHA-256 (Hugging Face's, of the file) | From |
| --- | --- | --- | --- | --- |
| `qwen3-8b` (the default) | `Qwen3-8B-Q5_K_M.gguf` | 5851112224 | `068bae163faa96ad48032daf4e071a6a28fe67d8dcc95367609c2ff165e52738` | [Qwen/Qwen3-8B-GGUF](https://huggingface.co/Qwen/Qwen3-8B-GGUF), Apache-2.0 |
| `gemma-3-12b` | `gemma-3-12b-it-q4_0.gguf` | 8074473920 | shown only after the licence is accepted (below) | [google/gemma-3-12b-it-qat-q4_0-gguf](https://huggingface.co/google/gemma-3-12b-it-qat-q4_0-gguf), Gemma Terms of Use |
| `qwen3-14b` (by day only) | `Qwen3-14B-Q4_K_M.gguf` | 9001752960 | `500a8806e85ee9c83f3ae08420295592451379b4f8cf2d0f41c15dffeb6b81f0` | [Qwen/Qwen3-14B-GGUF](https://huggingface.co/Qwen/Qwen3-14B-GGUF), Apache-2.0 |

**Gemma needs its licence accepted first**: sign in to Hugging Face, open the Gemma repository
above and accept the Gemma Terms of Use, then create a **read** access token (Settings → Access
Tokens) and keep it in 1Password ("infra production secrets", field `HF_TOKEN`). The Qwen files
are public.

On the server (`ssh -t admin@infra-host`), this function downloads one file as the `ai` account
into the volume through a throwaway, read-only curl container (the same pinned image the media
stack uses), resumes an interrupted download, checks the SHA-256 and only then gives the file
its name; with `-` instead of a checksum it prints the file's SHA-256 for you to compare:

```bash
get_model() {  # <file> <url> <sha256, or - to print it>
  sudo docker run --rm --user 2001:2001 --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    -e HF_TOKEN -e FILE="$1" -e URL="$2" -e SHA="$3" -v llama-models:/models --entrypoint sh \
    curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777 -c '
      set -eu
      cd /models
      if [ -n "${HF_TOKEN:-}" ]; then printf "Authorization: Bearer %s\n" "$HF_TOKEN" >/tmp/auth; else : >/tmp/auth; fi
      [ -f "$FILE" ] && { echo "$FILE is already there"; exit 0; }
      if [ -f "$FILE.part" ] && [ "$SHA" != - ] && echo "$SHA  $FILE.part" | sha256sum -c - >/dev/null 2>&1; then
        mv "$FILE.part" "$FILE"; echo "$FILE is in place"; exit 0
      fi
      curl -fL --retry 5 --retry-delay 10 -C - -H @/tmp/auth -o "$FILE.part" "$URL"
      if [ "$SHA" = - ]; then sha256sum "$FILE.part"; echo "compare this with the SHA-256 on the file page, then: mv $FILE.part $FILE (or run again with the checksum)"; exit 0; fi
      echo "$SHA  $FILE.part" | sha256sum -c -
      mv "$FILE.part" "$FILE"
      echo "$FILE is in place"'
}
hf=https://huggingface.co
get_model Qwen3-8B-Q5_K_M.gguf $hf/Qwen/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q5_K_M.gguf 068bae163faa96ad48032daf4e071a6a28fe67d8dcc95367609c2ff165e52738
get_model Qwen3-14B-Q4_K_M.gguf $hf/Qwen/Qwen3-14B-GGUF/resolve/main/Qwen3-14B-Q4_K_M.gguf 500a8806e85ee9c83f3ae08420295592451379b4f8cf2d0f41c15dffeb6b81f0
read -rsp 'Hugging Face token (1Password, HF_TOKEN): ' HF_TOKEN; echo; export HF_TOKEN
get_model gemma-3-12b-it-q4_0.gguf $hf/google/gemma-3-12b-it-qat-q4_0-gguf/resolve/main/gemma-3-12b-it-q4_0.gguf -
unset HF_TOKEN
```

Gemma's last line prints its SHA-256: compare it with the one on its file page
(<https://huggingface.co/google/gemma-3-12b-it-qat-q4_0-gguf/blob/main/gemma-3-12b-it-q4_0.gguf>,
"SHA256", visible once the licence is accepted), then run `get_model` again with that checksum
instead of `-` (the downloaded `.part` is reused, so nothing is fetched twice), and add it to the
table above. The token goes into the container only as an environment variable and a file in its
tmpfs, never onto the command line.

Each file is 6 to 9 GB: about 10 minutes at 100 Mbit/s. Nothing needs restarting: llama-server
opens a file when Home first asks for its model. Check:

```bash
sudo ls -l "$(sudo docker volume inspect llama-models --format '{{.Mountpoint}}')"   # the three files, owned by ai, no .part
sudo docker logs llama 2>&1 | tail                                                  # no "is missing" after the next start
```

**Another model**: add it to `home_ai_models` in `production.yml` (an id, the label and line
Home's picker shows, its file, and whether it is day-only), download its file the same way, and
release (`LLAMA_MODELS` and `HOME_AI_MODELS` both follow the list). It must fit the 12 GB card
with its context ([docs/stacks.md](docs/stacks.md#the-gpu-shared)). **Removing** one: take it out
of the list, release, then `sudo rm` its file from the volume.

### First logins

After the release, from the laptop (on the tailnet):

1. **Home**, `https://home.arbikullakshi.com/setup`: see [Home](#home) for the first setup.
1. **Beszel**, `http://infra-host:8090`: nothing to set up. Sign in with `status_owner_email`
   (`production.yml`) and `BESZEL_PASSWORD`; `infra-host` is already listed
   ([The status dashboard](#the-status-dashboard)).
1. **Files**, `http://infra-host:8091/web/client`: nothing to set up. Sign in as
   `owner` with `FILES_PASSWORD` ([Files](#files-s3-storage)).

### The links page

The links page's two tiles at `https://home.arbikullakshi.com/` were replaced by Home (below).
What is left of it, in the media stack, each on the Tailscale address only:

- `home` (busybox `httpd`, the page is in `stack/media/docker-compose.yml`) on port 80:
  `http://infra-host/` sends the browser on to `https://home.arbikullakshi.com/`, with plain
  links to Home, the file manager (`:8091`), Status (`:8090`) and S3 (`:3900`).
- `home-tls` (Traefik, the edge image) on port 443, for `https://home.arbikullakshi.com/` (Home's
  `home-server`; `/dav` goes to SFTPGo's WebDAV) over the media network, with no read or write
  timeout, so big uploads and long streams pass. It gets one Let's Encrypt certificate for
  `home.arbikullakshi.com` alone by the DNS-01 challenge through Cloudflare's API, so nothing on
  the internet has to reach the server, and keeps it in the `home-tls-acme` volume (not backed
  up: a lost one is simply reissued).

`home` is a DNS-only record (grey cloud, not proxied) to the server's Tailscale address. Off the
tailnet that address leads nowhere, so the record reveals nothing usable. There is no `*.home`
record (deleted 2026-10-28):

```bash
Z=<zone id>        # cf zones list: the id of the apex domain's zone
TS_IP=<100.x.y.z>  # the server's Tailscale IPv4: ssh admin@infra-host tailscale ip -4
cf dns records create -z $Z --body '{"type":"A","name":"home","content":"'"$TS_IP"'","proxied":false,"comment":"tailnet-only Home (home-tls)"}'
```

**The certificate's token.** `home-tls` needs a Cloudflare API token that may read the zone and
edit its DNS records, on arbikullakshi.com only, stored as the `HOME_TLS_CF_DNS_TOKEN` secret.
Create it, keep it in 1Password and set the secret without it ever showing on screen:

```bash
policies='[{"effect":"allow","resources":{"com.cloudflare.api.account.zone.'"$Z"'":"*"},"permission_groups":[{"id":"4755a26eedb94da69e1066d98aa820be"},{"id":"c8fed203ed3043cba015a93ad1616f1f"}]}]'
tok="$(cf user tokens create -q --name 'infra home-tls (arbikullakshi.com DNS edit)' --policies "$policies" | sed -n '/^{/,$p' | jq -r .value)"
[ -n "$tok" ] && [ "$tok" != null ] && op item create --category password --vault "Home Server" --title "Cloudflare DNS token (home TLS)" "password=$tok" >/dev/null &&
  printf %s "$tok" | gh secret set HOME_TLS_CF_DNS_TOKEN --env production -R somethim-home/infrastructure && echo "token stored and set"
unset tok
```

(The two permission groups are **DNS Write** and **Zone Read**.) If `cf` may not create tokens
with its login, use the dashboard instead: **My Profile → API Tokens → Create Token → Edit zone
DNS** template, add the permission **Zone · Zone · Read**, **Zone Resources: Include · Specific
zone · arbikullakshi.com**, create, then store and set it from the clipboard:

```bash
read -rsp 'token: ' tok; echo
op item create --category password --vault "Home Server" --title "Cloudflare DNS token (home TLS)" "password=$tok" >/dev/null &&
  printf %s "$tok" | gh secret set HOME_TLS_CF_DNS_TOKEN --env production -R somethim-home/infrastructure; unset tok
```

A tailnet whose policy predates the page needs `tcp:80` and `tcp:443` added to the admins' grant
to `tag:infra-server` ([Tailscale grants](#tailscale-grants)); until then the page times out.
Provisioning opens 443 in ufw and creates the `home-tls-acme` volume, so provision once before
the release that brings `home-tls`. The release then asks Home's name over https on the
Tailscale address and waits up to 5 minutes for the certificate ("home-tls serves https with a
trusted certificate on 100.x.y.z for home.arbikullakshi.com"): `https://home.arbikullakshi.com/healthz`
must answer 200 (home-server; a 404 means no route, 502 a container home-tls cannot reach). A refused token shows in
`ssh admin@infra-host sudo docker logs home-tls`.

### The status dashboard and S3 secrets

Six new secrets, generated here and kept in the "infra production secrets" item in 1Password
(the dashboard password and the S3 key are the ones you use); none is printed:

```bash
item="infra production secrets"
set_secret() { op item edit "$item" --vault "Home Server" "$1[password]=$2" >/dev/null && printf %s "$2" | gh secret set "$1" --env production -R somethim-home/infrastructure; }
set_secret BESZEL_PASSWORD "$(openssl rand -hex 16)"
set_secret BESZEL_AGENT_TOKEN "$(openssl rand -hex 24)"
set_secret GARAGE_RPC_SECRET "$(openssl rand -hex 32)"
set_secret GARAGE_ADMIN_TOKEN "$(openssl rand -hex 32)"
set_secret GARAGE_OWNER_ACCESS_KEY_ID "GK$(openssl rand -hex 12)"
set_secret GARAGE_OWNER_SECRET_KEY "$(openssl rand -hex 32)"
unset -f set_secret; unset item
```

The file manager (SFTPGo) adds one more, its sign-in password, the same way:

```bash
p="$(openssl rand -hex 16)"; op item edit "infra production secrets" --vault "Home Server" "FILES_PASSWORD[password]=$p" >/dev/null && printf %s "$p" | gh secret set FILES_PASSWORD --env production -R somethim-home/infrastructure; unset p
```

A release refuses to render without all seven. Then provision (it creates the `beszel-data`,
`beszel-agent-data` and `garage-meta` volumes, `/srv/media/s3` and `/srv/media/.beszel`, the
`beszel` role's socket proxy, and opens 3900 and 8090 in ufw; with the file manager also
`sftpgo-data` and 8091), then `release`.

### The status dashboard

Beszel at `http://infra-host:8090` (the all-systems overview,
infra-host and any other retained systems; click one for its page (remove the retired ci-runners row during section 13 cleanup)): CPU, memory, load, temperatures, the GPU
(use, memory, power), the SSD, the media disk and the backup disk, and every container's CPU,
memory and network, with history. Sign in with `status_owner_email` from `production.yml` and
`BESZEL_PASSWORD`:

```bash
op item get "infra production secrets" --vault "Home Server" --fields label=BESZEL_PASSWORD --reveal
```

Everything is code: the hub (`beszel`) creates that login on its first start; `beszel-pair`
makes `BESZEL_AGENT_TOKEN` your universal token and hands the agent the hub's key; the agent
(`beszel-agent`) connects and appears as `infra-host`. It sees Docker only through
`beszel-socket-proxy` (`roles/beszel`), which allows four reads (version, engine info, the
container list, one container's stats): no inspect, so no container's environment, and no
logs, which is why the dashboard's container "details" and "logs" buttons show nothing. The
agent is not on the host network, so the host's own network totals are not shown, only each
container's. The backup disk's size shows once it is mounted; after mounting it by hand,
`ssh admin@infra-host sudo docker restart beszel-agent`. Alerts (e-mail or a webhook) can be set
in the dashboard; they live in `beszel-data`, which the nightly backup copies.

### Files (S3 storage)

**The file manager.** `http://infra-host:8091/web/client` is SFTPGo's web
client on the `files` bucket. It stores only what you put there on purpose (no device backup or
sync of any kind); its file list works like a desktop's:

- **click** a row to select it (Ctrl/⌘-click adds to the selection); **double-click** opens it. On a
  phone, a **tap** opens it.
- Files open in a **full-screen preview** (PDF, images, video, audio, text) with **‹ ›** (or the
  arrow keys) for the previous and next file, **⤓** to download, **✕** or Esc to close. Other files
  show a Download button.
- **Right-click** a row for Open, Download, Rename, Move or copy, Share, Delete. The **⤓** button on
  each row downloads (a folder downloads as a zip).
- Folders open on double-click; drag files onto the page to upload; the search box filters.

Sign in as `owner` with `FILES_PASSWORD`. A sign-in lasts 12 hours,
renewed while you use it (SFTPGo allows no longer), and survives closing the browser and
releases; signing out, or 12 hours without opening the page, ends it:

```bash
op item get "infra production secrets" --vault "Home Server" --fields label=FILES_PASSWORD --reveal
```

**As a drive (WebDAV).** `https://home.arbikullakshi.com/dav` (through `home-tls`, so with
the real certificate), user `owner`, the same password. On the laptop: Nautilus, Other Locations,
`davs://home.arbikullakshi.com/dav`, or `rclone config create homedav webdav
url=https://home.arbikullakshi.com/dav vendor=other user=owner pass="$(rclone obscure "$(op item
get 'infra production secrets' --vault "Home Server" --fields label=FILES_PASSWORD --reveal)")"`. On
Android: a WebDAV-capable file manager (Material Files, Solid Explorer) with that address.

Everything is code: `sftpgo` loads its user from the compose file on every start (mode 0: added,
or updated to match), so the password follows `FILES_PASSWORD` and the storage is always the
`files` bucket with the owner's S3 key. SFTP, FTP, the admin web UI and the REST API are off; an
admin account exists only because SFTPGo requires one, with a random password made new at every
start. Share links, sessions and the key that signs them (`web-signing.key`, made once) live in
`sftpgo-data`, which the nightly backup copies (SFTPGo stopped for that copy alone). The log's first line is `files:
Drive-style file list on`; `files: WARNING … serving SFTPGo's own file list` means the image's
file-list page is not the one the Drive behaviour was written against (a re-pin skipped
`ci/files-ui.sh`): everything still works, only clicks and previews are SFTPGo's own. `ssh admin@infra-host sudo docker logs sftpgo` shows sign-ins and transfers.

**Straight to S3.** Garage at `http://infra-host:3900`: S3-compatible storage, region `garage`, path-style
addressing, bucket `files`, over the tailnet only (plain http; Tailscale encrypts the link).
Objects are on the media disk (`/srv/media/s3`), the metadata on the SSD (`garage-meta`); the
nightly backup stops Garage only while it copies `garage-meta` and `/srv/media/s3` into the same snapshot, so the two match, and starts it right after; a file deleted from the bucket stays in older snapshots for about two months.

The key is the one in 1Password; with rclone on the laptop:

```bash
rclone config create home s3 provider=Other endpoint=http://infra-host:3900 \
  region=garage force_path_style=true \
  access_key_id="$(op item get 'infra production secrets' --vault "Home Server" --fields label=GARAGE_OWNER_ACCESS_KEY_ID --reveal)" \
  secret_access_key="$(op item get 'infra production secrets' --vault "Home Server" --fields label=GARAGE_OWNER_SECRET_KEY --reveal)"
rclone copy ~/Documents/report.pdf home:files/
rclone ls home:files
```

Copy deliberately (`rclone copy`); nothing here is set up to sync or back up a device on its own,
and none should be. Any S3 client works the same way (Cyberduck, S3 Files, …): S3-compatible, server
`infra-host`, port 3900, no TLS, path-style. `garage-setup` assigns the node's layout once,
imports your key (`garage-setup.env`) and gives it read, write and owner rights on `files` on
every release; `ssh admin@infra-host sudo docker logs garage-setup` shows what it did. More
buckets: add their names to `GARAGE_BUCKETS` in `stack/media/docker-compose.yml` and release.
Garage's own web UIs are not used (the one community UI has had no release in a year and would
need Garage's full admin token); the file manager above is the interface.

### Home

Home (`stack/home`, image `ghcr.io/somethim-home/home-server`, built by the `somethim-home/home`
repository) is the owner's own app at `https://home.arbikullakshi.com/`: sign-in (password,
authenticator app, passkeys, recovery codes), the dashboard and Home Files, the family's
end-to-end encrypted storage. One container, `home-server`, behind `home-tls`; it follows
`:latest` with Watchtower like the portfolio. What it is made of is in
[docs/stacks.md](docs/stacks.md#home).

**First deploy**: [docs/deploy-home.md](docs/deploy-home.md) is the whole checklist (provisioning,
the secrets, the AI models, the release and the first-run checks of every app). The steps for
Home's own settings, in this order:

1. **The owner's address**, a repository variable (not in the `production` Environment): setup
   and recovery links only ever go there, and a release refuses to render without it.

   ```bash
   gh variable set HOME_OWNER_EMAIL -R somethim-home/infrastructure --body '<your address>'
   ```

2. **Resend**: `arbikullakshi.com`, the domain of `home@arbikullakshi.com`, must be verified in
   Resend, or every mail is refused and the setup link never arrives. The portfolio already
   sends from `contact@arbikullakshi.com`, so it should be; check under Domains. Create an API
   key with sending access, named "infra Home", and set it:

   ```bash
   read -rsp 'Resend API key: ' k; echo
   op item edit "infra production secrets" --vault "Home Server" "HOME_RESEND_API_KEY[password]=$k" >/dev/null &&
     printf %s "$k" | gh secret set HOME_RESEND_API_KEY --env production -R somethim-home/infrastructure; unset k
   ```

3. **The two keys**, new, different, kept in 1Password (`HOME_DATA_KEY` is the only copy of the
   key to every enrolled second factor and to the AI chats; it is not in the backups):

   ```bash
   item="infra production secrets"
   set_secret() { op item edit "$item" --vault "Home Server" "$1[password]=$2" >/dev/null && printf %s "$2" | gh secret set "$1" --env production -R somethim-home/infrastructure; }
   set_secret HOME_SECRET_KEY "$(openssl rand -base64 32)"
   set_secret HOME_DATA_KEY "$(openssl rand -base64 32)"
   unset -f set_secret; unset item
   ```

   And **TMDB's API Read Access Token** for Media's online details (themoviedb.org → Settings →
   API, the long `eyJ…` token, not the short API key), the same way as the Resend key:

   ```bash
   read -rsp 'TMDB API Read Access Token: ' k; echo
   op item edit "infra production secrets" --vault "Home Server" "HOME_TMDB_READ_TOKEN[password]=$k" >/dev/null &&
     printf %s "$k" | gh secret set HOME_TMDB_READ_TOKEN --env production -R somethim-home/infrastructure; unset k
   ```

4. **The GHCR token** must be able to read `ghcr.io/somethim-home/home-server` (a classic token
   with `read:packages` reads every package its account can; if `GHCR_USERNAME` is not a member
   of `somethim-home`, give it read access to the package).
5. **Provision** (`ansible-playbook -e infra_host=home -u admin --ask-become-pass provision.yml`, or
   `--tags common,host`): it adds `HOME_USER` and `HOME_IMAGE_REPO` to `/etc/infra/host.env`, creates the
   `home-server` account (uid 65532, the image's), the `home-data` and `home-keys` volumes,
   `/srv/media/home-files` (0700, 65532), the internal `home-llm` network and the `llama-models`
   volume, and installs the compose guard that lets home-server have the GPU, the film and series
   library and the `media` group. A release before this is refused ("HOME_USER is not …; run
   provisioning", or "service home-server sets group_add, which a release may not set").
6. **Release** (Actions → Deploy). Expect "compose model accepted: 2 service(s) in the home
   stack …", "starting home", `home-keys` among the finished one-shots, and home-tls serving
   `home.arbikullakshi.com` (its `/healthz` from home-server).
7. Open `https://home.arbikullakshi.com/setup` on the tailnet and ask for the setup link. It
   arrives by mail at `HOME_OWNER_EMAIL` from `Home <home@arbikullakshi.com>`; open it, press
   Continue, set the password and at least one second step (authenticator app or passkey), and
   keep the 10 recovery codes it shows once in 1Password. The link works once.

**Owner recovery**, when every factor and recovery code is lost: on the server,

```bash
ssh -t admin@infra-host sudo docker exec home-server /home-server reset-owner
```

removes the owner's password, factors, sessions and devices; setup runs again (step 7). The
family's accounts are untouched.

**Files pool.** Home Files hands out `home_files_capacity` (`production.yml`, 600G) from the media
disk; the owner sees and sets allocations at `/admin/storage`. The disk also holds Garage's
objects and the kept library folders, so raise the pool only as far as the disk allows, then
release.

**Status card.** Off until a read-only Beszel user exists; creating it is a manual step in
Beszel's own admin pages:

1. `http://infra-host:8090/_/` (PocketBase's admin pages), sign in as its
   superuser (on this hub, `status_owner_email` and `BESZEL_PASSWORD`; not checked against a
   running hub yet).
2. Collections → `users` → New record: an email of your choosing (e.g. a `+home` alias of
   yours), a password from `openssl rand -hex 16`, role `readonly`, verified on. Save.
3. Collections → `systems` → `infra-host` → add that user to `users`. Save.
4. Put the email in `production.yml` (`home_beszel_user`) on `master`, set the password as the
   `HOME_BESZEL_PASSWORD` secret (and in 1Password), and release. home-server then reads
   `http://beszel:8090` over the media network.

**Media** reads and writes the film and series library (`/srv/media/movies` and `/srv/media/shows`,
at `/data/media/films` and `/data/media/series` in home-server): copy films in as `admin` (the
folders are setgid `media` and group-writable; keep new folders group-writable, `mkdir -m 2775`,
so Home can write its `.nfo` files and pictures next to the videos), as `Title (Year)/Title
(Year).mkv` and `Show (Year)/Season 01/Show - S01E01 - Name.mkv`. A library copied in before
Home may have folders only `media` can write; `sudo chmod -R g+w /srv/media/movies /srv/media/shows`
lets Home write there too. **Books** keeps its library in `home-data` (`/data/books`) and fetches
Project Gutenberg's catalog and books from `www.gutenberg.org` over https. **AI** answers through
llama-server ([Home's AI models](#homes-ai-models)). What each needs and why:
[docs/stacks.md](docs/stacks.md#home).

**Logs**: `ssh admin@infra-host sudo docker logs home-server` (sign-ins, mail sent or refused by
Resend, Media scans, Books' catalog, AI answers), `sudo docker logs home-keys` ("the keys and
passwords are in place"), `sudo docker logs llama` (models loading and unloading).

### Home's power control

Home can switch the server off or restart it (after its own 10-second countdown) by handing the host one
signed request; the host checks it and runs `systemctl poweroff` or `reboot`, at most once per
10 minutes ([docs/host.md](docs/host.md#power-requests-from-home)). The key the requests are
signed with is made **on the server** by provisioning; the `HOME_POWER_KEY` secret is a copy of
it. **Owner action**, once:

1. **Provision with `--tags common,host`**, before the first release that carries this change.
   `host` makes `/etc/infra/home-power.key` (root, 0600, never printed), mounts the request
   directory `/run/home-power` and starts `home-power.path`; `common` installs the compose guard
   that allows home-server's bind mount of it and the `infra-apply` that checks `HOME_POWER_KEY`.
   Every release from now on mounts the directory into home-server, with or without the key, so
   without this step the release is refused (old guard) or home-server cannot start (no
   directory).

   ```bash
   ansible-playbook -e infra_host=home -u admin --ask-become-pass provision.yml --tags common,host
   ssh admin@infra-host systemctl is-active home-power.path      # active
   ssh admin@infra-host findmnt /run/home-power                   # tmpfs … mode=700,uid=65532,gid=65532
   ```

2. **Copy the key into the secret** (and 1Password) without showing it:

   ```bash
   read -rsp 'admin sudo password: ' pw; echo
   k="$(printf '%s\n' "$pw" | ssh admin@infra-host 'sudo -S -p "" cat /etc/infra/home-power.key')"; unset pw
   [[ "$k" =~ ^[A-Za-z0-9+/]{43}=$ ]] &&
     op item edit "infra production secrets" --vault "Home Server" "HOME_POWER_KEY[password]=$k" >/dev/null &&
     printf %s "$k" | gh secret set HOME_POWER_KEY --env production -R somethim-home/infrastructure; unset k
   ```

3. **Release.** `infra-apply` refuses the bundle if the secret is not the host's key ("HOME_POWER_KEY
   is not this host's power key"); then redo step 2. With it, `home-keys` writes
   `/run/keys/power_key` and home-server gets `HOME_POWER_DIR=/run/power`.
4. **Check that junk is refused** (nothing is powered off):

   ```bash
   ssh -t admin@infra-host 'echo junk | sudo tee /run/home-power/request.json >/dev/null; sleep 2; sudo journalctl -t home-power -n 1 --no-pager'
   # home-power: refused request.json: it is not JSON; removed
   ```

5. **A real request** (reboots the server; at a quiet moment), signed exactly as Home signs it,
   in a session on the server (`ssh -t admin@infra-host`):

   ```bash
   sudo python3 -I - <<'PY'
   import base64, hashlib, hmac, json, os, secrets, time
   key = base64.b64decode(open("/etc/infra/home-power.key").read().strip())
   action, at, nonce = "reboot", int(time.time()), secrets.token_hex(16)
   mac = hmac.new(key, f"home-power/v1\n{action}\n{at}\n{nonce}".encode(), hashlib.sha256).hexdigest()
   with open("/run/home-power/.request.tmp", "w") as f:
       json.dump({"action": action, "requested_at": at, "nonce": nonce, "hmac": mac}, f)
   os.rename("/run/home-power/.request.tmp", "/run/home-power/request.json")
   PY
   sudo journalctl -t home-power -n 1 --no-pager    # accepted reboot, requested 0 s ago; reboot in 5 s
   ```

   With `"poweroff"` instead, the server stays off: [Wake-on-LAN](#wake-on-lan) brings it back.

**Logs**: `ssh -t admin@infra-host sudo journalctl -t home-power` (one line per request: accepted, or
refused and why; never the request itself). A refused request is harmless; if they come from Home
and say `wrong hmac`, the secret and the host's key differ (step 2, then release).
**Stuck**: `systemctl --failed` listing `home-power.service` means the key or the state cannot be
read (the journal says which); `home-power.path` failed after a burst of requests (its trigger
limit): `sudo systemctl reset-failed home-power.path && sudo systemctl start home-power.path`.
**Off**: delete the `HOME_POWER_KEY` secret and release; Home then offers no power control.

### Phones

Install Tailscale on the device (App Store / Play Store) and sign in with the same account as
the laptop, so it is one of `autogroup:admin`'s devices. Then open
`https://home.arbikullakshi.com/` (Home) or the addresses in the table above:

- Files in the browser (`http://infra-host:8091/web/client`), or WebDAV at
  `https://home.arbikullakshi.com/dav`
- S3 apps: server `infra-host`, port 3900, TLS off, path-style, region `garage`

The phone resolves `home.arbikullakshi.com` through public DNS (the record points at the
Tailscale address) and `infra-host` through Tailscale's MagicDNS. A device that is not on the
tailnet gets nothing, by design.

### Retired apps (2026-10-20)

The media engine, Audiobookshelf, Kavita, Open WebUI, SearXNG and ComfyUI no longer run (Immich,
the photo backup, too; since plan 023 nothing of it is provisioned or backed up, see below);
the owner's own apps replace them: Home's Media now uses `shows` and `movies`, and Home's AI
replaces Open WebUI. Their volumes and the other folders under `/srv/media` (`audiobooks`,
`podcasts`, `books`) are kept, still created by provisioning and still backed up nightly (except
caches), and nothing deletes them.

**Immich's leftovers** (owner, 2026-10-28: no automatic photo or drive backup, only deliberate
storage). Provisioning no longer creates `/srv/media/photos`, the `immich-*` volumes or the
`immich` network, and the nightly backup no longer copies them; what is on the server stays until
you delete it. Copy out anything you want to keep first (the old snapshots on the backup disk
hold it for about two more months), then:

```bash
ssh -t admin@infra-host 'sudo rm -rf /srv/media/photos /srv/backup/immich; sudo docker volume rm immich-pgdata immich-ml-cache; sudo docker network rm immich'
``` What is kept, and what the owner may clean up (the four unused secrets, the old
Tailscale grants), is in [docs/stacks.md](docs/stacks.md#retired-apps-2026-10-20).

### Removing Ollama's models

Ollama (and its one-shot `ollama-pull`) no longer run: llama-server is the only AI engine. A
release removes the two containers from the `ai` stack by
itself (`docker compose up --remove-orphans`), but provisioning neither creates nor deletes the
old `ollama-models` volume (about 21 GB on the SSD, the models it pulled) or the `ai` and `llm`
networks, and the nightly backup never copied the volume. **On a clean reinstall none of this
exists; skip it.** On a server that still has them, once a release without Ollama is current:

```bash
ssh -t admin@infra-host
sudo docker ps -a --filter name=ollama --format '{{.Names}} {{.Status}}'   # nothing; if a container is listed, release first
sudo docker volume inspect ollama-models --format '{{.Mountpoint}}'          # exists?
sudo du -sh "$(sudo docker volume inspect ollama-models --format '{{.Mountpoint}}')"  # what it frees
sudo docker volume rm ollama-models                                          # refuses while a container uses it
sudo docker network rm ai llm                                                # refuses while a container is attached
sudo docker system df -v | grep -i ollama                                    # nothing left
```

The pulled `ollama/ollama` image goes with the next `docker-prune` run, or now with
`sudo docker image rm ollama/ollama:0.40.4`. Nothing of Ollama is in the backups, so there is
nothing to remove there.

## 13. Retire the home CI runners

**Done, 2026-10-20.** The self-hosted GitHub Actions runners this host once ran for another project were removed by a one-time
`roles/ci_runners` removal run (registrations, the `ci-runners` Incus instance, its firewall
unit, hooks and chains, the `incusbr-ci` bridge and its ufw rules, the `ci` pool and the Beszel
row), which was then deleted from the repository. That project's CI runs on GitHub-hosted runners. Incus
stays installed for later instances.

`tag:infra-ci` and the Tailscale OAuth client used by this repo's Deploy workflow are separate from
those runners; GitHub-hosted deploy jobs still need them.

## 14. Snowflake

The host runs Tor's standalone Snowflake proxy (roles/snowflake,
[docs/host.md](docs/host.md#snowflake)): it relays up to 10 censored users at once to Tor's
Snowflake bridge over WebRTC. Host network, fenced by uid 64999 off every local and private
address; no port published.

**Turn it on or update it** (provisioning; there is nothing to release):

```bash
# from a clean worktree of this repository (here ~/.cache/infra-clean), at origin/master
git fetch -q && cd ~/.cache/infra-clean && git checkout -q --detach origin/master
ansible-playbook -e infra_host=home -u admin --ask-become-pass provision.yml --tags snowflake
```

The run ends with the proxy's NAT type (`restricted` is normal behind a home router;
`unrestricted` is best; `strict` or `unknown` means fewer users can be matched).

**See what it does:**

```bash
ssh -t admin@infra-host 'sudo docker logs snowflake-proxy 2>&1 | grep -iE "connections|NAT type" | tail'
```

Every hour it logs a summary: completed connections and traffic relayed.

**Stop it:** set `snowflake_enabled: false` in `production.yml`, merge to `master`, and run the
same provisioning command; it removes the container, its fence and its files. To pause it for a
while instead: `ssh -t admin@infra-host sudo docker stop snowflake-proxy` (it starts again at the
next boot or provisioning run).

**Re-pin**: docs/agents.md, "Re-pinning third-party images".

## 15. Hetzner host

The public portfolio and its PostgreSQL run on their own small server (plan 023), so the home
server runs only Home. What runs there: `database` (the portfolio's PostgreSQL, dumped to R2
every day), `portfolio` (its media in Cloudflare R2), the edge Traefik on 80 and 443, which only
Cloudflare reaches, Watchtower and autoheal. No tunnel: Cloudflare proxies the names and connects
to the server's public address, SSL/TLS **Full (strict)** with a Cloudflare Origin CA
certificate and **Authenticated Origin Pulls** ([docs/edge.md](docs/edge.md)).

| | |
| --- | --- |
| Server | Hetzner Cloud **CAX (Arm64)**, Nuremberg, **Ubuntu 26.04 LTS arm64** (`resolute`), 2 vCPU, 4 GB |
| Public addresses | `138.199.170.38`, `2a01:4f8:c016:f67c::1` |
| Tailnet name | `infra-hetzner` (`production.yml`, `infra_hosts.hetzner.server_name`), tag `tag:infra-server` |
| Inventory | `[hetzner]` in `inventory/hosts`; every run `-e infra_host=hetzner` |
| Deploy | Actions → Deploy, host `hetzner` |

Every image it runs is pinned to a multi-arch index digest with `linux/arm64`, and Docker and
Tailscale come from their apt repositories for `resolute`, which carry arm64. The portfolio's own
image must be built for arm64 too (the portfolio repository).

The move, in order. Nothing changes for visitors until step 10. Nothing is copied from the home
server (owner, 2026-10-28: the old portfolio data is not worth keeping): the portfolio starts
here with an empty database and empty R2 buckets.

### 1. The server and its firewall

**Owner action**, in the Hetzner Cloud console. The server exists (CAX, Nuremberg, Ubuntu 26.04
arm64, your laptop's key for `root`). Create a **Firewall** and apply it to the server:

| Direction | Protocol | Port | Source |
| --- | --- | --- | --- |
| Inbound | ICMP | | Any IPv4, any IPv6 |
| Inbound | TCP | 80 | Cloudflare's ranges, below |
| Inbound | TCP | 443 | Cloudflare's ranges, below |
| Inbound | TCP | 22 | **your laptop's public address only, and only until step 4** |

Nothing else inbound; outbound is open. Cloudflare's ranges (2026-10-28,
<https://www.cloudflare.com/ips-v4>, <https://www.cloudflare.com/ips-v6>; `production.yml`
`cloudflare_ips_pinned` holds the same list):

```
173.245.48.0/20  103.21.244.0/22  103.22.200.0/22  103.31.4.0/22   141.101.64.0/18
108.162.192.0/18 190.93.240.0/20  188.114.96.0/20  197.234.240.0/22 198.41.128.0/17
162.158.0.0/15   104.16.0.0/13    104.24.0.0/14    172.64.0.0/13   131.0.72.0/22
2400:cb00::/32   2606:4700::/32   2803:f800::/32   2405:b500::/32  2405:8100::/32
2a06:98c0::/29   2c0f:f248::/32
```

The host enforces the same itself (ufw and `infra-firewall`, from the ranges provisioning fetches),
so the cloud firewall is a second lock, not the only one. When Cloudflare changes its ranges, a
hetzner provisioning run says so: update this firewall and `cloudflare_ips_pinned` together.

### 2. A Tailscale auth key

**Owner action.** As in [section 4](#4-tailscale): a pre-approved, single-use auth key with the
tag `tag:infra-server`. The grants that let your devices and `tag:infra-ci` reach
`tag:infra-server` on 22 already cover the new node.

### 3. First provision, over the public address

**Owner action**, on your laptop. The Hetzner image has only `root`, and provisioning never logs
in as root, so first make a bootstrap account the way the Ubuntu installer would (it is removed
in step 4; root login is turned off by this run):

```bash
H=138.199.170.38
ssh-keyscan -t ed25519 $H | ssh-keygen -lf -      # compare with the console's (Rescue → or the server's first boot log)
ssh-keyscan -t ed25519 $H >> ~/.ssh/known_hosts
ssh root@$H 'lsb_release -cs; uname -m'           # resolute, aarch64
ssh -t root@$H 'adduser --gecos "" setup && usermod -aG sudo setup &&
  install -d -m 0700 -o setup -g setup /home/setup/.ssh &&
  install -m 0600 -o setup -g setup /root/.ssh/authorized_keys /home/setup/.ssh/authorized_keys'
ssh setup@$H true                                 # no password prompt
```

`/root/.ssh/authorized_keys` must hold only your own plain key lines (the run checks `setup`'s
copy). Then:

```bash
cp -n inventory/hosts.example inventory/hosts
sed -i "s/^infra-hetzner ansible_host=.*/infra-hetzner ansible_host=$H/" inventory/hosts
ansible-playbook -e infra_host=hetzner -u setup --ask-become-pass provision.yml
```

`BECOME password` is `setup`'s; enter the auth key from step 2 at `Tailscale auth key for
infra-hetzner`. Expect, besides what section 5 lists for the home server: "Cloudflare's 22 address
ranges, fetched from cloudflare.com", ufw rules admitting each range to 80 and 443, the `edge`
and `data` networks and the empty `pgdata-v18` volume, `infra-pg-backup.timer` enabled, and
Traefik up with 80 and 443 published. No GPU, quiet hours, Beszel or Snowflake here. Then:

```bash
ssh -t setup@$H sudo passwd admin                 # the admin sudo password: keep it in your password manager
ssh-keyscan -t ed25519 infra-hetzner | ssh-keygen -lf -    # the same fingerprint as above
ssh-keyscan -t ed25519 infra-hetzner > /tmp/kh-hetzner && cat /tmp/kh-hetzner >> ~/.ssh/known_hosts
ssh admin@infra-hetzner true
```

### 4. Second provision, over the tailnet

**Owner action.**

```bash
sed -i 's/^infra-hetzner ansible_host=.*/infra-hetzner ansible_host=infra-hetzner/' inventory/hosts
ansible-playbook -e infra_host=hetzner -u admin --ask-become-pass provision.yml
ssh admin@infra-hetzner sudo rm -f /root/.ssh/authorized_keys
```

It closes 22 in ufw and removes `setup`. Now **delete the TCP 22 rule from the Hetzner Cloud
Firewall**, and check from the laptop:

```bash
nc -z -w 5 138.199.170.38 22                      # times out
ssh admin@infra-hetzner sudo ufw status           # 22 on tailscale0; 80,443 from each Cloudflare range
ssh admin@infra-hetzner sudo iptables -S INFRA-PUBLIC | head -3   # -s <Cloudflare range> ... --ctorigdstport 80 -j RETURN
ssh admin@infra-hetzner sudo docker ps --format '{{.Names}} {{.Ports}}'   # only edge-traefik, on 80 and 443
```

### 5. Cloudflare: R2, the origin certificate, Authenticated Origin Pulls

**Owner action**, in the Cloudflare dashboard of the account that holds `arbikullakshi.com`.
None of this changes what visitors see: the names still point at the home server's tunnel.

1. **R2 buckets.** The portfolio's two media buckets and the custom domain of the public one, as
   the portfolio's plan 011 says (their names become `R2_PUBLIC_BUCKET` and `R2_PRIVATE_BUCKET`,
   the public base URL, `https://media.arbikullakshi.com`, `MEDIA_PUBLIC_BASE`), and a third,
   private bucket **`portfolio-backups`** with a lifecycle rule: **delete objects 30 days after
   upload**.
2. **Two R2 API tokens** (R2 → Manage API tokens → Create API token, *Object Read & Write*,
   *Apply to specific buckets only*):
   - **portfolio**: the two media buckets. Its Access Key ID and Secret Access Key become
     `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`.
   - **portfolio-backups**: that bucket alone. Its pair becomes `R2_BACKUP_ACCESS_KEY_ID` and
     `R2_BACKUP_SECRET_ACCESS_KEY`. The portfolio's own key never reaches its backups.
   The account ID (R2 overview) is `R2_ACCOUNT_ID`.
3. **Origin certificate**: SSL/TLS → Origin Server → **Create Certificate**: let Cloudflare
   generate the key, hostnames `arbikullakshi.com` and `*.arbikullakshi.com`, validity 15 years,
   format PEM. Keep the certificate and the private key (shown once) in your password manager;
   they become `CF_ORIGIN_CERT` and `CF_ORIGIN_KEY`.
4. **Authenticated Origin Pulls**: SSL/TLS → Origin Server → **Authenticated Origin Pulls: On**
   (zone-level). Cloudflare then presents its client certificate to every origin; the tunnel to
   the home server is not affected.
5. **SSL/TLS mode Full (strict)**: SSL/TLS → Overview. Never *Flexible*. **Always Use HTTPS**
   stays on.
6. **A preview name**: DNS → Records → proxied `A` `next` → `138.199.170.38` and proxied `AAAA`
   `next` → `2a01:4f8:c016:f67c::1`.

### 6. Secrets and variables

**Owner action**, with `gh` in the checkout (the `production` Environment, as in
[section 7](#7-the-production-environment)). The database passwords, `PORTFOLIO_*`, `GHCR_*`,
`SSH_PRIVATE_KEY` and the Tailscale OAuth client are already set and stay as they are.

```bash
# The host key: SSH_KNOWN_HOSTS holds one line per host
{ ssh-keyscan -t ed25519 infra-host; cat /tmp/kh-hetzner; } | gh secret set SSH_KNOWN_HOSTS --env production && rm /tmp/kh-hetzner
gh variable set HETZNER_SSH_HOST --env production --body infra-hetzner

# R2 (step 5); paste each value at the prompt
for name in R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BACKUP_ACCESS_KEY_ID R2_BACKUP_SECRET_ACCESS_KEY; do
  gh secret set "$name" --env production
done
gh variable set R2_PUBLIC_BUCKET --env production --body '<public bucket>'
gh variable set R2_PRIVATE_BUCKET --env production --body '<private bucket>'
gh variable set MEDIA_PUBLIC_BASE --env production --body 'https://media.arbikullakshi.com'

# The origin certificate and key (step 5), from the files you saved
gh secret set CF_ORIGIN_CERT --env production < origin.pem
gh secret set CF_ORIGIN_KEY --env production < origin.key && shred -u origin.key
```

Compare `ssh-keyscan -t ed25519 infra-host | ssh-keygen -lf -` with the home server's known
fingerprint before trusting it again.

### 7. First release

**Owner action.** In `production.yml` on `master`, set `preview_domain: next.arbikullakshi.com`
(Traefik then routes that name to the portfolio too). Then Actions → Deploy, host **`hetzner`**,
action `release`. Expect:

```
infra-apply: compose model accepted: 1 service(s) in the database stack, ...
infra-apply: compose model accepted: 1 service(s) in the portfolio stack, ...
infra-apply: bundle accepted: 11 files, manifest checksums match
infra-apply: pulling images
infra-apply: starting the database
infra-apply: database roles, passwords and grants are in place
infra-apply: the origin certificate and the client-certificate rule are in place for Traefik
infra-apply: starting portfolio
infra-apply: every container is running and healthy, and has run for at least 30s without a restart
infra-apply: Traefik redirects http to https and refuses https without Cloudflare's client certificate for arbikullakshi.com/api/health www.arbikullakshi.com/
infra-apply: edge-socket-proxy edge-traefik watchtower-socket-proxy watchtower autoheal-socket-proxy autoheal: each client reaches Docker through its socket proxy with no refused calls
infra-apply: Cloudflare serves https://arbikullakshi.com/api/health https://www.arbikullakshi.com/ http://arbikullakshi.com/api/health
infra-apply: RELEASE OK: <id> is current, following :latest, auto-updates on
```

PostgreSQL initialises the empty `pgdata-v18`, `provision.sql` creates the `portfolio` role and
database, and the portfolio seeds it on its first start (its operator account from
`PORTFOLIO_ADMIN_PASSWORD`). Until step 10 the public check ("Cloudflare serves …") still reaches the home server;
it passes, but proves nothing about this host yet. Then check the first dump runs:

```bash
ssh admin@infra-hetzner sudo systemctl start infra-pg-backup && ssh admin@infra-hetzner sudo journalctl -u infra-pg-backup -n 3 --no-pager
# infra-pg-backup: portfolio database dumped to portfolio-backups/portfolio-<time>.dump
```

### 8. A fresh start

Nothing to copy. Sign in at `https://next.arbikullakshi.com/admin` with
`ADMIN_EMAIL` (`contact@arbikullakshi.com`) and `PORTFOLIO_ADMIN_PASSWORD`, and add the content
there. Passkeys, TOTP and Google sign-in are bound to `arbikullakshi.com`: enrol them after
step 10.

### 9. Check on the preview name

Open `https://next.arbikullakshi.com`:

- the pages load, and pictures and videos come from `media.arbikullakshi.com`;
- in the admin (password sign-in), upload a picture and see it published to R2 (it loads from
  `media.arbikullakshi.com`).

### 10. Switch the names

**Owner action**, in Cloudflare → DNS → Records:

1. Delete the `CNAME` records of `arbikullakshi.com` and `www` (they point at
   `<tunnel id>.cfargotunnel.com`), and create for each name a proxied `A` → `138.199.170.38`
   and a proxied `AAAA` → `2a01:4f8:c016:f67c::1`. Proxied records switch at once.
2. Delete `hypernova.arbikullakshi.com` (hypernova is retired) and the two `next` records.
3. Check from the laptop:

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' https://arbikullakshi.com/api/health            # 200
   curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://www.arbikullakshi.com/ # 301 https://arbikullakshi.com/
   curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' http://arbikullakshi.com/      # 301 https://arbikullakshi.com/
   curl -sS -o /dev/null -w '%{http_code}\n' --resolve arbikullakshi.com:443:138.199.170.38 -k https://arbikullakshi.com/   # 000: no client certificate, refused
   ```

4. Set `preview_domain: ""` in `production.yml` on `master`, and run Deploy, host `hetzner`,
   action `release`: its public check now proves the path to this host.
5. Sign in at `https://arbikullakshi.com/admin`, enrol TOTP and passkeys, and connect Google
   Calendar if you use it.
6. Redeploy the down-page Worker ([The down page](#the-down-page)): it drops the hypernova route.

### 11. Clean up the home server

**Owner action**, once the site has run from this host for a day.

1. **Provision and release the home server** with this repository's version (the home server's
   `/etc/infra/host.env` gains `INFRA_HOST=home` and its `infra-apply` learns the per-host layout;
   a home release before this provision fails with "INFRA_HOST is neither home nor hetzner"):

   ```bash
   ansible-playbook -e infra_host=home -u admin --ask-become-pass provision.yml
   ```

   then Actions → Deploy, host `home`, action `release`.
2. **Remove the public stacks, the tunnel, the edge and their data** there (their release files
   are no longer in a home bundle, so remove them directly; the old portfolio and hypernova data
   is not kept):

   ```bash
   ssh admin@infra-host 'sudo docker rm -f portfolio prizm-provider prizm-web cloudflared edge-traefik edge-socket-proxy postgresql'
   ssh admin@infra-host 'sudo docker volume rm pgdata-v18 portfolio-media hypernova_prizm-storage'
   ssh admin@infra-host 'sudo docker network rm edge data edge-socket && sudo rm -rf /opt/edge'
   ```

   The nightly backup skips the database dump once `postgresql` is gone; the old snapshots on the
   backup disk age out in about two months.
3. **Delete the tunnel**: Cloudflare → Zero Trust → Networks → Tunnels → `home-server` → Delete.
4. **Delete the secrets nothing reads any more** (hypernova is retired and no host runs a
   tunnel):

   ```bash
   for name in CF_TUNNEL_TOKEN PRIZM_DB_PASSWORD HYPERNOVA_SESSION_SECRET HYPERNOVA_ADMIN_PASSWORD; do
     gh secret delete "$name" --env production
   done
   ```

### Restoring the portfolio database

Dumps are in the private R2 bucket `portfolio-backups`, one a day for 30 days
(`portfolio-<UTC time>.dump`, `pg_dump --format=custom`). On the hetzner host, with the backup
key the release wrote (it may write to the bucket, so it may read it too):

```bash
ssh admin@infra-hetzner
I=$(sed -n 's/^readonly rclone_image=//p' /usr/local/sbin/infra-pg-backup)
E=/opt/infra/current/database/backup.env
sudo docker run --rm --env-file $E $I lsf :s3:portfolio-backups | tail -3        # the newest dumps
sudo docker stop portfolio
sudo docker run --rm --env-file $E $I cat :s3:portfolio-backups/portfolio-<time>.dump |
  sudo docker exec -i postgresql pg_restore --clean --if-exists --no-owner --role=portfolio -U postgres -d portfolio
sudo docker start portfolio
```

The media are in R2 already; nothing on the server needs restoring. **A new hetzner server**: steps
1 to 7, then the restore above.

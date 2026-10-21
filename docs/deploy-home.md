# Deploying Home: a clean-slate reinstall

One ordered path from a blank machine to everything live: the public sites (portfolio,
hypernova) through the tunnel, and on the tailnet Home (the web app at `/app`, sign-in, Files,
Media, Books, AI with live updates, the power button), the status dashboard and Files (S3), the
host's encrypted DNS and the nightly backup. The server is wiped and reinstalled: a fresh
Ubuntu, no users, no data on the SSD. What lives in the cloud stays as it is and is reused: the
Cloudflare Tunnel and its DNS records, the Tailscale policy and OAuth client, the GitHub
`production` Environment, the GHCR images, Resend and TMDB.

**What survives the wipe.** Only the SSD is reinstalled. The **1 TB internal HDD** (`/srv/media`:
Garage's objects, Home Files' ciphertext, the films and series) and the **1 TB external USB HDD**
(`/srv/backup`: the nightly snapshots) are separate disks: an OS reinstall does not touch them,
as long as the installer is pointed at the SSD and nobody formats them. Provisioning mounts them
again by the UUIDs already in `production.yml` ([step 10](#10-restore-from-the-old-servers-backups)
says what goes with them).

> **Never generate new `HOME_DATA_KEY` or `HOME_SECRET_KEY` for a server that already has users.**
> `HOME_DATA_KEY` seals every enrolled second factor and the AI chats: a new one locks everyone
> out of their second step and makes the chats unreadable. Only a server with no Home data yet
> gets new keys: this reinstall qualifies **unless you restore Home's data from the old backups**
> ([step 10](#10-restore-from-the-old-servers-backups)), which needs the keys that data was made with.

Every step is an **Owner action**. Commands run on your laptop, on the tailnet, in a checkout of
`master` with `gh` logged in to `somethim-home/infrastructure` and `op` signed in to 1Password,
unless a step says "on the server" (`ssh -t admin@infra-host`) or "at the console". No command
prints a secret.

What each piece is and why: [RUNBOOK.md](../RUNBOOK.md) (the server, in the order it was first
built), Home's stack in [stacks.md](stacks.md#home), llama-server in [stacks.md](stacks.md#ai),
the GPU budget in [stacks.md](stacks.md#the-gpu-shared), encrypted DNS in
[host.md](host.md#encrypted-dns), every secret in [deploying.md](deploying.md#secrets-and-variables).

## Decide first: fresh, or some of the old data back

Make this choice before [step 5](#5-the-secrets), because it decides which keys you keep:

| You want back | Keep these secrets as they are | Restore in step 10 |
| --- | --- | --- |
| nothing (a truly clean slate) | none of the keys; every generated value can be new | nothing; the media disk's films and series are picked up again by Home's scan |
| the portfolio (its database and uploads) | `PORTFOLIO_TOTP_ENCRYPTION_KEY` (else every enrolled TOTP is unreadable) | the `portfolio` database and `portfolio-media` |
| hypernova's data | none (its session secret only signs sessions) | the `prizm` database and `hypernova_prizm-storage` |
| Home (accounts, chats, Books, Media progress, Home Files) | `HOME_DATA_KEY` and `HOME_SECRET_KEY` | `home-data` and `/srv/media/home-files`, together |
| Files (the S3 bucket) and the dashboard's history | none (the owner's S3 key is imported again) | `garage-meta` with `/srv/media/s3`, together; `beszel-data`, `sftpgo-data` |

Database passwords can be new either way: every release sets each role's password from the
secrets ([RUNBOOK.md, Rotating a secret](../RUNBOOK.md#rotating-a-secret)).

## The checklist

| # | Step | Where | Done when |
| --- | --- | --- | --- |
| 0 | [Before you wipe](#0-before-you-wipe) | old server, GitHub | a complete backup from today, this guide on `master` |
| 1 | [Install Ubuntu](#1-install-ubuntu) | at the server | Ubuntu 26.04 boots from the SSD, the new host key's fingerprint written down |
| 2 | [BIOS](#2-bios) | at the server | AC BACK on, ErP off, Wake on LAN on, the SSD first |
| 3 | [First provisioning](#3-first-provisioning) | laptop, on the LAN | the run ends `failed=0`, the server is `infra-host` on the tailnet |
| 4 | [Tailscale, and the second provisioning](#4-tailscale-and-the-second-provisioning) | laptop | over the tailnet only; after the reboot: GPU, encrypted DNS, disks, Wake-on-LAN verified |
| 5 | [The secrets](#5-the-secrets) | laptop (`op`, `gh`) | `SSH_KNOWN_HOSTS` and `HOME_POWER_KEY` from the new host, the fresh ones set |
| 6 | [The AI models](#6-the-ai-models) | on the server | three GGUF files in `llama-models`, checksums match |
| 7 | [Release](#7-release) | GitHub Actions | `RELEASE OK` |
| 8 | [Home's first owner setup](#8-homes-first-owner-setup) | browser, on the tailnet | the owner has a password, a second step and recovery codes |
| 9 | [First-run checks](#9-first-run-checks) | browser, laptop, server | every check below passes |
| 10 | [Restore from the old server's backups](#10-restore-from-the-old-servers-backups) | on the server | only what you chose above, or nothing |
| 11 | [The down-page Worker](#11-the-down-page-worker) | laptop (`wrangler`) | the sites answer, the page shows while the tunnel is down |
| 12 | [Retire the old](#12-retire-the-old) | GitHub, 1Password, Tailscale | retired secrets and the old node gone |

[Rollback](#rollback) says how to undo each part.

## 0. Before you wipe

1. **Merge this change** into `master` on `somethim-home/infrastructure` and update your checkout
   (`git switch master && git pull --ff-only`). The Deploy workflow refuses any other branch.
2. **A complete backup from today**, if anything on the SSD may be wanted later (the database,
   Home, the dashboard's history; [step 10](#10-restore-from-the-old-servers-backups)). On the old
   server, it stops each app only while its own data is copied:

   ```bash
   ssh -t admin@infra-host sudo systemctl start infra-backup.service
   ssh admin@infra-host journalctl -u infra-backup.service --since -1h | tail -n 3   # ends "backup OK"
   ssh -t admin@infra-host sudo ls -l /srv/backup/snapshots/                          # latest -> today's date
   ```

3. **The disks' UUIDs still match `production.yml`** (`media_disk_uuid`, `backup_disk_uuid`):

   ```bash
   ssh admin@infra-host findmnt -n -o SOURCE,UUID /srv/media /srv/backup
   grep -E '^(media|backup)_disk_uuid' production.yml
   ```

4. **The keys you decided to keep** are in 1Password ("infra production secrets" in the "Home
   Server" vault: `HOME_DATA_KEY`, `HOME_SECRET_KEY`; `PORTFOLIO_TOTP_ENCRYPTION_KEY` was generated
   straight into GitHub, so it is kept by simply not setting it again). A GitHub secret cannot be
   read back, so 1Password is the only copy you can ever restore from.

Then shut the old server down (`ssh -t admin@infra-host sudo poweroff`). The public sites show
the down page (or Cloudflare's error) until [step 7](#7-release).

## 1. Install Ubuntu

At the server, with keyboard and monitor. Follow [RUNBOOK.md, 1. What you
need](../RUNBOOK.md#1-what-you-need) for the laptop's tools, then [3. Install Ubuntu
Server](../RUNBOOK.md#3-install-ubuntu-server) steps 1 to 3 (write the stick, the installer's
choices, confirm the host's facts), with these differences for a reinstall:

- **Unplug the USB backup disk** for the install. Boot from the stick through the firmware's boot
  menu (`F12` on this Gigabyte board) or by putting the stick first ([step 2](#2-bios)).
- **Storage**: choose the **225 GB SSD**, the one that held Ubuntu (`ubuntu-vg`), and nothing
  else. The 1 TB internal HDD is listed too: **do not select it, and do not format it**; it holds
  the films and series, which are not in any backup. If in doubt, open the case and unplug its
  SATA cable for the install.
- **Profile**: as before, server name `infra-host`, username `setup`.
- **The new host key**: a reinstall makes a new one. At the console, after the first boot,
  `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` prints `256 SHA256:… root@infra-host
  (ED25519)`: **write the `SHA256:` fingerprint down**. It is the out-of-band check for every
  later step that trusts the host key, `SSH_KNOWN_HOSTS` included.
- The router's fixed DHCP lease (RUNBOOK step 4) is still there for the same network card, so
  the server gets its old LAN address (`192.168.1.50` below); check with `ip -4 -brief address`.

Then plug the backup disk in again (and the HDD's cable, if you unplugged it), and on the
laptop forget the old host keys, so nothing trusts the wiped server's key:

```bash
ssh-keygen -R infra-host; ssh-keygen -R 192.168.1.50
```

## 2. BIOS

At the server; [RUNBOOK.md, 2. BIOS](../RUNBOOK.md#2-bios) has the vendor-neutral names. A
reinstall does not change them, but a firmware update can reset them, so check. On this Gigabyte
board, **Settings → Platform Power**:

- **AC BACK → Always On** (back by itself after a power cut),
- **ErP → Disabled** (the network card keeps standby power while the server is off),
- **Wake on LAN → Enabled**,

and in **Boot**, the SSD first. Leave Secure Boot as it is. Save and exit. Home's **Shut down**
leaves the server off until a magic packet or the power button; without these settings only the
button works.

## 3. First provisioning

On the laptop, on the home LAN. First, two things in the **Tailscale admin console**
(<https://login.tailscale.com/admin>), because this run joins the server to the tailnet:

1. **Machines**: remove the old `infra-host` (it is the wiped server). Otherwise the new one
   joins as `infra-host-1` and provisioning stops: it requires the name `infra-host`.
2. **Settings → Keys → Generate auth key**: one-off, pre-approved, not ephemeral, tag
   `tag:infra-server`, expiry 1 day, as in [RUNBOOK.md, 4. Tailscale](../RUNBOOK.md#4-tailscale)
   step 2. The policy (its grants) and the OAuth client of steps 1 and 3 there are unchanged:
   nothing to do.

Then [RUNBOOK.md, 5. First provision over the LAN](../RUNBOOK.md#5-first-provision-over-the-lan),
steps 2 to 5, with these notes:

- **Step 1 (the CI deploy key) is skipped**: the key stays. `roles/common/files/deploy_key.pub`
  is the public half of `SSH_PRIVATE_KEY`, and provisioning installs it for `deploy` again.
- Step 2 compares `ssh-keyscan`'s fingerprint with the one you wrote down in [step 1](#1-install-ubuntu).
- The run asks for the auth key at `Tailscale auth key for infra-host`.
- **The disks**: `production.yml` already names both by UUID, so this run mounts them at
  `/srv/media` and `/srv/backup`, keeps what is on them and only creates what is missing. Do
  **not** follow [RUNBOOK.md, Disks](../RUNBOOK.md#disks): its `wipefs` and `mkfs` erase them. A
  run that stops at "no such filesystem is attached" means the HDD's cable or its UUID; `sudo
  blkid` at the console shows what is there.
- Step 5 sets the admin sudo password. Keep it in your password manager.

## 4. Tailscale, and the second provisioning

1. **The server on the tailnet**: in the admin console it is `infra-host`, tag
   `tag:infra-server`, key expiry disabled. From the laptop, [RUNBOOK.md, 5](../RUNBOOK.md#5-first-provision-over-the-lan)
   step 6: record the host key under the tailnet name (compare the fingerprint again), and
   `ssh admin@infra-host true` works without a prompt. Keep `/tmp/kh` for [step 5](#5-the-secrets).
2. **Second provisioning, over the tailnet**: [RUNBOOK.md, 8](../RUNBOOK.md#8-second-provision-over-the-tailnet).
   It closes SSH on the LAN and removes `setup`. This run also installs the NVIDIA driver (`gpu`)
   and ends with "The NVIDIA driver was installed … Reboot when it suits you".
3. **Reboot, provision again, verify.** The reboot loads the driver and applies the LAN
   interface's DNS setting (encrypted DNS; the ISP's resolver is dropped at boot, never mid-run):

   ```bash
   ssh -t admin@infra-host sudo reboot
   # about a minute later:
   ansible-playbook -u admin --ask-become-pass provision.yml --tags gpu,host
   ssh admin@infra-host nvidia-smi                                    # the RTX 2060, 12288MiB, driver 580.x
   ssh admin@infra-host resolvectl dnsovertls                         # Global: yes
   ssh admin@infra-host resolvectl dns                                # Global: 1.1.1.1#cloudflare-dns.com …; the enp8s0 line has no server
   ssh -t admin@infra-host sudo ethtool enp8s0 | grep Wake-on         # Supports Wake-on: pumbg / Wake-on: g
   ssh admin@infra-host findmnt /srv/media /srv/backup                # both ext4, by UUID
   ssh admin@infra-host ls -l /srv/media                              # the old folders, owned as before (s3, home-files, movies, shows, …)
   ssh -t admin@infra-host sudo docker network inspect home-llm --format '{{.Internal}}'   # true
   ssh admin@infra-host systemctl is-active home-power.path           # active
   ssh admin@infra-host systemctl list-timers infra-backup.timer      # next run tonight, 02:30 UTC
   tailscale ping infra-host && ssh admin@infra-host true             # MagicDNS on the laptop still finds infra-host
   ```

   The folders on the media disk keep their owners: the accounts are created with the same uids
   (`media` 2000, `ai` 2001, `home-server` 65532). The second run's "Require nvidia-smi to see
   the GPU" and "Require every lookup to go to the encrypted resolvers over TLS" pass now. If
   `nvidia-smi` cannot talk to the driver, see [RUNBOOK.md, Provision, reboot and check the
   GPU](../RUNBOOK.md#provision-reboot-and-check-the-gpu).

Optional, to try Wake-on-LAN now: [RUNBOOK.md, Wake-on-LAN](../RUNBOOK.md#wake-on-lan).

## 5. The secrets

The `production` Environment already holds every secret the Deploy workflow reads (28), from
the old server. On a clean slate they fall into three groups:

| Group | Secrets | What to do |
| --- | --- | --- |
| **Must change**: they describe the old machine | `SSH_KNOWN_HOSTS`, `HOME_POWER_KEY` | below; a release fails without both (the host key check, "HOME_POWER_KEY is not this host's power key") |
| **Keep as they are**: credentials for outside services, unchanged by a reinstall | `SSH_PRIVATE_KEY` (the deploy key; its public half is committed), `TS_OAUTH_SECRET`, `GHCR_TOKEN`, `CF_TUNNEL_TOKEN` (the same tunnel; the wiped server's connector is gone), `HOME_TLS_CF_DNS_TOKEN`, `HOME_RESEND_API_KEY`, `HOME_TMDB_READ_TOKEN`, `PORTFOLIO_RESEND_API_KEY`, `PORTFOLIO_GOOGLE_CLIENT_SECRET` | nothing; the variables (`TS_OAUTH_CLIENT_ID`, `SERVER_SSH_HOST`, `GHCR_USERNAME`, `PORTFOLIO_GOOGLE_CLIENT_ID`, the repository's `HOME_OWNER_EMAIL`) stay too |
| **Fresh on a clean slate**: generated values that only guard this server's data, of which there is none yet | `POSTGRES_SUPERUSER_PASSWORD`, `PRIZM_DB_PASSWORD`, `PORTFOLIO_DB_PASSWORD`, `HYPERNOVA_SESSION_SECRET`, `HYPERNOVA_ADMIN_PASSWORD`, `PORTFOLIO_ADMIN_PASSWORD`, `BESZEL_PASSWORD`, `BESZEL_AGENT_TOKEN`, `GARAGE_RPC_SECRET`, `GARAGE_ADMIN_TOKEN`, `GARAGE_OWNER_ACCESS_KEY_ID`, `GARAGE_OWNER_SECRET_KEY`, `FILES_PASSWORD`; and, **only if you restore none of their data**, `PORTFOLIO_TOTP_ENCRYPTION_KEY`, `HOME_SECRET_KEY`, `HOME_DATA_KEY` | below. Keeping the old values works too; fresh ones mean nothing from the old server opens the new one |

`HOME_BESZEL_PASSWORD` is read only when `production.yml` names `home_beszel_user` (it is empty):
leave it, or delete it ([RUNBOOK.md, Home](../RUNBOOK.md#home), "Status card", makes the
Beszel user again on the new hub if you want Home's Status card).

The helper, as in [RUNBOOK.md, The status dashboard and S3 secrets](../RUNBOOK.md#the-status-dashboard-and-s3-secrets),
writes each value to its field in 1Password and to the Environment, without showing it:

```bash
R=somethim-home/infrastructure
item="infra production secrets"
set_secret() { op item edit "$item" --vault "Home Server" "$1[password]=$2" >/dev/null && printf %s "$2" | gh secret set "$1" --env production -R "$R" && echo "$1 set"; }
```

**`SSH_KNOWN_HOSTS`**, the new host key under the tailnet name the workflow connects to
(`SERVER_SSH_HOST`, `infra-host`). Read it over the tailnet, and set it **only** if its
fingerprint is the one you wrote down at the console in [step 1](#1-install-ubuntu): that
comparison is what makes the key trustworthy, since `ssh-keyscan` itself trusts whatever answers.

```bash
ssh-keyscan -t ed25519 infra-host 2>/dev/null >/tmp/kh    # or the /tmp/kh of step 4
cat /tmp/kh                                               # one line: infra-host ssh-ed25519 AAAA…
ssh-keygen -lf /tmp/kh                                    # 256 SHA256:… infra-host (ED25519): must equal the console's
gh secret set SSH_KNOWN_HOSTS --env production -R "$R" </tmp/kh && rm /tmp/kh
```

**The fresh values.** Nobody types the database passwords, the TOTP key or the session secret,
so they go straight into GitHub; the rest also go to 1Password:

```bash
for name in POSTGRES_SUPERUSER_PASSWORD PRIZM_DB_PASSWORD PORTFOLIO_DB_PASSWORD HYPERNOVA_SESSION_SECRET; do
  gh secret set "$name" --env production -R "$R" --body "$(openssl rand -hex 24)"
done
set_secret PORTFOLIO_ADMIN_PASSWORD "$(openssl rand -hex 16)"
set_secret HYPERNOVA_ADMIN_PASSWORD "$(openssl rand -hex 16)"
set_secret BESZEL_PASSWORD "$(openssl rand -hex 16)"
set_secret BESZEL_AGENT_TOKEN "$(openssl rand -hex 24)"
set_secret GARAGE_RPC_SECRET "$(openssl rand -hex 32)"
set_secret GARAGE_ADMIN_TOKEN "$(openssl rand -hex 32)"
set_secret GARAGE_OWNER_ACCESS_KEY_ID "GK$(openssl rand -hex 12)"
set_secret GARAGE_OWNER_SECRET_KEY "$(openssl rand -hex 32)"
set_secret FILES_PASSWORD "$(openssl rand -hex 16)"
```

`PORTFOLIO_ADMIN_PASSWORD` and `HYPERNOVA_ADMIN_PASSWORD` were echoed in [RUNBOOK.md,
7](../RUNBOOK.md#7-the-production-environment); here they go to 1Password instead
(`op item get "$item" --vault "Home Server" --fields label=PORTFOLIO_ADMIN_PASSWORD --reveal`
when you sign in). A new S3 key means rclone and your S3 apps need the new pair.

**The three data keys**, only for the data you will **not** restore (the table at the top):

```bash
gh secret set PORTFOLIO_TOTP_ENCRYPTION_KEY --env production -R "$R" --body "$(openssl rand -base64 32)"   # not if you restore the portfolio
set_secret HOME_SECRET_KEY "$(openssl rand -base64 32)"                                                  # not if you restore Home
set_secret HOME_DATA_KEY "$(openssl rand -base64 32)"                                                    # not if you restore Home
```

`set_secret` overwrites the 1Password field: if old Home snapshots on the backup disk might ever
be restored, first copy the old `HOME_DATA_KEY` and `HOME_SECRET_KEY` fields to a separate item
("Home keys, before the 2026 reinstall"); only they open that data.

**The power key** (`HOME_POWER_KEY`), a copy of the key provisioning made on the new host, so
Home's Admin → Server can restart or shut it down:

```bash
read -rsp 'admin sudo password: ' pw; echo
k="$(printf '%s\n' "$pw" | ssh admin@infra-host 'sudo -S -p "" cat /etc/infra/home-power.key')"; unset pw
[[ "$k" =~ ^[A-Za-z0-9+/]{43}=$ ]] && set_secret HOME_POWER_KEY "$k"; unset k
```

Then:

```bash
unset -f set_secret; unset item
gh secret list --env production -R "$R"     # every name, and today's date on the ones set above
gh variable list -R "$R"                    # HOME_OWNER_EMAIL
```

## 6. The AI models

llama-server serves the three GGUF files `production.yml`'s `home_ai_models` names, from the
`llama-models` volume (about 23 GB on the SSD; check `ssh admin@infra-host df -h /var/lib/docker`
first). The volume is new and empty, and llama-server has no route to the internet, so you
download them, once. The exact files, sizes and checksums are in [RUNBOOK.md, Home's AI
models](../RUNBOOK.md#homes-ai-models), which also has the download function.

1. **Gemma's licence.** Already accepted on your Hugging Face account; the read token is the
   `HF_TOKEN` field of "infra production secrets". If not: sign in, open
   <https://huggingface.co/google/gemma-3-12b-it-qat-q4_0-gguf>, accept the Gemma Terms of Use,
   and create a **read** access token (Settings → Access Tokens). The two Qwen models need
   neither.
2. **Download** on the server as the RUNBOOK section says: the two Qwen files are checked
   against their published SHA-256; Gemma's checksum is shown only once its licence is accepted,
   so the function prints it and you compare it with the one on the model's Hugging Face page.
3. **Check:**

   ```bash
   ssh -t admin@infra-host 'sudo ls -l "$(sudo docker volume inspect llama-models --format "{{.Mountpoint}}")"'
   # Qwen3-8B-Q5_K_M.gguf 5851112224, gemma-3-12b-it-q4_0.gguf 8074473920, Qwen3-14B-Q4_K_M.gguf 9001752960; no .part
   ```

The models can come before or after the release; a missing file only means that model cannot
answer (llama-server logs "…is missing").

## 7. Release

GitHub → **Actions → Deploy → Run workflow**, "Use workflow from" `master`, action `release`,
every other input at its default. Or from the laptop:

```bash
gh workflow run deploy.yml -R somethim-home/infrastructure --ref master -f action=release
gh run watch -R somethim-home/infrastructure "$(gh run list -R somethim-home/infrastructure --workflow deploy.yml -L 1 --json databaseId -q '.[0].databaseId')"
```

The first release on the new host creates everything that is not there yet: PostgreSQL
initialises the empty `pgdata-v18` (`provision.sql` makes the `prizm` and `portfolio` roles and
databases; the apps create their schemas; the portfolio can take up to 180 s to report healthy),
Beszel creates its login, Garage its layout, the owner's key and the `files` bucket, and Home its
databases. Expect in "Release on the server" the lines of [RUNBOOK.md, 9. First
release](../RUNBOOK.md#9-first-release), among them:

```
infra-apply: compose model accepted: 1 service(s) in the ai stack, …, the GPU only for llama, no Docker socket
infra-apply: compose model accepted: 2 service(s) in the home stack, …, no bind mount but home-server /srv/media/home-files, home-server /run/home-power, home-server /srv/media/movies, home-server /srv/media/shows, the GPU only for home-server, no Docker socket, no extra group but home-server +media
infra-apply: the Cloudflare Tunnel is connected (cloudflared /ready answers 200)
infra-apply: home-tls serves https with a trusted certificate on 100.x.y.z for home.arbikullakshi.com …, and Home's web app at https://home.arbikullakshi.com/app/
infra-apply: beszel-pair garage-setup home-keys finished: …, Home has its key files
infra-apply: Cloudflare serves https://arbikullakshi.com/api/health https://www.arbikullakshi.com/ https://hypernova.arbikullakshi.com/ …
infra-apply: RELEASE OK: <id> is current, following :latest, auto-updates on
```

The DNS records already point at the tunnel, so the public check passes on this first release
(RUNBOOK section 10 is not repeated). `home-tls` asks Let's Encrypt for a new certificate (its
`home-tls-acme` volume is new); that takes a minute and is part of the release's wait.

If it stops, the line before `FAILED` says why; the common ones:

| It says | Fix |
| --- | --- |
| "Host key verification failed" (in "Release on the server", before any `infra-apply` line) | step 5, `SSH_KNOWN_HOSTS`: set it from the new host |
| "Missing or invalid deploy secrets" / "`<name>` holds a $, quote, …" | step 5: a value is missing or malformed |
| "HOME_POWER_KEY is not this host's power key" | step 5, the power key: copy it from the new host again |
| "HOME_USER is not …; run provisioning" | step 4 was not finished |
| "not ready after 600s: home-server:unhealthy" or "llama:…" | `ssh -t admin@infra-host sudo docker logs home-server` (or `llama`); [Rollback](#rollback) |
| "https://home.arbikullakshi.com/app/ … answered 404, expected 200" | the running Home image has no web app; a newer image fixes it, or roll Home back |

## 8. Home's first owner setup

On a device on the tailnet, open `https://home.arbikullakshi.com/setup` and press **Email me the
setup link**. The mail comes from `Home <home@arbikullakshi.com>` to `HOME_OWNER_EMAIL` (check
spam if it is not there within a minute; `ssh -t admin@infra-host sudo docker logs --since 5m
home-server` says whether Resend accepted it). The link is valid for **one hour** and works
**once**; if it expired, ask for a new one on the same page.

Open it, press Continue, set the password and at least one second step (authenticator app or
passkey), and keep the 10 recovery codes it shows once in 1Password. Then sign out, and in
again at `/app`. A family member's device also needs a Tailscale grant of its own
([architecture.md](architecture.md#public-and-tailnet-only)).

If you restore Home's data in [step 10](#10-restore-from-the-old-servers-backups), the old
owner account comes back with it and replaces this one.

## 9. First-run checks

On a device on the tailnet. `H=https://home.arbikullakshi.com`.

1. **The public sites** (from anywhere):

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' https://arbikullakshi.com/api/health            # 200
   curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://www.arbikullakshi.com/ # 301 https://arbikullakshi.com/
   curl -sS -o /dev/null -w '%{http_code}\n' https://hypernova.arbikullakshi.com/api/health  # 200
   ```

   Sign in at `https://arbikullakshi.com/admin` with `PORTFOLIO_ADMIN_PASSWORD` and enrol TOTP and
   passkeys afresh, reconnect Google Calendar if you use it, and sign in to hypernova with
   `HYPERNOVA_ADMIN_PASSWORD` (its AI assistant is off: Ollama was removed). Skip the portfolio
   part if you will restore its database in step 10.
2. **Health**: `curl -fsS $H/healthz` prints `ok`.
3. **The web app** and its caching (home-tls passes Home's headers untouched; nothing in front
   of it rewrites or compresses):

   ```bash
   curl -sI $H/app/ | grep -iE '^(HTTP|cache-control|content-security-policy)'   # 200, no-cache, the app's CSP
   a="$(curl -s $H/app/ | grep -oE '[A-Za-z0-9_.-]+-[0-9a-f]{16}(_bg)?\.(js|wasm)' | head -n 1)"
   curl -sI "$H/app/$a" | grep -i cache-control                                   # public, max-age=31536000, immutable
   ```

   Open `$H/` in a browser: it lands on `/app/`.
4. **Files**: in the app, Files → create a space, upload a small file, open it on a second
   device. On the server only ciphertext appears:
   `ssh -t admin@infra-host sudo ls /srv/media/home-files/spaces`.
5. **Media scan**: the films and series on the media disk are still there; Admin → Media library
   → **Scan** (or wait: the scan also runs on changes and hourly) finds them again, and reuses the
   `.nfo` files and pictures next to them.

   ```bash
   ssh -t admin@infra-host sudo docker logs --since 5m home-server 2>&1 | grep -i media
   ```

   A film shows TMDB's poster and details (the TMDB attribution shows in its details). Play it
   in the browser; while a transcode runs, `ssh admin@infra-host nvidia-smi` lists the encoder
   session (`nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv`). Probing, pictures
   and transcodes need ffmpeg inside Home's image ([stacks.md](stacks.md#home), "Media"); until
   the image carries it, films still play as they are. New films go in as `admin`:
   [RUNBOOK.md, Home](../RUNBOOK.md#home), "Media".
6. **Books catalog**: Books → **Find books**, search `Austen`: the catalog (downloaded once from
   `www.gutenberg.org` at the first start, a few minutes) answers; add *Pride and Prejudice* and
   open it in the reader. Admin's catalog status shows its size and age.
7. **AI answer**: AI → New chat, model **Qwen3 8B**, ask "Say hello in Albanian". The first
   answer waits while the model loads (up to a minute), then streams. On the server:

   ```bash
   ssh admin@infra-host nvidia-smi                      # a llama-server process holding about 7 GB
   ssh -t admin@infra-host sudo docker logs --since 5m llama | tail
   ```

   Five idle minutes later the model unloads and `nvidia-smi` shows the memory free again. In
   quiet hours (23:00 to 08:00 Berlin time) Qwen3 14B is not offered and answers are shorter.
8. **Live updates**: open Home on two devices signed in as you. Rename a chat or upload a file
   on one: the other shows it without a reload. In the browser's developer tools, Network →
   `events` → EventStream shows `: home live` and a `ping` every 20 s, and the request stays open
   for minutes (home-tls has no read deadline and buffers nothing). Signing out on one device
   signs that session out at once.
9. **Power request, junk only** (nothing powers off):

   ```bash
   ssh -t admin@infra-host 'echo junk | sudo tee /run/home-power/request.json >/dev/null; sleep 2; sudo journalctl -t home-power -n 1 --no-pager'
   # home-power: refused request.json: it is not JSON; removed
   ```

   Admin → Server shows **Restart** and **Shut down** available. At a quiet moment, a real
   restart from there: type `restart`, the 10-second countdown runs, the server reboots and the
   page reloads when it is back (about 3 minutes). [RUNBOOK.md, Home's power control](../RUNBOOK.md#homes-power-control)
   has the signed test from the shell too.
10. **The status dashboard and Files**: `https://status.home.arbikullakshi.com` (sign in with
    `status_owner_email` and the new `BESZEL_PASSWORD`; `infra-host` appears with the GPU and the
    three disks) and `https://files.home.arbikullakshi.com/web/client` (the new `FILES_PASSWORD`).
11. **Encrypted DNS**: `ssh admin@infra-host resolvectl query www.themoviedb.org` answers, and
    `ssh admin@infra-host resolvectl statistics | grep -i transaction` counts up.
12. **Tonight's backup** (or now, which stops `home-server` for the copy):
    `ssh -t admin@infra-host sudo systemctl start infra-backup.service`, then
    `ssh admin@infra-host journalctl -u infra-backup.service --since -1h | tail` ends `backup OK`.
    It writes a new snapshot next to the old server's on the same disk
    ([operations.md](operations.md#backups)).

## 10. Restore from the old server's backups

Only what you chose at the top; skip this step for a truly clean slate. Everything here runs on
the server (`ssh -t admin@infra-host`), after the release (so every volume exists), from **one**
snapshot: the one [step 0](#0-before-you-wipe) made, the newest from before the wipe.

**Where the old data is.** The backup disk (`/srv/backup`, root only) has kept every snapshot
of the old server: `snapshots/<date>/postgres.sql.gz` (the whole database cluster) and
`snapshots/<date>/volumes/<volume>/` (each app volume as a plain tree); the layout is in
[RUNBOOK.md, Restoring from the backup disk](../RUNBOOK.md#restoring-from-the-backup-disk). The
media disk was not touched at all: the films and series (the videos too, which are in no
backup), Garage's objects in `s3` and Home Files' ciphertext in `home-files` are still on it,
mounted at `/srv/media` again by provisioning. What it no longer has is their partners on the
SSD: Garage's metadata (`garage-meta`) and Home's database (`home-data`).

**The media disk, remounted.** Nothing to do as long as its UUID is the one in `production.yml`:
provisioning wrote `UUID=<media_disk_uuid> /srv/media ext4 …` to `/etc/fstab` and mounted it
([step 4](#4-tailscale-and-the-second-provisioning) checked `findmnt`). If the UUID differs (the
disk was replaced or formatted), put the new one from `sudo blkid` in `production.yml` through
`master` and provision with `--tags host`. To look at a disk without provisioning, mount it
read-only somewhere else: `sudo mount -o ro UUID=<uuid> /mnt` (and `sudo umount /mnt` after).
Should the disk ever be lost, [RUNBOOK.md](../RUNBOOK.md#restoring-from-the-backup-disk),
"Everything on the media disk", brings back all but the videos.

Pick the snapshot first:

```bash
sudo ls -l /srv/backup/snapshots/                       # one folder per night; the old server's newest is the one before the wipe
s=/srv/backup/snapshots/<date>
sudo gzip -cd "$s/postgres.sql.gz" | grep '^-- Database ".*" dump'   # the databases in it: portfolio, prizm, …
```

**The portfolio** (its database and its uploads, from the same night; it needs the old
`PORTFOLIO_TOTP_ENCRYPTION_KEY` you kept in step 5). The dump holds the whole cluster; this takes
only the `portfolio` database out of it and puts it in place of the empty one the release made.
The role and its password stay the current ones:

```bash
sudo docker stop watchtower portfolio
sudo docker exec postgresql psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'DROP DATABASE portfolio WITH (FORCE)'
sudo gzip -cd "$s/postgres.sql.gz" |
  awk -v db=portfolio '/^-- Database ".*" dump$/ || /^-- PostgreSQL database cluster dump complete/ { p = ($0 == "-- Database \"" db "\" dump") } p' |
  sudo docker exec -i postgresql psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q
v="$(sudo docker volume inspect --format '{{.Mountpoint}}' portfolio-media)"
sudo rsync -a --delete --numeric-ids "$s/volumes/portfolio-media/" "$v/"
sudo docker start portfolio watchtower
curl -sS -o /dev/null -w '%{http_code}\n' https://arbikullakshi.com/api/health   # 200
```

Sign in at `/admin` with the old operator password and second factors (the restored account
is the old one; `PORTFOLIO_ADMIN_PASSWORD` only makes an account that does not exist).
**hypernova** the same way, with `prizm` for `portfolio` (in `DROP DATABASE` and `db=`),
`hypernova_prizm-storage` for `portfolio-media`, and `prizm-provider prizm-web` for the
`portfolio` container.

**Home** (accounts, chats, Books, Media's progress and Home Files; it needs the old
`HOME_DATA_KEY` and `HOME_SECRET_KEY` you kept in step 5): [RUNBOOK.md, Restoring from the backup
disk](../RUNBOOK.md#restoring-from-the-backup-disk), "All of Home", with that snapshot. It puts
`home-data` and `/srv/media/home-files` back together, which replaces the owner you set up in
step 8 with the old one, and the films' and series' `.nfo` files stay as they are on the disk.
**Not restoring Home** leaves the old Home Files' ciphertext in `/srv/media/home-files` with no
database that knows it and no key that opens it: it only takes disk space. Whether and when to
delete it is yours to decide (it is also in the old snapshots until they age out); new spaces
from step 7 on are written next to it.

**Files (S3)**: "All of Garage" in the same RUNBOOK section, which puts `garage-meta` and
`/srv/media/s3` back from the same night (its `--delete` drops anything uploaded since step 7).
`garage-setup` then imports the current `GARAGE_OWNER_*` key at the next release and drops the
old one: run `release` once more. **Not restoring** leaves the old objects in `/srv/media/s3`
as blocks the new metadata does not know; they cost only disk space.

**The dashboard's history and the file manager's settings**: "One app's data" in the same
section, for `beszel-data` (`beszel`) and `sftpgo-data` (`sftpgo`). Optional: a fresh Beszel
fills its history from now on.

The old snapshots age out like any other: the nightly run keeps the last 14 nights and one per
week for 8 weeks, so about two months after the reinstall the old server's snapshots are gone.
Restore what you want before then.

## 11. The down-page Worker

The Worker answers the **public** sites (`arbikullakshi.com`, `www.`, `hypernova.`) with a
"server is down" page while the tunnel is down. It runs in Cloudflare, so the reinstall did not
touch it, and Home (tailnet only, never behind the tunnel) has nothing to do with it. If it is
not deployed yet, or `cloudflare/down-page/` changed since, follow [RUNBOOK.md, The down
page](../RUNBOOK.md#the-down-page):

```bash
cd cloudflare/down-page
npx wrangler@4.147.0 login && npx wrangler@4.147.0 whoami
npx wrangler@4.147.0 deploy
```

then set its request limit failure mode to **Fail open** in the dashboard, and check the sites
(200, 301, 200) and, at a quiet moment, the page while `cloudflared` is stopped (`503 120`), as
that section shows.

## 12. Retire the old

1. **The retired apps' secrets**, still in the Environment and read by nothing:

   ```bash
   for n in IMMICH_ADMIN_PASSWORD IMMICH_DB_PASSWORD SEARXNG_SECRET WEBUI_SECRET_KEY; do
     gh secret delete "$n" --env production -R somethim-home/infrastructure   # "not found" is fine
   done
   gh secret list --env production -R somethim-home/infrastructure
   ```

   and their fields in "infra production secrets" can go too. Every secret left is one the Deploy
   workflow reads ([deploying.md](deploying.md#secrets-and-variables)).
2. **Old values in 1Password**: the fields `set_secret` overwrote are replaced already; the old
   Home keys you copied aside in step 5 stay until the old snapshots are gone (step 10's last
   paragraph), then delete that item.
3. **Tailscale**: the old `infra-host` node was removed in step 3; revoke any unused auth key
   (Settings → Keys).
4. **Ollama**: nothing to do. It was removed from this repository, and a reinstalled server never
   had its `ollama-models` volume or its `ai` and `llm` networks ([RUNBOOK.md, Removing Ollama's
   models](../RUNBOOK.md#removing-ollamas-models) is for a server that still has them).

## Rollback

| What | How |
| --- | --- |
| **A bad Home image** (it does not start, a feature is broken) | Deploy → `rollback`, `home: previous`, `dry_run: true` first, then without it ([RUNBOOK.md](../RUNBOOK.md#releases-status-rollback-resume)). Auto-updates pause for Home until `resume`. Home migrates its databases at start, so an image older than a migration may refuse them: then restore `home-data` from the night before the update ([RUNBOOK.md](../RUNBOOK.md#restoring-from-the-backup-disk), "All of Home") |
| **A restore that went wrong** (step 10) | do it again from the same snapshot: each recipe replaces what is there (`--delete`, `DROP DATABASE`) |
| **AI only** | `ssh -t admin@infra-host sudo docker stop llama`: Home shows the models offline, everything else works, until the next release or reboot starts it again. For good: empty `home_ai_models` is refused, so revert the AI part on `master` |
| **Media only** | Admin → Media library to hide titles; for good, revert the mounts in `stack/home/docker-compose.yml` (and `HOME_MEDIA_*`), release. Nothing deletes the films; Home's `.nfo` files and pictures stay next to them |
| **TMDB** | delete `HOME_TMDB_READ_TOKEN`, release: Wikidata only, no pictures |
| **Power control** | delete `HOME_POWER_KEY`, release: Home offers none |
| **Encrypted DNS** | `dns_over_tls_enabled: false` in `production.yml`, provision `--tags host`, reboot. By hand, at the console if DNS is gone: `sudo rm /etc/systemd/resolved.conf.d/60-infra-dns-over-tls.conf /etc/systemd/network/10-netplan-*.network.d/60-infra-dns.conf && sudo systemctl restart systemd-resolved`, then reboot ([host.md](host.md#encrypted-dns)) |
| **A secret** | [RUNBOOK.md, Rotating a secret](../RUNBOOK.md#rotating-a-secret); never rotate `HOME_DATA_KEY` casually |

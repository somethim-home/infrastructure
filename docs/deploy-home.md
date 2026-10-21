# Deploying Home

From today's state to every Home app live: the web app at `/app`, sign-in, Files, Media,
Books, AI with live updates, and Home's power button; plus the host's encrypted DNS. It assumes
the server is set up as in [RUNBOOK.md](../RUNBOOK.md) sections 1 to 10 (provisioned, the sites
live through the tunnel, a verified release running `database`, `portfolio`, `hypernova`,
`tunnel`, `ai` and `media`) and Home's first release (2026-10-20). Home's secrets are already in
the `production` environment and in 1Password (`HOME_DATA_KEY`, `HOME_SECRET_KEY`,
`HOME_RESEND_API_KEY`, `HOME_TMDB_READ_TOKEN`, all set 2026-10-21); only `HOME_POWER_KEY` is new.

> **Never generate new `HOME_DATA_KEY` or `HOME_SECRET_KEY` for a server that already ran Home.**
> `HOME_DATA_KEY` seals every enrolled second factor and the AI chats: a new one locks everyone
> out of their second step and makes the chats unreadable. Only a brand-new server gets new keys.

Every step is an **Owner action**. Commands run on your laptop, on the tailnet, in a checkout of
`master` with `gh` logged in to `somethim-home/infrastructure` and `op` signed in to 1Password,
unless a step says "on the server" (`ssh -t admin@infra-host`). No command prints a secret.

What each piece is and why: Home's stack in [stacks.md](stacks.md#home), llama-server in
[stacks.md](stacks.md#ai), the GPU budget in [stacks.md](stacks.md#the-gpu-shared), encrypted DNS
in [host.md](host.md#encrypted-dns), every secret in
[deploying.md](deploying.md#secrets-and-variables).

## The checklist

| # | Step | Where | Done when |
| --- | --- | --- | --- |
| 1 | [Merge this change](#1-merge) | GitHub | `master` has `docs/deploy-home.md` |
| 2 | [BIOS: Wake-on-LAN](#2-bios-wake-on-lan) | at the server | ErP off, Wake on LAN on, AC BACK on |
| 3 | [Provision `common,host`](#3-provision) | laptop | the run ends `failed=0` |
| 4 | [Reboot, provision `host` again](#4-reboot-and-verify-the-host) | laptop | encrypted DNS verified, `Wake-on: g` |
| 5 | [The secrets](#5-the-secrets) | laptop (`op`, `gh`) | five `HOME_*` secrets set, all in 1Password |
| 6 | [The AI models](#6-the-ai-models) | on the server | three GGUF files in `llama-models`, checksums match |
| 7 | [Release](#7-release) | GitHub Actions | `RELEASE OK` |
| 8 | [First-run checks](#8-first-run-checks) | browser, laptop, server | every check below passes |
| 9 | [The down-page Worker](#9-the-down-page-worker) | laptop (`wrangler`) | the sites answer, the page shows while the tunnel is down |
| 10 | [Clean up](#10-clean-up) | GitHub, 1Password | retired secrets gone |

[Rollback](#rollback) says how to undo each part.

## 1. Merge

Review and merge the `home-apps` branch into `master` on `somethim-home/infrastructure`, then
update your checkout:

```bash
git switch master && git pull --ff-only
```

Everything below runs from `master`: the Deploy workflow refuses any other branch.

## 2. BIOS: Wake-on-LAN

At the server, with keyboard and monitor (this needs a reboot into the firmware, so do it before
step 3, or combine it with the reboot of step 4). On this Gigabyte board, **Settings → Platform
Power**:

- **AC BACK → Always On** (back by itself after a power cut),
- **ErP → Disabled** (the network card keeps standby power while the server is off),
- **Wake on LAN → Enabled**.

Save and exit. These are the settings of [RUNBOOK.md, BIOS](../RUNBOOK.md#2-bios); a firmware
update can reset them, which is why they are checked again here. Home's **Shut down** leaves
the server off until a magic packet or the power button; without these settings only the button
works.

## 3. Provision

`common` installs the new compose guard and `infra-apply` (the GPU for llama-server and
home-server, the film and series mounts and the media group for home-server, the TMDB key line,
the `/app` check). `host` creates the internal `home-llm` network and the `llama-models`
volume, keeps Home's power request directory and key, and turns on encrypted DNS. A release
before this is refused ("service home-server sets group_add, which a release may not set").

```bash
ansible-playbook -u admin --ask-become-pass provision.yml --tags common,host
```

Expect, near the end of `host`:

- "Look a name up through the encrypted resolvers" `ok`: `www.gutenberg.org` resolved over TLS
  through Cloudflare. If it fails, the run has already put the previous resolver back and says
  so; check that outbound tcp 853 is open (`ssh admin@infra-host nc -vz 1.1.1.1 853`) before
  trying again.
- "Say that the LAN interface's DNS setting needs a reboot": the LAN's own DNS server (the
  ISP's) is dropped at the next boot, not now, so the run never cuts its own connection.

Check:

```bash
ssh admin@infra-host resolvectl dnsovertls                        # Global: yes
ssh admin@infra-host resolvectl dns                               # Global: 1.1.1.1#cloudflare-dns.com 1.0.0.1#… 9.9.9.9#dns.quad9.net 149.112.112.112#…
ssh -t admin@infra-host sudo docker network inspect home-llm --format '{{.Internal}}'   # true
ssh -t admin@infra-host sudo docker volume inspect llama-models --format '{{.Mountpoint}}'
ssh admin@infra-host ls -ld /srv/media/movies /srv/media/shows    # drwxrwsr-x media media, both
ssh admin@infra-host systemctl is-active home-power.path          # active
```

## 4. Reboot and verify the host

The reboot applies the LAN interface's DNS setting (and loads a driver update if one was
waiting). The sites are back about a minute later.

```bash
ssh -t admin@infra-host sudo reboot
# about a minute later:
ansible-playbook -u admin --ask-become-pass provision.yml --tags host
ssh admin@infra-host resolvectl dns              # the enp8s0 line has no server any more
ssh -t admin@infra-host sudo ethtool enp8s0 | grep Wake-on    # Supports Wake-on: pumbg / Wake-on: g
tailscale ping infra-host && ssh admin@infra-host true      # MagicDNS on the laptop still finds infra-host
```

The second run's "Require every lookup to go to the encrypted resolvers over TLS, and none to the
LAN's or Tailscale's" passes now. Tailscale is untouched: the server keeps `--accept-dns=false`,
so `tailscale0` has no DNS server and MagicDNS on your devices works as before.

Optional, to try Wake-on-LAN now: [RUNBOOK.md, Wake-on-LAN](../RUNBOOK.md#wake-on-lan).

## 5. The secrets

Five secrets for Home, each generated or copied here, stored in 1Password in the **"infra
production secrets"** item of the **"Home Server"** vault under a field named like the secret,
and set in the `production` Environment, without ever showing on screen. `HOME_OWNER_EMAIL` (a
repository variable) is already set: `gh variable list -R somethim-home/infrastructure` lists it.

The helper, as in [RUNBOOK.md, The status dashboard and S3 secrets](../RUNBOOK.md#the-status-dashboard-and-s3-secrets):

```bash
item="infra production secrets"
set_secret() { op item edit "$item" --vault "Home Server" "$1[password]=$2" >/dev/null && printf %s "$2" | gh secret set "$1" --env production -R somethim-home/infrastructure && echo "$1 set"; }
```

**The two keys** are already set; check they are there (names only) and skip to the next secret:

```bash
gh secret list --env production -R somethim-home/infrastructure | grep -E 'HOME_(DATA|SECRET)_KEY'
```

Only on a **brand-new server** that never ran Home, make them, new and different (`HOME_DATA_KEY`
seals the AI chats and every enrolled second factor; it is not in the backups, so 1Password is
its only copy):

```bash
set_secret HOME_SECRET_KEY "$(openssl rand -base64 32)"
set_secret HOME_DATA_KEY "$(openssl rand -base64 32)"
```

**Resend** (`HOME_RESEND_API_KEY`): `arbikullakshi.com` must be verified in Resend (the
portfolio already sends from it; check under Domains). Create an API key with sending access,
named "infra Home", copy it, then:

```bash
read -rsp 'Resend API key: ' v; echo; set_secret HOME_RESEND_API_KEY "$v"; unset v
```

**TMDB** (`HOME_TMDB_READ_TOKEN`, Media's online details): on themoviedb.org, sign in → Settings →
API (request a developer key for personal use if the page asks), and copy the **API Read Access
Token**: the long `eyJ…` token with two dots, not the 32-character API key (a release refuses
that one).

```bash
read -rsp 'TMDB API Read Access Token: ' v; echo; set_secret HOME_TMDB_READ_TOKEN "$v"; unset v
```

**The power key** (`HOME_POWER_KEY`), a copy of the key provisioning made on the server in step 3,
so Home's Admin → Server can restart or shut it down:

```bash
read -rsp 'admin sudo password: ' pw; echo
k="$(printf '%s\n' "$pw" | ssh admin@infra-host 'sudo -S -p "" cat /etc/infra/home-power.key')"; unset pw
[[ "$k" =~ ^[A-Za-z0-9+/]{43}=$ ]] && set_secret HOME_POWER_KEY "$k"; unset k
```

Then:

```bash
unset -f set_secret; unset item
gh secret list --env production -R somethim-home/infrastructure | grep '^HOME_'
# HOME_DATA_KEY, HOME_POWER_KEY, HOME_RESEND_API_KEY, HOME_SECRET_KEY, HOME_TLS_CF_DNS_TOKEN, HOME_TMDB_READ_TOKEN
```

`HOME_BESZEL_PASSWORD` stays unset until you want Home's Status card
([RUNBOOK.md, Home](../RUNBOOK.md#home), "Status card").

## 6. The AI models

llama-server serves the three GGUF files `production.yml`'s `home_ai_models` names, from the
`llama-models` volume (about 23 GB on the SSD; check `ssh admin@infra-host df -h /var/lib/docker`
first). It has no route to the internet, so you download them, once. The exact files, sizes and
checksums are in [RUNBOOK.md, Home's AI models](../RUNBOOK.md#homes-ai-models), which also has
the download function.

1. **Gemma's licence first.** Sign in to Hugging Face, open
   <https://huggingface.co/google/gemma-3-12b-it-qat-q4_0-gguf> and accept the Gemma Terms of Use
   (access is granted at once). Then create a **read** access token (Settings → Access Tokens)
   and keep it in 1Password as the `HF_TOKEN` field of "infra production secrets". The two Qwen
   models need neither.
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

Expect in "Release on the server", besides the usual lines:

```
infra-apply: compose model accepted: 3 service(s) in the ai stack, …, the GPU only for llama, ollama, no Docker socket
infra-apply: compose model accepted: 2 service(s) in the home stack, …, no bind mount but home-server /srv/media/home-files, home-server /run/home-power, home-server /srv/media/movies, home-server /srv/media/shows, the GPU only for home-server, no Docker socket, no extra group but home-server +media
infra-apply: home-tls serves https with a trusted certificate on 100.x.y.z for home.arbikullakshi.com …, and Home's web app at https://home.arbikullakshi.com/app/
infra-apply: beszel-pair garage-setup home-keys finished: …, Home has its key files
infra-apply: RELEASE OK: <id> is current, following :latest, auto-updates on
```

If it stops, the line before `FAILED` says why; the common ones:

| It says | Fix |
| --- | --- |
| "Missing or invalid deploy secrets" / "HOME_TMDB_READ_TOKEN, when set, as TMDB's API Read Access Token" | step 5: a secret is missing, or the TMDB value is the short API key |
| "service home-server sets group_add, which a release may not set" | step 3 was skipped (the host still has the old guard) |
| "HOME_POWER_KEY is not this host's power key" | step 5, the power key: copy it again |
| "not ready after 600s: home-server:unhealthy" or "llama:…" | `ssh -t admin@infra-host sudo docker logs home-server` (or `llama`); [Rollback](#rollback) |
| "https://home.arbikullakshi.com/app/ … answered 404, expected 200" | the running Home image has no web app; a newer image fixes it, or roll Home back |

## 8. First-run checks

On a device on the tailnet. `H=https://home.arbikullakshi.com`.

1. **Health**: `curl -fsS $H/healthz` prints `ok`.
2. **The web app** and its caching (home-tls passes Home's headers untouched; nothing in front
   of it rewrites or compresses):

   ```bash
   curl -sI $H/app/ | grep -iE '^(HTTP|cache-control|content-security-policy)'   # 200, no-cache, the app's CSP
   a="$(curl -s $H/app/ | grep -oE '[A-Za-z0-9_.-]+-[0-9a-f]{16}(_bg)?\.(js|wasm)' | head -n 1)"
   curl -sI "$H/app/$a" | grep -i cache-control                                   # public, max-age=31536000, immutable
   ```

   Open `$H/` in a browser: it lands on `/app/`.
3. **Sign-in**: open `$H/setup`, press **Email me the setup link**; the mail comes from
   `Home <home@arbikullakshi.com>` to `HOME_OWNER_EMAIL`. Set a password and a second step
   (authenticator app or passkey) and keep the 10 recovery codes in 1Password. Then sign out and
   in again in `/app`.
4. **Files**: in the app, Files → create a space, upload a small file, open it on a second
   device. On the server only ciphertext appears:
   `ssh -t admin@infra-host sudo ls /srv/media/home-files/spaces`.
5. **Media scan**: put one film in the library as `admin` (the folders are setgid `media` and
   group-writable), then Admin → Media library → **Scan** (or wait: the scan also runs on
   changes and hourly):

   ```bash
   scp 'Some Film (2001).mkv' admin@infra-host:/tmp/
   ssh admin@infra-host 'mkdir -p -m 2775 "/srv/media/movies/Some Film (2001)" && mv "/tmp/Some Film (2001).mkv" "/srv/media/movies/Some Film (2001)/"'
   ssh -t admin@infra-host sudo docker logs --since 5m home-server 2>&1 | grep -i media
   ```

   The film appears with TMDB's poster and details (the TMDB attribution shows in its details),
   and Home writes `Some Film (2001).nfo` and pictures next to it. Play it in the browser; while
   a transcode runs, `ssh admin@infra-host nvidia-smi` lists the encoder session
   (`nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv`). Probing, pictures and
   transcodes need ffmpeg inside Home's image ([stacks.md](stacks.md#home), "Media"); until the
   image carries it, films still play as they are.
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
10. **Encrypted DNS**: `ssh admin@infra-host resolvectl query www.themoviedb.org` answers, and
    `ssh admin@infra-host resolvectl statistics | grep -i transaction` counts up.
11. **Tonight's backup** (or now, which stops `home-server` for the copy):
    `ssh -t admin@infra-host sudo systemctl start infra-backup.service`, then
    `ssh admin@infra-host journalctl -u infra-backup.service --since -1h | tail` ends `backup OK`.
    `home-data` is copied without Media's cache, and `media/movies` and `media/shows` hold only
    the `.nfo` files, pictures and subtitles ([operations.md](operations.md#backups)).

## 9. The down-page Worker

The Worker answers the **public** sites (`arbikullakshi.com`, `www.`, `hypernova.`) with a
"server is down" page while the tunnel is down; Home is on the tailnet only and never behind
it, so nothing about Home changes here. If it is not deployed yet, or `cloudflare/down-page/`
changed, follow [RUNBOOK.md, The down page](../RUNBOOK.md#the-down-page):

```bash
cd cloudflare/down-page
npx wrangler@4.147.0 login && npx wrangler@4.147.0 whoami
npx wrangler@4.147.0 deploy
```

then set its request limit failure mode to **Fail open** in the dashboard, and check the sites
(200, 301, 200) and, at a quiet moment, the page while `cloudflared` is stopped (`503 120`), as
that section shows.

## 10. Clean up

The retired apps' secrets are still in the Environment and read by nothing:

```bash
for n in IMMICH_ADMIN_PASSWORD IMMICH_DB_PASSWORD SEARXNG_SECRET WEBUI_SECRET_KEY; do
  gh secret delete "$n" --env production -R somethim-home/infrastructure
done
```

and their fields in "infra production secrets" can go too. Home's AI replaces what the 14B
Ollama models were kept for; dropping `qwen2.5-coder:14b` and `qwen3:14b` from `ollama_models`
in `production.yml` (and releasing) frees about 18 GB of the SSD ([stacks.md](stacks.md#ai)).

## Rollback

| What | How |
| --- | --- |
| **A bad Home image** (it does not start, a feature is broken) | Deploy → `rollback`, `home: previous`, `dry_run: true` first, then without it ([RUNBOOK.md](../RUNBOOK.md#releases-status-rollback-resume)). Auto-updates pause for Home until `resume`. Home migrates its databases at start, so an image older than a migration may refuse them: then restore `home-data` from the night before the update ([RUNBOOK.md](../RUNBOOK.md#restoring-from-the-backup-disk), "All of Home") |
| **This change as a whole** (the stacks, the guard) | `git revert` the merge on `master`, provision `--tags common,host`, `release`. The data stays: `home-data`, `llama-models` and the library are untouched, and the next deploy picks them up |
| **AI only** | `ssh -t admin@infra-host sudo docker stop llama`: Home shows the models offline, everything else works, until the next release or reboot starts it again. For good: empty `home_ai_models` is refused, so revert the AI part on `master` |
| **Media only** | Admin → Media library to hide titles; for good, revert the mounts in `stack/home/docker-compose.yml` (and `HOME_MEDIA_*`), release. Nothing deletes the films; Home's `.nfo` files and pictures stay next to them |
| **TMDB** | delete `HOME_TMDB_READ_TOKEN`, release: Wikidata only, no pictures |
| **Power control** | delete `HOME_POWER_KEY`, release: Home offers none |
| **Encrypted DNS** | `dns_over_tls_enabled: false` in `production.yml`, provision `--tags host`, reboot. By hand, at the console if DNS is gone: `sudo rm /etc/systemd/resolved.conf.d/60-infra-dns-over-tls.conf /etc/systemd/network/10-netplan-*.network.d/60-infra-dns.conf && sudo systemctl restart systemd-resolved`, then reboot ([host.md](host.md#encrypted-dns)) |
| **A secret** | [RUNBOOK.md, Rotating a secret](../RUNBOOK.md#rotating-a-secret); never rotate `HOME_DATA_KEY` casually |

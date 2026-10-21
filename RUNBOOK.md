# Runbook

The owner's steps for the one production server: a dedicated PC at home, on the home LAN
behind a consumer router, with a dynamic public IP. Nothing on it is reachable from the
internet. The public reaches the sites only through a **Cloudflare Tunnel** that the server
dials out to; SSH works only over **Tailscale**. [`README.md`](README.md) and
[`docs/`](docs/README.md) explain how the pieces work; this file only says what to do, in
order. Every step that needs your accounts or your hands is marked **Owner action**.

The server starts empty: there is no data to carry over. The first release creates the
database and the app volumes empty, and the apps initialise them.

The values below are the ones in [`production.yml`](production.yml) and
[`roles/common/defaults/main.yml`](roles/common/defaults/main.yml): the tailnet name
`infra-host`, the tags `tag:infra-server` and `tag:infra-ci`, the accounts `admin` and
`deploy`, the domains `arbikullakshi.com`, `www.arbikullakshi.com` and
`hypernova.arbikullakshi.com`. If you change one, change that file first (through `master`)
and use your value throughout. `192.168.1.50` stands for the server's LAN address and `setup`
for the account the Ubuntu installer creates; use yours.

| Section | Where you are |
| --- | --- |
| [1. What you need](#1-what-you-need) | anywhere |
| [2. BIOS](#2-bios) | at the server, keyboard and monitor |
| [3. Install Ubuntu Server](#3-install-ubuntu-server) | at the server |
| [4. Tailscale](#4-tailscale) | Tailscale admin console |
| [5. First provision over the LAN](#5-first-provision-over-the-lan) | your laptop, on the home LAN |
| [6. Cloudflare Tunnel](#6-cloudflare-tunnel) | Cloudflare (`cf` or the dashboard) |
| [7. The production Environment](#7-the-production-environment) | GitHub (`gh`) |
| [8. Second provision over the tailnet](#8-second-provision-over-the-tailnet) | your laptop |
| [9. First release](#9-first-release) | GitHub Actions |
| [10. DNS switch-over and decommissioning the old server](#10-dns-switch-over-and-decommissioning-the-old-server) | Cloudflare, then the Hetzner console |
| [11. Day-2 operations](#11-day-2-operations) | from then on |
| [12. GPU, AI and media](#12-gpu-ai-and-media) | the server, Tailscale, GitHub, your devices |

Restoring anything from the backup disk is in
[Restoring from the backup disk](#restoring-from-the-backup-disk) (section 11).

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
   host in `[server]`, so an inline `-i '192.168.1.50,'` does not work):

   ```bash
   cp inventory/hosts.example inventory/hosts
   sed -i 's/^infra-host ansible_host=.*/infra-host ansible_host=192.168.1.50/' inventory/hosts
   ansible-playbook -u setup --ask-become-pass provision.yml
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
masks, the `edge` and `data` networks and the empty `pgdata-v18` volume are in place;
Traefik (no published port), Watchtower and autoheal start; last, password and
keyboard-interactive login are turned off and root login stays off. The run ends with:

```
setup stays until the first run as admin removes it.
Set the admin sudo password: ssh -t setup@192.168.1.50 sudo passwd admin
Then set ansible_host=infra-host in inventory/hosts and run: ansible-playbook -u admin --ask-become-pass provision.yml (RUNBOOK.md, "Second provision over the tailnet").
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

## 6. Cloudflare Tunnel

**Owner action.** One remotely managed tunnel, named `infra-host`, carries all three
hostnames to Traefik. "Remotely managed" means its routes (Public Hostnames) live in
Cloudflare, and the server only needs the tunnel's token, which the release renders into
`tunnel/tunnel.env` for the `cloudflared` container. The tunnel must route:

| Public hostname | Service |
| --- | --- |
| `arbikullakshi.com` | `http://edge-traefik:80` |
| `www.arbikullakshi.com` | `http://edge-traefik:80` |
| `hypernova.arbikullakshi.com` | `http://edge-traefik:80` |

and nothing else (no catch-all other than the default `http_status:404`). Leave every origin
option at its default: Traefik routes by the original `Host` header, which cloudflared passes
through. The DNS records come in section 10, not here: the hostnames still point at the old
server until then.

With `cf`:

```bash
# 1. Create the remotely managed tunnel and store its token in 1Password; the token is never printed
#    (done 2026-10-15: tunnel "home-server", id 1dfdb06e-04a8-4a4b-942b-ede6c46015de)
OUT=$(cf tunnels create --name home-server --config-source cloudflare 2>/dev/null)
TUNNEL_ID=$(jq -r '.id' <<<"$OUT"); TUNNEL_TOKEN=$(jq -r '.token' <<<"$OUT"); unset OUT
op item create --category password --vault "Home Server" --title "Cloudflare tunnel token (home-server)" \
  "password=$TUNNEL_TOKEN" "tunnel id[text]=$TUNNEL_ID" >/dev/null; unset TUNNEL_TOKEN

# 2. Set the tunnel's ingress
cf tunnels config update "$TUNNEL_ID" --body '{"config":{"ingress":[
 {"hostname":"arbikullakshi.com","service":"http://edge-traefik:80"},
 {"hostname":"www.arbikullakshi.com","service":"http://edge-traefik:80"},
 {"hostname":"hypernova.arbikullakshi.com","service":"http://edge-traefik:80"},
 {"service":"http_status:404"}]}}' >/dev/null && echo ok

# 3. "Always Use HTTPS" (already on for arbikullakshi.com; this only checks it)
cf zones settings get always_use_https -z arbikullakshi.com | jq -r .value
```

Or in the dashboard: **Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared**,
name it `home-server`, then on the "Install and run a connector" page pick **Docker** and copy
the token: the long string after `--token` in the command shown (it starts with `eyJ`). Do
not run that command anywhere; the release runs cloudflared. Then **Next → Public
Hostnames**: add the three rows of the table above (Subdomain empty / `www` / `hypernova`,
domain `arbikullakshi.com`, Service type `HTTP`, URL `edge-traefik:80`). If the dashboard
refuses a hostname because a DNS record with that name exists, do section 10's first step
(delete the old records) at that point, at the cost of a slightly longer gap. Then **SSL/TLS
→ Edge Certificates → Always Use HTTPS: On**.

Keep the token for section 7 (the `CF_TUNNEL_TOKEN` secret). It is a credential: anyone with
it can run a connector that serves your hostnames. If it leaks, rotate it
([Rotating a secret](#rotating-a-secret)).

## 7. The production Environment

**Owner action**, on your laptop, with `gh` in the checkout. Create the Environment first
(Settings → Environments → New environment → `production`; optionally restrict it to the
`master` branch and add yourself as a required reviewer). Every value is new: generate them
here. Every value must be free of `$`, `"`, `'`, `` ` ``, `\`, `#`, line breaks and leading
or trailing spaces; the generated ones are.

```bash
# Access: the CI deploy key, the host key from section 5, the Tailscale OAuth client from section 4
gh secret set SSH_PRIVATE_KEY --env production < ~/.ssh/infra-deploy
gh secret set SSH_KNOWN_HOSTS --env production < /tmp/kh && rm /tmp/kh
gh variable set SERVER_SSH_HOST --env production --body infra-host
gh variable set TS_OAUTH_CLIENT_ID --env production --body '<client id>'
gh secret set TS_OAUTH_SECRET --env production                     # paste the OAuth client secret

# The Cloudflare Tunnel token from section 6
op item get "Cloudflare tunnel token (home-server)" --vault "Home Server" --fields label=password --reveal | gh secret set CF_TUNNEL_TOKEN --env production

# GHCR: an account and a classic token with read:packages that can read
# ghcr.io/somethim/portfolio, the ghcr.io/hypernova3643725 images and ghcr.io/somethim-home/home-server
gh variable set GHCR_USERNAME --env production --body '<github user>'
# GitHub shows a token's value only once. If you don't have it saved, make a new one:
# GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic) →
# Generate new token (classic), scope read:packages only, expiry 1 year; store it in 1Password
# ("Home Server" vault, "GHCR read token (infra)"), then:
op item get "GHCR read token (infra)" --vault "Home Server" --fields label=password --reveal | gh secret set GHCR_TOKEN --env production

# Database: three different passwords, 48 hex characters each; nobody needs to know them
for name in POSTGRES_SUPERUSER_PASSWORD PRIZM_DB_PASSWORD PORTFOLIO_DB_PASSWORD; do
  gh secret set "$name" --env production --body "$(openssl rand -hex 24)"
done

# Apps: generated secrets
gh secret set PORTFOLIO_TOTP_ENCRYPTION_KEY --env production --body "$(openssl rand -base64 32)"
gh secret set HYPERNOVA_SESSION_SECRET --env production --body "$(openssl rand -hex 24)"
# The status dashboard and S3 storage: run the block in section 12, "The status dashboard and
# S3 secrets" (it keeps the values in 1Password: the dashboard password and the S3 key are yours to use)
# HOME_TLS_CF_DNS_TOKEN: a Cloudflare API token, created as in "The links page" (section 12)
# Home: its owner variable, two keys and the Resend key, as in "Home" (section 12); its power
# key (HOME_POWER_KEY, optional) is a copy of one provisioning makes on the server, so it comes
# later, as in "Home's power control" (section 12)

# Apps: the two operator passwords you will log in with; store each in your password manager first
portfolio_admin="$(openssl rand -hex 16)"; echo "portfolio admin: $portfolio_admin"
gh secret set PORTFOLIO_ADMIN_PASSWORD --env production --body "$portfolio_admin"
hypernova_admin="$(openssl rand -hex 16)"; echo "hypernova admin: $hypernova_admin"
gh secret set HYPERNOVA_ADMIN_PASSWORD --env production --body "$hypernova_admin"
unset portfolio_admin hypernova_admin

# Optional: outgoing mail and the Google Calendar integration
gh secret set PORTFOLIO_RESEND_API_KEY --env production            # paste the Resend API key
gh variable set PORTFOLIO_GOOGLE_CLIENT_ID --env production --body '<client id>.apps.googleusercontent.com'
gh secret set PORTFOLIO_GOOGLE_CLIENT_SECRET --env production      # paste the client secret
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
cp inventory/hosts.example inventory/hosts      # [server] infra-host ansible_host=infra-host
ansible-playbook -u admin --ask-become-pass provision.yml
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
action `release`, every other input at its default. Expect in the "Release on the server"
step:

```
infra-apply: compose model accepted: 1 service(s) in the database stack, ...
infra-apply: compose model accepted: 1 service(s) in the portfolio stack, ...
infra-apply: compose model accepted: 2 service(s) in the hypernova stack, ...
infra-apply: compose model accepted: 1 service(s) in the tunnel stack, ...
infra-apply: compose model accepted: 2 service(s) in the ai stack, no privileged settings, no host port but none on the tailnet, ...
infra-apply: compose model accepted: 9 service(s) in the media stack, no privileged settings, no host port but beszel 100.x.y.z:8090, garage 100.x.y.z:3900, home 100.x.y.z:80, home-tls 100.x.y.z:443, sftpgo 100.x.y.z:8091 on the tailnet, ...
infra-apply: compose model accepted: 2 service(s) in the home stack, no privileged settings, no host port but none on the tailnet, no bind mount but home-server /srv/media/home-files, ...
infra-apply: bundle accepted: 29 files, manifest checksums match
infra-apply: Watchtower is stopped until the app stacks are up
infra-apply: pulling images
infra-apply: starting the database
infra-apply: database roles, passwords and grants are in place
infra-apply: starting portfolio
infra-apply: starting hypernova
infra-apply: starting tunnel
infra-apply: starting ai
infra-apply: starting media
infra-apply: starting home
infra-apply: Watchtower is running again
infra-apply: every container is running and healthy, and has run for at least 30s without a restart
infra-apply: Traefik routes arbikullakshi.com/api/health www.arbikullakshi.com/ hypernova.arbikullakshi.com/ hypernova.arbikullakshi.com/api/health to their apps
infra-apply: the Cloudflare Tunnel is connected (cloudflared /ready answers 200)
infra-apply: the tailnet-only ports home:80 home-tls:443 beszel:8090 garage:3900 sftpgo:8091 are bound to 100.x.y.z alone
infra-apply: home-tls serves https with a trusted certificate on 100.x.y.z for home.arbikullakshi.com files.home.arbikullakshi.com status.home.arbikullakshi.com s3.home.arbikullakshi.com
infra-apply: beszel-pair garage-setup home-keys finished: the dashboard's agent is paired, S3 has its layout, the owner's key and the files bucket, Home has its key files
infra-apply: Traefik, Watchtower, autoheal and Beszel's agent reach Docker through their socket proxies with no refused calls
infra-apply: RELEASE OK: <id> is current, following :latest, auto-updates on
```

PostgreSQL initialises the empty `pgdata-v18` volume on this first start, and `provision.sql`
creates the `prizm` and `portfolio` roles and databases; the apps create their schemas. The
portfolio can take up to 180 s to report healthy. The `ai` and `media` stacks need the GPU,
the status dashboard and S3 secrets and (for Garage's objects off the SSD) the disks; set them
up first ([section 12](#12-gpu-ai-and-media)), since a release refuses without the first two. In the Cloudflare dashboard the tunnel now
shows **Healthy** with connections.

The release ends by asking the public hostnames through Cloudflare from the server
("Cloudflare serves …", just before `RELEASE OK`). If the DNS records still point at the old
server, that check fails although the release is current and verified; section 10 fixes the
records and ends with a second `release` whose public check proves the new path.

## 10. DNS switch-over and decommissioning the old server

**Owner action.** This is the only moment the sites change hands, and the only section that
touches the old Hetzner server. Nothing is copied from it: the new server started empty.

1. **Replace the old records with the tunnel's.** Delete the `A` and `AAAA` records of
   `arbikullakshi.com`, `www.arbikullakshi.com` and `hypernova.arbikullakshi.com` (they point
   at the Hetzner server), then create, for each of the three names, a proxied `CNAME` to
   `<tunnel id>.cfargotunnel.com`:

   ```bash
   # (done 2026-10-15) 1. Delete the old records (ids from `cf dns records list -z $Z`)
   Z=<zone id>    # cf zones list: the id of the apex domain's zone
   cf dns records delete <record id> -z $Z --force

   # 2. Route the three hostnames to the tunnel
   for n in arbikullakshi.com www hypernova; do
     cf dns records create -z $Z --body "{\"type\":\"CNAME\",\"name\":\"$n\",\"content\":\"$TUNNEL_ID.cfargotunnel.com\",\"proxied\":true}" >/dev/null && echo "ok $n"
   done

   # 3. Check: each name is a proxied CNAME to the tunnel, no A/AAAA left
   cf dns records list -z $Z | jq -r '.[] | select(.type=="A" or .type=="AAAA" or .type=="CNAME") | "\(.type) \(.name) \(.content) proxied=\(.proxied)"'
   ```

   In the dashboard: **DNS → Records**, delete the three names' `A`/`AAAA` records; then in
   **Zero Trust → Networks → Tunnels → home-server → Public Hostnames**, re-save each
   hostname (adding a public hostname creates its proxied CNAME). Leave the zone's other
   records (mail: `MX`, `TXT`, Resend's DKIM) alone.
2. **Check from outside**, for example from a phone off Wi-Fi or the laptop (Cloudflare's
   proxy answers at once; there is no TTL to wait out for proxied records):

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' https://arbikullakshi.com/api/health            # 200
   curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://www.arbikullakshi.com/ # 301 https://arbikullakshi.com/
   curl -sS -o /dev/null -w '%{http_code}\n' https://hypernova.arbikullakshi.com/api/health  # 200
   curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' http://arbikullakshi.com/      # 301 https://arbikullakshi.com/
   ```

   A `530` (error 1033) means the tunnel has no connector or no Public Hostname for that
   name; a `502` that cloudflared cannot reach `edge-traefik:80`; a `404` that Traefik has no
   router for that host.
3. **Run `release` again** (Actions → Deploy, action `release`). Its public check now goes
   through the tunnel and prints "Cloudflare serves https://arbikullakshi.com/api/health
   https://www.arbikullakshi.com/ https://hypernova.arbikullakshi.com/ …" before `RELEASE OK`.
4. **Set up the portfolio again**: sign in at `https://arbikullakshi.com/admin` with
   `PORTFOLIO_ADMIN_PASSWORD`, enrol TOTP and passkeys afresh, and reconnect Google Calendar
   if you use it. Sign in to hypernova with `HYPERNOVA_ADMIN_PASSWORD`.
5. **Decommission the old server**, in the Hetzner Cloud console (<https://console.hetzner.cloud>),
   only after step 3 is green. There is nothing to snapshot (no data moves):
   - the project's **Servers** → the old server → **Delete** (this also deletes its primary
     IPs unless they are protected; delete any that remain under **Primary IPs**);
   - **Volumes**: delete any volume that was attached to it;
   - **Firewalls**, **Floating IPs**, **Networks** and **Snapshots/Backups** that belonged to
     it: delete them;
   - then check the project's **Usage** shows nothing billable, and cancel the project if it is
     empty.
6. **Clean up the rest of the old setup**: in the Tailscale console, remove the old server's
   node if it is still listed and revoke any unused auth key; in GitHub, delete any old
   repository-level secrets (Settings → Secrets and variables → Actions) that the
   `production` Environment now holds.

## 11. Day-2 operations

### Releases, status, rollback, resume

All four are **Actions → Deploy → Run workflow** from `master`, with the `action` input. The
`portfolio`, `hypernova_provider`, `hypernova_web`, `home` and `dry_run` inputs apply only to
`rollback`; the workflow refuses them with any other action.

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

**`rollback`** pins app images to digests. Per app, the input is:

| Input | Means |
| --- | --- |
| `previous` (default) | the first digest that differs from the running one: from the current release's `recorded` lines, then the previous release's, then the `known` images |
| `current` | the digest running now (freezes it) |
| `latest` | keep following `:latest` for this app |
| a 40-character commit sha | portfolio only: its `:<sha>` tag, by digest |
| `sha256:<64 hex>` | that digest, after checking GHCR has it |

Run it with `dry_run: true` first: it prints the status and the resolved pins (`RELEASE_MODE=pinned`
and one `PORTFOLIO_IMAGE=`, `PROVIDER_IMAGE=`, `WEB_IMAGE=`, `HOME_IMAGE=` line each) and stops.
All four `latest` is refused (that is `resume`). A pinned image is `<repository>:latest@sha256:<digest>`,
which Watchtower cannot move, so auto-updates stay paused for the pinned apps until `resume`.
hypernova and Home only publish `:latest`, so their rollback needs a digest the host or a
release has seen; if none is known, pass one explicitly.

**`resume`** is a `release` again: every app back on `:latest`, auto-updates on. Run it once
the fix is published.

**When a release fails**, the output says where:

- "…; the running release is untouched": refused before any change (a bad bundle or
  compose model, a refused GHCR login, a failed pull).
- "FAILED: before the app stacks changed, …" then "release `<id>` is installed but not
  current; … a rollback cannot fix this …": the database did not come up healthy or
  `provision.sql` failed. The database runs the new definition, portfolio and hypernova the
  previous one, and `current` still names the previous release. A `rollback` does not help
  here: it only re-pins the app images and renders `stack/database`, `provision.sql` and the
  secrets from `master` again. Revert the `stack/database` or secret change on `master` (or fix
  the secret in the `production` Environment) and run `release`.
- "release `<id>` is current but not verified; … (the last verified release was `<id>`:
  `<summary>`)": an app stack or the tunnel did not start, or the release did not verify; the
  new release is `current`, and `previous` still names the last verified one. Read the failure
  line above it (which container was not healthy, which route answered what, whether
  cloudflared reached Cloudflare). Run `rollback` only when an app image is the cause: it
  changes nothing but the four app image references. A broken `stack/` file, env template or
  secret (a revoked `CF_TUNNEL_TOKEN` among them) comes back with a rollback (it is rendered
  from `master` again), so fix that on `master` or in the Environment and run `release`. The
  release kept in `/opt/infra/releases/` cannot be re-applied.

### Rotating a secret

Change it in the `production` Environment, then run `release`. That is the whole procedure for
most values:

- **Database passwords**: `provision.sql` re-sets each role's password in the same release
  that renders the new DSN, so the two cannot drift. `POSTGRES_SUPERUSER_PASSWORD` is re-set
  the same way. Generate with `openssl rand -hex 24`.
- **`CF_TUNNEL_TOKEN`**: in the dashboard, **Zero Trust → Networks → Tunnels → home-server →
  Refresh token** (or delete the tunnel and repeat section 6 steps 1–2 under the same name, then section 10 step 2 for the new id), store the new token,
  then run `release`: it recreates `cloudflared` with the new token, and the old token stops
  working. The sites are unreachable from the token refresh until the release's tunnel check
  passes, about a minute.
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
  passkey; home-server refuses to start with a key that does not open them. Only with
  `reset-owner` and every family member re-enrolling (see [Home](#home)).
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
ansible-playbook -u admin --ask-become-pass provision.yml                 # everything
ansible-playbook -u admin --ask-become-pass provision.yml --tags edge     # one role
```

Run it when a role changes on `master`. It never touches the app stacks or their data.

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

### The sites are down but the server is up

```bash
ssh admin@infra-host sudo docker ps --format '{{.Names}} {{.Status}}'
ssh admin@infra-host sudo docker logs --tail 50 cloudflared
```

`cloudflared` restarts on its own (`restart: always`, and autoheal when it reports
unhealthy). Logs saying the token is invalid mean the tunnel was deleted or its token
refreshed: store the current token as `CF_TUNNEL_TOKEN` and run `release`. A home internet
outage takes the sites down until the line is back; cloudflared reconnects by itself, and a
change of the home's public IP needs nothing at all.

### The down page

A Cloudflare Worker answers the public sites with a "server is down" page (503) while the
server is off or the tunnel is not connected, and otherwise passes every request through
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

3. **Deploy** (builds with `worker-build --release`, uploads, and attaches the three routes in
   `wrangler.toml`):

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
   curl -sS -o /dev/null -w '%{http_code}\n' https://hypernova.arbikullakshi.com/api/health  # 200
   ```

   and, at a quiet moment, that the page appears while the tunnel is down and goes away after:

   ```bash
   ssh admin@infra-host sudo docker stop cloudflared
   curl -s -o /dev/null -w '%{http_code} %header{retry-after}\n' https://arbikullakshi.com/   # 503 120
   ssh admin@infra-host sudo docker start cloudflared
   ```

**Free plan**: 100,000 requests a day for the whole account (Workers & Pages → Overview shows
the count), 10 ms CPU per request, which this Worker stays far below. **Off**: `npx
wrangler@4.147.0 delete` (or remove its routes in the dashboard); the sites then show
Cloudflare's own error pages again. **Logs**: none are kept (Workers Logs are off); `npx
wrangler@4.147.0 tail` streams live requests only while you watch, and shows their URLs, so use
it only to debug.

### Re-pinning third-party images

Every non-app image (PostgreSQL, Traefik, cloudflared, the socket proxies, Watchtower,
autoheal) is pinned `<image>:<tag>@sha256:<digest>`, one version per repository across
`stack/` and `roles/*/files/`, and the bundle build refuses anything else. To move one (a
Watchtower that the Engine calls "too old", a Traefik, cloudflared or PostgreSQL patch
release), follow [docs/agents.md](docs/agents.md#re-pinning-third-party-images), then
provision with that role's tag, or run `release` for `postgres` (a minor version only; a
major is a dump and restore, [docs/database.md](docs/database.md#upgrades)) and `cloudflared`
(`stack/tunnel`).

### Restoring from the backup disk

The external disk holds, under `/srv/backup/snapshots/` (root only), one folder per night,
`<YYYY-MM-DD>/`, and `latest` pointing at the newest:

```
snapshots/<date>/postgres.sql.gz       pg_dumpall of the shared PostgreSQL
snapshots/<date>/volumes/<volume>/     the apps' volumes as plain trees: portfolio-media,
                                       hypernova_prizm-storage, beszel-data, garage-meta, sftpgo-data, home-data,
                                       and the retired apps' kept volumes (jellyfin-config,
                                       audiobookshelf-config, audiobookshelf-metadata, kavita-config,
                                       open-webui-data, immich-pgdata)
snapshots/<date>/media/<name>/         s3 (Garage's objects, the Files bucket), home-files (Home Files'
                                       ciphertext), and the retired
                                       apps' kept folders audiobooks, books, podcasts and photos
```

Snapshots from before 2026-10-20 also hold `immich.sql.gz`, Immich's own database dump.

Kept: the last 14 nights, plus the first night of each of the last 8 weeks, so anything
deleted within about two months is still in an older snapshot. Unchanged files are hard links
between snapshots, so each night only costs what changed. Movies, shows and the Ollama models
are not backed up. Check last night's run with
`ssh admin@infra-host journalctl -u infra-backup.service --since yesterday`; a failed one also
logs "the nightly backup FAILED" at error priority, and its unfinished
`snapshots/.<date>.partial` stays until the next run.

**A file from the retired apps' folders** (books, audiobooks, podcasts and photos are plain
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

**The database**, all roles and databases at once, into the running cluster (a dump of the
whole cluster; restoring it over existing databases fails on objects that exist, so for one
app drop its database first, or restore into a fresh `pgdata-v18` after a reinstall):

```bash
sudo docker stop portfolio prizm-provider prizm-web
gzip -cd /srv/backup/snapshots/<date>/postgres.sql.gz | sudo docker exec -i postgresql psql -U postgres -d postgres
sudo docker start portfolio prizm-provider prizm-web
```

Restore `portfolio-media` from the same snapshot as the dump: the portfolio's `media` table is
a ledger of that volume ([docs/database.md](docs/database.md#backups)).

**Everything on the media disk**, after replacing the internal disk (format it as in
[Disks](#disks), put the new UUID in `production.yml`, provision):

```bash
sudo rsync -a --numeric-ids /srv/backup/snapshots/latest/media/ /srv/media/   # owners, groups and modes come back as they were
```

**A new server**: install and provision as in sections 3–9 with the same `production.yml`
(the backup disk's UUID included), release once so every volume exists, then restore each
app volume, Garage and the database as above, all from the same snapshot.

**Before snapshots** (backups written before this layout): the first snapshot run deletes the
old `media/` mirror and `apps/` folder once a complete snapshot exists (it links to the old
mirror, so nothing is copied twice), and the old `postgres/` and `immich/` dumps once 14
snapshots exist.

### More recipes

PostgreSQL access, disk, backups, a major PostgreSQL upgrade, Watchtower and a hung site are
in [docs/operations.md](docs/operations.md).

## 12. GPU, AI and media

**Owner action.** Turns on what the rest of the hardware is for: Ollama on the RTX 2060 (for
hypernova), the status dashboard, Files (S3 storage on the 1 TB internal HDD) behind a links
page, and a nightly backup to the 1 TB external USB HDD. None of it is public: it is reachable
only over the tailnet, on the server's Tailscale address, and only by the Tailscale accounts the
policy names (you). Do the steps in this order; each one says how to check it.

The media and AI apps that used to be here (Immich, the media engine, Audiobookshelf, Kavita,
Open WebUI, SearXNG, ComfyUI) were retired on 2026-10-20; their data is kept and still backed
up. See [Retired apps](#retired-apps-2026-10-20).

Every service has an https name under `home.arbikullakshi.com` with a real certificate, served by
`home-tls` on the Tailscale address (443). Use these: browsers allow the clipboard and installing a
site as an app only over https. The old `http://infra-host:<port>` addresses
still work (apps set up with them keep running) and may be retired later.

| Service | Address (on the tailnet) | Also, older | Container port |
| --- | --- | --- | --- |
| Home (the owner's app: sign-in, dashboard, Home Files) | `https://home.arbikullakshi.com/` | `http://infra-host/` sends the browser there | 8080 (`home-server`, no host port); 80 (`home`) |
| Files (SFTPGo, the file manager) | `https://files.home.arbikullakshi.com` (web client at `/web/client`, WebDAV at `/dav`) | `http://infra-host:8091/web/client` | 8091, 8092 |
| Beszel (server status) | `https://status.home.arbikullakshi.com` | `http://infra-host:8090` | 8090 |
| Garage (S3 behind Files) | `https://s3.home.arbikullakshi.com` (path-style, region `garage`) | `http://infra-host:3900` | 3900 |

The names come from one map, `home_hosts` in `production.yml` (key: the service; value: the first
label); a release requires exactly `files`, `status` and `s3`. Changing a label there changes
the route, the app's own public URL and the release check together.

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
account, setgid, group-writable) and `photos` ([Retired apps](#retired-apps-2026-10-20)),
creates Home's `home-files` (the `home-server` account's alone, uid 65532), and
keeps the backup disk root-only. While a configured disk is missing its mountpoint stays empty and unwritable, so
nothing lands on the SSD in its place. Check after provisioning:

```bash
ssh admin@infra-host findmnt /srv/media /srv/backup        # both, ext4, by UUID
ssh admin@infra-host ls -l /srv/media                      # s3 and photos drwx------ media media, home-files drwx------ home-server home-server, the other five drwxrwsr-x, media media
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
ansible-playbook -u admin --ask-become-pass provision.yml
```

The `gpu` role installs the driver and the NVIDIA Container Toolkit; `host` writes the
Tailscale address into `/etc/infra/host.env`, turns on non-local binds, adds the second
firewall hook, the `ai`, `llm` and `media` networks, the `ai` and `media` accounts (and puts
`admin` in the `media` group) with their volumes, mounts the disks and installs the nightly
backup. A first run ends the `gpu` part with "The NVIDIA driver was installed or updated since the last boot
and is not loaded yet … Reboot when it suits you": the driver loads at the next boot. Reboot
(the sites are back when Docker has restarted the stacks, about a minute), then verify:

```bash
ssh -t admin@infra-host sudo reboot
ansible-playbook -u admin --ask-become-pass provision.yml --tags gpu,host
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
100.x.y.z alone". In the background, after the release, `ollama-pull` downloads
`ollama_models` in order: `qwen3:4b` (2.6 GB, the model hypernova uses, first),
`qwen2.5-coder:14b` (9 GB) and `qwen3:14b` (9.3 GB), about 21 GB on the SSD; roughly 30
minutes at 100 Mbit/s.

```bash
ssh admin@infra-host sudo docker logs -f ollama-pull      # "every model in ollama_models is present"
ssh admin@infra-host sudo docker exec ollama nvidia-smi -L   # GPU 0: NVIDIA GeForce RTX 2060 (inside the container)
ssh admin@infra-host sudo docker exec ollama ollama ps    # after a hypernova AI request: 100% GPU
ssh admin@infra-host sudo docker ps --format '{{.Names}} {{.Ports}}'   # ports only on 100.x.y.z
```

hypernova's AI features use the same Ollama over the internal `llm` network from this release
on.

### First logins

After the release, from the laptop (on the tailnet):

1. **Home**, `https://home.arbikullakshi.com/setup`: see [Home](#home) for the first setup.
1. **Beszel**, `https://status.home.arbikullakshi.com`: nothing to set up. Sign in with `status_owner_email`
   (`production.yml`) and `BESZEL_PASSWORD`; `infra-host` is already listed
   ([The status dashboard](#the-status-dashboard)).
1. **Files**, `https://files.home.arbikullakshi.com/web/client`: nothing to set up. Sign in as
   `owner` with `FILES_PASSWORD` ([Files](#files-s3-storage)).

### The links page

The links page's two tiles at `https://home.arbikullakshi.com/` were replaced by Home (below).
What is left of it, in the media stack, each on the Tailscale address only:

- `home` (busybox `httpd`, the pages are in `stack/media/docker-compose.yml`) on port 80:
  `http://infra-host/` sends the browser on to `https://home.arbikullakshi.com/` (with plain
  links to Home, the file manager and Status for a browser that does not follow it), and
  `/files.html` lists the other ways into the files bucket, also at
  `https://home.arbikullakshi.com/files.html`.
- `home-tls` (Traefik, the edge image) on port 443, for `https://home.arbikullakshi.com/` (Home's
  `home-server`; `/dav` and `/files.html` still go to SFTPGo and `home`) and every
  `<label>.home.arbikullakshi.com`: it routes each name to its container over the media
  network, with no read or write timeout, so big uploads and long streams pass. `home-tls` gets one
  Let's Encrypt certificate for `home.arbikullakshi.com` and `*.home.arbikullakshi.com` by the
  DNS-01 challenge through Cloudflare's API, so nothing on the internet has to reach the server,
  and keeps it in the `home-tls-acme` volume (not backed up: a lost one is simply reissued).

`home` and `*.home` are DNS-only records (grey cloud, not proxied) to the server's Tailscale
address. Off the tailnet that address leads nowhere, so the records reveal nothing usable:

```bash
Z=<zone id>        # cf zones list: the id of the apex domain's zone
TS_IP=<100.x.y.z>  # the server's Tailscale IPv4: ssh admin@infra-host tailscale ip -4
cf dns records create -z $Z --body '{"type":"A","name":"home","content":"'"$TS_IP"'","proxied":false,"comment":"tailnet-only Home (home-tls)"}'
cf dns records create -z $Z --body '{"type":"A","name":"*.home","content":"'"$TS_IP"'","proxied":false,"comment":"tailnet-only service names (home-tls)"}'
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
the release that brings `home-tls`. The release then asks every name over https on the
Tailscale address and waits up to 5 minutes each for the certificate ("home-tls serves https
with a trusted certificate on 100.x.y.z for home.arbikullakshi.com files.home… s3.home…"):
`https://home.arbikullakshi.com/healthz` must answer 200 (home-server), a service 2xx, 3xx, 401 or 403 (a 404 means no route, 502 a
container home-tls cannot reach). A refused token shows in
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

Beszel at `https://status.home.arbikullakshi.com` (the all-systems overview,
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

**The file manager.** `https://files.home.arbikullakshi.com/web/client` is SFTPGo's web
client on the `files` bucket, made to work like Google Drive:

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

**As a drive (WebDAV).** `https://files.home.arbikullakshi.com/dav` (through `home-tls`, so with
the real certificate; `https://home.arbikullakshi.com/dav` still works for older mounts), user
`owner`, the same password. On the laptop: Nautilus, Other Locations,
`davs://files.home.arbikullakshi.com/dav`, or `rclone config create homedav webdav
url=https://files.home.arbikullakshi.com/dav vendor=other user=owner pass="$(rclone obscure "$(op item
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

**Straight to S3.** Garage at `https://s3.home.arbikullakshi.com` (or `http://infra-host:3900`): S3-compatible storage, region `garage`, path-style
addressing, bucket `files`, over the tailnet only (plain http; Tailscale encrypts the link).
Objects are on the media disk (`/srv/media/s3`), the metadata on the SSD (`garage-meta`); the
nightly backup stops Garage only while it copies `garage-meta` and `/srv/media/s3` into the same snapshot, so the two match, and starts it right after; a file deleted from the bucket stays in older snapshots for about two months.
`https://home.arbikullakshi.com/files.html` (or `http://infra-host/files.html`) shows the same instructions.

The key is the one in 1Password; with rclone on the laptop:

```bash
rclone config create home s3 provider=Other endpoint=https://s3.home.arbikullakshi.com \
  region=garage force_path_style=true \
  access_key_id="$(op item get 'infra production secrets' --vault "Home Server" --fields label=GARAGE_OWNER_ACCESS_KEY_ID --reveal)" \
  secret_access_key="$(op item get 'infra production secrets' --vault "Home Server" --fields label=GARAGE_OWNER_SECRET_KEY --reveal)"
rclone copy ~/Documents/report.pdf home:files/
rclone ls home:files
rclone mount home:files ~/S3 --vfs-cache-mode writes     # optional: as a folder
```

Any S3 app works the same way (Cyberduck, S3 Files, FolderSync, …): S3-compatible, server
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

**First deploy**, in this order:

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
   key to every enrolled second factor; it is not in the backups):

   ```bash
   item="infra production secrets"
   set_secret() { op item edit "$item" --vault "Home Server" "$1[password]=$2" >/dev/null && printf %s "$2" | gh secret set "$1" --env production -R somethim-home/infrastructure; }
   set_secret HOME_SECRET_KEY "$(openssl rand -base64 32)"
   set_secret HOME_DATA_KEY "$(openssl rand -base64 32)"
   unset -f set_secret; unset item
   ```

4. **The GHCR token** must be able to read `ghcr.io/somethim-home/home-server` (a classic token
   with `read:packages` reads every package its account can; if `GHCR_USERNAME` is not a member
   of `somethim-home`, give it read access to the package).
5. **Provision** (`ansible-playbook -u admin --ask-become-pass provision.yml`, or
   `--tags host`): it adds `HOME_USER` and `HOME_IMAGE_REPO` to `/etc/infra/host.env`, creates the
   `home-server` account (uid 65532, the image's), the `home-data` and `home-keys` volumes and
   `/srv/media/home-files` (0700, 65532). A release before this is refused ("HOME_USER is not
   …; run provisioning").
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

1. `https://status.home.arbikullakshi.com/_/` (PocketBase's admin pages), sign in as its
   superuser (on this hub, `status_owner_email` and `BESZEL_PASSWORD`; not checked against a
   running hub yet).
2. Collections → `users` → New record: an email of your choosing (e.g. a `+home` alias of
   yours), a password from `openssl rand -hex 16`, role `readonly`, verified on. Save.
3. Collections → `systems` → `infra-host` → add that user to `users`. Save.
4. Put the email in `production.yml` (`home_beszel_user`) on `master`, set the password as the
   `HOME_BESZEL_PASSWORD` secret (and in 1Password), and release. home-server then reads
   `http://beszel:8090` over the media network.

**Logs**: `ssh admin@infra-host sudo docker logs home-server` (sign-ins, mail sent or refused by
Resend), `sudo docker logs home-keys` ("the keys and passwords are in place").

### Home's power control

Home can switch the server off or restart it (after its own countdown) by handing the host one
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
   ansible-playbook -u admin --ask-become-pass provision.yml --tags common,host
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
`https://home.arbikullakshi.com/` (Home) or the https names in the table above. In
apps, use the https names as the server address:

- Files in the browser (`https://files.home.arbikullakshi.com/web/client`), or WebDAV at
  `https://files.home.arbikullakshi.com/dav`
- S3 apps: server `s3.home.arbikullakshi.com`, port 443, TLS on, path-style, region `garage`

The phone resolves these names through public DNS (the records point at the Tailscale address),
so Tailscale's own DNS setting does not matter. A device that is not on the tailnet gets
nothing, by design. Apps already set up with `http://infra-host:<port>` keep working; switch them
when convenient.

### Retired apps (2026-10-20)

Immich, the media engine, Audiobookshelf, Kavita, Open WebUI, SearXNG and ComfyUI no longer run;
the owner's own apps will replace them. Their volumes and the folders under `/srv/media`
(`shows`, `movies`, `audiobooks`, `podcasts`, `books`, `photos`) are kept, still created by
provisioning and still backed up nightly (except caches and the films and series), and nothing
deletes them. What is kept, and what the owner may clean up (the four unused secrets, the old
Tailscale grants), is in [docs/stacks.md](docs/stacks.md#retired-apps-2026-10-20).

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
ansible-playbook -u admin --ask-become-pass provision.yml --tags snowflake
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

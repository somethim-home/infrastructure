# Variables: what is specific to one setup

Everything in this repository that names the owner's own server, domains, accounts or
addresses, as a variable with an example value. Production keeps its real values where it
always has: [`production.yml`](../production.yml), the gitignored `inventory/hosts`, and the
GitHub `production` Environment. To reuse the repository, start from
[`production.example.yml`](../production.example.yml) (nothing reads it; copy it over
`production.yml`) and set the rest as below.

Example values use the documentation ranges and names: `example.com`, `192.168.1.50` for a LAN
address, `100.64.0.7` for a Tailscale address, `owner@example.com`.

## `production.yml`: facts about the host

Read by both `provision.yml` and `release.yml`. No secrets.

| Key | Example | Meaning |
| --- | --- | --- |
| `server_name` | `infra-host` | The server's tailnet hostname; provisioning names the node after it. Also `SERVER_SSH_HOST` below and the `inventory/hosts` entry |
| `tailscale_server_tag`, `tailscale_ci_tag` | `tag:infra-server`, `tag:infra-ci` | Tailscale ACL tags of the server and of the ephemeral CI node |
| `ubuntu_release`, `docker_engine_major` | `resolute`, `29` | Confirmed on the host before provisioning; a mismatch refuses to run |
| `reboot_time`, `backup_time` | `"04:00"`, `"02:30"` | UTC; unattended-upgrades reboot and the nightly backup |
| `gpu_enabled`, `nvidia_driver_major` | `true`, `580` | The NVIDIA card and its driver branch; `false` skips the GPU |
| `ai_uid`/`ai_gid`, `media_uid`/`media_gid`, `home_uid`/`home_gid` | `2001`, `2000`, `65532` | Service accounts the stacks run as (`home_uid` is fixed by Home's image) |
| `media_disk_uuid`, `backup_disk_uuid` | `"00000000-0000-4000-8000-000000000001"` | Filesystem UUIDs (`sudo blkid`) of the library and backup disks; empty means not mounted |
| `quiet_hours_*`, `quiet_gpu_power_limit_w`, `quiet_cpu_max_percent` | `true`, `"23:00"`, `"08:00"`, `Europe/London`, `130`, `70` | Quiet hours ([host.md](host.md#quiet-hours)) |
| `swap_size` | `2G` | Swap file size |
| `lan_interface` | `enp8s0` | The wired NIC (`ip -br link`) that Wake-on-LAN is set on |
| `infra_hosts` | `{home: {server_name: infra-host, stacks: [ai, media, home]}, hetzner: {server_name: infra-hetzner, stacks: [database, portfolio]}}` | The two hosts: tailnet names and the stacks each bundle holds |
| `public_ports` | `[]` on home, `[80, 443]` on hetzner | Docker-published ports the public interface may reach (hetzner: from Cloudflare only) |
| `cloudflare_ips_pinned` | Cloudflare's ranges | The fallback when provisioning cannot fetch them |
| `apex_domain`, `www_domain`, `preview_domain` | `example.com`, `www.example.com`, `""` | The public site on the hetzner host, and an optional second name for checking it before a switch |
| `home_domain` | `home.example.com` | Home's tailnet-only https name, served by `home-tls` (the only one; no wildcard) |
| `acme_email`, `status_owner_email` | `owner@example.com` | Let's Encrypt contact; the Beszel dashboard login |
| `home_files_capacity`, `home_beszel_user` | `600G`, `""` | Home Files' storage pool; Home's read-only Beszel user |
| `home_media_transcodes`, `home_media_transcodes_quiet` | `2`, `1` | Home's Media: HLS transcodes at once, by day and in quiet hours |
| `home_ai_models` | `[{id: qwen3-8b, label: Qwen3 8B, about: …, file: Qwen3-8B-Q5_K_M.gguf, day_only: false}, …]` | Home's AI models: what Home lists (`HOME_AI_MODELS`) and the GGUF files llama-server serves (`LLAMA_MODELS`); the first is the default |
| `dns_over_tls_enabled`, `dns_over_tls_servers` | `true`, `[1.1.1.1#cloudflare-dns.com, …]` | The host's encrypted DNS ([host.md](host.md#encrypted-dns)) |
| `portfolio_image_repo`, `home_image_repo` | `ghcr.io/example/portfolio`, … | The app images Watchtower follows |
| `snowflake_enabled` | `true` | The Tor Snowflake proxy ([host.md](host.md#snowflake)) |

## `inventory/hosts` (gitignored)

Copied from [`inventory/hosts.example`](../inventory/hosts.example). One host in `[server]`,
reached by its tailnet name; only the very first run (before the host joins the tailnet) points
`ansible_host` at its LAN address:

```ini
[server]
infra-host ansible_host=infra-host
# first run only: infra-host ansible_host=192.168.1.50
```

## The GitHub `production` Environment

Read only by the Deploy workflow ([deploying.md](deploying.md#secrets-and-variables) has every
format and where each value lands on the host). Secrets never appear in the repository.

| Variable | Example | Meaning |
| --- | --- | --- |
| `SERVER_SSH_HOST` | `infra-host` | The server's tailnet name; the only address the workflow SSHes to |
| `SERVER_USER` | `deploy` | *(optional)* The forced-command account |
| `TS_OAUTH_CLIENT_ID` | `k123…` | Tailscale OAuth client for the ephemeral CI node |
| `GHCR_USERNAME` | `example` | Account of `GHCR_TOKEN` |
| `HETZNER_SSH_HOST` | `infra-hetzner` | The hetzner host's tailnet name (`SERVER_SSH_HOST` is home's) |
| `R2_PUBLIC_BUCKET`, `R2_PRIVATE_BUCKET` | `example-public`, `example-private` | The portfolio's media buckets |
| `MEDIA_PUBLIC_BASE` | `https://media.example.com` | The public bucket's URL |
| `PORTFOLIO_GOOGLE_CLIENT_ID` | `….apps.googleusercontent.com` | *(optional)* |
| `HOME_OWNER_EMAIL` | `owner@example.com` | A repository variable: Home's owner account |

Secrets: `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`, `TS_OAUTH_SECRET`, `GHCR_TOKEN`,
`HOME_TLS_CF_DNS_TOKEN`, `POSTGRES_SUPERUSER_PASSWORD`, `PORTFOLIO_DB_PASSWORD`,
`PORTFOLIO_ADMIN_PASSWORD`, `PORTFOLIO_RESEND_API_KEY`, `PORTFOLIO_TOTP_ENCRYPTION_KEY`,
`PORTFOLIO_GOOGLE_CLIENT_SECRET`, `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
`R2_BACKUP_ACCESS_KEY_ID`, `R2_BACKUP_SECRET_ACCESS_KEY`, `CF_ORIGIN_CERT`, `CF_ORIGIN_KEY`,
`BESZEL_PASSWORD`, `BESZEL_AGENT_TOKEN`, `GARAGE_RPC_SECRET`,
`GARAGE_ADMIN_TOKEN`, `GARAGE_OWNER_ACCESS_KEY_ID`, `GARAGE_OWNER_SECRET_KEY`, `FILES_PASSWORD`,
`HOME_SECRET_KEY`, `HOME_DATA_KEY`, `HOME_RESEND_API_KEY`, `HOME_POWER_KEY`,
`HOME_TMDB_READ_TOKEN`, `HOME_BESZEL_PASSWORD`. [`ci/sample-extra-vars.json`](../ci/sample-extra-vars.json) shows each
one's shape with fake values.

## Committed public keys

[`roles/common/files/deploy_key.pub`](../roles/common/files/deploy_key.pub) is the public half
of the CI deploy key (its private half is `SSH_PRIVATE_KEY`). A fork replaces it with its own.

## Values still written into files

A few files carry the owner's values directly rather than through `production.yml`; a fork
edits them by hand:

| File | Value |
| --- | --- |
| [`stack/portfolio/portfolio.env.j2`](../stack/portfolio/portfolio.env.j2) | the portfolio's origin, admin and sender addresses |
| [`stack/portfolio/docker-compose.yml`](../stack/portfolio/docker-compose.yml) | the `www.` to apex redirect |
| [`stack/home/home-server.env.j2`](../stack/home/home-server.env.j2) | Home's `From` address |
| [`cloudflare/down-page/wrangler.toml`](../cloudflare/down-page/wrangler.toml), `src/` | the Worker's routes and the hosts it answers for |
| `ci/*.sh` | test expectations that use the real domains |
| [`RUNBOOK.md`](../RUNBOOK.md) and `docs/` | the owner's names as worked examples; `192.168.1.50` stands for the LAN address, `$TS_IP` and `<zone id>` for the Tailscale address and Cloudflare zone |

## Kept out of the repository

`inventory/hosts`, `vars.json`, `.env` and `ansible_password.txt` are gitignored, and so are the
owner's own `plans/` and `audit/` notes, which some comments still cite by number.

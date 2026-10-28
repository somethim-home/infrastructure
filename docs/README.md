# infra docs

Why this server is built the way it is. The code says *what* happens; these files say
*why*, and what will break if you change it. What to *do*, in order, is in
[RUNBOOK.md](../RUNBOOK.md).

| Document | Covers |
| --- | --- |
| [architecture.md](architecture.md) | The deployment model: two hosts (home, tailnet only; hetzner, the public portfolio behind Cloudflare), one deployer, three access paths, provision vs release, the stacks and their order, the releases directory, env files, networks, public vs tailnet-only services, why no port is public, host keys |
| [deploy-home.md](deploy-home.md) | **A clean-slate reinstall**, as one ordered checklist: from a blank machine (the media and backup disks kept) to everything live, Home included; the OS install, BIOS, both provisionings, Tailscale, which secrets to keep and which to make fresh, the AI models, the release, Home's owner setup, first-run checks, restoring from the old backups, the down page, retiring the old, rollback |
| [deploying.md](deploying.md) | The Deploy workflow and its inputs, every secret and variable (and where production keeps each), where each secret lands, what `infra-apply` checks, provisioning tags, adding a project |
| [stacks.md](stacks.md) | What is peculiar about the portfolio, the tailnet-only `ai` (llama-server) and `media` (`home-tls`, status dashboard, S3 and file manager) and `home` (Home, the owner's app: web app, Files, Media, Books, AI, live updates) stacks: hardening, bind mounts, the GPU shared and its VRAM budget; the apps retired on 2026-10-20 |
| [database.md](database.md) | The shared PostgreSQL — the volume, the superuser, how roles and databases are provisioned at release time, upgrades |
| [edge.md](edge.md) | Cloudflare in front of the hetzner host's Traefik: Full (strict) with an Origin CA certificate, Authenticated Origin Pulls, the Cloudflare-only firewall, client IPs, routing by label, the "server is down" Worker |
| [host.md](host.md) | The home server: Tailscale-only SSH, the accounts and the LAN bootstrap, sshd policy, firewall, fail2ban, patching, time, power and Wake-on-LAN, quiet hours, encrypted DNS, journald, swap, the Docker daemon, the GPU, service accounts, the disks, memory limits |
| [agents.md](agents.md) | The three things that act on their own: Watchtower, autoheal, the prune timer; re-pinning third-party images |
| [operations.md](operations.md) | Short recipes: PostgreSQL access, disk, the backups, a major upgrade, Watchtower, a hung site |
| [variables.md](variables.md) | Every value specific to the owner's setup (`production.yml`, `inventory/hosts`, the GitHub Environment, values written into templates) with example values; [`production.example.yml`](../production.example.yml) |

## Elsewhere in the repository

| File | Covers |
| --- | --- |
| [README.md](../README.md) | What this is, the architecture diagram, how home, home-crypto, latchkey and infra fit, running the checks, the security model in short, what is owner-specific |
| [RUNBOOK.md](../RUNBOOK.md) | What to do, in order: 1 what you need · 2 BIOS · 3 install Ubuntu · 4 Tailscale · 5 first provision over the LAN · 6 Cloudflare Tunnel (retired) · 7 the production Environment · 8 second provision · 9 first release · 10 DNS switch-over (done) · 11 day-2 operations (releases and rollback, rotating a secret, encrypted DNS, locked out, Wake-on-LAN, the down page, restoring from the backup disk) · 12 GPU, AI and media (disks, Tailscale grants, Home's AI models, the links page, Files, Home, Home's power control) · 13 retired CI runners · 14 Snowflake · 15 the hetzner host: setup, Cloudflare, R2, the move, clean-up, restoring the database |
| [SECURITY.md](../SECURITY.md) | Reporting a problem, scope, and the settings a public copy of this repository needs |
| [cloudflare/down-page/](../cloudflare/down-page/) | The "server is down" Worker: `src/decision.rs` (what it answers), `src/page.html`, `wrangler.toml` (routes); explained in [edge.md](edge.md#the-down-page) |
| [ci/](../ci/) | The test harnesses CI runs against fakes: release, rollback, backup, quiet hours, power requests, verify tasks, template and access rules |

Related repositories: [home](https://github.com/somethim-home/home) (Home, the app the `home`
stack runs), [home-crypto](https://github.com/somethim-home/home-crypto) (Home Files' encryption
format and [threat model](https://github.com/somethim-home/home-crypto/blob/master/docs/threat-model.md)),
[latchkey](https://github.com/somethim/latchkey) (Home's sign-in building blocks).

## Reading order

New to the repo: [architecture.md](architecture.md), then [deploying.md](deploying.md).

Reinstalling the server from a blank machine and deploying everything, Home included: [deploy-home.md](deploy-home.md).

Reusing it for your own server: [variables.md](variables.md).

About to change something stateful: [database.md](database.md) first.

Locked out, or something is down: [RUNBOOK.md](../RUNBOOK.md), then
[operations.md](operations.md).

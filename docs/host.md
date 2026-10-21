# The host

A dedicated PC at the owner's home running Ubuntu Server (`ubuntu_release` in
`production.yml`, 26.04 LTS `resolute`), wired to a consumer router on the home LAN, with a
dynamic public IP that nothing depends on. Nothing on it is reachable from the internet: the
public arrives through the Cloudflare Tunnel, which dials out ([edge.md](edge.md)), and SSH
only over the tailnet. Everything below is provisioning: `roles/common`, `roles/tailscale`,
`roles/docker`, `roles/gpu`, `roles/host` and `roles/quiet`, run from the owner's laptop with
`provision.yml`.

## SSH: Tailscale only

SSH is reachable only over the tailnet. The server joins it as `infra-host` with the tag
`tag:infra-server`; the Tailscale policy lets only tailnet admins and the CI tag
`tag:infra-ci` reach it, on tcp 22 only ([RUNBOOK.md](../RUNBOOK.md#4-tailscale)). OpenSSH with
keys stays the login: Tailscale SSH, Tailscale DNS and accepted routes are off
(`--ssh=false --accept-dns=false --accept-routes=false`), set on every run.

### Accounts

| Account | Login | Can do |
| --- | --- | --- |
| `admin` | the owner's keys, copied once from the installer's account on the first run | sudo, with a password (`--ask-become-pass`); the password also logs in at the local console |
| `deploy` | one root-owned line: `restrict,command="/usr/local/sbin/infra-deploy-gate" <CI key>` | `sudo -n infra-apply release` or `status`, nothing else |
| the installer's account (`setup`) | the owner's key, installed with `ssh-copy-id`; exists only between the first and the second run | sudo with its password; used by the bootstrap run only |
| `root` | never (`PermitRootLogin no`, and Ubuntu leaves root's password locked) | — |

#### The bootstrap

A fresh Ubuntu Server install has one account, the one the installer created, with sudo
through the `sudo` group and SSH with a password. The first run of `provision.yml` logs in as
that account over the LAN (`-u setup --ask-become-pass`, `ansible_host` = the LAN address);
`tasks/provision-checks.yml` calls it the **bootstrap run** (the login is not `admin`; `root`
and `deploy` are refused outright). It:

1. requires the account's `authorized_keys` to hold only plain public keys (no options, never
   the CI key), and copies them once to `admin`;
2. records the account's name in `/etc/infra/bootstrap-user`;
3. at the end, logs in as `admin` with those keys (`id -un` with `ansible_user: admin`) before
   it turns password login off, and stops if that fails.

The owner then sets `admin`'s password and runs provisioning as `admin` over the tailnet. That
run (and any later one) requires `admin` to have a password, removes the recorded installer
account with its home directory (`userdel --remove --force`, never `root`, `admin`, `deploy` or
the account the run itself uses), and forgets the record. From then on `admin` is the only
interactive account.

`admin` and `deploy` are created with a locked password; the owner sets `admin`'s, for sudo
and the local console only (sshd accepts keys alone). `deploy` belongs to no group but its own
(not `docker`). Provisioning reads `sudo -l` back for both and stops if `admin` has a
`NOPASSWD` rule or `deploy` has anything but its one rule — a cloud image's
`/etc/sudoers.d/90-cloud-init-users` or the `sudo` group would add more. It also stops if the
installer's account or `admin` trusts the CI key, or if `deploy`'s file is not exactly that
line, owned by root.

The CI key's public half is committed at `roles/common/files/deploy_key.pub`; provisioning
and the release render refuse to run while it is still the placeholder.

### sshd policy

`ssh_access.yml` runs last on every provision, whatever the tags, and writes
`/etc/ssh/sshd_config.d/10-hardening.conf`:

```
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
ExposeAuthInfo yes
```

**The number matters.** sshd keeps the **first** value it reads for a keyword, and the Ubuntu
installer's cloud-init writes `50-cloud-init.conf` with `PasswordAuthentication yes` when you
allow password login over SSH during the install; `10-` sorts before it. Provisioning also
deletes that file.

Safety properties of that step:

- Password login closes only after `admin` has logged in with the copied keys (on the
  bootstrap run); the installer's account goes only on a run that `admin` itself logs in to
  and has a sudo password for.
- `validate: sshd -t -f %s` on the file and `sshd -t` on the whole configuration — a
  malformed drop-in would make sshd refuse to start, and the reload would take the only way
  in with it.
- The handler **reloads** rather than restarts, so established sessions survive.
- `sshd -T` is read back afterwards; if another file overrides the policy, the run stops.

The server's own keyboard and monitor are the backstop either way: the local console goes
through neither sshd nor the tailnet, and takes `admin`'s password.
[RUNBOOK.md](../RUNBOOK.md#locked-out) has the procedure.

## Firewall

ufw denies inbound by default and allows only **22 and the tailnet-only ports (80, 443, 3900,
8090, 8091) on `tailscale0`** (`ufw_allowed`). The rules for the ports of the apps retired on
2026-10-20 (2283, 5000, 8080, 8096, 13378) are deleted on every run (`ufw_retired`). There is no public web port (80 and 443 are the tailnet-only redirect page and `home-tls`, which serves Home and every tailnet service's https name; Home itself publishes no port): the Cloudflare Tunnel is an outbound
connection. Outbound is unrestricted (image pulls,
Cloudflare, Resend, Tailscale, NTP, and for Home: TMDB's `api.themoviedb.org` and
`image.tmdb.org`, Wikidata, and `www.gutenberg.org` for Books, all https on 443, from
`home-server` on the `media` bridge; DNS-over-TLS on 853 from the host). The router forwards no port to the host, so even LAN 22
is unreachable from the internet.

LAN 22 is lockout-safe: a run that did not come in over the tailnet (the bootstrap, over the
LAN) adds `ufw allow 22/tcp` and says so at the end; a run that came in over the tailnet
deletes it. "Over the tailnet" means positive evidence only: the server address in the run's
own `SSH_CONNECTION` is a Tailscale address (`100.64.0.0/10` or `fd7a:115c:a1e0::/48`,
`tasks/ssh-route.yml`, the `ssh_outside_tailnet` fact). A run over the LAN address, any other
IPv4 or IPv6, or one whose `SSH_CONNECTION` cannot be read, keeps 22 open. No run can cut the
session it runs in, and LAN 22 closes only once the tailnet has been proven by a run over it.

ufw does not see Docker's published ports, which are NAT rules. `roles/host` installs
`/usr/local/sbin/infra-firewall` and `infra-firewall.service`, which run after every Docker
start: they build a chain `INFRA-PUBLIC` that lets new connections on the LAN-facing
interface (`PUBLIC_INTERFACE`, the default route's) reach only `public_ports` — **none** on
this host, `public_ports: []` — and drops the rest, and hook it first in Docker's
`DOCKER-USER` chain. So every new connection from the LAN (or the internet, were a port ever
forwarded) to any container is dropped, even if a container published a port by mistake.
A second hook sends every new connection that Docker destination-NATed to a published port
(conntrack state `DNAT`) and that did not come in on `tailscale0` (`TAILNET_INTERFACE`) through
the same chain, so the tailnet-only ports answer only on the tailnet, whatever other interface
(Wi-Fi, a second NIC, a LAN host routing to the Tailscale address) a packet arrives on.
Provisioning reads both chains back and stops if the hooks are not first and second or a port
is admitted. The interfaces and ports come from `/etc/infra/host.env`.

The tailnet-only ports are bound to the Tailscale IPv4 (`TAILSCALE_IP` in `host.env`, read with
`tailscale ip -4` on every run). At boot Docker may start its containers before `tailscaled`
has brought that address up, so `/etc/sysctl.d/62-infra-tailnet-bind.conf` sets
`net.ipv4.ip_nonlocal_bind = 1` and the bind succeeds anyway; provisioning reads the setting
back. It also lists every port any container publishes (`docker ps`) and stops on one that is
not an allowlisted container's own port on that address. The node's Tailscale address stays
the same for as long as the node exists; if the server ever re-joins the tailnet as a new
node, run provisioning (it rewrites `host.env`) and then `release` (it re-binds the ports).

The ufw tasks use the `command` module with `changed_when: false`: ufw rules are idempotent
already, and `command` keeps the repo free of collection dependencies.

## Service accounts and their volumes

The hardened stacks never run as root. `roles/host` creates a system account per stack with a
fixed uid and gid from `production.yml` (`ai`: `ai_uid`/`ai_gid`, `2001`; `media`:
`media_uid`/`media_gid`, `2000`; `home-server`: `home_uid`/`home_gid`, `65532`, the account
Home's image runs as, so not a choice), no login shell, no home and a locked password, and
writes them to `host.env` (`AI_USER=2001:2001`, `MEDIA_USER=2000:2000`,
`HOME_USER=65532:65532`); the compose guard refuses an `ai`, `media` or `home` service that runs
as anything else. `admin` is in the `media` group, so it can copy
files into the folders on the media disk. The `home-server` account is not; its container gets
the `media` group added by the release instead (`group_add`, which the guard allows to
`home-server` alone and only with `MEDIA_USER`'s gid), so Home can write into the film and
series library and nowhere else that group reaches.

Their data lives in volumes provisioning creates (`llama-models` (Home's AI
models, the `ai` account's, filled by the owner: [RUNBOOK.md](../RUNBOOK.md#homes-ai-models)), `home-tls-acme`,
`beszel-data`, `beszel-agent-data`, `garage-meta`, `sftpgo-data`, Home's `home-data` and
`home-keys`, and the volumes of the apps
retired on 2026-10-20, which no stack mounts but which are kept until the owner has audited
them: [stacks.md](stacks.md#retired-apps-2026-10-20)), external
to the stacks like `pgdata-v18`, so a release can never create an empty one in its place. Each
volume's root is handed to its account, mode 0700, on every run; the stacks mount them with
`nocopy`, because Docker otherwise copies the image's directory, root ownership included, onto
an empty volume the first time it is mounted.

## Disks

| Disk | Mounted at | `production.yml` | Holds |
| --- | --- | --- | --- |
| 225 GB SSD | `/` | — | Ubuntu, Docker's data root (images, every volume: PostgreSQL, app configs, Home's AI models), swap |
| 1 TB internal HDD | `/srv/media` | `media_disk_uuid` | Garage's objects (`s3`), Home Files' ciphertext (`home-files`, at most `home_files_capacity` of it), Home's film and series library (`movies`, `shows`), and the retired apps' library folders, kept: `audiobooks`, `podcasts`, `books`, `photos` |
| 1 TB external USB HDD | `/srv/backup` | `backup_disk_uuid` | the nightly backup ([operations.md](operations.md#backups)) |

`roles/host/tasks/disks.yml` mounts each HDD by its **filesystem UUID** (never `/dev/sdX`,
which can change between boots, least of all for USB), ext4, with
`nofail,x-systemd.device-timeout=10s,noatime,nodev,nosuid,noexec`: a missing disk costs the
boot at most ten seconds and never drops it into emergency mode, and nothing on either disk
can be executed or act as a device node. An empty UUID skips that disk with a message (the
media folders then live on the SSD; the backup writes nothing). A UUID that is set but not attached
stops provisioning for the media disk and only warns for the backup disk, which may well be
unplugged.

While a configured disk is **not** mounted its mountpoint is an empty directory with the
immutable attribute (`chattr +i`), so nothing can be written there: the media containers
that bind-mount a folder there, which then does not exist, fail to start rather than write to
the SSD, and the backup cannot fill the SSD. A drop-in orders Docker after
`srv-media.mount` at boot. Provisioning reads back which filesystem is mounted where, and
creates the library folders as `media:media`, mode `2775` (setgid, group-writable: what
`admin` copies in stays in the `media` group), `s3` and `photos` as the media account's alone
(`0700`), `home-files` as the `home-server` account's alone (`0700`), and the backup folders as `root`, `0700`. It
refuses to mount over a mountpoint that has files of its own (they would vanish under the
disk) and names the fix. Formatting and finding the UUIDs is in
[RUNBOOK.md](../RUNBOOK.md#disks).

## fail2ban

Bans an SSH source after repeated failures. Only the SSH jail is enabled — the web ports are
Traefik's, and banning at the firewall on HTTP patterns would sooner or later ban a reader.

- `bantime = 1d`, doubling (`bantime.factor = 2`) to a maximum of one week.
- `maxretry = 10` within `findtime = 10m`.

`ignoreip` covers loopback, the Docker bridge ranges and the tailnet (`100.64.0.0/10`): a
container talking to the host, or the owner on the tailnet, must not be able to lock the
operator out. With LAN 22 closed after the second provision, a ban can only happen during the
bootstrap; the console unbans (`fail2ban-client set sshd unbanip <ip>`).

## Patching

`unattended-upgrades` (installed and switched on by `/etc/apt/apt.conf.d/20auto-upgrades`)
installs security updates every day but by default never reboots, so a kernel update sits on
disk while the old kernel keeps running.
`/etc/apt/apt.conf.d/20auto-upgrades-reboot` sets a reboot at **`reboot_time`** (`04:00`,
`production.yml`), including when someone is logged in — an SSH session left open is
otherwise enough to defer a kernel patch indefinitely. The clock is kept on UTC, the clock that
time is read in (04:00 UTC is 05:00 or 06:00 in Central Europe). The reboot takes every site
down for about a minute; the containers and the tunnel come back by themselves
(`restart: always`).

## Time

`chrony` keeps the clock in sync (Ubuntu's default time daemon since 25.10; installing it
replaces `systemd-timesyncd`). TLS to Cloudflare, the tunnel's authentication and TOTP all
need a correct clock.

## Power

A home server must stay on. `roles/host/tasks/power.yml`:

- masks `sleep.target`, `suspend.target`, `hibernate.target`, `hybrid-sleep.target` and
  `suspend-then-hibernate.target`, so nothing (a desktop idle policy, a key, a stray
  `systemctl suspend`) can put it to sleep; provisioning reads them back as `masked`;
- writes `/etc/systemd/logind.conf.d/50-infra-server.conf`: the lid switch (on every power
  source), the suspend and hibernate keys, and idleness are ignored. logind reads it at boot;
  the masked targets already block sleep before then.

Coming back after a power cut is a firmware setting ("Restore on AC power loss: Power On",
on this Gigabyte board **AC BACK → Always On**), which provisioning cannot make
([RUNBOOK.md](../RUNBOOK.md#2-bios)). After a reboot, Docker, the stacks, Tailscale and the
tunnel all start by themselves.

### Wake-on-LAN

A server that was shut down on purpose (from Home, or `sudo poweroff`) can be switched on again
by a **magic packet**: a broadcast frame on the LAN carrying the NIC's MAC address sixteen
times. Three things must hold, and only the last is provisioning's:

1. **The firmware keeps the NIC powered while the host is off.** Gigabyte boards cut standby
   power with **ErP** enabled, so it must be **Disabled**, and **Wake on LAN** must be
   **Enabled** (both under Settings → Platform Power; [RUNBOOK.md](../RUNBOOK.md#2-bios)).
2. **Something on the LAN sends the packet.** The server's own Tailscale is off while it is,
   so the sender must be another always-on device on the same LAN (planned: a Raspberry Pi on
   the tailnet, plans/021); a router that can send Wake-on-LAN, or a laptop on the LAN, works too.
3. **The NIC listens for it.** `roles/host/tasks/wake.yml` sets magic-packet wake (`g`) on
   `lan_interface` (`production.yml`, `enp8s0`, the board's Realtek NIC; `ip -br link` shows
   its MAC): `ethtool -s enp8s0 wol g` for now, and, so it survives every boot,
   `/etc/netplan/60-infra-wake-on-lan.yaml` with `wakeonlan: true`. Ubuntu Server configures
   the LAN through netplan (the installer's `/etc/netplan/50-cloud-init.yaml`, networkd
   underneath), so the setting is a netplan override merged into the installer's definition
   of the interface (by its id, which provisioning reads with `netplan get ethernets`; it
   also finds a definition that renames the NIC with `set-name`). `netplan generate` turns it
   into the link file udev applies when the NIC appears at boot; nothing is re-applied to the
   running network, so the run cannot cut its own connection. A hand-written systemd `.link`
   file was not used: the first matching `.link` file wins outright, so one of ours would
   replace netplan's (and the default naming policy with it) instead of adding one setting.
   Provisioning stops when netplan does not configure the interface exactly once, reads back
   `netplan get ethernets.<id>.wakeonlan` as `true`, and verify reads `ethtool enp8s0`:
   `Supports Wake-on` and `Wake-on` must both contain `g`.

Wake-on-LAN is unauthenticated by design: anyone on the LAN who knows the MAC can switch the
server on, which is harmless (it can only start, never stop it). It never reaches past the
router: a magic packet is a LAN broadcast, and the router forwards nothing to the server.
How to test it is in [RUNBOOK.md](../RUNBOOK.md#wake-on-lan).

### Power requests from Home

Home (the owner's app, [stacks.md](stacks.md#home)) can switch the server off or restart it:
an admin asks, Home's own 10-second countdown runs (with Cancel), and only then does home-server hand the
host **one signed request**. There is no socket, no API and no command channel: home-server
writes a small file, and a host service decides whether to act on it. The host acts on exactly
two things, `systemctl poweroff` and `systemctl reboot`; nothing in a request is ever executed
or passed to a shell.

| Piece | What it is |
| --- | --- |
| `/run/home-power` | the request directory: its own tmpfs (`size=64k,nr_inodes=64`, `nosuid,nodev,noexec`, mode `0700`, owned by `home-server`, 65532), from `/etc/fstab` at every boot. Bound into home-server at `/run/power`, read-write; the compose guard allows that bind mount to `home-server` alone, at that path. A tmpfs of its own, so a misbehaving container can fill neither `/run` nor a disk, and a request never survives a reboot |
| `/etc/infra/home-power.key` | the key, base64 of 32 random bytes, `root`, `0600`. Provisioning makes it once (`openssl rand -base64 32`) when it is missing and never prints, copies or changes it; the owner copies it into the `HOME_POWER_KEY` secret ([RUNBOOK.md](../RUNBOOK.md#homes-power-control)), which the release writes into the `home-keys` volume as `/run/keys/power_key` for home-server |
| `home-power.path` | starts the service whenever the directory holds any entry (`DirectoryNotEmpty=`), and checks again each time the service exits, so a request that lands while a run is ending is not missed |
| `home-power.service` | a oneshot running `/usr/local/sbin/home-power` (Python, standard library only, `python3 -I`) as root with only `CAP_DAC_OVERRIDE` (to read and remove what 65532 wrote), no network, a read-only system (`ProtectSystem=strict`; writable: the directory and its state), its own `/tmp`; logs as `home-power` |
| `/var/lib/home-power/state.json` | the time of the last accepted action and the nonces of the last ten minutes, root's alone (`StateDirectory=`, `0700`), written and synced before the host acts |

**Why the host's key comes from provisioning, not the release.** The release path (the CI key,
the `deploy` account) can change what home-server runs with, but it never writes the key the
host trusts: that key is made on the host and stays root's. So a release cannot quietly change
who may power the server off, and the secret in GitHub is a copy of the host's, not the other
way round. `infra-apply` compares the two before anything changes and refuses a release whose
`HOME_POWER_KEY` is set but differs (or that arrives before provisioning made one), so a
mismatch shows up as a failed release instead of a power button that silently never works.
An empty `HOME_POWER_KEY` is allowed: home-keys removes `power_key`, `HOME_POWER_DIR` is empty,
and Home offers no power control.

#### The request format (for the Home app)

home-server writes the request as a temporary file whose name starts with a dot (for example
`/run/power/.request.tmp`), then renames it to **`/run/power/request.json`** (an atomic rename
in the same directory). The host never reads a half-written file: names starting with a dot are
left alone for 10 seconds (and removed after that), and `request.json` is the only name read.

```json
{"action": "reboot", "requested_at": 1792500000, "nonce": "3f9c0e8a1b2d4c6e8f0a1b2c3d4e5f60", "hmac": "<64 hex digits>"}
```

| Field | Value |
| --- | --- |
| `action` | `"poweroff"` or `"reboot"` |
| `requested_at` | when Home made the request, in whole Unix seconds (UTC), a JSON integer; at most 120 s old and not in the future when the host reads it (container and host share one clock) |
| `nonce` | 32 to 64 lowercase hex digits, random for every request (16 bytes from the OS's CSPRNG is right); never reused |
| `hmac` | 64 lowercase hex digits: HMAC-SHA256 of the message below, keyed with the **32 bytes base64-decoded** from `/run/keys/power_key` (whose content is the base64 text, no newline) |

The signed message is the ASCII text, with `\n` a line feed and no trailing one:

```
home-power/v1\n<action>\n<requested_at in decimal>\n<nonce>
```

The file must hold exactly those four fields (no others), be UTF-8 JSON of at most 4 KiB, and be
a regular file. Home learns the outcome only indirectly: `request.json` disappears within a
second or two either way (it is read and removed whatever it holds), and an accepted request
takes the server down `5` seconds later, so home-server can still answer the browser. The
outcome is in the host's journal, not in the directory.

Python, the way `ci/power-scripts.sh` signs its test requests:

```python
mac = hmac.new(base64.b64decode(key_text), f"home-power/v1\n{action}\n{requested_at}\n{nonce}".encode(), hashlib.sha256).hexdigest()
```

#### What the host checks, in order

`home-power` reads every entry once and removes it, whatever it is, and logs one line per entry
without its content (`journalctl -t home-power`):

1. Any name but `request.json` (a fresh dot file aside) is removed: `removed '<name>', which is not
   a request`. A directory is removed without following links out of it.
2. `request.json` must be a regular file (opened without following a link and without blocking
   on a pipe) of at most 4 KiB, JSON with exactly `action`, `requested_at`, `nonce` and `hmac`
   in the forms above.
3. The `hmac` must match (compared in constant time).
4. The `nonce` must not be one seen before: it is remembered for ten minutes from the later of
   now and its `requested_at`, whether or not the request is then carried out.
5. The `action` must be `poweroff` or `reboot`.
6. `requested_at` must be at most 120 s ago and not in the future.
7. No action may have been accepted in the last **10 minutes** (across reboots: the state is on
   disk), so a fault or a stolen key cannot reboot-loop the server.

Then: `accepted <action>, requested <n> s ago; <action> in 5 s`, the state is saved, and after 5
seconds `systemctl --no-block poweroff` or `reboot`. A refused request is logged as `refused
request.json: it <reason>; removed`. Without a readable key (missing, not `root` `0600`, not base64
of 32 bytes, a link) or with an unreadable state, every request is refused and removed, the run
fails (`FAILED: …`) and `systemctl --failed` lists `home-power.service`. A burst of changes in the
directory can trip the path unit's trigger limit; it then stops (fail-closed) until `sudo
systemctl reset-failed home-power.path && sudo systemctl start home-power.path`, and verify
reports it.

A poweroff or reboot from here is the same as the nightly patch reboot: systemd stops every
container (PostgreSQL shuts down cleanly), and after a reboot everything comes back by itself.
After a poweroff the server stays off until [Wake-on-LAN](#wake-on-lan) or its power button.

**Who can power the server off.** Only a process that can write into `/run/home-power` and knows
the key: home-server (and root). Another container cannot mount the directory (the compose
guard), and home-server's key file is in its read-only `home-keys` volume. A compromised
home-server could at worst power the server off or reboot it once per 10 minutes, which is what
the feature is for; it gains nothing else on the host.

Provisioning (`--tags host`, `roles/host/tasks/home_power.yml`; the compose guard's and
`infra-apply`'s side is `--tags common`) makes the key, writes the
`fstab` line and mounts the tmpfs, installs the script and the two units and enables the path
unit; verify reads back that `home-power.path` is enabled and active and that the directory is
that tmpfs. `ci/power-scripts.sh` tests the script against a valid poweroff and reboot, a request
renamed into place mid-run, a wrong `hmac`, stale and future requests, replays, the rate limit,
unknown actions and junk (links, pipes, directories, oversized and malformed files, other names).

## Quiet hours

The server stands in a room people sleep in. `roles/quiet` (tag `quiet`, on when
`quiet_hours_enabled`) makes it quieter at night: from `quiet_hours_start` to `quiet_hours_end`
(`23:00` to `08:00`, wall clock in `quiet_hours_timezone`, `Europe/Berlin`, so the edges follow
summer time; every other time on this host is UTC) the fans have less heat to move.

- **The GPU** gets the power limit `quiet_gpu_power_limit_w` (`130` W; the RTX 2060 12 GB's
  default is about 184 W) with `nvidia-smi -pl`. A value outside the card's own range
  (`nvidia-smi -q -d POWER`, min and max) is moved to the nearest end and the log line says so.
  A GPU without persistence mode gets it first (`nvidia-smi -pm 1`): without it the driver
  unloads when the GPU is idle and drops the limit. At the end the limit goes back to the
  card's `power.default_limit`; persistence mode stays on. Skipped where `nvidia-smi` does not
  exist. The cap is the whole card's, so everything on it is slower in those hours: llama-server
  (Home's AI) and home-server's NVENC transcodes. No
  container can raise it (none has the rights `nvidia-smi -pl` needs); Home asks for less on its
  own in the same hours (`HOME_AI_QUIET_HOURS`, `HOME_MEDIA_QUIET_HOURS`, both from
  `quiet_hours_*`: one answer at a time with a 4k context and no day-only model, one transcode
  instead of two; [stacks.md](stacks.md#the-gpu-shared)).
- **The CPU** gets a top frequency of `quiet_cpu_max_percent` (`70`) of each cpufreq policy's
  `cpuinfo_max_freq` (never below `cpuinfo_min_freq`), written to `scaling_max_freq`; at the end
  `cpuinfo_max_freq` again. Skipped where cpufreq does not exist.

`/usr/local/sbin/infra-quiet start|end|auto` (`roles/quiet/files/infra-quiet`) does both, reads
its settings from `/etc/infra/quiet.env`, refuses an invalid one without changing anything,
leaves whatever is already at its target alone, and logs one line (`journalctl -t infra-quiet`
or `-u 'infra-quiet-*'`). `infra-quiet-start.timer` and `infra-quiet-end.timer` run it at the
two edges; `infra-quiet-boot.service` runs `auto` at every boot, which picks whichever the
clock says (the timers are not `Persistent`), so a reboot inside quiet hours, the 04:00 one
included, comes back quiet. Provisioning runs `auto` too, and reads back that the three units are enabled and
each timer is scheduled at its time and zone. `quiet_hours_enabled: false` turns them off and
puts the defaults back.

Family streams are not throttled by any of this: nothing here touches the network or a
container. The backup runs inside quiet hours ([backup_time](operations.md#backups), 02:30 UTC)
and the USB disk it writes to is audible while it seeks; that is the owner's choice and
`backup_time` stays where it is. The 04:00 UTC reboot also falls inside them.

## Encrypted DNS

The home connection's ISP resolver blocks some sites by name, so the host does not use it.
`roles/host/tasks/dns.yml` (on when `production.yml`'s `dns_over_tls_enabled`) makes
`systemd-resolved`, Ubuntu's own resolver behind `/etc/resolv.conf` (`127.0.0.53`), ask only
`dns_over_tls_servers` (Cloudflare `1.1.1.1` and `1.0.0.1`, then Quad9 `9.9.9.9` and
`149.112.112.112`), over DNS-over-TLS only, for every name:

- `/etc/systemd/resolved.conf.d/60-infra-dns-over-tls.conf`: `DNS=` the four, each as
  `<address>#<name>` so resolved checks the server's certificate against `cloudflare-dns.com`
  or `dns.quad9.net`; `DNSOverTLS=yes` (strict: no fallback to plain DNS, so a resolver that
  cannot be reached over TLS fails rather than leaks); `Domains=~.` (these servers for every
  name); `FallbackDNS=` empty (never systemd's built-in list). Applied at once by restarting
  resolved, which cuts no connection.
- `/etc/systemd/network/10-netplan-<id>.network.d/60-infra-dns.conf`, a drop-in for the network
  file netplan writes for `lan_interface`: `DNS=` empty and `UseDNS=no` for DHCPv4, DHCPv6 and
  router advertisements, so the LAN interface brings no resolver of its own. Read at the next
  boot (like Wake-on-LAN, nothing is re-applied to the network the run came in over); until
  then provisioning says a reboot is due, and verify forgives the router's resolver on that
  interface (the flag `/run/infra-dns-reboot-pending`, gone at boot).

Right after the restart provisioning looks up `www.gutenberg.org` (three tries). If it fails,
port 853 is blocked on the way out or the servers are unreachable: it removes both drop-ins,
restarts resolved on the previous settings and stops with the reason, so a run never leaves a
host that resolves nothing. Verify (every `--tags host`) requires resolved active, `Global: yes`
from `resolvectl dnsovertls`, exactly the four servers as the global ones, no server on the LAN
interface (after the reboot) or on `tailscale0`, and a lookup that answers.

**Tailscale.** The server joins the tailnet with `--accept-dns=false` (roles/tailscale, on every
run): it never used MagicDNS, `tailscale0` carries no DNS server, and nothing here applies to it;
the owner's devices keep MagicDNS as before. Were Tailscale DNS ever accepted, resolved would
have to reach `100.100.100.100` over TLS, which it cannot; verify fails on that, and the next
provisioning sets `--accept-dns=false` again.

**Containers.** Docker's embedded DNS forwards to the servers in
`/run/systemd/resolve/resolv.conf`, which are now the four above, in plain DNS on port 53
(Docker cannot speak TLS to them, and resolved's stub listens on the host's loopback only). So
containers never ask the ISP's resolver either; their queries are unencrypted to Cloudflare and
Quad9, which is enough against a resolver that blocks names. The DNS-01 challenge of `home-tls`
asks `1.1.1.1` and `8.8.8.8` itself, as before.

**Rollback**: `dns_over_tls_enabled: false`, provision with `--tags host` (both drop-ins go,
resolved restarts), then reboot (the LAN interface takes the router's resolver again). By hand:
[RUNBOOK.md](../RUNBOOK.md#encrypted-dns).

## journald and swap

- The journal is capped (`/etc/systemd/journald.conf.d/50-infra.conf`: 500 MB on disk, 32 MB
  files, one month), so it cannot fill the disk PostgreSQL's data lives on.
- A swap file of `swap_size` (`2G`) is created only when the host has no swap, with
  `vm.swappiness = 10`; provisioning stops if the host has less than 1 GiB of swap. The Ubuntu
  installer usually creates `/swap.img` already, which counts. Swap is for a memory spike, not
  for steady use.

## The Docker daemon

Installed from **Docker's own apt repository** for `ubuntu_release`, its signing key pinned by
checksum, and the Engine held to **`docker_engine_major`** by an apt pin
(`/etc/apt/preferences.d/docker`, `5:<major>.*`). The pin is written by
`roles/docker/tasks/pin.yml`, which `roles/common` runs before its `apt upgrade` (the first
apt operation of a provision), so even the first run on a host that already has Docker from
Docker's repository upgrades only within the pinned major. Provisioning refuses to run when the
installed Engine has another major, so a major upgrade is a deliberate edit of
`production.yml`, never a side effect of `apt upgrade`. `ci/check_access.py` (rule 8) fails if
any apt task that upgrades or installs Docker runs before the pin.

`daemon.json` is rendered whole from `roles/docker/templates/daemon.json.j2`, with the `nvidia`
runtime when `gpu_enabled` ([The GPU](#the-gpu)), so no other tool (such as `nvidia-ctk runtime
configure`) edits it and no setting is lost on the next run:

- caps container logs at 30 MB each (3 × 10 MB). Without it the `json-file` driver keeps
  every line a container has ever written, and one crash-looping container fills the disk.
  The limit applies to containers created after the daemon picks it up.
- sets **`live-restore`**, so containers keep running while the daemon itself restarts (an
  Engine package update).

The handler **reloads** the daemon, never restarts it: `systemctl restart docker` would stop
every container; SIGHUP re-reads `daemon.json` in place.

## The GPU

An NVIDIA RTX 2060 with 12 GB. `roles/gpu` runs after `roles/docker` when `production.yml`
sets `gpu_enabled: true` (with `false` it only says so and touches nothing):

- **The driver** is Ubuntu's, the server branch `nvidia_driver_major` pins (`580`), installed
  with apt (`nvidia-driver-<major>-server` and `linux-modules-nvidia-<major>-server-generic`): the headless driver and
  Canonical's **signed, precompiled kernel modules**, so it loads with Secure Boot on and needs
  no DKMS build or MOK enrolment. The role first checks that `ubuntu-drivers list --gpgpu`
  offers that branch, and stops naming the ones it does offer otherwise. It also installs
  `nvidia-utils-<major>-server` (`nvidia-smi`) and the `libnvidia-encode`/`libnvidia-decode`
  libraries for NVENC/NVDEC video work. Package names carry the branch, so `apt upgrade` and
  unattended-upgrades only ever bring updates within it; a new branch is a deliberate edit of
  `production.yml`.
- **The NVIDIA Container Toolkit** comes from NVIDIA's apt repository
  (`nvidia.github.io/libnvidia-container`), its signing key pinned by sha256 in
  `roles/gpu/defaults/main.yml`, like Docker's and Tailscale's. Containers get the GPU through a
  Compose device reservation (`driver: nvidia`, `capabilities: [gpu]`), which uses the toolkit's
  hook; `daemon.json` also registers the `nvidia` runtime (not as the default), which `docker
  info` shows.
- **No reboot.** A driver installed or updated in a run is not loaded until the next boot (a
  fresh Ubuntu may even have `nouveau` loaded). Provisioning then prints "The NVIDIA driver was
  installed or updated since the last boot and is not loaded yet … Reboot when it suits you" instead of
  failing, and the next run (`--tags gpu`) requires `nvidia-smi` to answer. Unattended-upgrades
  can update the driver within the branch; until the 04:00 reboot it schedules, `nvidia-smi`
  reports "Driver/library version mismatch" and a GPU container that restarts in that window
  cannot start. Provisioning names both cases.

Read back on every run: `docker info` lists the `nvidia` runtime, and `nvidia-smi` names the
card. To change the key pin: download `https://nvidia.github.io/libnvidia-container/gpgkey`,
check its fingerprint (`gpg --show-keys`: `C95B 321B 61E8 8C18 09C4 F759 DDCA E044 F796 ECB0`,
NVIDIA's published one), and put its `sha256sum` in the defaults.

## Memory limits

Every application and agent container has a `mem_limit`. The stateful one — PostgreSQL —
deliberately does not.

That asymmetry is the point: bounding the others is what stops a runaway from making the
kernel's OOM killer pick PostgreSQL, which every stack depends on. The ceilings are 4–6×
observed usage, so they catch a runaway and nothing else.

Retune if a container is killed in normal work:

```bash
sudo docker inspect <name> --format '{{.State.OOMKilled}}'
```

## CI runners

**Removed, 2026-10-20.** The self-hosted Actions runners this host once ran for another project, and everything they used
(Incus instance, firewall, bridge, pool, dashboard row) are gone; see RUNBOOK section 13. Incus
itself stays installed.

## Snowflake

`roles/snowflake` (on when `snowflake_enabled`) runs Tor's standalone Snowflake proxy, which relays
censored users' WebRTC connections to Tor's Snowflake bridge. It is not a Tor relay or exit node:
traffic goes only to Tor's bridge, never to arbitrary sites on a user's behalf.

- **Host network, deliberately.** Behind a Docker bridge the extra NAT layer makes Snowflake
  measure its NAT as `strict` (tested: bridge `strict`, host network `restricted`), so Tor matches
  it with far fewer users. It is the one compose service allowed `network_mode: host`
  (ci/check_templates.py rule 9, `HOST_NETWORK_SERVICES`). It publishes no port: WebRTC is
  outbound with STUN, and ufw still refuses every new inbound connection.
- **Fenced by uid.** The proxy runs as uid 64999, used by nothing else on the host.
  `/etc/snowflake-guard.nft` (its own nftables table, loaded by `snowflake-guard.service` before
  Docker starts) rejects that uid's packets to loopback, 0/8, 10/8, 100.64/10 (the tailnet),
  169.254/16, 172.16/12, 192.168/16, multicast and reserved space, and on IPv6 to loopback,
  unique-local (Tailscale's range too), link-local and multicast. Only the systemd-resolved stub
  (127.0.0.53/54, port 53) and the public internet stay reachable. So it cannot reach this
  host's services, the LAN, the tailnet or any container.
- **Hardened container**: no capabilities, no-new-privileges, read-only root, a 16 MB `/tmp`,
  256 processes, 384 MB of memory, log rotation, pinned image (docs/agents.md), no Watchtower label.
- **Bounded**: `-capacity 10` caps concurrent users; Tor's broker also paces assignments.
  Typical use is a few hundred kB/s to a few MB/s when busy. Future work if it ever matters:
  shape its traffic on the host (tc with a cgroup or uid match).
- **Exempt from the planned no-egress rule** (plans/007): relaying to the internet is its job.
- **Verify** (`--tags snowflake`): running as 64999:64999 on the host network, the fence loaded,
  uid 64999 refused at loopback sshd, the LAN address, the tailnet address and Traefik's edge
  address (curl exit 7) while Tor's broker answers, and the proxy's log showing its NAT type.

# Operations

The procedures — first setup of the home server and of the hetzner host, releases, rollback,
rotating a secret, a lockout, re-pinning an image — are in [RUNBOOK.md](../RUNBOOK.md). This page keeps the short recipes
that are not part of a procedure. Every command runs as `admin` over the tailnet, on the host it
names (`ssh admin@infra-host` for Home, `ssh admin@infra-hetzner` for the portfolio and its
database).

| Situation | Where |
| --- | --- |
| A release failed, or an app must go back a version | [RUNBOOK.md, Releases, status, rollback, resume](../RUNBOOK.md#releases-status-rollback-resume) |
| A secret must change (the origin certificate and R2 keys too) | [RUNBOOK.md, Rotating a secret](../RUNBOOK.md#rotating-a-secret) |
| SSH does not let you in | [RUNBOOK.md, Locked out](../RUNBOOK.md#locked-out) |
| The site is down but the hetzner host is up | [RUNBOOK.md, The site is down but the hetzner host is up](../RUNBOOK.md#the-site-is-down-but-the-hetzner-host-is-up) |
| The portfolio's database must come back | [RUNBOOK.md, Restoring the portfolio database](../RUNBOOK.md#restoring-the-portfolio-database) |
| The "server is down" page must be deployed or changed | [RUNBOOK.md, The down page](../RUNBOOK.md#the-down-page) |
| Home's power button does nothing | [RUNBOOK.md, Home's power control](../RUNBOOK.md#homes-power-control) |
| A third-party image must move | [RUNBOOK.md, Re-pinning third-party images](../RUNBOOK.md#re-pinning-third-party-images) |
| Something must come back from the backup disk | [RUNBOOK.md, Restoring from the backup disk](../RUNBOOK.md#restoring-from-the-backup-disk) |
| GPU, AI, media, disks | [RUNBOOK.md, GPU, AI and media](../RUNBOOK.md#12-gpu-ai-and-media) |

## Getting into PostgreSQL

On the hetzner host. The image trusts connections over the local Unix socket, so a lost superuser password is not
a lockout:

```bash
sudo docker exec -it postgresql psql -U postgres
```

The next `release` re-sets every role's password from the `production` Environment.

## Reclaiming disk

```bash
sudo systemctl start docker-prune.service   # the Sunday timer, now: unused images older than a week
sudo docker system df
```

Old releases need no cleanup: `infra-apply` keeps only `current` and `previous`. See
[agents.md](agents.md#the-prune-timer).

## Backups

**The hetzner host**: `infra-pg-backup.timer` dumps the portfolio's database to R2 every day
([database.md](database.md#backups)):

```bash
ssh admin@infra-hetzner systemctl list-timers infra-pg-backup.timer
ssh admin@infra-hetzner journalctl -u infra-pg-backup --since -2d     # "dumped to portfolio-backups/…" each day
```

**The home server**: `infra-backup.timer` runs `/usr/local/sbin/infra-backup` (`roles/host/files/infra-backup`)
every night at `backup_time` (02:30 UTC, plus up to 15 minutes of jitter), at least an hour
before the 04:00 reboot window and clear of the Sunday 03:00 image prune; a night missed while
the server was off runs at the next boot. The run falls inside quiet hours, and the backup disk
is audible; the owner keeps it there ([host.md](host.md#quiet-hours)). It writes only to the external USB disk at
`/srv/backup`, one dated snapshot per night:

| Path | What |
| --- | --- |
| `snapshots/<date>/postgres.sql.gz` | `pg_dumpall` of the old shared PostgreSQL, mode 0600, only while a `postgresql` container still runs on the home server (until RUNBOOK section 15's clean-up) |
| `snapshots/<date>/volumes/<volume>/` | `portfolio-media` while it exists (until RUNBOOK section 15's clean-up), `beszel-data` (the dashboard's history and alerts), `garage-meta` (Garage's configuration and metadata), `sftpgo-data` (the file manager's database: share links, sessions), `home-data` (Home's SQLite databases: `home.db` with accounts, sessions, factors and the audit log, `media.db` with Media's catalogue, progress and lists, `ai.db` with the chats, sealed; and Books' library in `books/`: `books.db`, the EPUBs, covers; without `media-cache/`, Media's pictures, trickplay and HLS cache, and Books' `catalog-covers/` and `.tmp/`, which come back by themselves), and the kept volumes of the apps retired on 2026-10-20 ([stacks.md](stacks.md#retired-apps-2026-10-20)): `jellyfin-config` (without logs, cache and transcodes), `audiobookshelf-config`, `audiobookshelf-metadata` (without its cache, logs, streams), `kavita-config` (without cache, temp, logs), and `open-webui-data` (without its model cache), as plain trees |
| `snapshots/<date>/media/s3/` | Garage's objects (`/srv/media/s3`), copied in the same stop of Garage as `garage-meta`, so the two match |
| `snapshots/<date>/media/home-files/` | Home Files' ciphertext (`/srv/media/home-files`), copied in the same stop of `home-server` as `home-data`, so the two match. `home-keys` (Home's keys) is never copied: the keys stay out of the backups, in the GitHub secrets and 1Password |
| `snapshots/<date>/media/{movies,shows}/` | Home's film and series library, **metadata only**: every folder, with the `.nfo` files, pictures (`jpg`, `jpeg`, `png`, `webp`, `tbn`) and subtitle files (`srt`, `ass`, `ssa`, `vtt`) Home and the owner keep next to the videos, never the videos themselves (they would not fit) nor Home's uploads in progress (`.home-uploads/`). The edits people made in Home (titles, matches, pictures) survive a lost disk; the films have to be copied in again |
| `snapshots/<date>/media/{audiobooks,books,podcasts}/` | those library folders of the retired apps, kept |
| `snapshots/latest` | a symlink to the newest complete snapshot |

**Snapshots, not a mirror.** Every tree is copied with `rsync --link-dest` against the
previous complete snapshot: a file that did not change is a hard link to the earlier copy and
takes no space, so a night costs only what changed (plus the two database dumps). A file
deleted on the server stays in every older snapshot.

**Retention: about two months.** After a complete snapshot the script keeps the newest 14 and
the first snapshot of each of the 8 newest ISO weeks (Monday to Sunday), and removes the rest.
Removing a snapshot frees only the files no other snapshot links to.

**Room on the disk.** Before writing, if less than 10% of the disk is free
(`INFRA_BACKUP_MIN_FREE_PERCENT`), the oldest snapshots are removed first, but never the newest
two; if that is still not enough the run fails without writing anything (and without stopping
any app).

**Only complete snapshots count.** A night is built in `snapshots/.<date>.partial` and becomes
`snapshots/<date>` (with a `.complete` marker, then the `latest` symlink) only when every step
succeeded. A failed night's partial is kept for inspection until the next run deletes it; it is
never linked against.

**From the old layout.** The first snapshot links to the old `media/` mirror instead of copying
it again; the old `media/` and `apps/` go once a complete snapshot exists, the old `postgres/`
and `immich/` dumps once 14 snapshots exist.

Not copied: the AI models (Home's `llama-models`; they download again,
[RUNBOOK.md](../RUNBOOK.md#homes-ai-models)), `home-keys` (Home's keys), the videos in `movies`
and `shows` (they would not fit; their metadata is copied), and of the retired apps' kept data
`comfyui-data` and `jellyfin-cache` (downloads and caches), and nothing of Immich (no photo
or device backup of any kind: the files bucket and Home Files hold only what is put there on purpose).

- **No disk, no writes.** If `/srv/backup` is not a mountpoint (the disk is unplugged, or
  `backup_disk_uuid` is empty) the script logs a warning and exits 0 without writing
  anything; the mountpoint itself is immutable while empty, so nothing can land on the SSD.
- **Consistent copies, one service at a time.** Beszel, Garage, SFTPGo and Home keep SQLite
  databases in their volumes, so the script stops each of them that runs (`docker stop`, up to
  60 s) only while its own data is copied, and starts it again right after, also when the copy
  fails: Beszel for `beszel-data`, Garage for `garage-meta` and its objects in `/srv/media/s3`
  (which must match), SFTPGo for `sftpgo-data`, `home-server` for `home-data` and `/srv/media/home-files`. Only one
  is down at a time, for its own copy: seconds for Beszel and SFTPGo, longer for Garage or Home
  on a night with many new objects (Files cannot reach its storage meanwhile, nor can anyone
  sign in to Home). The images have no shell, so stopping is the consistent copy (Home's
  `sqlite3 .backup` is not available). `home-server` carries a Watchtower label, and Watchtower
  revives stopped labelled containers when it updates them, so an update published during its
  copy could start it again mid-copy. A container that was not running is neither stopped nor
  started. If the script dies mid-run (killed, or its 6-hour limit), its exit trap starts
  whatever it had stopped. The retired apps' volumes have no container any more and are copied
  as they are.
- **No empty library over a full backup.** A library folder that is missing, or empty while
  the last snapshot of it is not (a disk that did not mount), fails the night instead of being
  backed up empty.
- **Every step runs**, and the run fails if any did: that night makes no snapshot, the earlier
  ones stay, and `infra-backup-failed.service` logs "the nightly backup FAILED" at error
  priority. Read it with:

  ```bash
  ssh admin@infra-host journalctl -u infra-backup.service --since yesterday
  ssh admin@infra-host journalctl -p err -t infra-backup
  ssh admin@infra-host sudo systemctl start infra-backup.service     # a run now
  ```

Restoring is in [RUNBOOK.md](../RUNBOOK.md#restoring-from-the-backup-disk).

The backup disk sits next to the server: it covers a dead SSD or HDD and a bad upgrade, not a
fire or a burglary. For that, copy the newest snapshot's dumps and app volumes off-site now
and then (they are small), for example to the laptop over the tailnet:

```bash
ssh admin@infra-host sudo tar -C /srv/backup/snapshots/latest/ -czf - volumes > infra-backup-$(date +%F).tgz
```

## A major PostgreSQL upgrade

On the hetzner host. Never by editing the image tag — the on-disk formats are incompatible and
the server will refuse to start.

1. Stop the writer: `sudo docker stop portfolio` (not the database).
   Watchtower revives stopped labelled containers, so stop it first:
   `sudo docker stop watchtower`.
2. `pg_dumpall` from the running container.
3. Create a fresh volume named for the new major, start the new image against it, and restore.
4. Change the image pin and the volume name in `stack/database/docker-compose.yml`,
   `roles/host/tasks/main.yml`, `roles/common/files/infra-compose-guard` and the fixtures in
   `ci/release-scripts.sh` ([database.md](database.md#upgrades)); merge to `master`.
5. Provision (it creates the new volume if missing and starts Watchtower again), then run
   `release`, verify, and only then delete the old volume.

## Watchtower is not updating anything

```bash
sudo docker ps -a --filter name=watchtower
sudo docker logs watchtower --tail 50
```

An expired GHCR token, or a missing `/root/.docker/config.json`, leaves it unable to check
digests: store a new `GHCR_TOKEN` and run `release`, which logs in again. A missing or
stopped `watchtower` container comes back with `provision.yml --tags watchtower`. An "API
version too old" error means the pinned image must move
([RUNBOOK.md](../RUNBOOK.md#re-pinning-third-party-images)).

Remember that Watchtower only updates containers that already exist, and never one pinned by
a rollback. A missing app container comes back from a `release`.

## The public site

On the hetzner host:

```bash
sudo docker ps --format '{{.Names}} {{.Status}}'          # edge-traefik, portfolio, postgresql
sudo docker logs --tail 50 edge-traefik
sudo ls -l /opt/edge/dynamic/tls.yml                     # written by every release, 0600
```

A `521`/`522` from Cloudflare means it cannot reach the server (the Hetzner Cloud Firewall, the
records' addresses, or Traefik down); `525` a failed handshake (Authenticated Origin Pulls off,
or `tls.yml` missing: run `release`); `526` a certificate Full (strict) does not accept
([edge.md](edge.md#verifying-it)).

## A site is up but hung

Autoheal restarts containers that report `unhealthy`, but only those labelled `autoheal=true`
that define a healthcheck: the portfolio does both. Anything else that hangs needs a
`sudo docker restart <container>`.

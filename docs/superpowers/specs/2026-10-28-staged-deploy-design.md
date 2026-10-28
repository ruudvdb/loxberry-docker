# Staged deploy: build an installed image before switching

Date: 2026-10-28

## Goal

A redeploy in Komodo must not take LoxBerry offline for the 10-15 minute
install, and must leave the running container untouched when the new
version doesn't work.

Success criteria:

- During a redeploy the old container keeps running until the new image
  is installed and checked.
- The switch itself takes about a minute.
- A failed build or failed check aborts the deploy; nothing changes.
- Rolling back to the previous image takes about a minute.

## Current situation

The image only contains a fake DietPi environment and the LoxBerry
installer. `loxberry-autoinstall.sh` installs LoxBerry at first boot of
every new container, because the installer needs a running systemd. It
backs up `/opt/loxberry` (bind mount of `/home/docker/loxberry-data`),
runs the installer (which wipes `/opt/loxberry`), restores the user data,
restores plugin system setup (apt packages, `postroot`, sudoers, Apache,
Weather4Lox emulator) and starts `loxberry.service`. Komodo deploys the
stack from git and builds the image with `docker compose build`.

## Approach

Komodo runs a Stack's `pre_deploy` command before `docker compose up`.
If it exits non-zero, Komodo stops the deploy (`ComposeUp` in
`bin/periphery/src/api/compose.rs` returns before compose up) and the
running container stays up. There is no timeout on it.

A new script, `build-installed-image.sh`, runs as `pre_deploy`. It
installs LoxBerry in a temporary container next to the running one,
checks it, and saves it with `docker commit` as an image. Compose then
starts the real container from that image. That container already has
the install flag, so it boots straight onto the real data.

Rejected:

- Komodo Build + Procedure: a Komodo Build runs a plain `docker build`,
  which can't run privileged systemd, which the installer needs.
- Real blue/green with a reverse proxy or macvlan: much more moving
  parts to save about a minute.

## Components

### `build-installed-image.sh` (new)

Runs in the Komodo periphery container (has `docker` and `bash`, not
`/home/docker`) or on the host. Working directory: the repo checkout.

1. Load `./.env` if present (Komodo writes the Stack environment there
   before `pre_deploy`).
2. If `LOXBERRY_IMAGE_TAG` is set and not `installed`, check that image
   exists and exit 0 without building (rollback deploy).
3. Check free disk space in Docker's data root; fail below 15 GB.
4. Remove a leftover `loxberry-staging` container and staging data.
5. `docker build -t loxberry-docker:base .`
6. Using a helper container from `loxberry-docker:base` with
   `/home/docker` mounted:
   - copy `/home/docker/loxberry-data` to
     `/home/docker/loxberry-staging/data`;
   - create `/home/docker/loxberry-staging/backup`, copy
     `loxberry-user.shadow` from `/home/docker/loxberry-backup` into it,
     and create the marker file `staging` there.
7. Start `loxberry-staging` from `loxberry-docker:base` with the same
   runtime settings as `docker-compose.yml` (privileged, cgroup host,
   tmpfs, cgroup mount), `/opt/loxberry` and `/var/backups/loxberry`
   bound to the staging directories, no published ports, no `-e`
   variables (they would end up in the committed image).
8. Wait for the result file `/var/lib/loxberry-docker/autoinstall-result`
   in the staging container, at most `STAGING_TIMEOUT` seconds (default
   2700).
9. Run the checks (below).
10. Clean apt caches, apt lists and `/root/.cpanm` in the staging
    container, stop it, and
    `docker commit loxberry-staging loxberry-docker:<YYYYMMDD-HHMM>`.
    Tag it `loxberry-docker:installed`.
11. Remove the staging container and staging data; keep the two newest
    date tags, remove older ones.

On any failure: print the last 50 lines of `docker logs
loxberry-staging` (shown in the Komodo deploy log), remove the staging
data, leave the stopped staging container for inspection, exit 1.

### `loxberry-autoinstall.sh` (changed)

- Staging mode: active when `$BACKUP_DIR/staging` exists.
  - Don't start `loxberry.service` (no plugin daemons).
  - In `restore_user_data`, stop `cron.service` instead of restarting
    it (no plugin cron jobs). Apache and Mosquitto are restarted as now.
  - Leave the host-IP handling as is: without `LOXBERRY_HOST_IP` it
    does nothing; the real boot sets the DNS record later.
- Always write the exit code to
  `/var/lib/loxberry-docker/autoinstall-result` at the end, and log
  failures in the plugin step with the word `FAILED` (already the case).
  Remove a stale result file at start.

### `docker-compose.yml` (changed)

- Remove `build:`; use
  `image: loxberry-docker:${LOXBERRY_IMAGE_TAG:-installed}` with
  `pull_policy: never`.
- Everything else stays.

The fallback path stays: a container from `loxberry-docker:base` (no
install flag) still installs itself at boot as today.

## Checks before committing

All must pass:

1. `autoinstall-result` contains `0` (install and restore succeeded).
2. The staging container's journal for `loxberry-autoinstall.service`
   has no `>>>` line (the script's own messages) containing `FAILED`.
   Installer output isn't matched: it can print `[FAILED]` for checks
   it then recovers from.
3. `apache2` and `mosquitto` are active.
4. `curl http://localhost/` in the staging container returns 200.
5. If Weather4Lox has `EMU=1`: `dnsmasq` is active and
   `curl http://localhost:6066/forecast/` returns 200.

Not checked: "no failed units". `bluetooth` and `dphys-swapfile` always
fail in Docker.

## Rollback

Set `LOXBERRY_IMAGE_TAG=<date tag>` in the Komodo Stack environment and
redeploy: the script skips the build and compose starts that image.
Remove the variable to go back to `installed`.

## Komodo configuration (manual, one time)

- Pre Deploy: command `bash build-installed-image.sh`, path `.`
- Run Build: off
- Auto Pull: off
- Environment: `LOXBERRY_HOST_IP=10.0.206.25`

## Disk space

The current container layer is 4.5 GB, so each committed image is about
that size. Two kept versions plus a build in progress: about 10-14 GB
plus 4-5 GB temporarily. The host has 52 GB free (98% used), hence the
15 GB check.

## First deploy after this change

Komodo pulls the repo, `pre_deploy` builds the first installed image
(about 15 minutes, old container running), then compose replaces the
current `loxberry-experimental:4.0` container with
`loxberry-docker:installed`.

## Testing

1. Run `build-installed-image.sh` by hand on this host while the current
   container keeps running: full build with the real plugins. Inspect
   the image and confirm the checks ran.
2. Failure path: run with `STAGING_TIMEOUT=60`; the script must exit 1,
   keep the stopped staging container and remove the staging data.
3. Switch and rollback in Komodo, by the user, with the steps and
   expected log lines provided.

## Out of scope

- Caching (skipping the build when nothing changed): every deploy
  rebuilds, 15 minutes without downtime.
- Isolating the staging container's network. `postroot` scripts run
  there, as in a normal plugin install.

# LoxBerry 4.0 on Docker (experimental, unofficial)

An experimental Docker setup that runs the official, **unmodified**
LoxBerry 4.0 installer (`install_trixie_v4.sh`) inside a container, by
faking just enough of a DietPi environment for it to pass its checks.

## What this is (and isn't)

There is no official Docker support for LoxBerry. The v4 installer is
written to only run on a real DietPi installation, and LoxBerry itself
starts a whole stack of systemd services (Apache, Mosquitto, Samba,
vsftpd, cron, autofs, watchdog, USB automount, ssdpd, ...). This project:

- Fakes the files the installer checks for DietPi
  (`/boot/dietpi/.version`, `/boot/dietpi/.hw_model`).
- Stubs out the DietPi-specific tools the installer calls
  (`dietpi-software`, `dietpi-set_hardware`, `dietpi-set_software`) with
  harmless no-ops, so the real, unaltered LoxBerry installer can run.
- Runs systemd as PID 1 inside the container, because LoxBerry relies on
  real systemd units, not a single foreground process.

This is **not officially supported by the LoxBerry or DietPi projects**.
Use it for testing/development, not as your production Smart Home
controller.

## What will NOT work

- **I2C, GPIO, serial ports** — no real hardware inside a container, so
  any plugin depending on them will fail.
- **USB automount / the watchdog device** — need host hardware access a
  container normally doesn't have.
- **Reboot/shutdown from the LoxBerry web UI** — doesn't make sense
  inside a container; use `docker restart` / `docker stop` + `docker
  start` instead.
- Plugins that try to run Docker themselves (Docker-in-Docker) or
  reconfigure host network interfaces.

## Surviving redeploys (Portainer, GitOps, etc.)

If this stack is deployed via Portainer (or any other setup that
recreates the container from the image, e.g. after a git push), be
aware of what does and doesn't survive:

- **Survives**: everything under `/opt/loxberry` (config, plugins,
  logs) - it's bind-mounted from a fixed host path (see "Where your
  data lives" below).
- **Does NOT survive**: the apt-installed system packages (`apache2`,
  `samba`, `mosquitto`, `vsftpd`, ...). Those live in the container's
  own writable layer, which is discarded whenever the container is
  recreated.

To bridge that gap, this image bakes in `loxberry-autoinstall.service`
— a systemd unit, enabled by default, that runs on every boot and:

1. Checks whether the system packages are actually present.
2. If not (fresh container, or a redeploy that recreated it), removes
   the stale install marker in `/opt/loxberry` (which would otherwise
   make the installer refuse to run) and re-runs
   `install_trixie_v4.sh` automatically.
3. If the packages are already there, does nothing and boots normally.

In practice this means: a "pull and redeploy" in Portainer is safe and
won't lose your LoxBerry configuration, but it does trigger another
10-15 minute reinstall of the system packages before the web
interface is reachable again. Watch it happen with:

```bash
docker logs -f loxberry
```

If you want a redeploy to be instant instead, the real fix is baking
the system packages into the image itself at build time rather than
relying on `install_trixie_v4.sh` to apt-install them at runtime -
that's a heavier change (effectively vendoring the installer's package
list into the Dockerfile) and isn't done here yet.

## Where your data lives

`/opt/loxberry` (LoxBerry's config, plugins, logs, everything the
installer sets up) is bind-mounted directly from a fixed path on the
host, set in `docker-compose.yml`:

```yaml
volumes:
  - /home/docker/loxberry-data:/opt/loxberry
```

This is a hardcoded path rather than an `.env`-driven variable, because
this stack is deployed via Portainer's Git integration, which doesn't
reliably pick up a `.env` file from the repo. If you need to change the
location, edit that line directly.

Because it's a plain host directory rather than a Docker-managed
volume, you can:

- Back it up directly: `tar -czf loxberry-backup.tar.gz /home/docker/loxberry-data`
- Inspect or edit files from the host without `docker exec`
- Recreate, rebuild, or `docker rm` the container entirely without
  losing anything — only deleting this folder yourself removes the data

Note that the **container's own filesystem** (the systemd, Apache,
Samba, vsftpd, ... packages installed by `install_trixie_v4.sh`) is
*not* covered by this bind mount — that lives in the container layer
itself. See "Surviving redeploys" below for how that gap is handled.

## Requirements

- Docker Engine with Compose v2 (`docker compose ...`)
- The container runs `privileged: true` and mounts the host's cgroup
  filesystem — this is a hard requirement of running systemd inside
  Docker, not something that can be safely removed.

## Ports

Every port LoxBerry uses is published through an environment variable, so
you can freely remap anything that clashes with other containers you're
already running. Copy `.env.example` to `.env` and edit the **host**
side (the left-hand number) — the container-side port stays fixed
because it's what LoxBerry expects internally.

| Service              | Container port | `.env` variable            | Default host port |
|-----------------------|:--------------:|-----------------------------|:------------------:|
| Web UI (HTTP)         | 80              | `LOXBERRY_HTTP_PORT`        | 8880 |
| Web UI (HTTPS)        | 443             | `LOXBERRY_HTTPS_PORT`       | 8843 |
| SSH                   | 22              | `LOXBERRY_SSH_PORT`         | 2222 |
| FTP (vsftpd)          | 21              | `LOXBERRY_FTP_PORT`         | 2121 |
| MQTT (Mosquitto)      | 1883            | `LOXBERRY_MQTT_PORT`        | 18830 |
| Samba UDP (NetBIOS)   | 137, 138        | `LOXBERRY_SAMBA_UDP_137/138`| 1137, 1138 (disabled by default) |
| Samba TCP (SMB)       | 139, 445        | `LOXBERRY_SAMBA_TCP_139/445`| 1139, 1445 (disabled by default) |

Samba's host ports are commented out in `docker-compose.yml` by default —
uncomment them there (and set them in `.env`) only if you actually need
file sharing reachable from outside the host.

```bash
cp .env.example .env
# edit .env, e.g. if 8880 is already taken:
#   LOXBERRY_HTTP_PORT=9080
```

## Build and start

```bash
cp .env.example .env      # first time only, for the port settings - edit as needed
mkdir -p /home/docker/loxberry-data
docker compose build
docker compose up -d
```

Creating the folder yourself first avoids Docker auto-creating it as
`root:root`; the container runs privileged, so this is rarely an issue
in practice, but it's a cheap step to skip a class of permission
problems entirely.

## Install LoxBerry

On first boot, `loxberry-autoinstall.service` runs the installer for
you automatically (see "Surviving redeploys" above) — no manual step
needed. Follow progress with:

```bash
docker logs -f loxberry
```

Expect roughly 10-15 minutes, the same as on a real DietPi device.
Afterwards, the web interface is reachable at
`http://localhost:<LOXBERRY_HTTP_PORT>/` (8880 by default).

If you ever need to trigger the installer manually (e.g. while
debugging), the same script it calls can still be run directly — it
must run **after** systemd is already active, so it can't be part of
`docker build`:

```bash
docker exec -it loxberry /root/install_trixie_v4.sh
```

## Known gotcha: Portainer "pull access denied" on redeploy

Portainer runs `docker compose pull` before redeploying a stack. Since
this service only ever exists as a locally built image
(`loxberry-experimental:4.0` isn't a real registry image),  that pull
fails with something like:

```
pull access denied for loxberry-experimental, repository does not
exist or may require 'docker login': denied: requested access to the
resource is denied
```

`docker-compose.yml` already sets `pull_policy: build` to tell Compose
to always build this service locally instead of pulling it. This needs
Compose Spec support for `pull_policy` (Docker Compose v2.22+ / a
reasonably recent Portainer). If your Portainer's bundled Compose is
older and rejects the `pull_policy` key entirely (an error like
`Additional property pull_policy is not allowed`), remove the `image:`
line instead - Compose then falls back to auto-naming the built image
and skips pulling it by design.

## Known gotcha: install hangs forever on "watchdog.service"

There's no real `/dev/watchdog` hardware timer inside a container.
Starting `watchdog.service` doesn't fail fast in that situation - it
hangs indefinitely, which in turn blocks `dpkg --configure --pending`
and stalls the entire installer partway through (Apache, Samba, etc.
never get configured, so the web UI never comes up).

The Dockerfile masks `watchdog.service` from the start (before the
`watchdog` package is even installed), so a clean build shouldn't hit
this. If you're stuck on an older image or already mid-install when
this happens, unstick it with:

```bash
docker exec -it loxberry systemctl mask watchdog.service
docker exec -it loxberry ps aux | grep -E "watchdog|ask-password"
# if it's still stuck after ~a minute, kill the PIDs the above shows:
docker exec -it loxberry kill -9 <pid> <pid>
```

Then follow progress again with `docker logs -f loxberry` /
`docker exec -it loxberry journalctl -u loxberry-autoinstall.service -f`
- the installer should now run to completion.

## Known gotcha: services stuck "enabled" but "inactive (dead)"

Debian's base images ship a `policy-rc.d` that blocks service starts
during package installation, to keep build layers side-effect free. This
image overrides that from the start, but if you're rebuilding from an
older version of this Dockerfile (or hit this after manually installing
extra packages), a service can end up `enabled` yet never actually
started, causing the installer's own health checks to report `[FAILED]`
for that service. Fix:

```bash
docker exec -it loxberry bash -c "
printf '#!/bin/sh\nexit 0\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d
systemctl start <service-name>   # e.g. smbd, nmbd, vsftpd, apache2, mosquitto
"
docker exec -it loxberry /root/install_trixie_v4.sh
```

If several services are affected, it's usually faster to just rebuild
clean:

```bash
docker compose down -v
docker compose build --no-cache
docker compose up -d
docker exec -it loxberry /root/install_trixie_v4.sh
```

## LoxBerry healthcheck.pl patch (Docker false positives)

Fixes three false positives in `/opt/loxberry/sbin/healthcheck.pl`.
**This is applied automatically** by `loxberry-autoinstall.sh` — every
time the installer runs, and again on every boot in case a LoxBerry
core update (from the web UI) overwrote `healthcheck.pl` with the
original, unpatched version. No manual step needed; the rest of this
section is only for understanding what it does or running it by hand.

1. **RootFS ReadWrite check** only recognized `ext4` as a valid
   read-write filesystem. Docker's root is OverlayFS, so it always
   reported "not mounted ReadWrite" even when the filesystem is
   genuinely writable. Now matches any filesystem type.
2. **RootFS free space check** (`check_rootfssize`) only looked at the
   free-space *percentage*. On a large disk, 5-10% free can still be
   tens of GB — plenty. Now it only warns when the percentage **and**
   the absolute free space (default floor: 5GB) are both low.
3. **RAMDiscs free space check** (`check_tmpfssize`) checks
   `$lbhomedir/log/plugins` and `$lbhomedir/log/system_tmpfs`. On a
   real Raspberry Pi these live on an actual tmpfs (RAM), but in this
   Docker setup they're just regular folders on the bind-mounted disk
   — so this check ends up reporting the same "/opt/loxberry is below
   limit of 5%" warning a second time, under a different name. Same
   fix: only warn when percentage **and** absolute free space are both
   low.

### Running it manually

Only needed for a one-off, e.g. while debugging - normally this
already happened automatically:

```bash
docker exec -it loxberry python3 /usr/local/bin/patch_healthcheck.py /opt/loxberry/sbin/healthcheck.pl
docker exec -it loxberry bash -lc "/opt/loxberry/sbin/healthcheck.pl"
```

No service restart needed — `healthcheck.pl` is invoked fresh each
time (by cron / the web UI), it isn't a long-running daemon.

### Adjusting the 5GB floor

Edit `ABSOLUTE_MIN_KB` near the top of `patch_healthcheck.py` in this
repo, e.g. for a 2GB floor:

```python
ABSOLUTE_MIN_KB = 2 * 1024 * 1024  # 2 GB
```

Then rebuild the image (`docker compose build`) so the updated script
gets baked in and used on the next install/boot.

## Note

This patches a **core** LoxBerry file, not a plugin. The next time
you run LoxBerry's own update through the web UI, `healthcheck.pl`
will be overwritten and this patch will need to be re-applied. The
script is idempotent (safe to re-run) and keeps a `.bak` of whatever
it last patched, so re-applying after an update is just a matter of
running the same three commands again.

## Recommendation

For actual production use, a Raspberry Pi, another officially supported
SBC, or a VM running real DietPi remains the sensible choice — that's
what the LoxBerry developer actually tests and supports. This Docker
setup is best suited for quickly experimenting with the web interface or
testing a plugin without committing dedicated hardware.

## License / attribution

This repository only contains build tooling (Dockerfile, compose file,
scripts). LoxBerry itself is licensed and maintained by its own project:
https://github.com/mschlenstedt/Loxberry

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
cp .env.example .env      # first time only, then edit as needed
docker compose build
docker compose up -d
```

## Install LoxBerry

The installer must run **after** systemd is already active, so it can't
be part of `docker build` (there's no real PID 1 systemd to talk to
during a build):

```bash
docker exec -it loxberry /root/install_trixie_v4.sh
```

This downloads and installs the latest LoxBerry 4 release exactly like it
would on a real DietPi device. Expect roughly the same 10-15 minutes as
on a Raspberry Pi. Afterwards, the web interface is reachable at
`http://localhost:<LOXBERRY_HTTP_PORT>/` (8880 by default).

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

# LoxBerry healthcheck.pl patch (Docker false positives)

Fixes two false positives in `/opt/loxberry/sbin/healthcheck.pl`:

1. **RootFS ReadWrite check** only recognized `ext4` as a valid
   read-write filesystem. Docker's root is OverlayFS, so it always
   reported "not mounted ReadWrite" even when the filesystem is
   genuinely writable. Now matches any filesystem type.
2. **RootFS free space check** only looked at the free-space
   *percentage*. On a large disk, 5-10% free can still be tens of GB —
   plenty. Now it only warns when the percentage **and** the absolute
   free space (default floor: 5GB) are both low.

Verified with `perl -c` against the exact code you pasted from your
container — syntax is valid, brace-balanced.

## Apply it

```bash
# Copy the file out of the running container
docker cp loxberry:/opt/loxberry/sbin/healthcheck.pl ./healthcheck.pl

# Run the patch (writes healthcheck.pl.bak automatically)
python3 patch_healthcheck.py ./healthcheck.pl

# Copy the patched file back in
docker cp ./healthcheck.pl loxberry:/opt/loxberry/sbin/healthcheck.pl

# Re-run the healthcheck to confirm
docker exec -it loxberry /opt/loxberry/sbin/healthcheck.pl
```

No service restart needed — `healthcheck.pl` is invoked fresh each
time (by cron / the web UI), it isn't a long-running daemon.

## Adjusting the 5GB floor

Open `patch_healthcheck.py` and change `ABSOLUTE_MIN_KB` at the top
before running it, e.g. for a 2GB floor:

```python
ABSOLUTE_MIN_KB = 2 * 1024 * 1024  # 2 GB
```

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

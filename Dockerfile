# Experimental, community-built image to run LoxBerry 4.0 inside Docker.
#
# IMPORTANT: this is NOT an officially supported way to run LoxBerry.
# The v4 installer expects a real DietPi installation, and LoxBerry itself
# starts a whole stack of systemd services (Apache, Mosquitto, Samba,
# vsftpd, cron, autofs, watchdog, USB automount, ...). This image fakes
# just enough of DietPi for the official, unmodified installer to run, but
# hardware-dependent features (I2C, GPIO, real USB automount, the watchdog
# device, ...) will NOT work inside a container.
#
# See README.md for build/run instructions and known limitations.

FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# --- Base: systemd + tools the installer needs itself -----------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus udev \
        sudo curl wget ca-certificates gnupg2 lsb-release jq git \
        openssh-server locales \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    # Strip unit types that don't make sense / don't work inside a container
    && rm -f /lib/systemd/system/multi-user.target.wants/* \
    && rm -f /etc/systemd/system/*.wants/* \
    && rm -f /lib/systemd/system/local-fs.target.wants/* \
    && rm -f /lib/systemd/system/sockets.target.wants/*udev* \
    && rm -f /lib/systemd/system/sockets.target.wants/*initctl*

# Debian base images ship a policy-rc.d that blocks postinst scripts from
# starting services (it keeps build layers side-effect free). LoxBerry's
# installer relies on the opposite: packages it apt-installs at runtime
# (samba, apache2, mosquitto, vsftpd, ...) are expected to start right
# away. Without this override they end up "enabled" but "inactive (dead)"
# and the installer's own health checks fail.
RUN printf '#!/bin/sh\nexit 0\n' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d

# Mask watchdog.service BEFORE the "watchdog" package is ever installed.
# There's no real /dev/watchdog hardware timer inside a container, and
# starting this unit hangs indefinitely (systemd waits on ExecStart to
# return) instead of failing fast - which in turn blocks
# `dpkg --configure --pending` and stalls the entire installer. Masking
# pre-empts this: even once the package later drops its own unit file,
# systemd's config lookup finds this symlink first and deb-systemd-invoke
# skips calling "start" on it entirely.
RUN mkdir -p /etc/systemd/system \
    && ln -sf /dev/null /etc/systemd/system/watchdog.service

# --- Fake just enough DietPi for the installer's checks to pass -------------
RUN mkdir -p /boot/dietpi/func

# Sourced by install_trixie_v4.sh; only needs to exist and define these vars.
RUN cat <<'EOF' > /boot/dietpi/.version
G_DIETPI_VERSION_CORE=9
G_DIETPI_VERSION_SUB=9
G_DIETPI_VERSION_RC=0
G_GITBRANCH='master'
G_GITOWNER='MichaIng'
G_LIVE_PATCH_STATUS[0]='applied'
EOF

RUN cat <<'EOF' > /boot/dietpi/.hw_model
G_HW_MODEL=20
G_HW_MODEL_NAME='Virtual Machine (x86_64)'
G_HW_ARCH=10
G_HW_ARCH_NAME='x86_64'
G_HW_CPUID=0
G_HW_CPU_CORES=2
G_DISTRO=7
G_DISTRO_NAME='trixie'
G_ROOTFS_DEV='/dev/sda1'
G_HW_UUID='00000000-0000-0000-0000-000000000000'
EOF

# Stub for dietpi-software: the installer only calls "install 105"
# (OpenSSH server), which we already provide via apt above.
RUN cat <<'EOF' > /boot/dietpi/dietpi-software
#!/bin/bash
echo "[stub] dietpi-software $* (ignored, no real DietPi hardware here)"
exit 0
EOF
RUN chmod +x /boot/dietpi/dietpi-software

# Stubs for dietpi-set_software (apt reset/compress/clean) and
# dietpi-set_hardware (i2c enable): purely cosmetic / hardware-bound,
# safe to no-op in a container.
RUN cat <<'EOF' > /boot/dietpi/func/dietpi-set_software
#!/bin/bash
echo "[stub] dietpi-set_software $* (ignored)"
exit 0
EOF
RUN cat <<'EOF' > /boot/dietpi/func/dietpi-set_hardware
#!/bin/bash
echo "[stub] dietpi-set_hardware $* (ignored, no real hardware in a container)"
exit 0
EOF
RUN chmod +x /boot/dietpi/func/dietpi-set_software /boot/dietpi/func/dietpi-set_hardware

# --- Bundle the official LoxBerry installer ----------------------------------
RUN curl -fsSL -o /root/install_trixie_v4.sh \
    https://raw.githubusercontent.com/mschlenstedt/Loxberry_Installer/main/install_trixie_v4.sh \
    && chmod +x /root/install_trixie_v4.sh

# Auto-reinstall on boot: /opt/loxberry's DATA survives a container
# recreate (it's bind-mounted from the host), but the apt-installed
# system packages (apache2, samba, mosquitto, vsftpd, ...) live in the
# container's own writable layer and do NOT. This unit detects that
# mismatch at every boot and re-runs the installer automatically -
# important for GitOps-style deploys (e.g. Portainer "pull and
# redeploy") where the container gets recreated from the image.
COPY loxberry-autoinstall.sh /usr/local/bin/loxberry-autoinstall.sh
RUN chmod +x /usr/local/bin/loxberry-autoinstall.sh

# Applied automatically by loxberry-autoinstall.sh after every install/
# reinstall, and again on every boot in case a LoxBerry core update
# overwrote healthcheck.pl with the original, unpatched version.
COPY patch_healthcheck.py /usr/local/bin/patch_healthcheck.py
RUN chmod +x /usr/local/bin/patch_healthcheck.py

COPY loxberry-autoinstall.service /etc/systemd/system/loxberry-autoinstall.service
RUN mkdir -p /etc/systemd/system/multi-user.target.wants \
    && ln -s /etc/systemd/system/loxberry-autoinstall.service \
        /etc/systemd/system/multi-user.target.wants/loxberry-autoinstall.service

# Ports LoxBerry normally uses (web, ssh, ftp, samba, mqtt). These are the
# CONTAINER-internal ports; how they're published to the host is entirely
# controlled in docker-compose.yml / .env — see README.md.
EXPOSE 80 443 22 21 137/udp 138/udp 139 445 1883

STOPSIGNAL SIGRTMIN+3

# systemd must be PID 1, so the container MUST run with --privileged (or
# equivalent capabilities) and the cgroup mount from docker-compose.yml.
CMD ["/lib/systemd/systemd"]

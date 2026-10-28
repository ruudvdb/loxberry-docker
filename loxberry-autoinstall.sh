#!/bin/bash
# Runs at every container boot (via systemd, see loxberry-autoinstall.service).
# The bind-mounted /opt/loxberry survives container recreation, but the
# apt-installed system packages (apache2, samba, mosquitto, vsftpd, ...)
# live in the container's own writable layer and do NOT survive a
# redeploy (Komodo/Portainer rebuild) or any other container recreate.
#
# This script detects that mismatch and re-runs the installer
# automatically, instead of requiring a manual `docker exec`. It then
# always (re)applies the healthcheck.pl Docker fixes - see
# patch_healthcheck.py - so that never needs a manual step either.
#
# IMPORTANT: the installer starts with `rm -rf /opt/loxberry`, i.e. it
# wipes all LoxBerry settings (Miniserver, web login, plugins, ...).
# So before re-running it on an existing install, this script takes a
# full tar backup of /opt/loxberry into $BACKUP_DIR (a separate host bind
# mount), and restores the user data from it once the installer is done.

set -uo pipefail

LBHOME="/opt/loxberry"
MARKER="$LBHOME/config/system/do_lbupdate"
INSTALLER="/root/install_trixie_v4.sh"
HEALTHCHECK_FILE="$LBHOME/sbin/healthcheck.pl"
HEALTHCHECK_PATCHER="/usr/local/bin/patch_healthcheck.py"
# Written only after the installer exits successfully. Lives in the
# container's own writable layer (NOT in /opt/loxberry), so it disappears
# together with the system packages on a container recreate. Checking
# for apache2 alone isn't enough: an installer that aborts halfway has
# already apt-installed apache2, and the next boot would then wrongly
# skip the install and leave only the Apache default page.
DONE_FLAG="/var/lib/loxberry-docker/install-complete"

# Host bind mount (see docker-compose.yml) - must NOT be inside $LBHOME.
BACKUP_DIR="/var/backups/loxberry"
# Name of the backup still waiting to be restored. Survives a failed
# installer run, so a retry restores the original backup instead of
# backing up (and later restoring) the half-wiped tree.
PENDING_RESTORE="$BACKUP_DIR/pending-restore"
# Password hash of the 'loxberry' Linux user (SSH/console). /etc/shadow
# lives in the container layer, so it's saved here on every boot and
# put back after a reinstall (which resets it to 'loxberry').
SHADOW_SAVE="$BACKUP_DIR/loxberry-user.shadow"
KEEP_BACKUPS=10

# User data restored after a reinstall: all of config/ and data/ (system
# settings incl. Miniserver and web login, plugin settings, plugin
# database), plus every directory LoxBerry installs plugin files into.
# Copied OVER the fresh install, so the new LoxBerry code stays.
RESTORE_PATHS=(
    config
    data
    bin/plugins
    log/plugins
    templates/plugins
    webfrontend/html/plugins
    webfrontend/htmlauth/plugins
    system/daemons/plugins
    system/cron
)

is_installed() {
    [ -e "$DONE_FLAG" ]
}

has_existing_install() {
    [ -e "$LBHOME/config/system/general.json" ]
}

backup_lbhome() {
    local file="$BACKUP_DIR/loxberry-$(date +%Y%m%d-%H%M%S).tgz"
    echo ">>> Backing up $LBHOME to $file ..."
    if ! tar -czf "$file.part" -C "$LBHOME" .; then
        rm -f "$file.part"
        return 1
    fi
    mv "$file.part" "$file" || return 1
    basename "$file" > "$PENDING_RESTORE"
    echo ">>> Backup done ($(du -h "$file" | cut -f1))."
}

restore_user_data() {
    local file="$BACKUP_DIR/$(cat "$PENDING_RESTORE")"
    local tmp
    tmp=$(mktemp -d /var/tmp/loxberry-restore.XXXXXX) || return 1
    echo ">>> Restoring settings and plugins from $file ..."
    if ! tar -xzf "$file" -C "$tmp"; then
        rm -rf "$tmp"
        return 1
    fi
    local p
    for p in "${RESTORE_PATHS[@]}"; do
        if [ -d "$tmp/$p" ]; then
            mkdir -p "$LBHOME/$p"
            cp -a "$tmp/$p/." "$LBHOME/$p/" || { rm -rf "$tmp"; return 1; }
            echo "    restored $p"
        fi
    done
    rm -rf "$tmp"

    if [ -s "$SHADOW_SAVE" ]; then
        usermod -p "$(cat "$SHADOW_SAVE")" loxberry \
            && echo "    restored password of Linux user 'loxberry'"
    fi

    # Regenerate the mosquitto config from the restored MQTT settings (the
    # installer does the same), then restart what reads the restored files.
    PERL5LIB="$LBHOME/libs/perllib" "$LBHOME/sbin/mqtt-handler.pl" action=updateconfig || true
    systemctl try-restart apache2.service mosquitto.service cron.service || true
    rm -f "$PENDING_RESTORE"
    echo ">>> Restore done."
}

prune_backups() {
    ls -1t "$BACKUP_DIR"/loxberry-*.tgz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f
}

rc=0
mkdir -p "$BACKUP_DIR"

if is_installed; then
    echo ">>> LoxBerry install already completed in this container, nothing to install."
    if getent shadow loxberry | cut -d: -f2 > "$SHADOW_SAVE.tmp"; then
        chmod 600 "$SHADOW_SAVE.tmp" && mv "$SHADOW_SAVE.tmp" "$SHADOW_SAVE"
    fi
else
    echo ">>> No completed LoxBerry install in this container (fresh container, redeploy, rebuild, or a previous failed attempt)."

    if [ -e "$PENDING_RESTORE" ]; then
        echo ">>> A previous attempt left backup $(cat "$PENDING_RESTORE") to restore - not taking a new one."
    elif has_existing_install; then
        if ! backup_lbhome; then
            echo ">>> BACKUP FAILED - NOT running the installer, it would wipe $LBHOME."
            echo ">>> Fix the problem (e.g. disk space for $BACKUP_DIR) and restart the container."
            exit 1
        fi
        prune_backups
    fi

    if [ -e "$MARKER" ]; then
        echo ">>> Found a leftover install marker from a previous container's data volume."
        echo ">>> Removing it so the installer is allowed to run again: $MARKER"
        rm -f "$MARKER"
    fi

    echo ">>> Running $INSTALLER - this takes roughly 10-15 minutes, as it did on first install."
    "$INSTALLER"
    rc=$?
    echo ">>> Installer finished (exit code $rc)."
    if [ "$rc" -eq 0 ]; then
        if [ -e "$PENDING_RESTORE" ] && ! restore_user_data; then
            echo ">>> RESTORE FAILED - your data is still in $BACKUP_DIR/$(cat "$PENDING_RESTORE")."
            echo ">>> It will be retried on the next container start."
            rc=1
        else
            mkdir -p "$(dirname "$DONE_FLAG")"
            touch "$DONE_FLAG"
            # loxberry.service (system daemons such as the MQTT Gateway,
            # plugin daemons) is created by the installer, so it didn't
            # exist yet when this boot started and never ran. On real
            # hardware a reboot follows the install; start it here instead.
            # --no-block: don't wait on another unit from inside a unit
            # that is itself still part of the boot transaction.
            echo ">>> Install complete. Starting LoxBerry boot services (loxberry.service)..."
            systemctl --no-block start loxberry.service || true
        fi
    else
        echo ">>> Installer FAILED - it will be retried on the next container start."
    fi
fi

# Always (re)apply the Docker-specific healthcheck.pl fixes: after a
# fresh install above, and also on every boot even when packages were
# already present - this covers the case where a LoxBerry core update
# (run from the web UI) overwrote healthcheck.pl with the original,
# unpatched version.
if [ -f "$HEALTHCHECK_FILE" ] && [ -f "$HEALTHCHECK_PATCHER" ]; then
    echo ">>> Applying healthcheck.pl Docker fixes..."
    python3 "$HEALTHCHECK_PATCHER" "$HEALTHCHECK_FILE"
else
    echo ">>> Skipping healthcheck.pl patch: file not present yet."
fi

# LoxBerry's get_localip() returns the container's Docker-internal IP
# (e.g. 172.x), which the Miniserver can't reach. Plugins use it for URLs
# and DNS records they hand out - e.g. the Weather4Lox cloud emulator
# points weather.loxone.com at it. If LOXBERRY_HOST_IP is set (see
# docker-compose.yml), make get_localip() return that instead. Re-applied
# on every boot because a LoxBerry core update overwrites these libraries.
HOST_IP=$(tr '\0' '\n' < /proc/1/environ | sed -n 's/^LOXBERRY_HOST_IP=//p')
HOST_IP_FILE="/etc/loxberry-docker/host-ip"
PERL_SYSTEM="$LBHOME/libs/perllib/LoxBerry/System.pm"
PHP_SYSTEM="$LBHOME/libs/phplib/loxberry_system.php"
if [ -n "$HOST_IP" ]; then
    echo ">>> Reporting Docker host IP $HOST_IP as LoxBerry's local IP."
    mkdir -p "$(dirname "$HOST_IP_FILE")"
    echo "$HOST_IP" > "$HOST_IP_FILE"
    if [ -f "$PERL_SYSTEM" ] && ! grep -q "$HOST_IP_FILE" "$PERL_SYSTEM"; then
        perl -0pi -e 's|(sub get_localip\n\{\n)|$1\tif (open(my \$fh, "<", "'"$HOST_IP_FILE"'")) { my \$ip = <\$fh>; chomp \$ip; return \$ip if \$ip; } # loxberry-docker\n|' "$PERL_SYSTEM"
    fi
    if [ -f "$PHP_SYSTEM" ] && ! grep -q "$HOST_IP_FILE" "$PHP_SYSTEM"; then
        perl -0pi -e 's|(public static function get_localip\(\)\n\t\{\n)|$1\t\t\$ip = trim(\@file_get_contents("'"$HOST_IP_FILE"'")); if (\$ip) return \$ip; // loxberry-docker\n|' "$PHP_SYSTEM"
    fi
    # Weather4Lox cloud emulator: fix a DNS record still pointing at the
    # container IP from before LOXBERRY_HOST_IP was set.
    if [ -f /etc/dnsmasq.d/weather4lox.conf ]; then
        sed -i -E "s|^(address=/[^/]+/).*|\1$HOST_IP|" /etc/dnsmasq.d/weather4lox.conf
    fi
else
    rm -f "$HOST_IP_FILE"
fi

# dnsmasq (installed by e.g. the Weather4Lox cloud emulator) is started by
# Debian with --local-service: it only answers clients in its own subnet,
# which inside Docker is just the bridge network - so queries from the
# Miniserver are silently dropped. Naming an interface turns that off.
mkdir -p /etc/dnsmasq.d
echo "interface=eth0" > /etc/dnsmasq.d/00-loxberry-docker.conf
systemctl try-restart dnsmasq.service || true

exit "$rc"

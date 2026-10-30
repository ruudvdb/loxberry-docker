#!/bin/bash
# Runs at every container boot (via systemd, see loxberry-autoinstall.service).
# The bind-mounted /opt/loxberry survives container recreation, but the
# apt-installed system packages (apache2, samba, mosquitto, vsftpd, ...)
# live in the container's own writable layer and do NOT survive a
# redeploy or any other container recreate.
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
# Exit code of the last run, for build-installed-image.sh, which waits
# for it in the staging container.
RESULT_FILE="/var/lib/loxberry-docker/autoinstall-result"
# Set by build-installed-image.sh in the staging container's backup dir.
# That container runs on a copy of the real config, so it must not reach
# out to the Miniserver: no plugin daemons, no plugin cron jobs.
STAGING=0
[ -e "$BACKUP_DIR/staging" ] && STAGING=1

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
# System config that plugins add to (sudoers rules, Apache sites and
# modules - /etc/sudoers.d and /etc/apache2 are symlinks into here).
# Only files missing from the fresh install are copied back, so the new
# LoxBerry defaults stay.
RESTORE_MISSING_PATHS=(
    system/sudoers
    system/apache2
)
# Set once a reinstall restored the user data: plugins then still need
# their system packages and root setup redone, see reinstall_plugins.
RESTORED=0
START_LOXBERRY=0

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
    for p in "${RESTORE_MISSING_PATHS[@]}"; do
        if [ -d "$tmp/$p" ]; then
            mkdir -p "$LBHOME/$p"
            cp -an "$tmp/$p/." "$LBHOME/$p/" || { rm -rf "$tmp"; return 1; }
            echo "    restored missing files in $p"
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
    if [ "$STAGING" -eq 1 ]; then
        systemctl try-restart apache2.service mosquitto.service || true
        systemctl stop cron.service || true
    else
        systemctl try-restart apache2.service mosquitto.service cron.service || true
    fi
    rm -f "$PENDING_RESTORE"
    RESTORED=1
    echo ">>> Restore done."
}

# Redo what each plugin installed outside /opt/loxberry, which the
# reinstall threw away: its apt packages and its postroot script (Perl
# modules, Apache modules, ...). Both are read from the copies LoxBerry's
# plugin installer keeps of the currently installed plugin version in
# data/system/install/<folder>/, so this follows plugin updates.
reinstall_plugins() {
    local db="$LBHOME/data/system/plugindatabase.json"
    [ -f "$db" ] || return 0
    local debian_major
    debian_major=$(cut -d. -f1 /etc/debian_version)
    local apt_updated=0

    local folder name version
    while IFS=$'\t' read -r folder name version; do
        local dir="$LBHOME/data/system/install/$folder"
        [ -d "$dir" ] || continue
        echo ">>> Restoring system setup of plugin $name $version ..."

        # Same apt file selection as LoxBerry's plugininstall.pl.
        local aptfile="$dir/dpkg/apt"
        [ -f "$dir/dpkg/apt$debian_major" ] && aptfile="$dir/dpkg/apt$debian_major"
        if [ -f "$aptfile" ]; then
            local packages
            packages=$(grep -v '^\s*#' "$aptfile" | xargs)
            if [ -n "$packages" ]; then
                [ "$apt_updated" -eq 1 ] || { apt-get update; apt_updated=1; }
                apt-get install -y --no-install-recommends $packages \
                    || echo ">>> Installing apt packages of $name FAILED: $packages"
            fi
        fi

        # Called like plugininstall.pl does: <tempfile> <name> <folder>
        # <version> <lbhomedir> <tempfolder>, with /etc/environment loaded.
        local script
        for script in "$dir"/postroot*; do
            [ -f "$script" ] || continue
            chmod a+x "$script"
            ( set -a; . /etc/environment; set +a
              cd "$dir" && "$script" "$dir" "$name" "$folder" "$version" "$LBHOME" "$dir" ) \
                || echo ">>> $(basename "$script") of $name FAILED"
        done
    done < <(jq -r '.plugins[] | [.folder, .name, .version] | @tsv' "$db")

    # Weather4Lox enables its cloud emulator (dnsmasq + Apache site) only
    # when its setting is saved; redo that. Must run after the host IP
    # setup below has patched get_localip().
    local w4l_cfg="$LBHOME/config/plugins/weather4lox/weather4lox.cfg"
    local w4l_emu="$LBHOME/bin/plugins/weather4lox/cloudemu.sh"
    if [ -x "$w4l_emu" ] && grep -qx 'EMU=1' "$w4l_cfg" 2>/dev/null; then
        echo ">>> Re-enabling the Weather4Lox cloud emulator ..."
        # Not reported as FAILED: cloudemu.sh 4.20.1 also exits non-zero
        # when only its own log bookkeeping fails ("Invalid emulator log
        # status" on the first emulator log of a day). Whether the
        # emulator really runs is checked by build-installed-image.sh
        # (dnsmasq active, port 6066 answers).
        "$w4l_emu" enable || echo ">>> Weather4Lox cloud emulator script returned an error - check that dnsmasq runs and port 6066 answers"
    fi

    systemctl try-reload-or-restart apache2.service || true
}

prune_backups() {
    ls -1t "$BACKUP_DIR"/loxberry-*.tgz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f
}

finish() {
    mkdir -p "$(dirname "$RESULT_FILE")"
    echo "$1" > "$RESULT_FILE"
    exit "$1"
}

rc=0
rm -f "$RESULT_FILE"
mkdir -p "$BACKUP_DIR"

# An image from build-installed-image.sh carries the install flag, but was
# installed on a copy of the data. If the real data has no LoxBerry
# install (fresh setup) or a failed reinstall left it half-restored, the
# system files the flag vouches for don't match it: install after all.
if is_installed && { ! has_existing_install || [ -e "$PENDING_RESTORE" ]; }; then
    echo ">>> Install flag present, but $LBHOME has no complete LoxBerry install - installing anyway."
    rm -f "$DONE_FLAG"
fi

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
            finish 1
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
            echo ">>> Install complete."
            START_LOXBERRY=1
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

# The timezone chosen in the web UI is stored in general.json, but a new
# container starts with the one baked into the image. loxberryinit.sh
# should apply it at boot, but a broken test there (`[ ... && ... ]`)
# skips that, so only the hourly cron job would fix it. Apply it here.
# Set the files directly: timedatectl needs timedated over D-Bus.
TIMEZONE=$(jq -r '.Timeserver.Timezone // empty' "$LBHOME/config/system/general.json" 2>/dev/null || true)
if [ -n "$TIMEZONE" ] && [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
    echo ">>> Setting timezone to $TIMEZONE."
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    echo "$TIMEZONE" > /etc/timezone
fi

if [ "$RESTORED" -eq 1 ]; then
    reinstall_plugins
fi

# dnsmasq (installed by e.g. the Weather4Lox cloud emulator) is started by
# Debian with --local-service: it only answers clients in its own subnet,
# which inside Docker is just the bridge network - so queries from the
# Miniserver are silently dropped. Naming an interface turns that off.
# Weather4Lox also forwards everything to 1.1.1.1/1.0.0.1, which can't
# resolve LAN names (e.g. optiplex.home) - and since the container's own
# resolv.conf points at this dnsmasq, neither can LoxBerry. Forward to
# Docker's DNS instead, which uses the host's resolver. Its server=
# lines are removed rather than outranked: dnsmasq would otherwise take
# whichever upstream answers first, NXDOMAIN included.
# After reinstall_plugins: cloudemu.sh enable rewrites weather4lox.conf.
mkdir -p /etc/dnsmasq.d
printf 'interface=eth0\nserver=127.0.0.11\n' > /etc/dnsmasq.d/00-loxberry-docker.conf
if [ -f /etc/dnsmasq.d/weather4lox.conf ]; then
    sed -i '/^server=/d' /etc/dnsmasq.d/weather4lox.conf
fi
# LOXBERRY_DNSMASQ=off: weather.loxone.com is redirected elsewhere (e.g.
# in the router), so nothing needs this dnsmasq. Mask it, so neither the
# image's enabled unit nor the plugin can start it, and point the
# container back at Docker's DNS: stopping dnsmasq makes openresolv
# rewrite resolv.conf without any nameserver.
if [ "$(tr '\0' '\n' < /proc/1/environ | sed -n 's/^LOXBERRY_DNSMASQ=//p')" = "off" ]; then
    echo ">>> LOXBERRY_DNSMASQ=off: stopping and masking dnsmasq."
    systemctl disable --now dnsmasq.service 2>/dev/null || true
    systemctl mask dnsmasq.service || true
    printf 'nameserver 127.0.0.11\noptions ndots:0\n' > /etc/resolv.conf
else
    systemctl unmask dnsmasq.service 2>/dev/null || true
    systemctl try-restart dnsmasq.service || true
fi

# loxberry.service (system daemons such as the MQTT Gateway, plugin
# daemons) is created by the installer, so it didn't exist yet when this
# boot started and never ran. On real hardware a reboot follows the
# install; start it here instead - last, so plugin daemons find their
# packages back. --no-block: don't wait on another unit from inside a
# unit that is itself still part of the boot transaction.
if [ "$START_LOXBERRY" -eq 1 ] && [ "$STAGING" -eq 1 ]; then
    echo ">>> Staging container: not starting loxberry.service (no plugin daemons)."
elif [ "$START_LOXBERRY" -eq 1 ]; then
    echo ">>> Starting LoxBerry boot services (loxberry.service)..."
    systemctl --no-block start loxberry.service || true
fi

finish "$rc"

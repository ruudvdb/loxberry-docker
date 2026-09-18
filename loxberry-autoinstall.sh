#!/bin/bash
# Runs at every container boot (via systemd, see loxberry-autoinstall.service).
# The bind-mounted /opt/loxberry survives container recreation, but the
# apt-installed system packages (apache2, samba, mosquitto, vsftpd, ...)
# live in the container's own writable layer and do NOT survive a
# "pull and redeploy" in Portainer, or any other container recreate.
#
# This script detects that mismatch and re-runs the installer
# automatically, instead of requiring a manual `docker exec`. It then
# always (re)applies the healthcheck.pl Docker fixes - see
# patch_healthcheck.py - so that never needs a manual step either.

set -uo pipefail

MARKER="/opt/loxberry/config/system/do_lbupdate"
INSTALLER="/root/install_trixie_v4.sh"
HEALTHCHECK_FILE="/opt/loxberry/sbin/healthcheck.pl"
HEALTHCHECK_PATCHER="/usr/local/bin/patch_healthcheck.py"

is_installed() {
    dpkg-query -W -f='${Status}' apache2 2>/dev/null | grep -q "^install ok installed"
}

rc=0

if is_installed; then
    echo ">>> LoxBerry system packages are present, nothing to install."
else
    echo ">>> LoxBerry system packages are missing (fresh container, redeploy, or rebuild)."

    if [ -e "$MARKER" ]; then
        echo ">>> Found a leftover install marker from a previous container's data volume."
        echo ">>> Removing it so the installer is allowed to run again: $MARKER"
        rm -f "$MARKER"
    fi

    echo ">>> Running $INSTALLER - this takes roughly 10-15 minutes, as it did on first install."
    "$INSTALLER"
    rc=$?
    echo ">>> Installer finished (exit code $rc)."
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

exit "$rc"

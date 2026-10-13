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
# Written only after the installer exits successfully. Lives in the
# container's own writable layer (NOT in /opt/loxberry), so it disappears
# together with the system packages on a container recreate. Checking
# for apache2 alone isn't enough: an installer that aborts halfway has
# already apt-installed apache2, and the next boot would then wrongly
# skip the install and leave only the Apache default page.
DONE_FLAG="/var/lib/loxberry-docker/install-complete"

is_installed() {
    [ -e "$DONE_FLAG" ]
}

rc=0

if is_installed; then
    echo ">>> LoxBerry install already completed in this container, nothing to install."
else
    echo ">>> No completed LoxBerry install in this container (fresh container, redeploy, rebuild, or a previous failed attempt)."

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
        mkdir -p "$(dirname "$DONE_FLAG")"
        touch "$DONE_FLAG"
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

exit "$rc"

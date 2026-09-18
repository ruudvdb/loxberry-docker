#!/bin/bash
# Runs at every container boot (via systemd, see loxberry-autoinstall.service).
# The bind-mounted /opt/loxberry survives container recreation, but the
# apt-installed system packages (apache2, samba, mosquitto, vsftpd, ...)
# live in the container's own writable layer and do NOT survive a
# "pull and redeploy" in Portainer, or any other container recreate.
#
# This script detects that mismatch and re-runs the installer
# automatically, instead of requiring a manual `docker exec`.

set -uo pipefail

MARKER="/opt/loxberry/config/system/do_lbupdate"
INSTALLER="/root/install_trixie_v4.sh"

is_installed() {
    dpkg-query -W -f='${Status}' apache2 2>/dev/null | grep -q "^install ok installed"
}

if is_installed; then
    echo ">>> LoxBerry system packages are present, nothing to do."
    exit 0
fi

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
exit "$rc"

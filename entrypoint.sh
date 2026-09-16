#!/bin/bash
# Boots systemd as PID 1. The actual LoxBerry installation is NOT run
# automatically here (systemctl calls need real systemd already running),
# so it must be triggered manually after the container is up. See README.md.
set -e

MARKER="/opt/loxberry/config/system/do_lbupdate"

if [ ! -e "$MARKER" ]; then
    echo ">>> First start: LoxBerry does not appear to be installed yet."
    echo ">>> systemd is starting now. Once the container is up, install with:"
    echo ">>>   docker exec -it loxberry /root/install_trixie_v4.sh"
else
    echo ">>> LoxBerry appears to be installed already, starting systemd."
fi

exec "$@"

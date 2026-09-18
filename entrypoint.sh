#!/bin/bash
# Boots systemd as PID 1. The loxberry-autoinstall.service unit (baked
# into the image, enabled by default) takes care of running or
# re-running the LoxBerry installer automatically once systemd is up -
# see loxberry-autoinstall.sh for details.
set -e

echo ">>> Starting systemd. LoxBerry installer will run automatically"
echo ">>> if system packages are missing (first boot, or after a redeploy)."
echo ">>> Follow progress with: docker logs -f loxberry"

exec "$@"


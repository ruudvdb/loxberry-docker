#!/bin/bash
# Builds an image with LoxBerry already installed, next to the running
# container, and only succeeds when that install works. Runs as Komodo's
# Stack "pre_deploy" command: if it fails, Komodo doesn't run
# `docker compose up`, so the running container stays as it is. If it
# succeeds, compose starts the container from loxberry-docker:installed,
# which boots straight onto the real data without the 10-15 minute
# install. See README.md, "Deploys without downtime".
#
# How: the LoxBerry installer needs a running systemd, so it can't run in
# `docker build`. Instead this starts a temporary container
# (loxberry-staging) from the base image, without ports, on a COPY of the
# data. loxberry-autoinstall.sh then does there what it does in any fresh
# container (backup, install, restore, plugin setup). After checking the
# result, the container is saved with `docker commit`.
#
# Works inside the Komodo periphery container, which has the Docker CLI
# but not the host's /home/docker or Docker data root: everything on
# host paths goes through short-lived helper containers.
#
# Environment (read from ./.env, which Komodo writes from the Stack
# environment, or from the shell):
#   LOXBERRY_IMAGE_TAG  set to anything but "installed" to deploy that
#                       existing image instead of building (rollback)
#   STAGING_TIMEOUT     seconds to wait for the install (default 2700)

set -uo pipefail

BASE_IMAGE="loxberry-docker:base"
IMAGE_REPO="loxberry-docker"
STAGING="loxberry-staging"
DATA_DIR="/home/docker/loxberry-data"
BACKUP_DIR="/home/docker/loxberry-backup"
STAGING_DIR="/home/docker/loxberry-staging"
RESULT_FILE="/var/lib/loxberry-docker/autoinstall-result"
MIN_FREE_KB=$((15 * 1024 * 1024))
KEEP_IMAGES=2

load_env() {
    if [ -f ./.env ]; then
        set -a
        . ./.env
        set +a
    fi
    STAGING_TIMEOUT="${STAGING_TIMEOUT:-2700}"
}

# Runs a shell command in a throwaway container that sees /home/docker.
helper() {
    docker run --rm -v /home/docker:/home/docker "$BASE_IMAGE" bash -c "$1"
}

check_disk() {
    local root avail
    root=$(docker info -f '{{.DockerRootDir}}') || return 1
    avail=$(docker run --rm -v "$root":/dockerroot:ro "$BASE_IMAGE" \
        df --output=avail -k /dockerroot | tail -1) || return 1
    echo ">>> Free disk space for Docker: $((avail / 1024 / 1024)) GB."
    if [ "$avail" -lt "$MIN_FREE_KB" ]; then
        echo ">>> Less than $((MIN_FREE_KB / 1024 / 1024)) GB free - an installed image is about 4.5 GB. Free up space first."
        return 1
    fi
}

# Also clears what an interrupted or cancelled earlier run left behind.
cleanup_staging() {
    if docker container inspect "$STAGING" > /dev/null 2>&1; then
        echo ">>> Removing leftover $STAGING container."
        docker rm -f "$STAGING" > /dev/null || return 1
    fi
    helper "rm -rf '$STAGING_DIR'"
}

prepare_staging_data() {
    echo ">>> Copying $DATA_DIR to $STAGING_DIR/data ..."
    helper "set -e
        mkdir -p '$STAGING_DIR/backup'
        cp -a '$DATA_DIR' '$STAGING_DIR/data'
        if [ -f '$BACKUP_DIR/loxberry-user.shadow' ]; then
            cp -a '$BACKUP_DIR/loxberry-user.shadow' '$STAGING_DIR/backup/'
        fi
        touch '$STAGING_DIR/backup/staging'"
}

# Same runtime settings as docker-compose.yml, minus ports. No -e
# variables: `docker commit` would bake them into the image.
start_staging() {
    echo ">>> Starting $STAGING container ..."
    docker run -d --name "$STAGING" --hostname loxberry \
        --privileged --cgroupns=host -t \
        --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        -v "$STAGING_DIR/data":/opt/loxberry \
        -v "$STAGING_DIR/backup":/var/backups/loxberry \
        "$BASE_IMAGE" > /dev/null
}

wait_for_result() {
    echo ">>> Waiting for the LoxBerry install in $STAGING (up to $((STAGING_TIMEOUT / 60)) minutes) ..."
    local waited=0 result
    while [ "$waited" -lt "$STAGING_TIMEOUT" ]; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$STAGING" 2>/dev/null)" != "true" ]; then
            echo ">>> $STAGING stopped unexpectedly."
            return 1
        fi
        if result=$(docker exec "$STAGING" cat "$RESULT_FILE" 2>/dev/null); then
            if [ "$result" = "0" ]; then
                echo ">>> Install finished after about $((waited / 60)) minutes."
                return 0
            fi
            echo ">>> Install in $STAGING FAILED (exit code $result)."
            return 1
        fi
        sleep 15
        waited=$((waited + 15))
    done
    echo ">>> Install in $STAGING did not finish within $((STAGING_TIMEOUT / 60)) minutes."
    return 1
}

run_checks() {
    echo ">>> Checking $STAGING ..."
    local ok=0
    if docker exec "$STAGING" journalctl -u loxberry-autoinstall.service -o cat | grep '^>>>.*FAILED'; then
        echo ">>> Check failed: the autoinstall log above reports failures."
        ok=1
    fi
    local service
    for service in apache2 mosquitto; do
        if ! docker exec "$STAGING" systemctl is-active --quiet "$service"; then
            echo ">>> Check failed: $service is not running."
            ok=1
        fi
    done
    if [ "$(docker exec "$STAGING" curl -s -o /dev/null -w '%{http_code}' http://localhost/)" != "200" ]; then
        echo ">>> Check failed: the web UI doesn't answer with HTTP 200."
        ok=1
    fi
    if docker exec "$STAGING" grep -qx 'EMU=1' /opt/loxberry/config/plugins/weather4lox/weather4lox.cfg 2>/dev/null; then
        if ! docker exec "$STAGING" systemctl is-active --quiet dnsmasq; then
            echo ">>> Check failed: Weather4Lox cloud emulator is on, but dnsmasq is not running."
            ok=1
        fi
        if [ "$(docker exec "$STAGING" curl -s -o /dev/null -w '%{http_code}' http://localhost:6066/forecast/)" != "200" ]; then
            echo ">>> Check failed: Weather4Lox cloud emulator doesn't answer on port 6066."
            ok=1
        fi
    fi
    [ "$ok" -eq 0 ] && echo ">>> All checks passed."
    return "$ok"
}

commit_image() {
    local tag
    tag=$(date +%Y%m%d-%H%M)
    echo ">>> Saving $STAGING as $IMAGE_REPO:$tag ..."
    # Caches are about a GB of the image and are never needed again.
    docker exec "$STAGING" bash -c 'apt-get clean; rm -rf /var/lib/apt/lists/* /root/.cpanm' || return 1
    docker stop -t 60 "$STAGING" > /dev/null || return 1
    docker commit "$STAGING" "$IMAGE_REPO:$tag" > /dev/null || return 1
    docker tag "$IMAGE_REPO:$tag" "$IMAGE_REPO:installed" || return 1
    echo ">>> $IMAGE_REPO:installed is now $IMAGE_REPO:$tag."
}

# No -f: an image the running container still uses is kept.
prune_images() {
    docker images "$IMAGE_REPO" --format '{{.Tag}}' \
        | grep -E '^[0-9]{8}-[0-9]{4}$' | sort -r | tail -n +$((KEEP_IMAGES + 1)) \
        | while read -r tag; do
            echo ">>> Removing old image $IMAGE_REPO:$tag."
            docker rmi "$IMAGE_REPO:$tag" > /dev/null || true
        done
}

# The stopped staging container is kept for `docker logs`; the next run
# removes it.
fail() {
    echo ">>> FAILED - the running LoxBerry container is not changed."
    if docker container inspect "$STAGING" > /dev/null 2>&1; then
        echo ">>> Last lines of $STAGING (full log: docker logs $STAGING):"
        docker logs --tail 50 "$STAGING" 2>&1
        docker stop -t 60 "$STAGING" > /dev/null 2>&1
    fi
    helper "rm -rf '$STAGING_DIR'" > /dev/null 2>&1
    exit 1
}

main() {
    load_env
    local tag="${LOXBERRY_IMAGE_TAG:-installed}"
    if [ "$tag" != "installed" ]; then
        if docker image inspect "$IMAGE_REPO:$tag" > /dev/null 2>&1; then
            echo ">>> LOXBERRY_IMAGE_TAG=$tag: deploying that existing image, not building."
            exit 0
        fi
        echo ">>> LOXBERRY_IMAGE_TAG=$tag, but image $IMAGE_REPO:$tag doesn't exist."
        exit 1
    fi

    echo ">>> Building $BASE_IMAGE ..."
    docker build -t "$BASE_IMAGE" . || fail
    check_disk || fail
    cleanup_staging || fail
    prepare_staging_data || fail
    start_staging || fail
    wait_for_result || fail
    run_checks || fail
    commit_image || fail
    docker rm "$STAGING" > /dev/null
    helper "rm -rf '$STAGING_DIR'"
    prune_images
    echo ">>> Done. The deploy can switch to $IMAGE_REPO:installed."
}

if [ "${1:-}" != "--source-only" ]; then
    main
fi

# Staged Deploy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Komodo redeploy builds and checks an installed LoxBerry image next to the running container, and only then switches to it.

**Architecture:** `build-installed-image.sh` runs as Komodo `pre_deploy`. It runs the existing `loxberry-autoinstall.sh` flow in a port-less `loxberry-staging` container on a copy of the data, checks it and `docker commit`s it. `docker-compose.yml` runs that committed image, which already has the install flag.

**Tech Stack:** bash, Docker CLI, systemd inside the container, Komodo Stack `pre_deploy`.

**Spec:** `docs/superpowers/specs/2026-10-28-staged-deploy-design.md`

## Global Constraints

- Image names: `loxberry-docker:base`, `loxberry-docker:installed`, date tags `loxberry-docker:YYYYMMDD-HHMM`; keep the 2 newest date tags.
- Staging container name: `loxberry-staging`; staging dirs `/home/docker/loxberry-staging/data` and `/home/docker/loxberry-staging/backup`; marker file `staging` in the backup dir.
- Result file in the container: `/var/lib/loxberry-docker/autoinstall-result`.
- `STAGING_TIMEOUT` default 2700 seconds. Minimum free disk space: 15 GB.
- No `-e` variables on the staging container.
- Never stop, restart or modify the container named `loxberry`.
- The script must work both in the Komodo periphery container (no `/home/docker`, no `/var/lib/docker`) and on the host: all file access on host paths goes through helper containers from `loxberry-docker:base`.
- Code style: match `loxberry-autoinstall.sh` (`set -uo pipefail`, `>>>` messages, comments explaining why).

## Review Focus

1. Komodo cancels a deploy mid-build: the staging container keeps running. The next run must remove it and the staging dirs first (Task 2, step 6).
2. The running `loxberry` container must stay untouched for the whole build: its `StartedAt` must not change (Task 3, step 2).
3. `.env` missing (manual run on the host) or without `LOXBERRY_IMAGE_TAG`: the script builds normally (Task 2, step 4).
4. `LOXBERRY_IMAGE_TAG` set to a tag that doesn't exist: fail before building, with a clear message (Task 2, step 4).
5. Pruning old date tags while one is in use by the running container: `docker rmi` without `-f`, errors ignored, so the running image is never forced away (Task 2, step 3).

---

### Task 1: Staging mode and result file in `loxberry-autoinstall.sh`

**Files:**
- Modify: `loxberry-autoinstall.sh`

**Interfaces:**
- Produces: staging mode when `$BACKUP_DIR/staging` exists; `/var/lib/loxberry-docker/autoinstall-result` containing the script's exit code, written on every run; removed at start.

- [ ] **Step 1: Add the staging flag and result file**

Near the other constants: `STAGING=0; [ -e "$BACKUP_DIR/staging" ] && STAGING=1` and `RESULT_FILE="/var/lib/loxberry-docker/autoinstall-result"`. Remove `$RESULT_FILE` right after `rc=0`. Write `$rc` to it (create its directory) just before the final `exit "$rc"`; the early `exit 1` after a failed backup must write `1` too.

- [ ] **Step 2: Staging behaviour**

- In `restore_user_data`: when `STAGING=1`, run `systemctl try-restart apache2.service mosquitto.service` and `systemctl stop cron.service`, instead of the current `try-restart` of all three.
- At the `loxberry.service` start at the end: skip it when `STAGING=1`, with a `>>>` message saying why.
- Comment both with the reason: the staging container has a copy of the real config and must not send anything to the Miniserver.

- [ ] **Step 3: Verify**

Run: `bash -n loxberry-autoinstall.sh && grep -c 'STAGING' loxberry-autoinstall.sh`
Expected: no syntax error, count ≥ 3. Behaviour is verified end to end in Task 3.

- [ ] **Step 4: Commit**

```bash
git add loxberry-autoinstall.sh
git commit -m "Add a staging mode to the autoinstall script"
```

### Task 2: `build-installed-image.sh`, compose file and README

**Files:**
- Create: `build-installed-image.sh`
- Modify: `docker-compose.yml` (remove `build:`, change `image:` and `pull_policy:`)
- Modify: `README.md` (new section "Deploys without downtime" replacing the redeploy timing text in "Surviving redeploys"; Komodo settings; rollback)

**Interfaces:**
- Consumes: Task 1's marker file and result file.
- Produces: exit 0 = `loxberry-docker:installed` (or the rollback tag) is ready; exit 1 = deploy must stop. Env inputs: `LOXBERRY_IMAGE_TAG`, `STAGING_TIMEOUT`.

- [ ] **Step 1: Compose file**

`image: loxberry-docker:${LOXBERRY_IMAGE_TAG:-installed}`, `pull_policy: never`, drop `build: .` and the old pull_policy comment; add a comment pointing to `build-installed-image.sh`.

Verify: `docker compose config | grep 'image:'` → `image: loxberry-docker:installed`; with `LOXBERRY_IMAGE_TAG=20261028-1530` → that tag.

- [ ] **Step 2: Script skeleton**

Functions (each echoes `>>>` messages, returns non-zero on failure):
- `load_env` — `set -a; . ./.env; set +a` if `./.env` exists.
- `helper <cmd...>` — `docker run --rm -v /home/docker:/home/docker -v "$(docker info -f '{{.DockerRootDir}}')":/dockerroot:ro loxberry-docker:base bash -c "<cmd>"`.
- `check_disk` — `helper` running `df --output=avail -k /dockerroot`; fail below 15 GB.
- `cleanup_staging` — `docker rm -f loxberry-staging` (ignore missing), `helper rm -rf /home/docker/loxberry-staging`.
- `prepare_staging_data` — copy data, create backup dir, copy `loxberry-user.shadow` if present, touch `staging`.
- `start_staging` — `docker run -d --name loxberry-staging --hostname loxberry --privileged --cgroupns=host -t --tmpfs /tmp --tmpfs /run --tmpfs /run/lock -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v /home/docker/loxberry-staging/data:/opt/loxberry -v /home/docker/loxberry-staging/backup:/var/backups/loxberry loxberry-docker:base`.
- `wait_for_result` — poll `docker exec loxberry-staging cat /var/lib/loxberry-docker/autoinstall-result` every 15 s up to `STAGING_TIMEOUT`; fail if not `0`.
- `run_checks` — the five checks from the spec, each with its own `>>>` line on failure. Check 2: `journalctl -u loxberry-autoinstall.service -o cat | grep '^>>>.*FAILED'` must find nothing.
- `commit_image` — clean caches (`apt-get clean; rm -rf /var/lib/apt/lists/* /root/.cpanm`), `docker stop -t 60`, `docker commit` with a date tag, `docker tag` to `installed`.
- `prune_images` — keep the 2 newest date tags (sort tags, `docker rmi` the rest, no `-f`, `|| true`).
- `fail` — print `docker logs --tail 50 loxberry-staging`, `helper rm -rf /home/docker/loxberry-staging`, exit 1 (container kept).

Main flow in spec order, with one change: `docker build -t loxberry-docker:base .` runs before `check_disk`, because the helpers need the base image (it is about 260 MB and mostly cached).

- [ ] **Step 3: Pruning test**

```bash
for t in 20260101-0000 20260102-0000 20260103-0000; do docker tag loxberry-docker:base loxberry-docker:$t; done
bash -c '. ./build-installed-image.sh --source-only; prune_images'
docker images loxberry-docker --format '{{.Tag}}' | grep -E '^[0-9]{8}-' | sort
```
Expected: only `20260102-0000` and `20260103-0000` remain. Support `--source-only` (define functions, skip main) for this. Remove the test tags afterwards.

- [ ] **Step 4: Rollback and env tests**

- `LOXBERRY_IMAGE_TAG=doesnotexist bash build-installed-image.sh` → exit 1, message names the missing image, no `docker build` ran.
- `docker tag loxberry-docker:base loxberry-docker:20260101-0000; LOXBERRY_IMAGE_TAG=20260101-0000 bash build-installed-image.sh` → exit 0 within seconds. Remove the tag.
- Without `.env` and without the variable, the script starts building (stop it with Ctrl-C after "docker build").

- [ ] **Step 5: Failure path test**

Run: `STAGING_TIMEOUT=60 bash build-installed-image.sh; echo rc=$?`
Expected: `rc=1`, the last 50 log lines printed, `docker ps -a --filter name=loxberry-staging` shows the container, `/home/docker/loxberry-staging` is gone, container `loxberry` still running.

- [ ] **Step 6: Interrupted run test**

Start `bash build-installed-image.sh`, interrupt it once `loxberry-staging` is running, start it again.
Expected: second run prints that it removes the leftover container and staging data, then continues. Interrupt again and run `cleanup_staging` via `--source-only`.

- [ ] **Step 7: README**

Document: how a deploy works now, the Komodo settings (Pre Deploy `bash build-installed-image.sh`, path `.`; Run Build off; Auto Pull off; `LOXBERRY_HOST_IP`), rollback with `LOXBERRY_IMAGE_TAG`, `docker logs loxberry-staging` after a failed deploy, disk usage. Update the "Surviving redeploys" text that says a redeploy means 10-15 minutes of downtime.

- [ ] **Step 8: Commit**

```bash
git add build-installed-image.sh docker-compose.yml README.md
git commit -m "Build an installed image before switching on deploy"
```

### Task 3: Full build on this host

**Files:** none (verification only)

- [ ] **Step 1: Record the running container**

Run: `docker inspect -f '{{.State.StartedAt}}' loxberry`

- [ ] **Step 2: Full build**

Run: `bash build-installed-image.sh; echo rc=$?` (run in the background, about 15 minutes)
Expected: `rc=0`; `docker images loxberry-docker` shows `base`, `installed` and one date tag; no `loxberry-staging` container; `/home/docker/loxberry-staging` gone; `StartedAt` of `loxberry` unchanged.

- [ ] **Step 3: Inspect the image**

Run: `docker run --rm --entrypoint bash loxberry-docker:installed -c 'test -e /var/lib/loxberry-docker/install-complete && ls /etc/dnsmasq.d && dpkg -l dnsmasq libjson-xs-perl | tail -2'`
Expected: install flag present, `weather4lox.conf` and `00-loxberry-docker.conf` listed, both packages `ii`. `docker image inspect loxberry-docker:installed -f '{{.Config.Env}}'` shows no `LOXBERRY_*` variable.

- [ ] **Step 4: Push and hand over**

`git push`. Give the user the Komodo settings and what to expect in the deploy log, and the rollback steps.

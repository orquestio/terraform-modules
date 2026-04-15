#!/bin/bash
# =============================================================================
# restart.sh — Restart the running OpenClaw container via full RECREATE
#
# Contract:
#   restart.sh
#   exit 0  → container recreated and healthz passing
#   exit !=0 → failure (no container, recreate failed, health check timeout)
#
# Invoked by the Orquestio orchestrator via AWS SSM send_command as root.
# stdout/stderr go to the SSM command invocation output.
#
# Strategy: full `docker stop` + `docker rm` + `docker run`. A plain
# `docker restart` does NOT re-read --env-file, so env vars written to
# /mnt/efs/config/container.env by update_env_var.sh would never become
# visible to the process inside the container. Recreate is the only way to
# re-read the env-file with the Docker CLI.
#
# Image and host port are preserved from the currently-running container
# (detected via `docker inspect`), so a restart never silently changes
# which OpenClaw version is live — only upgrade.sh ever changes the image.
# There is no rolling-replacement here; the ~5-10s downtime between stop
# and the new container passing healthz is the accepted window for an
# explicit operator-triggered restart.
# =============================================================================
set -euo pipefail

CURRENT_NAME="openclaw-current"
CONTAINER_PORT=18789
PORT_A=18789
PORT_B=18790
HEALTH_TIMEOUT_SECONDS=60
EFS_MOUNT="/mnt/efs"
CONTAINER_ENV_FILE="${EFS_MOUNT}/config/container.env"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [restart.sh] $*"; }
err() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [restart.sh] ERROR: $*" >&2; }

log "start"

# Legacy container rename — same idempotency check as upgrade.sh.
if docker inspect openclaw >/dev/null 2>&1 && ! docker inspect "$CURRENT_NAME" >/dev/null 2>&1; then
  log "renaming legacy container 'openclaw' → '$CURRENT_NAME'"
  docker rename openclaw "$CURRENT_NAME"
fi

if ! docker inspect "$CURRENT_NAME" >/dev/null 2>&1; then
  err "no '$CURRENT_NAME' container on this host; cannot restart"
  exit 3
fi

# Find the host port the container exposes so we can preserve it on recreate
# and health-check against it afterwards.
HOST_PORT=$(docker inspect --format \
  "{{(index (index .NetworkSettings.Ports \"${CONTAINER_PORT}/tcp\") 0).HostPort}}" \
  "$CURRENT_NAME" 2>/dev/null || echo "")
case "$HOST_PORT" in
  "$PORT_A"|"$PORT_B") ;;
  *)
    err "unexpected host port '${HOST_PORT}' (expected ${PORT_A} or ${PORT_B})"
    exit 4
    ;;
esac
log "host port: ${HOST_PORT}"

# Discover current image so we recreate on the same version (only upgrade.sh
# ever changes the image).
CURRENT_IMAGE=$(docker inspect --format '{{.Config.Image}}' "$CURRENT_NAME" 2>/dev/null || echo "")
if [ -z "$CURRENT_IMAGE" ]; then
  err "could not read current image of '$CURRENT_NAME'"
  exit 4
fi
log "current image: ${CURRENT_IMAGE}"

# Defensive touch: user_data.sh is supposed to create this file at first boot,
# but legacy instances bootstrapped before this fix may not have it. Without
# the file, `docker run --env-file` errors out.
if [ ! -f "$CONTAINER_ENV_FILE" ]; then
  log "creating missing $CONTAINER_ENV_FILE (legacy instance)"
  touch "$CONTAINER_ENV_FILE"
  chmod 600 "$CONTAINER_ENV_FILE"
fi

# Stop + remove + run. `docker rm -f` would do stop+rm in one call, but we
# separate them so a failure at either stage produces a clear error message.
log "stopping '$CURRENT_NAME'"
if ! docker stop "$CURRENT_NAME" >/dev/null; then
  err "docker stop failed; container still running, aborting without recreate"
  exit 5
fi

log "removing '$CURRENT_NAME'"
if ! docker rm "$CURRENT_NAME" >/dev/null; then
  err "docker rm failed after stop; manual intervention required"
  exit 5
fi

# Recreate. Keep every flag byte-identical to user_data.sh / upgrade.sh step 2
# except that we preserve the current host port (no alternation — only
# upgrade.sh alternates).
log "recreating '$CURRENT_NAME' on host port ${HOST_PORT} with image ${CURRENT_IMAGE}"
if ! docker run -d \
    --name "$CURRENT_NAME" \
    --restart unless-stopped \
    --env-file "$CONTAINER_ENV_FILE" \
    -e HOME=/home/node \
    -e TERM=xterm-256color \
    -e TZ=UTC \
    -v "$EFS_MOUNT/config:/home/node/.openclaw" \
    -v "$EFS_MOUNT/workspace:/home/node/.openclaw/workspace" \
    -p "${HOST_PORT}:${CONTAINER_PORT}" \
    "$CURRENT_IMAGE" \
    node openclaw.mjs gateway --bind lan --port "${CONTAINER_PORT}" \
    >/dev/null; then
  err "docker run failed — container is now MISSING on this host"
  err "image=${CURRENT_IMAGE} host_port=${HOST_PORT}"
  err "manual intervention required: re-run user_data.sh or restart the EC2"
  exit 5
fi

# Wait for healthz with exponential backoff. Same loop shape as upgrade.sh.
log "health-checking at http://127.0.0.1:${HOST_PORT}/healthz (timeout ${HEALTH_TIMEOUT_SECONDS}s)"
deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
delay=1
healthy=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  if curl -sf --max-time 3 "http://127.0.0.1:${HOST_PORT}/healthz" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep "$delay"
  if [ "$delay" -lt 8 ]; then
    delay=$(( delay * 2 ))
  fi
done

if [ "$healthy" -ne 1 ]; then
  err "health check failed within ${HEALTH_TIMEOUT_SECONDS}s after recreate"
  err "container logs (tail 50):"
  docker logs --tail 50 "$CURRENT_NAME" >&2 || true
  exit 6
fi

log "restart complete — ${CURRENT_NAME} healthy on host port ${HOST_PORT}"
exit 0

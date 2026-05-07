#!/bin/bash
# restart.sh — full container RECREATE (stop + rm + run). Plain
# `docker restart` does NOT re-read --env-file, so env vars set by
# update_env_var.sh would never reach the container. Image and host port
# are preserved via docker inspect (only upgrade.sh changes them).
# Invoked by the orchestrator via SSM send_command; stdout/stderr → SSM.
set -euo pipefail

CURRENT_NAME="openclaw-current"
CONTAINER_PORT=18789
PORT_A=18789
PORT_B=18790
HEALTH_TIMEOUT_SECONDS=300
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

# Preserve the current host port on recreate (upgrade.sh alternates, we don't).
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

# Defensive touch for legacy instances bootstrapped before the --env-file fix.
if [ ! -f "$CONTAINER_ENV_FILE" ]; then
  touch "$CONTAINER_ENV_FILE"
  chmod 600 "$CONTAINER_ENV_FILE"
fi

# Defensive mkdir for legacy instances bootstrapped before the
# plugin-runtime-deps local-SSD bind mount was introduced. See user_data.sh
# step 5 and OPENCLAW_AUTH_AND_PROXY.md (issue #1 — cache loop on EFS).
mkdir -p /var/lib/openclaw/plugin-runtime-deps
chown -R 1000:1000 /var/lib/openclaw 2>/dev/null || true

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

# Clear any stale plugin-runtime mirror locks left behind by the previous
# container. A `.openclaw-runtime-mirror.lock` directory inside
# plugin-runtime-deps survives `docker rm` (it lives on the host bind mount)
# and, if not removed, causes OpenClaw to stall during plugin startup —
# /healthz answers but the gateway never finishes wiring up. Targeted removal
# (only the lock dirs) preserves the cached deps that make subsequent boots
# fast; pre_start_wipe.sh is the heavier hammer reserved for watchdog-driven
# recoveries.
log "clearing stale .openclaw-runtime-mirror.lock dirs (if any)"
find /var/lib/openclaw/plugin-runtime-deps \
     -mindepth 1 -maxdepth 6 -type d -name '.openclaw-runtime-mirror.lock' \
     -exec rm -rf {} + 2>/dev/null || true

# Recreate. Flags kept in sync with user_data.sh / upgrade.sh step 2.
# Healthcheck strategy: see user_data.sh. We override the image's baked-in
# healthcheck rather than passing --no-healthcheck, so the watchdog still has
# a Health.Status signal to act on.
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
    -v /var/lib/openclaw/plugin-runtime-deps:/home/node/.openclaw/plugin-runtime-deps \
    --health-cmd "curl -sf --max-time 3 http://127.0.0.1:${CONTAINER_PORT}/healthz || exit 1" \
    --health-interval 30s \
    --health-timeout 5s \
    --health-retries 3 \
    --health-start-period 1200s \
    -p "127.0.0.1:${HOST_PORT}:${CONTAINER_PORT}" \
    "$CURRENT_IMAGE" \
    node openclaw.mjs gateway --bind lan --port "${CONTAINER_PORT}" \
    >/dev/null; then
  err "docker run failed — container is MISSING on this host"
  err "image=${CURRENT_IMAGE} host_port=${HOST_PORT} — manual intervention required"
  exit 5
fi

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

# Wait for the "http server listening" gateway log line. /healthz responds
# before the gateway fully wires up its handlers — accepting connections too
# early can leave WebSocket upgrades returning 1008 for several seconds. The
# `http server listening` line proves the HTTP server (and plugin runtime
# bootstrap) is up and ready to serve. We previously gated on `[gateway]
# ready`, but on this image that line is emitted only after every channel
# and sidecar (browser, etc.) finish, ~85s in — far later than needed for
# routability. CRITICAL: the OpenClaw logger emits ANSI color codes, so we
# must strip them before the grep, otherwise the literal pattern never
# matches and we time out for no reason.
log "waiting for 'http server listening' log line (timeout ${HEALTH_TIMEOUT_SECONDS}s)"
ready_deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
ready=0
while [ "$(date +%s)" -lt "$ready_deadline" ]; do
  if docker logs "$CURRENT_NAME" 2>&1 \
       | sed "s/\x1b\[[0-9;]*m//g" \
       | grep -qE 'http server listening'; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  err "container responded to /healthz but never logged 'http server listening' within ${HEALTH_TIMEOUT_SECONDS}s"
  err "container logs (tail 50):"
  docker logs --tail 50 "$CURRENT_NAME" >&2 || true
  exit 6
fi

log "restart complete — ${CURRENT_NAME} healthy on host port ${HOST_PORT}"
exit 0

#!/bin/bash
# =============================================================================
# restart.sh — Full container RECREATE for Hermes (rm -f + run). Plain
# `docker restart` does NOT re-read --env-file, so env vars applied by
# apply_env_vars.sh would never reach the container.
#
# Contract:
#   restart.sh
#   exit 0  → container recreated on the same image, health confirmed
#   exit 3  → no hermes-current container on this host (nothing to restart)
#   exit 5  → docker run failed (container is MISSING — manual intervention)
#   exit 6  → recreated but never became healthy within the timeout
#
# Invoked by the Orquestio orchestrator via AWS SSM send_command as root.
# stdout/stderr go to the SSM command invocation output.
#
# Hermes runs with --network host (no port mappings to preserve) and a single
# canonical image per instance — only upgrade.sh ever changes the image. The
# host-level iptables IMDS rule persists across container recreate, so this
# script does not need to re-add it.
# =============================================================================
set -euo pipefail

CURRENT_NAME="hermes-current"
EFS_MOUNT="/mnt/efs"
CONTAINER_ENV_FILE="${EFS_MOUNT}/config/container.env"
DASHBOARD_LOGIN_URL="http://127.0.0.1:9119/login"
HEALTH_TIMEOUT_SECONDS=120

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [restart.sh] $*"; }
err() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [restart.sh] ERROR: $*" >&2; }

log "start"

# Discover the current image BEFORE removing anything — we recreate on the
# exact same version.
IMAGE=$(docker inspect --format '{{.Config.Image}}' "$CURRENT_NAME" 2>/dev/null || echo "")
if [ -z "$IMAGE" ]; then
  err "no '$CURRENT_NAME' container on this host; cannot restart"
  exit 3
fi
log "current image: ${IMAGE}"

# Defensive touch for hosts bootstrapped without the env file.
if [ ! -f "$CONTAINER_ENV_FILE" ]; then
  mkdir -p "$(dirname "$CONTAINER_ENV_FILE")"
  touch "$CONTAINER_ENV_FILE"
  chmod 600 "$CONTAINER_ENV_FILE"
fi

log "removing '$CURRENT_NAME'"
docker rm -f "$CURRENT_NAME" >/dev/null 2>&1 || true

# Canonical Hermes docker run — keep in sync with user_data.sh / upgrade.sh.
log "recreating '$CURRENT_NAME' with image ${IMAGE}"
if ! docker run -d \
    --name "$CURRENT_NAME" \
    --restart unless-stopped \
    --network host \
    --env-file "$CONTAINER_ENV_FILE" \
    -e TZ=UTC \
    -v "${EFS_MOUNT}/config:/opt/data" \
    --health-cmd "curl -sf --max-time 3 http://127.0.0.1:8642/health || exit 1" \
    --health-interval 30s --health-timeout 5s --health-retries 3 --health-start-period 1200s \
    "$IMAGE" \
    gateway run \
    >/dev/null; then
  err "docker run failed — container is MISSING on this host"
  err "image=${IMAGE} — manual intervention required"
  exit 5
fi

# Health wait: accept EITHER Docker's health status flipping to "healthy"
# (the --health-cmd probes the health API on :8642) OR an HTTP 200/302 from
# the dashboard on loopback :9119 — whichever comes first.
log "waiting for health (docker Health.Status or ${DASHBOARD_LOGIN_URL}; timeout ${HEALTH_TIMEOUT_SECONDS}s)"
deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
healthy=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  status=$(docker inspect --format '{{.State.Health.Status}}' "$CURRENT_NAME" 2>/dev/null || echo "unknown")
  if [ "$status" = "healthy" ]; then
    healthy=1
    break
  fi
  http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$DASHBOARD_LOGIN_URL" || echo "000")
  case "$http_code" in
    200|302)
      healthy=1
      break
      ;;
  esac
  sleep 2
done

if [ "$healthy" -ne 1 ]; then
  err "container never became healthy within ${HEALTH_TIMEOUT_SECONDS}s"
  err "container logs (tail 50):"
  docker logs --tail 50 "$CURRENT_NAME" >&2 || true
  exit 6
fi

log "restart complete — ${CURRENT_NAME} healthy on image ${IMAGE}"
exit 0

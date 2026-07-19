#!/bin/bash
# =============================================================================
# upgrade.sh — Stop/replace upgrade for Hermes on Orquestio EC2 clients
#
# Contract:
#   upgrade.sh <target_version>        (e.g. v2026.7.7.2 or v2026.7.7)
#   exit 0  → upgrade OK (or already on target_version)
#   exit 2  → missing/invalid target_version
#   exit 3  → no hermes-current container on this host
#   exit 5  → docker pull failed (no changes made)
#   exit 6  → new image never became healthy; rolled back to previous image
#   exit 7  → new image failed AND rollback also failed (container down)
#
# Invoked by the Orquestio orchestrator via AWS SSM send_command as root.
# stdout/stderr go to the SSM command invocation output.
#
# Strategy: Hermes has NO blue/green — the container runs with --network host,
# so old and new cannot overlap on the same ports. This is a stop/replace
# window (acceptable for a starter product). On health failure we roll back to
# the previous image (captured before the pull).
# =============================================================================
set -euo pipefail

TARGET_VERSION="${1:-}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [upgrade.sh] $*"; }
err() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [upgrade.sh] ERROR: $*" >&2; }

if [ -z "$TARGET_VERSION" ]; then
  err "missing target_version argument"
  err "usage: upgrade.sh <target_version>   (e.g. v2026.7.7.2)"
  exit 2
fi
# Accept 3 OR 4 dotted components: vYYYY.M.D or vYYYY.M.D.N
if ! [[ "$TARGET_VERSION" =~ ^v[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}(\.[0-9]+)?$ ]]; then
  err "invalid target_version '${TARGET_VERSION}' (expected e.g. v2026.7.7 or v2026.7.7.2)"
  exit 2
fi

IMAGE_REPO="nousresearch/hermes-agent"
TARGET_IMAGE="${IMAGE_REPO}:${TARGET_VERSION}"
CURRENT_NAME="hermes-current"
EFS_MOUNT="/mnt/efs"
CONTAINER_ENV_FILE="${EFS_MOUNT}/config/container.env"
DASHBOARD_LOGIN_URL="http://127.0.0.1:9119/login"
HEALTH_TIMEOUT_SECONDS=120

log "start — target_version=${TARGET_VERSION}"

if ! docker inspect "$CURRENT_NAME" >/dev/null 2>&1; then
  err "no '$CURRENT_NAME' container on this host; cannot upgrade a missing product"
  exit 3
fi

# ---------- idempotency: already on target_version? ----------
PREVIOUS_IMAGE=$(docker inspect --format '{{.Config.Image}}' "$CURRENT_NAME" 2>/dev/null || echo "")
log "current image: ${PREVIOUS_IMAGE}"
if [ "$PREVIOUS_IMAGE" = "$TARGET_IMAGE" ]; then
  log "already on ${TARGET_IMAGE}, nothing to do"
  exit 0
fi

# ---------- helpers ----------
# Canonical Hermes docker run — keep in sync with user_data.sh / restart.sh.
run_hermes() {
  local image="$1"
  docker run -d \
    --name "$CURRENT_NAME" \
    --restart unless-stopped \
    --network host \
    --env-file "$CONTAINER_ENV_FILE" \
    -e TZ=UTC \
    -v "${EFS_MOUNT}/config:/opt/data" \
    --health-cmd "curl -sf --max-time 3 http://127.0.0.1:8642/health || exit 1" \
    --health-interval 30s --health-timeout 5s --health-retries 3 --health-start-period 1200s \
    "$image" \
    gateway run \
    >/dev/null
}

# Returns 0 once docker health flips to "healthy" OR the dashboard answers
# 200/302 on loopback — whichever comes first.
wait_healthy() {
  local deadline status http_code
  deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    status=$(docker inspect --format '{{.State.Health.Status}}' "$CURRENT_NAME" 2>/dev/null || echo "unknown")
    if [ "$status" = "healthy" ]; then
      return 0
    fi
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$DASHBOARD_LOGIN_URL" || echo "000")
    case "$http_code" in
      200|302) return 0 ;;
    esac
    sleep 2
  done
  return 1
}

# ---------- step 1: pull target image (before touching the container) ----------
log "pulling ${TARGET_IMAGE}"
if ! docker pull "$TARGET_IMAGE"; then
  err "docker pull failed for ${TARGET_IMAGE}; aborting without changes"
  err "old container '$CURRENT_NAME' remains active and serving traffic"
  exit 5
fi

# ---------- step 2: stop/replace ----------
log "removing '$CURRENT_NAME' (stop/replace window begins)"
docker rm -f "$CURRENT_NAME" >/dev/null 2>&1 || true

log "starting '$CURRENT_NAME' on ${TARGET_IMAGE}"
new_started=1
if ! run_hermes "$TARGET_IMAGE"; then
  err "docker run failed for ${TARGET_IMAGE}"
  new_started=0
fi

# ---------- step 3: health check, roll back on failure ----------
if [ "$new_started" -eq 1 ]; then
  log "waiting for health (timeout ${HEALTH_TIMEOUT_SECONDS}s)"
  if wait_healthy; then
    log "upgrade complete — ${CURRENT_NAME} healthy on ${TARGET_IMAGE}"
    exit 0
  fi
  err "new container never became healthy within ${HEALTH_TIMEOUT_SECONDS}s"
  err "container logs (tail 50):"
  docker logs --tail 50 "$CURRENT_NAME" >&2 || true
fi

# ---------- rollback ----------
err "rolling back to previous image ${PREVIOUS_IMAGE}"
docker rm -f "$CURRENT_NAME" >/dev/null 2>&1 || true
if ! run_hermes "$PREVIOUS_IMAGE"; then
  err "ROLLBACK FAILED — docker run failed for ${PREVIOUS_IMAGE}; container is DOWN"
  err "manual intervention required"
  exit 7
fi
if wait_healthy; then
  err "rollback succeeded — ${CURRENT_NAME} healthy again on ${PREVIOUS_IMAGE}"
else
  err "rollback container started but did not confirm healthy within ${HEALTH_TIMEOUT_SECONDS}s"
  err "container logs (tail 50):"
  docker logs --tail 50 "$CURRENT_NAME" >&2 || true
fi
exit 6

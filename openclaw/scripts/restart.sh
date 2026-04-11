#!/bin/bash
# =============================================================================
# restart.sh — Restart the running OpenClaw container
#
# Contract:
#   restart.sh
#   exit 0  → container restarted and healthz passing
#   exit !=0 → failure (no container, restart failed, health check timeout)
#
# Invoked by the Orquestio orchestrator via AWS SSM send_command as root.
# stdout/stderr go to the SSM command invocation output.
#
# Strategy: `docker restart` is a hard restart of the existing container.
# OpenClaw has no drain endpoint, so requests in flight at the moment of
# restart are dropped. This is a ~5-10s downtime window — acceptable for an
# explicit operator-triggered restart. There is NO rolling-replacement here;
# use upgrade.sh if you need zero-downtime semantics.
# =============================================================================
set -euo pipefail

CURRENT_NAME="openclaw-current"
CONTAINER_PORT=18789
PORT_A=18789
PORT_B=18790
HEALTH_TIMEOUT_SECONDS=60

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

# Find the host port the container exposes so we can health check on it.
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

log "docker restart ${CURRENT_NAME}"
if ! docker restart "$CURRENT_NAME" >/dev/null; then
  err "docker restart failed"
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
  err "health check failed within ${HEALTH_TIMEOUT_SECONDS}s after restart"
  err "container logs (tail 50):"
  docker logs --tail 50 "$CURRENT_NAME" >&2 || true
  exit 6
fi

log "restart complete — ${CURRENT_NAME} healthy on host port ${HOST_PORT}"
exit 0

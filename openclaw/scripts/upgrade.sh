#!/bin/bash
# =============================================================================
# upgrade.sh — Rolling replacement upgrade for OpenClaw on Orquestio EC2 clients
#
# Contract:
#   upgrade.sh <target_version>
#   exit 0  → upgrade OK (or already on target_version)
#   exit !=0 → failure, stderr contains human-readable reason; old container
#              keeps serving traffic in any pre-switch failure path.
#
# Invoked by the Orquestio orchestrator via AWS SSM send_command as root. SSM
# captures stdout/stderr into the command invocation output, so this script
# logs to stdout/stderr only (no /var/log writes).
#
# Strategy: rolling replacement with Nginx upstream switch + cooldown.
# OpenClaw does not expose a drain endpoint (see notas_drain.md); instead we
# overlap old and new containers on different host ports and switch Nginx's
# upstream via hot reload. A 30s cooldown lets in-flight requests on the old
# container terminate naturally before it is removed.
#
# Port allocation approach: ALTERNATING PORTS. The current container binds
# either host port 18789 or 18790. The new container takes the other one. The
# upstream file is rewritten to point at whichever the new container owns, and
# the container survives with its "non-canonical" port mapping for the lifetime
# of that version — next upgrade will flip back. This keeps the script simple,
# idempotent, and avoids a second recreate to "normalize" the port (which would
# double the downtime window).
# =============================================================================
set -euo pipefail

# ---------- args & constants ----------
TARGET_VERSION="${1:-}"
if [ -z "$TARGET_VERSION" ]; then
  echo "ERROR: missing target_version argument" >&2
  echo "usage: upgrade.sh <target_version>" >&2
  exit 2
fi

IMAGE_REPO="odoopartners/openclaw"
TARGET_IMAGE="${IMAGE_REPO}:${TARGET_VERSION}"
CURRENT_NAME="openclaw-current"
NEW_NAME="openclaw-new"
CONTAINER_PORT=18789
PORT_A=18789
PORT_B=18790
UPSTREAM_CONF="/etc/nginx/conf.d/openclaw-upstream.conf"
COOLDOWN_SECONDS=30
HEALTH_TIMEOUT_SECONDS=60
EFS_MOUNT="/mnt/efs"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [upgrade.sh] $*"; }
err() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [upgrade.sh] ERROR: $*" >&2; }

log "start — target_version=${TARGET_VERSION}"

# ---------- legacy container rename ----------
# Instances provisioned before Fase 4 Sprint 2 may have a container named
# "openclaw" instead of "openclaw-current". Rename it so the rest of this
# script uses a stable name.
if docker inspect openclaw >/dev/null 2>&1 && ! docker inspect "$CURRENT_NAME" >/dev/null 2>&1; then
  log "renaming legacy container 'openclaw' → '$CURRENT_NAME'"
  docker rename openclaw "$CURRENT_NAME"
fi

if ! docker inspect "$CURRENT_NAME" >/dev/null 2>&1; then
  err "no '$CURRENT_NAME' container on this host; cannot upgrade a missing product"
  exit 3
fi

# ---------- idempotency: already on target_version? ----------
CURRENT_IMAGE=$(docker inspect --format '{{.Config.Image}}' "$CURRENT_NAME" 2>/dev/null || echo "")
log "current image: ${CURRENT_IMAGE}"
if [ "$CURRENT_IMAGE" = "$TARGET_IMAGE" ]; then
  log "already on ${TARGET_IMAGE}, nothing to do"
  exit 0
fi

# ---------- determine current host port (for alternation) ----------
# Inspect the published host port mapping of the running container. We expect
# exactly one of PORT_A / PORT_B. If neither matches we bail — something manual
# happened on the host and we won't make it worse.
CURRENT_HOST_PORT=$(docker inspect --format \
  "{{(index (index .NetworkSettings.Ports \"${CONTAINER_PORT}/tcp\") 0).HostPort}}" \
  "$CURRENT_NAME" 2>/dev/null || echo "")
log "current host port: ${CURRENT_HOST_PORT}"

case "$CURRENT_HOST_PORT" in
  "$PORT_A") NEW_HOST_PORT="$PORT_B" ;;
  "$PORT_B") NEW_HOST_PORT="$PORT_A" ;;
  *)
    err "unexpected current host port '${CURRENT_HOST_PORT}' (expected ${PORT_A} or ${PORT_B})"
    exit 4
    ;;
esac
log "new host port will be: ${NEW_HOST_PORT}"

# ---------- step 1: pull target image ----------
log "pulling ${TARGET_IMAGE}"
if ! docker pull "$TARGET_IMAGE"; then
  err "docker pull failed for ${TARGET_IMAGE}; aborting without changes"
  exit 5
fi

# ---------- safety: remove any stale openclaw-new ----------
if docker inspect "$NEW_NAME" >/dev/null 2>&1; then
  log "removing stale container '$NEW_NAME' left over from a previous run"
  docker rm -f "$NEW_NAME" >/dev/null
fi

# ---------- step 2: start new container on the lateral port ----------
# Replicate the runtime config of openclaw-current. We reuse the same env vars,
# volumes, restart policy and command. Only the host port and the container
# name change.
#
# --env-file "$CONTAINER_ENV_FILE": runtime env vars set by update_env_var.sh.
# Must match the flag used in user_data.sh and restart.sh. user_data.sh creates
# the file on first boot; we `touch` it here defensively in case that step was
# ever skipped (legacy instances, repaired bootstrap).
CONTAINER_ENV_FILE="$EFS_MOUNT/config/container.env"
if [ ! -f "$CONTAINER_ENV_FILE" ]; then
  touch "$CONTAINER_ENV_FILE"
  chmod 600 "$CONTAINER_ENV_FILE"
fi

log "starting '$NEW_NAME' on host port ${NEW_HOST_PORT}"
docker run -d \
  --name "$NEW_NAME" \
  --restart unless-stopped \
  --env-file "$CONTAINER_ENV_FILE" \
  -e HOME=/home/node \
  -e TERM=xterm-256color \
  -e TZ=UTC \
  -v "$EFS_MOUNT/config:/home/node/.openclaw" \
  -v "$EFS_MOUNT/workspace:/home/node/.openclaw/workspace" \
  -p "${NEW_HOST_PORT}:${CONTAINER_PORT}" \
  "$TARGET_IMAGE" \
  node openclaw.mjs gateway --bind lan --port "${CONTAINER_PORT}" \
  >/dev/null

# ---------- step 3: health check with exponential backoff ----------
log "health-checking new container at http://127.0.0.1:${NEW_HOST_PORT}/healthz (timeout ${HEALTH_TIMEOUT_SECONDS}s)"
deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
delay=1
healthy=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  if curl -sf --max-time 3 "http://127.0.0.1:${NEW_HOST_PORT}/healthz" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep "$delay"
  if [ "$delay" -lt 8 ]; then
    delay=$(( delay * 2 ))
  fi
done

if [ "$healthy" -ne 1 ]; then
  err "health check failed for '$NEW_NAME' within ${HEALTH_TIMEOUT_SECONDS}s"
  err "container logs (tail 50):"
  docker logs --tail 50 "$NEW_NAME" >&2 || true
  docker stop "$NEW_NAME" >/dev/null 2>&1 || true
  docker rm   "$NEW_NAME" >/dev/null 2>&1 || true
  err "old container '$CURRENT_NAME' remains active and serving traffic"
  exit 6
fi
log "new container is healthy"

# ---------- step 4: switch Nginx upstream to the new port ----------
log "rewriting ${UPSTREAM_CONF} → 127.0.0.1:${NEW_HOST_PORT}"
cat > "$UPSTREAM_CONF" <<NGINX_UPSTREAM
# Managed by /opt/openclaw/scripts/upgrade.sh — do not edit by hand.
upstream openclaw_backend {
    server 127.0.0.1:${NEW_HOST_PORT};
}
NGINX_UPSTREAM

if ! nginx -t >/dev/null 2>&1; then
  err "nginx -t failed after upstream rewrite; rolling back upstream file"
  cat > "$UPSTREAM_CONF" <<NGINX_ROLLBACK
# Managed by /opt/openclaw/scripts/upgrade.sh — do not edit by hand.
upstream openclaw_backend {
    server 127.0.0.1:${CURRENT_HOST_PORT};
}
NGINX_ROLLBACK
  docker stop "$NEW_NAME" >/dev/null 2>&1 || true
  docker rm   "$NEW_NAME" >/dev/null 2>&1 || true
  exit 7
fi

log "nginx -s reload (hot reload, keeps established connections)"
nginx -s reload

# ---------- step 5: cooldown ----------
# Trade-off acknowledged in notas_drain.md: the ~100ms between reload and full
# worker propagation may drop a handful of in-flight requests routed to the old
# container. We do NOT try to close that window because OpenClaw has no drain
# endpoint to make it deterministic.
log "cooldown ${COOLDOWN_SECONDS}s — letting in-flight requests on old container finish"
sleep "$COOLDOWN_SECONDS"

# ---------- step 6: cleanup old container ----------
log "stopping + removing old container '$CURRENT_NAME'"
docker stop "$CURRENT_NAME" >/dev/null
docker rm   "$CURRENT_NAME" >/dev/null

# ---------- step 7: rename new → current ----------
log "renaming '$NEW_NAME' → '$CURRENT_NAME' (now serving on host port ${NEW_HOST_PORT})"
docker rename "$NEW_NAME" "$CURRENT_NAME"

# NOTE: we deliberately do NOT recreate the container to put it back on the
# "canonical" port 18789. Alternating ports between upgrades is simpler, adds
# zero extra downtime, and keeps this script idempotent: the only invariant is
# that the upstream file and the running container's published port agree,
# which they now do.

log "upgrade complete — ${CURRENT_NAME} on ${TARGET_IMAGE} at host port ${NEW_HOST_PORT}"
exit 0

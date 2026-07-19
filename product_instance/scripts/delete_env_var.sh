#!/bin/bash
# =============================================================================
# delete_env_var.sh — Remove an env var from the OpenClaw container
#
# Contract:
#   delete_env_var.sh <name>
#     name: env var name (must match ^[A-Z_][A-Z0-9_]*$ — POSIX env var rules)
#   exit 0  → env var removed (or already absent), container restarted, healthz passing
#   exit !=0 → failure (bad name, missing container, restart failed, etc.)
#
# Idempotent: deleting a non-existent var is a no-op (exit 0).
# Strategy mirrors update_env_var.sh: rewrite container.env on EFS, then
# restart.sh recreates the container so --env-file is re-read.
# =============================================================================
set -euo pipefail

NAME="${1:-}"

if [ -z "$NAME" ]; then
  echo "ERROR: missing name argument" >&2
  echo "usage: delete_env_var.sh <name>" >&2
  exit 2
fi

if ! [[ "$NAME" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
  echo "ERROR: invalid env var name '${NAME}' (must match ^[A-Z_][A-Z0-9_]*$)" >&2
  exit 2
fi

CURRENT_NAME="openclaw-current"
EFS_MOUNT="/mnt/efs"
CONTAINER_ENV_FILE="${EFS_MOUNT}/config/container.env"
SCRIPTS_DIR="/opt/openclaw/scripts"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [delete_env_var.sh] $*"; }
err() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [delete_env_var.sh] ERROR: $*" >&2; }

log "start (name=${NAME})"

if ! docker inspect "$CURRENT_NAME" >/dev/null 2>&1; then
  err "no '$CURRENT_NAME' container on this host; cannot delete env var"
  exit 3
fi

if [ ! -f "$CONTAINER_ENV_FILE" ]; then
  log "container.env does not exist — nothing to delete (idempotent no-op)"
  exit 0
fi

# Detect whether NAME is actually present so we can log honestly and skip the
# restart when there is nothing to propagate.
if ! grep -q "^${NAME}=" "$CONTAINER_ENV_FILE"; then
  log "${NAME} not present in ${CONTAINER_ENV_FILE} — nothing to delete (idempotent no-op)"
  exit 0
fi

TMP_ENV=$(mktemp)
trap 'rm -f "$TMP_ENV"' EXIT
grep -v "^${NAME}=" "$CONTAINER_ENV_FILE" > "$TMP_ENV" || true
mv "$TMP_ENV" "$CONTAINER_ENV_FILE"
trap - EXIT
chmod 600 "$CONTAINER_ENV_FILE"
log "removed ${NAME} from ${CONTAINER_ENV_FILE}"

log "restarting container so env var removal takes effect"
if ! bash "${SCRIPTS_DIR}/restart.sh"; then
  err "restart.sh failed after env var delete; the file IS already updated"
  err "next manual restart will pick up the removal"
  exit 5
fi

log "delete_env_var complete"
exit 0

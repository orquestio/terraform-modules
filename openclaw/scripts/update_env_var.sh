#!/bin/bash
# =============================================================================
# update_env_var.sh — Set or update an env var on the OpenClaw container
#
# Contract:
#   update_env_var.sh <name> <value> [is_secret]
#     name: env var name (must match ^[A-Z_][A-Z0-9_]*$ — POSIX env var rules)
#     value: arbitrary string. May contain spaces if quoted by the caller.
#     is_secret: optional, "true" or "false" (default false). When true the
#                value is masked in the script's log output. The container
#                env file always lives at 0600 regardless of this flag.
#   exit 0  → env var written, container restarted, healthz passing
#   exit !=0 → failure (bad name, missing container, restart failed, etc.)
#
# Strategy: write env file on EFS, then restart.sh propagates. Requires
# restart.sh to do a full RECREATE (docker rm + run) — plain `docker
# restart` does NOT re-read --env-file and this script becomes a no-op.
# =============================================================================
set -euo pipefail

NAME="${1:-}"
VALUE="${2:-}"
IS_SECRET="${3:-false}"

if [ -z "$NAME" ]; then
  echo "ERROR: missing name argument" >&2
  echo "usage: update_env_var.sh <name> <value> [is_secret]" >&2
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

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [update_env_var.sh] $*"; }
err() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [update_env_var.sh] ERROR: $*" >&2; }

if [ "$IS_SECRET" = "true" ]; then
  log "start (name=${NAME}, value=<masked>)"
else
  log "start (name=${NAME}, value=${VALUE})"
fi

if ! docker inspect "$CURRENT_NAME" >/dev/null 2>&1; then
  err "no '$CURRENT_NAME' container on this host; cannot update env var"
  exit 3
fi

mkdir -p "$(dirname "$CONTAINER_ENV_FILE")"

TMP_ENV=$(mktemp)
trap 'rm -f "$TMP_ENV"' EXIT
if [ -f "$CONTAINER_ENV_FILE" ]; then
  grep -v "^${NAME}=" "$CONTAINER_ENV_FILE" > "$TMP_ENV" || true
fi
echo "${NAME}=${VALUE}" >> "$TMP_ENV"
mv "$TMP_ENV" "$CONTAINER_ENV_FILE"
trap - EXIT
chmod 600 "$CONTAINER_ENV_FILE"
log "wrote ${NAME} to ${CONTAINER_ENV_FILE}"

log "restarting container so new env var takes effect"
if ! bash "${SCRIPTS_DIR}/restart.sh"; then
  err "restart.sh failed after env var update; the file IS already updated"
  err "next manual restart will pick up the new value"
  exit 5
fi

log "update_env_var complete"
exit 0

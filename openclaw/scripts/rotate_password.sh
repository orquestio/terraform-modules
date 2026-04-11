#!/bin/bash
# =============================================================================
# rotate_password.sh — Rotate the OpenClaw gateway password
#
# Contract:
#   rotate_password.sh [notify_client]
#     notify_client: optional, "true" or "false" (default false). Reserved for
#                    a future webhook hook — currently the script accepts and
#                    ignores it so the wizard can pass the parameter cleanly.
#   exit 0  → password rotated, AWS Secrets Manager updated, container restarted
#   exit !=0 → failure (no container, secrets put failed, restart failed, etc.)
#
# Strategy: generate a new 32-byte hex password, write it to the gateway env
# file on EFS so the container picks it up at restart, push the new value to
# AWS Secrets Manager (so Orquestio's portal can show it to the client), then
# restart the container so the new password becomes effective. Restart goes
# through restart.sh to keep the health-check + log-tail behavior consistent.
#
# The previous password is NOT preserved — rotation is one-way. Clients with
# active gateway sessions need to re-authenticate.
# =============================================================================
set -euo pipefail

NOTIFY_CLIENT="${1:-false}"

CURRENT_NAME="openclaw-current"
EFS_MOUNT="/mnt/efs"
GATEWAY_ENV_FILE="${EFS_MOUNT}/config/gateway.env"
INSTANCE_ID_FILE="/opt/openclaw/instance_id"
SCRIPTS_DIR="/opt/openclaw/scripts"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [rotate_password.sh] $*"; }
err() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [rotate_password.sh] ERROR: $*" >&2; }

log "start (notify_client=${NOTIFY_CLIENT})"

if ! docker inspect "$CURRENT_NAME" >/dev/null 2>&1; then
  err "no '$CURRENT_NAME' container on this host; cannot rotate password"
  exit 3
fi

if [ ! -f "$INSTANCE_ID_FILE" ]; then
  err "instance_id marker not found at $INSTANCE_ID_FILE"
  exit 4
fi
INSTANCE_ID=$(cat "$INSTANCE_ID_FILE")
log "instance_id: ${INSTANCE_ID}"

NEW_PASSWORD=$(openssl rand -hex 32)
log "generated new gateway password (32 bytes hex)"

mkdir -p "$(dirname "$GATEWAY_ENV_FILE")"
TMP_ENV=$(mktemp)
trap 'rm -f "$TMP_ENV"' EXIT
if [ -f "$GATEWAY_ENV_FILE" ]; then
  grep -v '^OPENCLAW_GATEWAY_PASSWORD=' "$GATEWAY_ENV_FILE" > "$TMP_ENV" || true
fi
echo "OPENCLAW_GATEWAY_PASSWORD=${NEW_PASSWORD}" >> "$TMP_ENV"
mv "$TMP_ENV" "$GATEWAY_ENV_FILE"
trap - EXIT
chmod 600 "$GATEWAY_ENV_FILE"
log "wrote new password to ${GATEWAY_ENV_FILE}"

SECRET_NAME="orquestio/instances/${INSTANCE_ID}/gateway-password"
log "updating Secrets Manager: ${SECRET_NAME}"
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME" \
    --secret-string "$NEW_PASSWORD" >/dev/null
else
  aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --secret-string "$NEW_PASSWORD" \
    --tags Key=Project,Value=orquestio Key=InstanceId,Value="$INSTANCE_ID" >/dev/null
fi
log "Secrets Manager updated"

log "restarting container so new password takes effect"
if ! bash "${SCRIPTS_DIR}/restart.sh"; then
  err "restart.sh failed after password rotation; password file IS already updated"
  err "next manual restart will pick up the new password"
  exit 5
fi

if [ "$NOTIFY_CLIENT" = "true" ]; then
  log "notify_client=true requested but webhook hook is not yet implemented"
  log "(reserved for future iteration; rotation itself succeeded)"
fi

log "rotate_password complete"
exit 0

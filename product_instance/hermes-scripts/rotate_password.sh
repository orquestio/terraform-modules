#!/bin/bash
# =============================================================================
# rotate_password.sh — Rotate the Hermes gateway (login-wall) password
#
# Contract:
#   rotate_password.sh [notify_client]
#     notify_client: optional, "true" or "false" (default false). Reserved for
#                    a future webhook hook — currently accepted and ignored.
#   exit 0  → new password in AWS Secrets Manager, nginx cookie map updated,
#             nginx reloaded.
#   exit !=0 → failure.
#
# Hermes has NO native login and NO config-file token — the nginx cookie wall
# is the ONLY auth layer, so the password lives in exactly TWO places:
#   1. /etc/nginx/conf.d/gateway-auth.conf → $cookie_oc_session map compares
#      the cookie against SHA-256(password). Reload propagates the new hash
#      without dropping connections.
#   2. AWS Secrets Manager "orquestio/instances/<id>/gateway-password" →
#      the Orquestio portal reads this to mint handoff cookies / display the
#      password to the client.
# The container does NOT read the wall password — NO container recreate is
# needed. Rotating invalidates every existing oc_session cookie (they hash to
# the old value); the portal handoff mints new cookies from the new SM value.
# =============================================================================
set -euo pipefail

NOTIFY_CLIENT="${1:-false}"

INSTANCE_ID_FILE="/opt/hermes/instance_id"
NGINX_AUTH_CONF="/etc/nginx/conf.d/gateway-auth.conf"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [rotate_password.sh] $*"; }
err() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [rotate_password.sh] ERROR: $*" >&2; }

log "start (notify_client=${NOTIFY_CLIENT})"

if [ ! -f "$INSTANCE_ID_FILE" ]; then
  err "instance_id marker not found at $INSTANCE_ID_FILE"
  exit 4
fi
INSTANCE_ID=$(cat "$INSTANCE_ID_FILE")
log "instance_id: ${INSTANCE_ID}"

NEW_PASSWORD=$(openssl rand -hex 24)
log "generated new gateway password (24 bytes hex)"
NEW_HASH=$(echo -n "${NEW_PASSWORD}" | sha256sum | cut -d' ' -f1)

# --- 1. AWS Secrets Manager (portal reads this to mint handoff cookies) ---
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

# --- 2. nginx cookie map — ONLY $auth_ok for Hermes (no token injection
#        maps; Hermes has no bearer token to inject) ---
mkdir -p "$(dirname "$NGINX_AUTH_CONF")"
cat > "$NGINX_AUTH_CONF" <<NGINXCONF
# Managed by rotate_password.sh — do not edit by hand.
# Cookie oc_session value = SHA-256(gateway password).
map \$cookie_oc_session \$auth_ok {
    "${NEW_HASH}" "yes";
    default "no";
}
NGINXCONF
log "wrote ${NGINX_AUTH_CONF}"

# --- 3. reload nginx so the new hash takes effect ---
if ! nginx -t >/dev/null 2>&1; then
  err "nginx -t failed after writing gateway-auth.conf; aborting before reload"
  exit 6
fi
systemctl reload nginx
log "nginx reloaded — all existing oc_session cookies are now invalid"

# NO container recreate: the Hermes container does not read the wall password.

if [ "$NOTIFY_CLIENT" = "true" ]; then
  log "notify_client=true requested but webhook hook is not yet implemented"
fi

log "rotate_password complete"
exit 0

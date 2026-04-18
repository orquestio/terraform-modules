#!/bin/bash
# =============================================================================
# rotate_password.sh — Rotate the OpenClaw gateway password end-to-end
#
# Contract:
#   rotate_password.sh [notify_client]
#     notify_client: optional, "true" or "false" (default false). Reserved for
#                    a future webhook hook — currently accepted and ignored.
#   exit 0  → password rotated, container.env updated, nginx cookie map
#             updated, openclaw.json updated, AWS Secrets Manager updated,
#             container recreated, nginx reloaded.
#   exit !=0 → failure.
#
# Why the full sync matters (Fase 5 bug postmortem 2026-04-15):
#   The gateway password exists in FOUR places that MUST stay aligned:
#     1. OPENCLAW_GATEWAY_PASSWORD + OPENCLAW_GATEWAY_TOKEN in
#        /mnt/efs/config/container.env → read by the container at `docker run`
#        (via --env-file in restart.sh). Both hold the same value.
#     2. openclaw.json → "gateway.auth.token" → read by OpenClaw core at
#        startup. Must match OPENCLAW_GATEWAY_TOKEN env var.
#     3. /etc/nginx/conf.d/gateway-auth.conf → nginx cookie_oc_session map →
#        the Orquestio login wall hashes the cookie and compares against
#        SHA-256(password). Nginx reload propagates new hash without dropping
#        connections.
#     4. AWS Secrets Manager at "orquestio/instances/<id>/gateway-password"
#        → Orquestio portal reads this to display the password to the client.
# =============================================================================
set -euo pipefail

NOTIFY_CLIENT="${1:-false}"

CURRENT_NAME="openclaw-current"
EFS_MOUNT="/mnt/efs"
CONTAINER_ENV_FILE="${EFS_MOUNT}/config/container.env"
OPENCLAW_CONFIG="${EFS_MOUNT}/config/openclaw.json"
INSTANCE_ID_FILE="/opt/openclaw/instance_id"
SCRIPTS_DIR="/opt/openclaw/scripts"
NGINX_AUTH_CONF="/etc/nginx/conf.d/gateway-auth.conf"

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

NEW_PASSWORD=$(openssl rand -hex 24)
log "generated new gateway password (24 bytes hex)"
NEW_HASH=$(echo -n "${NEW_PASSWORD}" | sha256sum | cut -d' ' -f1)

# --- 1. container.env (env for docker run) ---
mkdir -p "$(dirname "$CONTAINER_ENV_FILE")"
TMP_ENV=$(mktemp)
trap 'rm -f "$TMP_ENV"' EXIT
if [ -f "$CONTAINER_ENV_FILE" ]; then
  grep -v '^OPENCLAW_GATEWAY_PASSWORD=' "$CONTAINER_ENV_FILE" | grep -v '^OPENCLAW_GATEWAY_TOKEN=' > "$TMP_ENV" || true
fi
echo "OPENCLAW_GATEWAY_PASSWORD=${NEW_PASSWORD}" >> "$TMP_ENV"
echo "OPENCLAW_GATEWAY_TOKEN=${NEW_PASSWORD}" >> "$TMP_ENV"
mv "$TMP_ENV" "$CONTAINER_ENV_FILE"
trap - EXIT
chmod 600 "$CONTAINER_ENV_FILE"
log "updated ${CONTAINER_ENV_FILE}"

# --- 2. openclaw.json (config-file password — keep aligned with env) ---
if [ -f "$OPENCLAW_CONFIG" ]; then
  export OPENCLAW_CONFIG NEW_PASSWORD
  python3 <<'PYEOF'
import json, os, shutil
path = os.environ["OPENCLAW_CONFIG"]
pw = os.environ["NEW_PASSWORD"]
with open(path) as f:
    cfg = json.load(f)
shutil.copy2(path, path + ".bak.rotate")
gw = cfg.setdefault("gateway", {})
auth = gw.setdefault("auth", {})
# Token mode: OpenClaw validates the token for all requests (including
# internal cron/exec loopback). The nginx cookie wall remains as the
# user-facing login layer.
auth["mode"] = "token"
auth["token"] = pw
# Remove legacy trusted-proxy fields
auth.pop("password", None)
auth.pop("trustedProxy", None)
# Disable device pairing (stateless token auth is sufficient)
cui = gw.setdefault("controlUi", {})
cui["dangerouslyDisableDeviceAuth"] = True
cui["dangerouslyAllowHostHeaderOriginFallback"] = True
cfg["gateway"]["auth"] = auth
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
os.chown(path, 1000, 1000)
PYEOF
  log "updated ${OPENCLAW_CONFIG} gateway.auth.token"
fi

# --- 3. nginx cookie map ---
mkdir -p "$(dirname "$NGINX_AUTH_CONF")"
cat > "$NGINX_AUTH_CONF" <<NGINXCONF
# Managed by /opt/openclaw/scripts/rotate_password.sh — do not edit by hand.
# Cookie oc_session value = SHA-256(OPENCLAW_GATEWAY_PASSWORD).
map \$cookie_oc_session \$auth_ok {
    "${NEW_HASH}" "yes";
    default "no";
}
NGINXCONF
log "wrote ${NGINX_AUTH_CONF}"

# Reload nginx so the new hash takes effect without dropping the listener.
if ! nginx -t >/dev/null 2>&1; then
  err "nginx -t failed after writing gateway-auth.conf; aborting before reload"
  exit 6
fi
systemctl reload nginx
log "nginx reloaded"

# --- 4. AWS Secrets Manager ---
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

# --- 5. container full recreate so new env propagates ---
log "restarting container so new password takes effect"
if ! bash "${SCRIPTS_DIR}/restart.sh"; then
  err "restart.sh failed after password rotation; password file IS already updated"
  err "next manual restart will pick up the new password"
  exit 5
fi

if [ "$NOTIFY_CLIENT" = "true" ]; then
  log "notify_client=true requested but webhook hook is not yet implemented"
fi

log "rotate_password complete"
exit 0

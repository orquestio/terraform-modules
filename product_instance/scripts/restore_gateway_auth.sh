#!/bin/bash
# =============================================================================
# restore_gateway_auth.sh — Re-pin gateway auth to token mode
#
# Self-service recovery op for when the OpenClaw agent inside the container
# modifies openclaw.json and breaks the auth contract (e.g. agent changes
# auth mode, removes token, or adds password field).
#
# Contract:
#   restore_gateway_auth.sh
#   exit 0  → openclaw.json re-pinned to token mode, token re-aligned
#             from container.env, device auth disabled, container
#             recreated. User AI providers / env vars / workspace UNTOUCHED.
#   exit !=0 → failure.
#
# This is a NARROW version of rotate_password.sh — we do NOT generate a new
# password, do NOT touch nginx conf.d/gateway-auth.conf, do NOT touch Secrets
# Manager. The password is assumed already aligned across the 4 places
# (container.env / openclaw.json / nginx / Secrets Manager); we read it back
# from container.env (no extra IAM permissions needed) and re-pin
# openclaw.json's auth block to token mode with that value.
# =============================================================================
set -euo pipefail

CURRENT_NAME="openclaw-current"
EFS_MOUNT="/mnt/efs"
OPENCLAW_CONFIG="${EFS_MOUNT}/config/openclaw.json"
CONTAINER_ENV_FILE="${EFS_MOUNT}/config/container.env"
SCRIPTS_DIR="/opt/openclaw/scripts"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [restore_gateway_auth.sh] $*"; }
err() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [restore_gateway_auth.sh] ERROR: $*" >&2; }

log "start"

if ! docker inspect "$CURRENT_NAME" >/dev/null 2>&1; then
  err "no '$CURRENT_NAME' container on this host; cannot restore gateway auth"
  exit 3
fi

if [ ! -f "$OPENCLAW_CONFIG" ]; then
  err "openclaw.json not found at $OPENCLAW_CONFIG"
  exit 4
fi

if [ ! -f "$CONTAINER_ENV_FILE" ]; then
  err "container.env not found at $CONTAINER_ENV_FILE"
  exit 4
fi

# Read the password from container.env (already 4-way aligned with
# openclaw.json, nginx conf.d and Secrets Manager by rotate_password.sh and
# user_data.sh). Avoids needing secretsmanager:GetSecretValue on the instance
# IAM role, which the EC2 profile does not grant (only put/create).
PASSWORD=$(grep '^OPENCLAW_GATEWAY_PASSWORD=' "$CONTAINER_ENV_FILE" | head -1 | cut -d= -f2-)

if [ -z "$PASSWORD" ]; then
  err "OPENCLAW_GATEWAY_PASSWORD not found in ${CONTAINER_ENV_FILE}"
  exit 5
fi
log "read gateway password from ${CONTAINER_ENV_FILE}"

export OPENCLAW_CONFIG PASSWORD
python3 <<'PYEOF'
import json, os, shutil
path = os.environ["OPENCLAW_CONFIG"]
pw = os.environ["PASSWORD"]
with open(path) as f:
    cfg = json.load(f)
shutil.copy2(path, path + ".bak.restore")
gw = cfg.setdefault("gateway", {})
auth = gw.setdefault("auth", {})
auth["mode"] = "token"
auth["token"] = pw
# Remove legacy trusted-proxy / password fields
auth.pop("password", None)
auth.pop("trustedProxy", None)
# Disable device pairing
cui = gw.setdefault("controlUi", {})
cui["dangerouslyDisableDeviceAuth"] = True
cui["dangerouslyAllowHostHeaderOriginFallback"] = True
cfg["gateway"]["auth"] = auth
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
os.chown(path, 1000, 1000)
PYEOF
log "openclaw.json re-pinned: mode=token, device auth disabled"

# Ensure OPENCLAW_GATEWAY_TOKEN is set in container.env (same value as PASSWORD).
if ! grep -q '^OPENCLAW_GATEWAY_TOKEN=' "$CONTAINER_ENV_FILE" 2>/dev/null; then
  echo "OPENCLAW_GATEWAY_TOKEN=${PASSWORD}" >> "$CONTAINER_ENV_FILE"
  chmod 600 "$CONTAINER_ENV_FILE"
  log "added OPENCLAW_GATEWAY_TOKEN to ${CONTAINER_ENV_FILE}"
fi

log "restarting container so auth changes take effect"
if ! bash "${SCRIPTS_DIR}/restart.sh"; then
  err "restart.sh failed after restore; openclaw.json IS already updated"
  err "next manual restart will pick up the new auth config"
  exit 6
fi

log "restore_gateway_auth complete"
exit 0

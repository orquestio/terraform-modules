#!/bin/bash
# =============================================================================
# apply_env_vars.sh — Bulk-apply user env vars to the OpenClaw container
#
# Contract:
#   apply_env_vars.sh '<json_array>'
#     json_array: [{"name":"FOO","value":"bar","is_secret":true}, ...]
#   exit 0  → container.env rewritten, container restarted, healthz passing
#   exit !=0 → failure (bad args/name, missing container, restart failed)
#
# Semantics:
#   - REPLACE (not merge): the resulting container.env contains exactly the
#     vars in the JSON, plus OPENCLAW_GATEWAY_PASSWORD preserved from the
#     existing file (infra-owned, never user-managed).
#   - Last-wins on duplicate names within the JSON array.
#   - Names must match ^[A-Z_][A-Z0-9_]*$. Attempting to set
#     OPENCLAW_GATEWAY_PASSWORD via this script is rejected.
#   - Idempotent: same input → same file contents. restart.sh runs once at
#     the end regardless.
# =============================================================================
set -euo pipefail

PAYLOAD_JSON="${1:-}"

if [ -z "$PAYLOAD_JSON" ]; then
  echo "ERROR: missing JSON payload argument" >&2
  echo "usage: apply_env_vars.sh '<json_array>'" >&2
  exit 2
fi

CURRENT_NAME="openclaw-current"
EFS_MOUNT="/mnt/efs"
CONTAINER_ENV_FILE="${EFS_MOUNT}/config/container.env"
SCRIPTS_DIR="/opt/openclaw/scripts"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [apply_env_vars.sh] $*"; }
err() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [apply_env_vars.sh] ERROR: $*" >&2; }

log "start"

if ! docker inspect "$CURRENT_NAME" >/dev/null 2>&1; then
  err "no '$CURRENT_NAME' container on this host; cannot apply env vars"
  exit 3
fi

mkdir -p "$(dirname "$CONTAINER_ENV_FILE")"

TMP_ENV=$(mktemp)
trap 'rm -f "$TMP_ENV"' EXIT

export PAYLOAD_JSON CONTAINER_ENV_FILE TMP_ENV
python3 << 'PYEOF'
import json
import os
import re

payload_json = os.environ["PAYLOAD_JSON"]
env_file = os.environ["CONTAINER_ENV_FILE"]
tmp_file = os.environ["TMP_ENV"]

NAME_RE = re.compile(r"^[A-Z_][A-Z0-9_]*$")
RESERVED = {"OPENCLAW_GATEWAY_PASSWORD"}

try:
    items = json.loads(payload_json)
except json.JSONDecodeError as e:
    raise SystemExit(f"ERROR: payload is not valid JSON: {e}")

if not isinstance(items, list):
    raise SystemExit("ERROR: payload must be a JSON array")

ordered = {}
for i, item in enumerate(items):
    if not isinstance(item, dict):
        raise SystemExit(f"ERROR: item {i} is not an object")
    name = item.get("name")
    value = item.get("value", "")
    if not isinstance(name, str) or not NAME_RE.match(name):
        raise SystemExit(f"ERROR: item {i} has invalid name {name!r} (must match ^[A-Z_][A-Z0-9_]*$)")
    if name in RESERVED:
        raise SystemExit(f"ERROR: {name} is infra-managed and cannot be set via apply_env_vars")
    if not isinstance(value, str):
        value = "" if value is None else str(value)
    # Last-wins: re-inserting moves the key to the end and overwrites value.
    ordered.pop(name, None)
    ordered[name] = value

# Preserve OPENCLAW_GATEWAY_PASSWORD from existing file.
gateway_line = None
if os.path.exists(env_file):
    with open(env_file, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if line.startswith("OPENCLAW_GATEWAY_PASSWORD="):
                gateway_line = line

lines = [f"{k}={v}" for k, v in ordered.items()]
if gateway_line is not None:
    lines.append(gateway_line)

with open(tmp_file, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
    if lines:
        f.write("\n")

print(f"prepared {len(ordered)} user var(s); gateway_password_preserved={gateway_line is not None}")
PYEOF

mv "$TMP_ENV" "$CONTAINER_ENV_FILE"
trap - EXIT
chmod 600 "$CONTAINER_ENV_FILE"
log "wrote ${CONTAINER_ENV_FILE}"

log "restarting container so new env vars take effect"
if ! bash "${SCRIPTS_DIR}/restart.sh"; then
  err "restart.sh failed after apply_env_vars; container.env IS already updated"
  err "next manual restart will pick up the values"
  exit 5
fi

log "apply_env_vars complete"
exit 0

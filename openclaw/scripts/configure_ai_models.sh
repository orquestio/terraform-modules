#!/bin/bash
# =============================================================================
# configure_ai_models.sh — Inject AI model provider configs into openclaw.json
#
# Usage: configure_ai_models.sh '<json_payload>'
#
# v28 envelope (preferred):
#   {"mode": "merge|replace", "providers": [{...}]}
#
# Legacy form (backwards-compat, treated as mode=merge):
#   [{"provider":"openai","baseUrl":"...","apiKey":"sk-...",...}]
#
# Each provider object:
#   {"provider":"openai-codex","adapter":"openai-responses",
#    "baseUrl":"https://chatgpt.com/backend-api","apiKey":"",
#    "model":"gpt-5.5","default":true,"reasoning":false,
#    "auth_type":"oauth_device|api_key","auth_method":"oauth-cn"}
#
# Modes:
#   merge   — leave existing models.providers entries untouched, only update
#             the providers in the payload. DEFAULT.
#   replace — wipe models.providers and write only the payload entries. Used
#             only via the explicit "Reset and start fresh" UI path.
# =============================================================================
set -euo pipefail

CONFIG_FILE="/mnt/efs/config/openclaw.json"
PAYLOAD="$1"

if [ -z "$PAYLOAD" ]; then
    echo "ERROR: No provider config JSON provided"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: OpenClaw config not found at $CONFIG_FILE"
    exit 1
fi

echo "[$(date)] Configuring AI models..."

export CONFIG_FILE PAYLOAD
python3 << 'PYEOF'
import json
import os
import shutil

config_file = os.environ.get("CONFIG_FILE", "/mnt/efs/config/openclaw.json")
raw = os.environ.get("PAYLOAD", "[]")

with open(config_file, "r") as f:
    config = json.load(f)

# Defensive: keep gateway.trustedProxies present (OPENCLAW_AUTH_AND_PROXY.md
# invariant 1). Without it WebSocket upgrades fail with 1008.
gw = config.setdefault("gateway", {})
if "trustedProxies" not in gw or not isinstance(gw.get("trustedProxies"), list):
    gw["trustedProxies"] = ["172.17.0.1", "127.0.0.1", "::1"]

# Accept envelope or bare list. Bare list is treated as merge.
parsed = json.loads(raw)
if isinstance(parsed, dict):
    mode = (parsed.get("mode") or "merge").lower()
    providers_in = parsed.get("providers") or []
else:
    mode = "merge"
    providers_in = parsed

if mode not in ("merge", "replace"):
    raise SystemExit(f"ERROR: invalid mode {mode!r}, expected merge or replace")

print(f"[mode={mode}] Providers in payload: {', '.join(p.get('provider','?') for p in providers_in)}")

models_root = config.get("models") or {}
if not isinstance(models_root, dict):
    models_root = {}

# Preserve existing providers map by default. In replace mode we start fresh.
existing_map = models_root.get("providers") or {}
if not isinstance(existing_map, dict):
    existing_map = {}
providers_map = {} if mode == "replace" else dict(existing_map)

models_root["mode"] = mode
models_root["providers"] = providers_map

default_provider_id = None
default_model_id = None

for p in providers_in:
    pid = (p.get("provider") or "").strip()
    if not pid:
        continue
    model_id = p.get("model") or pid
    auth_type = p.get("auth_type") or ""
    api_key = p.get("apiKey") or ""

    model_entry = {"id": model_id, "name": model_id}
    api = p.get("adapter")
    if api:
        model_entry["api"] = api
    if p.get("reasoning"):
        model_entry["reasoning"] = True

    prov_entry = {
        "baseUrl": p.get("baseUrl", ""),
        "models": [model_entry],
    }
    # OAuth providers: do NOT inject apiKey. OpenClaw resolves auth from
    # auth-profiles.json via the provider plugin; an apiKey marker would
    # confuse the auth-resolution chain.
    if auth_type != "oauth_device" and api_key:
        prov_entry["apiKey"] = api_key

    auth_method = p.get("auth_method")
    if auth_method:
        prov_entry["authMethod"] = auth_method

    providers_map[pid] = prov_entry
    if p.get("default") and default_provider_id is None:
        default_provider_id = pid
        default_model_id = model_id

config["models"] = models_root

# Build the agent model catalog for the UI selector — keys are "provider/model".
agents = config.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
model_catalog = {}
for pid, prov in providers_map.items():
    for m in prov.get("models", []):
        full_id = f"{pid}/{m['id']}"
        model_catalog[full_id] = {}
defaults["models"] = model_catalog

# Only update agents.defaults.model when the payload actually marks a default.
# In merge mode, leave the existing default alone otherwise — switching
# providers should not silently change which model the agent uses.
if default_provider_id and default_model_id:
    defaults["model"] = f"{default_provider_id}/{default_model_id}"
elif mode == "replace":
    # In replace mode with no default: pick the first configured model so
    # the agent has SOMETHING to use.
    if model_catalog and not defaults.get("model"):
        defaults["model"] = next(iter(model_catalog))

shutil.copy2(config_file, config_file + ".bak")
with open(config_file, "w") as f:
    json.dump(config, f, indent=2)

os.chown(config_file, 1000, 1000)
print(f"Configured {len(providers_in)} provider(s) — total now: {len(providers_map)}")
PYEOF

echo "[$(date)] Recreating OpenClaw container to apply config..."
# restart.sh does a full docker rm + docker run (see configure_ai_models.sh
# v1 commentary): plain `docker restart` does NOT reload --env-file or
# trigger the gateway.auth.mode flip rescue path.
if ! bash /opt/openclaw/scripts/restart.sh; then
    echo "ERROR: restart.sh failed after config change; restoring backup"
    cp "$CONFIG_FILE.bak" "$CONFIG_FILE"
    chown 1000:1000 "$CONFIG_FILE"
    bash /opt/openclaw/scripts/restart.sh || true
    exit 1
fi
echo "[$(date)] OpenClaw recreated successfully with new AI model config"

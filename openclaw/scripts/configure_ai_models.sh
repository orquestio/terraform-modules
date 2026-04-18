#!/bin/bash
# =============================================================================
# configure_ai_models.sh — Inject AI model provider configs into openclaw.json
#
# Usage: configure_ai_models.sh '<json_array_of_providers>'
#
# The JSON array contains objects like:
#   [{"provider":"openai","baseUrl":"https://api.openai.com/v1","apiKey":"sk-...","adapter":"openai-completions","model":"gpt-4o"}]
#
# This script:
#   1. Reads the current openclaw.json
#   2. Merges the AI model configs into the "models" section
#   3. Writes back openclaw.json
#   4. Restarts the OpenClaw container to pick up the new config
# =============================================================================
set -euo pipefail

CONFIG_FILE="/mnt/efs/config/openclaw.json"
PROVIDERS_JSON="$1"

if [ -z "$PROVIDERS_JSON" ]; then
    echo "ERROR: No provider config JSON provided"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: OpenClaw config not found at $CONFIG_FILE"
    exit 1
fi

echo "[$(date)] Configuring AI models..."
echo "[$(date)] Providers: $(echo "$PROVIDERS_JSON" | python3 -c "import sys,json; data=json.load(sys.stdin); print(', '.join(p.get('provider','?') for p in data))")"

# Use Python to merge the config since jq may not be installed on AL2023
export CONFIG_FILE PROVIDERS_JSON
python3 << 'PYEOF'
import json
import os
import shutil

config_file = os.environ.get("CONFIG_FILE", "/mnt/efs/config/openclaw.json")
providers_json = os.environ.get("PROVIDERS_JSON", "[]")

with open(config_file, "r") as f:
    config = json.load(f)

providers_in = json.loads(providers_json)

# OpenClaw schema (v2026.4.10): models is an object with "mode" and "providers"
# map keyed by provider id. Each provider has baseUrl, apiKey, adapter and a
# "models" array of {id, name, api, reasoning?} entries.
models_root = config.get("models") or {}
if not isinstance(models_root, dict):
    models_root = {}
models_root["mode"] = "replace"
providers_map = {}
models_root["providers"] = providers_map

default_provider_id = None
default_model_id = None

for p in providers_in:
    pid = p.get("provider", "").strip()
    if not pid:
        continue
    model_id = p.get("model") or pid
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
    if p.get("apiKey"):
        prov_entry["apiKey"] = p["apiKey"]

    providers_map[pid] = prov_entry
    if p.get("default") and default_provider_id is None:
        default_provider_id = pid
        default_model_id = model_id

config["models"] = models_root

# Build the agent model catalog so the UI selector only shows configured models.
# Keys are "provider/model" IDs — OpenClaw shows exactly these in the dropdown.
agents = config.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
model_catalog = {}
for pid, prov in providers_map.items():
    for m in prov.get("models", []):
        full_id = f"{pid}/{m['id']}"
        model_catalog[full_id] = {}
defaults["models"] = model_catalog

if default_provider_id and default_model_id:
    defaults["model"] = f"{default_provider_id}/{default_model_id}"

shutil.copy2(config_file, config_file + ".bak")
with open(config_file, "w") as f:
    json.dump(config, f, indent=2)

os.chown(config_file, 1000, 1000)

print(f"Configured {len(providers_in)} AI provider(s)")
PYEOF

echo "[$(date)] Recreating OpenClaw container to apply config..."
# Use restart.sh (full docker rm + docker run) instead of `docker restart`.
# Reasons:
#   1. restart.sh reloads --env-file so OPENCLAW_GATEWAY_PASSWORD / env
#      vars set via update_env_var.sh actually propagate. Plain `docker
#      restart` keeps the env from the original docker run.
#   2. OpenClaw v2026.4.10 on a soft restart can flip gateway.auth.mode
#      if it detects env/config drift, which invalidates the nginx
#      cookie wall and locks users out. A full
#      recreate starts OpenClaw from a clean slate against the pinned
#      openclaw.json + container.env, avoiding the flip.
if ! bash /opt/openclaw/scripts/restart.sh; then
    echo "ERROR: restart.sh failed after config change; restoring backup"
    cp "$CONFIG_FILE.bak" "$CONFIG_FILE"
    chown 1000:1000 "$CONFIG_FILE"
    bash /opt/openclaw/scripts/restart.sh || true
    exit 1
fi
echo "[$(date)] OpenClaw recreated successfully with new AI model config"

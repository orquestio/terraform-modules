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
import sys
import os
import shutil

config_file = os.environ.get("CONFIG_FILE", "/mnt/efs/config/openclaw.json")
providers_json = os.environ.get("PROVIDERS_JSON", "[]")

# Read current config
with open(config_file, "r") as f:
    config = json.load(f)

# Parse providers
providers = json.loads(providers_json)

# Build the models config for OpenClaw
# OpenClaw expects models in the "models" key as a list of model configs
models = []
for p in providers:
    model_entry = {
        "provider": p.get("provider", ""),
        "baseUrl": p.get("baseUrl", ""),
        "apiKey": p.get("apiKey", ""),
        "adapter": p.get("adapter", "openai-completions"),
    }
    if p.get("model"):
        model_entry["model"] = p["model"]
    if p.get("reasoning"):
        model_entry["reasoning"] = True
    if p.get("default"):
        model_entry["default"] = True
    models.append(model_entry)

# Merge into config
config["models"] = models

# Backup and write
shutil.copy2(config_file, config_file + ".bak")
with open(config_file, "w") as f:
    json.dump(config, f, indent=2)

# Fix ownership
os.chown(config_file, 1000, 1000)

print(f"Configured {len(models)} AI provider(s)")
PYEOF

echo "[$(date)] Restarting OpenClaw container to apply config..."
docker restart openclaw-current
sleep 5

# Verify container is running
if docker ps --format '{{.Names}}' | grep -q openclaw-current; then
    echo "[$(date)] OpenClaw restarted successfully with new AI model config"
else
    echo "ERROR: OpenClaw container failed to restart after config change"
    # Restore backup
    cp "$CONFIG_FILE.bak" "$CONFIG_FILE"
    chown 1000:1000 "$CONFIG_FILE"
    docker start openclaw-current
    exit 1
fi

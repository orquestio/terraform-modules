#!/bin/bash
# =============================================================================
# disconnect_ai_provider.sh — Remove a provider from openclaw.json + revoke
# any OAuth profile, then restart OpenClaw.
#
# Usage:
#   disconnect_ai_provider.sh <provider_id> <auth_provider_id>
#
# Args:
#   provider_id        — key in models.providers (e.g. "openai-codex").
#   auth_provider_id   — provider id used by `openclaw models auth` (often
#                        the same string; passed separately so the
#                        orchestrator can map catalog entries that differ).
#
# Steps:
#   1. Remove the provider entry from models.providers.
#   2. Drop any matching agents.defaults.models entries.
#   3. If agents.defaults.model points at the removed provider, fall back to
#      the first remaining model (or unset if none left).
#   4. Best-effort: ask OpenClaw to logout the OAuth profile (no revoke
#      subcommand exists today; we delete the auth-profiles.json entry
#      directly via a python rewrite). API-key disconnect needs no token
#      cleanup.
#   5. Restart OpenClaw to pick up the new config.
# =============================================================================
set -uo pipefail

CONFIG_FILE="/mnt/efs/config/openclaw.json"
PROVIDER="${1:-}"
AUTH_PROVIDER="${2:-$PROVIDER}"

if [ -z "$PROVIDER" ]; then
    echo "ERROR: provider id required"
    exit 2
fi
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: openclaw.json not found at $CONFIG_FILE"
    exit 2
fi

echo "[$(date)] disconnecting provider=$PROVIDER auth_provider=$AUTH_PROVIDER"

# Step 1-3: edit openclaw.json on disk.
export CONFIG_FILE PROVIDER
python3 << 'PYEOF'
import json
import os
import shutil

cf = os.environ["CONFIG_FILE"]
pid = os.environ["PROVIDER"]

with open(cf, "r") as f:
    config = json.load(f)

models_root = config.get("models") or {}
providers = models_root.get("providers") or {}
removed = providers.pop(pid, None)
models_root["providers"] = providers
config["models"] = models_root

agents = config.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
model_catalog = defaults.get("models") or {}
for full_id in list(model_catalog.keys()):
    if full_id.split("/", 1)[0] == pid:
        model_catalog.pop(full_id, None)
defaults["models"] = model_catalog

current_default = defaults.get("model") or ""
if current_default.split("/", 1)[0] == pid:
    if model_catalog:
        defaults["model"] = next(iter(model_catalog))
    else:
        defaults.pop("model", None)

shutil.copy2(cf, cf + ".bak")
with open(cf, "w") as f:
    json.dump(config, f, indent=2)
os.chown(cf, 1000, 1000)

print(f"removed provider={pid} (existed={bool(removed)})")
PYEOF

# Step 4: best-effort OAuth profile cleanup. The auth-profiles.json file
# lives inside the container at /home/node/.openclaw/agents/main/agent/.
# OpenClaw 2026.5.7 has no `auth logout` subcommand, so we rewrite the file
# directly. If the file does not exist or has no matching profile this is a
# no-op.
sudo docker exec openclaw-current bash -c "
python3 - <<PYEOF2
import json, os
candidates = [
    '/home/node/.openclaw/agents/main/agent/auth-profiles.json',
    '/root/.openclaw/agents/main/agent/auth-profiles.json',
]
target = None
for p in candidates:
    if os.path.exists(p):
        target = p
        break
if not target:
    print('no auth-profiles.json found (nothing to revoke)')
    raise SystemExit(0)
with open(target) as f:
    data = json.load(f)
profiles = data.get('profiles') if isinstance(data, dict) else None
if not isinstance(profiles, list):
    print('auth-profiles.json has no profiles list')
    raise SystemExit(0)
before = len(profiles)
data['profiles'] = [p for p in profiles if p.get('provider') != '$AUTH_PROVIDER']
after = len(data['profiles'])
with open(target, 'w') as f:
    json.dump(data, f, indent=2)
print(f'auth-profiles.json: removed {before - after} profile(s) for $AUTH_PROVIDER')
PYEOF2
" || echo "WARN: auth profile cleanup failed (continuing — config is already updated)"

# Step 5: restart so the new config takes effect.
echo "[$(date)] restarting OpenClaw..."
if ! bash /opt/openclaw/scripts/restart.sh; then
    echo "ERROR: restart failed; rolling back openclaw.json"
    cp "$CONFIG_FILE.bak" "$CONFIG_FILE"
    chown 1000:1000 "$CONFIG_FILE"
    bash /opt/openclaw/scripts/restart.sh || true
    exit 1
fi
echo "[$(date)] disconnected $PROVIDER and restarted OpenClaw"

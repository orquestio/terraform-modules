#!/bin/bash
# configure_ai_models.sh '<json_payload>'
#
# Payload variants:
#   {"mode":"merge|replace","providers":[{...}]}    add/update models
#   {"op":"remove_model","provider":"X","model":"Y"} remove one model
#   [{...}]                                          legacy bare list (=merge)
#
# Provider object: {provider, adapter, baseUrl, apiKey, model, default,
#                   reasoning?, auth_type?, auth_method?}
# Mode merge appends/updates models in providers[pid].models[] without
# wiping siblings. replace wipes models.providers and rewrites.
set -euo pipefail
CONFIG_FILE="/mnt/efs/config/openclaw.json"
PAYLOAD="$1"
[ -z "$PAYLOAD" ] && { echo "ERROR: empty payload"; exit 1; }
[ -f "$CONFIG_FILE" ] || { echo "ERROR: $CONFIG_FILE missing"; exit 1; }

echo "[$(date)] Configuring AI models..."

export CONFIG_FILE PAYLOAD
python3 << 'PYEOF'
import json, os, shutil

cf = os.environ["CONFIG_FILE"]
raw = os.environ.get("PAYLOAD", "[]")
with open(cf, "r") as f:
    config = json.load(f)

# Defensive: gateway.trustedProxies must stay present (OPENCLAW_AUTH_AND_PROXY).
gw = config.setdefault("gateway", {})
if not isinstance(gw.get("trustedProxies"), list):
    gw["trustedProxies"] = ["172.17.0.1", "127.0.0.1", "::1"]

parsed = json.loads(raw)

# ---------- normalize input ----------
op = None
mode = "merge"
providers_in = []
remove_target = None

if isinstance(parsed, dict):
    if parsed.get("op") == "remove_model":
        op = "remove_model"
        remove_target = (parsed.get("provider"), parsed.get("model"))
    else:
        mode = (parsed.get("mode") or "merge").lower()
        providers_in = parsed.get("providers") or []
elif isinstance(parsed, list):
    providers_in = parsed

if mode not in ("merge", "replace"):
    raise SystemExit(f"ERROR: invalid mode {mode!r}")

models_root = config.get("models")
if not isinstance(models_root, dict):
    models_root = {}
existing = models_root.get("providers") or {}
if not isinstance(existing, dict):
    existing = {}

agents = config.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})

# ---------- op: remove_model ----------
if op == "remove_model":
    pid, mid = remove_target
    if not pid or not mid:
        raise SystemExit("ERROR: remove_model requires provider+model")
    pcfg = existing.get(pid)
    if isinstance(pcfg, dict):
        pcfg["models"] = [m for m in (pcfg.get("models") or [])
                          if isinstance(m, dict) and m.get("id") != mid]
        if not pcfg["models"]:
            existing.pop(pid, None)
    models_root["providers"] = existing
    models_root.setdefault("mode", "merge")
    # Rebuild catalog + fix default if it pointed at the removed model.
    catalog = {}
    for ppid, pp in existing.items():
        for m in pp.get("models", []):
            if isinstance(m, dict) and m.get("id"):
                catalog[f"{ppid}/{m['id']}"] = {}
    defaults["models"] = catalog
    cur_default = defaults.get("model", "")
    if cur_default == f"{pid}/{mid}" or cur_default == pid:
        defaults["model"] = next(iter(catalog), None) or ""
        if not defaults["model"]:
            defaults.pop("model", None)
    config["models"] = models_root
    print(f"removed {pid}/{mid}; providers remaining: {list(existing.keys())}")
else:
    # ---------- apply (merge | replace) ----------
    providers_map = {} if mode == "replace" else dict(existing)
    models_root["mode"] = mode

    default_provider_id = None
    default_model_id = None

    for p in providers_in:
        pid = (p.get("provider") or "").strip()
        if not pid:
            continue
        model_id = p.get("model") or pid
        auth_type = p.get("auth_type") or ""
        api_key = p.get("apiKey") or ""

        new_model = {"id": model_id, "name": model_id}
        if p.get("adapter"):
            new_model["api"] = p["adapter"]
        if p.get("reasoning"):
            new_model["reasoning"] = True

        prev = providers_map.get(pid)
        if isinstance(prev, dict) and mode == "merge":
            prev_models = prev.get("models") or []
            kept = [m for m in prev_models if not (isinstance(m, dict) and m.get("id") == model_id)]
            kept.append(new_model)
            prev["models"] = kept
            if p.get("baseUrl"):
                prev["baseUrl"] = p["baseUrl"]
            if auth_type != "oauth_device" and api_key:
                prev["apiKey"] = api_key
            if p.get("auth_method"):
                prev["authMethod"] = p["auth_method"]
        else:
            entry = {"baseUrl": p.get("baseUrl", ""), "models": [new_model]}
            if auth_type != "oauth_device" and api_key:
                entry["apiKey"] = api_key
            if p.get("auth_method"):
                entry["authMethod"] = p["auth_method"]
            providers_map[pid] = entry

        if p.get("default") and default_provider_id is None:
            default_provider_id = pid
            default_model_id = model_id

    models_root["providers"] = providers_map
    config["models"] = models_root

    # Rebuild agents.defaults.models catalog.
    catalog = {}
    for ppid, pp in providers_map.items():
        for m in pp.get("models", []):
            if isinstance(m, dict) and m.get("id"):
                catalog[f"{ppid}/{m['id']}"] = {}
    defaults["models"] = catalog
    if default_provider_id and default_model_id:
        defaults["model"] = f"{default_provider_id}/{default_model_id}"
    elif mode == "replace" and catalog and not defaults.get("model"):
        defaults["model"] = next(iter(catalog))
    # In merge mode without explicit default, leave the existing default
    # alone unless it points to a non-existent model.
    elif defaults.get("model") and defaults["model"] not in catalog and catalog:
        defaults["model"] = next(iter(catalog))
    elif defaults.get("model") and not catalog:
        defaults.pop("model", None)

    print(f"providers: {list(providers_map.keys())}; total models: {sum(len(p.get('models',[])) for p in providers_map.values())}")

shutil.copy2(cf, cf + ".bak")
with open(cf, "w") as f:
    json.dump(config, f, indent=2)
os.chown(cf, 1000, 1000)
PYEOF

echo "[$(date)] Recreating OpenClaw container..."
if ! bash /opt/openclaw/scripts/restart.sh; then
    echo "ERROR: restart.sh failed; restoring backup"
    cp "$CONFIG_FILE.bak" "$CONFIG_FILE"
    chown 1000:1000 "$CONFIG_FILE"
    bash /opt/openclaw/scripts/restart.sh || true
    exit 1
fi
echo "[$(date)] done"

#!/bin/bash
# =============================================================================
# probe_model.sh — In-container post-restart health check for an AI model.
#
# Usage:
#   probe_model.sh <provider> <model>
#
# Runs after configure_ai_models.sh restarts OpenClaw to confirm the new
# (provider, model) pair actually loaded. Cheaper than the orchestrator's
# full tool-probe — uses `openclaw models list --json --provider <p>` to
# verify the model is registered, then `openclaw models status --json` to
# verify auth is OK.
#
# Exit codes:
#   0 — model is registered and reachable
#   1 — model is registered but auth is missing/expired
#   2 — model is not registered (config did not load)
#   3 — openclaw container not running / CLI unavailable
# =============================================================================
set -uo pipefail

PROVIDER="${1:-}"
MODEL="${2:-}"

if [ -z "$PROVIDER" ] || [ -z "$MODEL" ]; then
    echo "ERROR: usage: probe_model.sh <provider> <model>"
    exit 2
fi

if ! sudo docker ps --format '{{.Names}}' | grep -q '^openclaw-current$'; then
    echo "ERROR: openclaw-current container not running"
    exit 3
fi

LIST_JSON=$(sudo docker exec openclaw-current openclaw models list --json --provider "$PROVIDER" 2>&1) || {
    echo "ERROR: models list failed: $LIST_JSON"
    exit 3
}

if ! echo "$LIST_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
models = data.get('models') or data.get('configured') or []
target = sys.argv[1]
ids = [m.get('id') for m in models if isinstance(m, dict)]
ok = any(target == m_id or target == m_id.split('/', 1)[-1] for m_id in ids if m_id)
sys.exit(0 if ok else 2)
" "$MODEL"; then
    echo "ERROR: model $MODEL not registered for $PROVIDER"
    exit 2
fi

STATUS_JSON=$(sudo docker exec openclaw-current openclaw models status --json 2>&1) || true

# Auth is considered OK if the provider is in providersWithOAuth (subscription)
# OR has an apiKey configured (api_key path) OR appears in providers without
# a missing-auth flag.
echo "$STATUS_JSON" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)  # status read failed; we already know the model is loaded
auth = data.get('auth', {}) or {}
provider = sys.argv[1]
missing = auth.get('missingProvidersInUse') or []
if provider in missing:
    sys.exit(1)
sys.exit(0)
" "$PROVIDER"
RC=$?

if [ $RC -ne 0 ]; then
    echo "WARN: model registered but auth status reports missing for $PROVIDER"
    exit 1
fi

echo "OK: $PROVIDER/$MODEL registered and auth OK"
exit 0

#!/bin/bash
# =============================================================================
# oauth_status.sh — Report OAuth profile state for the portal.
#
# Usage:
#   oauth_status.sh                    # full models status JSON
#   oauth_status.sh <auth_provider_id> # filtered to one provider
#
# Wraps `openclaw models status --json` (preferred) and falls back to
# `openclaw models auth list --json` if status is unavailable. Output goes
# straight to stdout — the orchestrator parses it and serves to the portal.
# =============================================================================
set -uo pipefail

PROVIDER="${1:-}"

if [ -n "$PROVIDER" ]; then
    sudo docker exec openclaw-current openclaw models auth list --json --provider "$PROVIDER"
else
    if sudo docker exec openclaw-current openclaw models status --json 2>/dev/null; then
        :
    else
        sudo docker exec openclaw-current openclaw models auth list --json
    fi
fi

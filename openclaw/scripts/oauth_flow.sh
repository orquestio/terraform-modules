#!/bin/bash
# =============================================================================
# oauth_flow.sh — Wrap `openclaw models auth login` (RFC 8628 device flow).
#
# Usage:
#   oauth_flow.sh start <auth_provider_id> [--method <id>] [--set-default]
#
# The orchestrator dispatches this from the portal "Connect" button. The
# auth_provider_id is the ID OpenClaw exposes (e.g. "openai-codex",
# "github-copilot", "minimax-portal"). The script runs the login flow non-
# interactively and prints whatever the OpenClaw plugin emits — typically a
# verification_uri + user_code + expires_in tuple. The orchestrator parses
# the output to surface the device-code modal to the customer.
# =============================================================================
set -uo pipefail

ACTION="${1:-}"
PROVIDER="${2:-}"
shift 2 || true

if [ "$ACTION" != "start" ]; then
    echo "ERROR: unknown action: $ACTION (expected: start)"
    exit 2
fi
if [ -z "$PROVIDER" ]; then
    echo "ERROR: provider id required"
    exit 2
fi

ARGS=(models auth login --provider "$PROVIDER")
while [ $# -gt 0 ]; do
    case "$1" in
        --method)
            ARGS+=(--method "$2")
            shift 2
            ;;
        --set-default)
            ARGS+=(--set-default)
            shift
            ;;
        *)
            shift
            ;;
    esac
done

echo "[$(date)] starting oauth flow: openclaw ${ARGS[*]}"

# GitHub Copilot uses a dedicated subcommand; map for convenience.
if [ "$PROVIDER" = "github-copilot" ]; then
    sudo docker exec openclaw-current openclaw models auth login-github-copilot
    exit $?
fi

# OpenClaw's `auth login` will print verification_uri / user_code on stdout
# and then poll until the customer authorizes. The `< /dev/null` redirects
# stdin so the plugin doesn't hang waiting for a TTY prompt.
sudo docker exec -i openclaw-current openclaw "${ARGS[@]}" < /dev/null
RC=$?

echo "[$(date)] oauth flow exited rc=$RC"
exit $RC

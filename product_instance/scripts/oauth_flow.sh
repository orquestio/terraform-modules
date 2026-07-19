#!/bin/bash
# oauth_flow.sh start <pid> [--method M] [--set-default]
# Wraps `openclaw models auth login` in a script(1) pseudo-TTY (the CLI
# refuses no-TTY) and detached docker exec, then emits OAUTH_*= markers
# (verification URI + user code) for the orchestrator. Completion is
# detected by polling `openclaw models auth list --json` separately.
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

EXTRA_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --method)
            EXTRA_ARGS+=(--method "$2")
            shift 2
            ;;
        --set-default)
            EXTRA_ARGS+=(--set-default)
            shift
            ;;
        *)
            shift
            ;;
    esac
done

SAFE_PROVIDER=$(echo "$PROVIDER" | tr -c 'A-Za-z0-9._-' '_')
LOG_INSIDE="/tmp/oauth_${SAFE_PROVIDER}.log"
LOG_OUTSIDE="/mnt/efs/oauth-logs/${SAFE_PROVIDER}.log"
sudo mkdir -p /mnt/efs/oauth-logs 2>/dev/null || true
sudo chown 1000:1000 /mnt/efs/oauth-logs 2>/dev/null || true

# github-copilot uses a dedicated subcommand.
if [ "$PROVIDER" = "github-copilot" ]; then
    INNER_CMD=(openclaw models auth login-github-copilot)
else
    INNER_CMD=(openclaw models auth login --provider "$PROVIDER" "${EXTRA_ARGS[@]}")
fi

echo "[$(date)] starting oauth flow: ${INNER_CMD[*]}"

# Kill any stale flow + start a fresh detached pseudo-TTY run via script(1).
sudo docker exec openclaw-current sh -c "pkill -f 'oauth_${SAFE_PROVIDER}' 2>/dev/null || true; rm -f $LOG_INSIDE 2>/dev/null || true"
INNER_QUOTED=$(printf '%q ' "${INNER_CMD[@]}")
sudo docker exec -d openclaw-current sh -c \
    "script -qfc \"$INNER_QUOTED\" $LOG_INSIDE >/dev/null 2>&1"

# Poll the in-container log for the verification URI + user code.
WAIT_S=20
URI=""
CODE=""
EXPIRES_IN=""
INTERVAL="5"
deadline=$(( $(date +%s) + WAIT_S ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    BUF=$(sudo docker exec openclaw-current cat "$LOG_INSIDE" 2>/dev/null || true)
    # Strip ANSI color codes the OpenClaw logger emits.
    CLEAN=$(printf '%s' "$BUF" | sed 's/\x1b\[[0-9;]*m//g')
    if [ -z "$URI" ]; then
        URI=$(printf '%s' "$CLEAN" | grep -oE 'https?://[^[:space:]"]+' | head -1)
    fi
    if [ -z "$CODE" ]; then
        CODE=$(printf '%s' "$CLEAN" | grep -oE '\b[A-Z0-9]{4}-[A-Z0-9]{4}\b' | head -1)
        [ -z "$CODE" ] && CODE=$(printf '%s' "$CLEAN" | grep -oE '\b[A-Z0-9]{8,12}\b' | grep -vE '^(HTTPS?|OAUTH)$' | head -1)
    fi
    if [ -z "$EXPIRES_IN" ]; then
        EXPIRES_IN=$(printf '%s' "$CLEAN" | grep -oE 'expires? in [0-9]+ (seconds|minutes)' | head -1 \
                    | awk '{ if ($4 == "minutes") print $3 * 60; else print $3 }')
    fi
    if [ -n "$URI" ] && [ -n "$CODE" ]; then
        break
    fi
    sleep 1
done

# Mirror to /mnt/efs (survives container restart, orchestrator-readable).
sudo docker exec openclaw-current cat "$LOG_INSIDE" 2>/dev/null \
    | sudo tee "$LOG_OUTSIDE" >/dev/null 2>/dev/null || true

echo "OAUTH_VERIFICATION_URI=${URI}"
echo "OAUTH_USER_CODE=${CODE}"
echo "OAUTH_EXPIRES_IN=${EXPIRES_IN:-600}"
echo "OAUTH_POLL_INTERVAL=${INTERVAL}"
echo "OAUTH_LOG_PATH=${LOG_OUTSIDE}"
# Always 0; completion is detected separately via oauth_status.sh.
exit 0

#!/bin/bash
# =============================================================================
# oauth_flow.sh — Wrap `openclaw models auth login` (RFC 8628 device flow).
#
# Usage:
#   oauth_flow.sh start <auth_provider_id> [--method <id>] [--set-default]
#
# OpenClaw 2026.5.7's `models auth login` refuses to run without a controlling
# TTY ("Error: models auth login requires an interactive TTY"). SSM
# RunCommand has no TTY, so we use the `script` utility (already present in
# the container's Debian image) to create a pseudo-TTY, and run the flow in
# detached `docker exec -d` mode so the device-code polling keeps going
# inside the container even after this script returns.
#
# Output protocol — the orchestrator parses these lines from stdout:
#
#   OAUTH_VERIFICATION_URI=https://chatgpt.com/codex/device
#   OAUTH_USER_CODE=ABCD-WXYZ
#   OAUTH_EXPIRES_IN=600
#   OAUTH_POLL_INTERVAL=5
#
# Once the customer enters the user code in the verification URI, OpenClaw's
# in-container poller will pick up the access token and persist it to
# auth-profiles.json. The orchestrator polls `openclaw models auth list
# --json` (via oauth_status.sh) to detect completion.
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

# Special case: github-copilot uses a dedicated subcommand. Both subcommands
# share the same TTY requirement so the wrapper is the same.
if [ "$PROVIDER" = "github-copilot" ]; then
    INNER_CMD=(openclaw models auth login-github-copilot)
else
    INNER_CMD=(openclaw models auth login --provider "$PROVIDER" "${EXTRA_ARGS[@]}")
fi

echo "[$(date)] starting oauth flow: ${INNER_CMD[*]}"

# Kill any stale flow for the same provider so the container does not
# accumulate dead pollers.
sudo docker exec openclaw-current sh -c "pkill -f 'oauth_${SAFE_PROVIDER}' 2>/dev/null || true; rm -f $LOG_INSIDE 2>/dev/null || true"

# Launch the OpenClaw CLI inside a script(1) pseudo-TTY in detached mode.
# `--return` preserves the inner exit code; `-q` suppresses banner; `-c` runs
# the command non-interactively. The trailing redirections write the live
# output to a log file the orchestrator (and this wrapper) can poll.
INNER_QUOTED=$(printf '%q ' "${INNER_CMD[@]}")
sudo docker exec -d openclaw-current sh -c \
    "script -qfc \"$INNER_QUOTED\" $LOG_INSIDE >/dev/null 2>&1"

# Poll the log inside the container for the device-flow markers. OpenClaw
# emits something like:
#   To authorize, visit https://chatgpt.com/codex/device and enter the code:
#       ABCD-WXYZ
#   This code expires in 10 minutes.
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
        # The user code is typically a 4-4 group (ABCD-WXYZ) or 8-char alnum.
        CODE=$(printf '%s' "$CLEAN" | grep -oE '\b[A-Z0-9]{4}-[A-Z0-9]{4}\b' | head -1)
        if [ -z "$CODE" ]; then
            CODE=$(printf '%s' "$CLEAN" | grep -oE '\b[A-Z0-9]{8,12}\b' | grep -vE '^(HTTPS?|HTTP|OAUTH|TODO|NULL)$' | head -1)
        fi
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

# Mirror the log out to /mnt/efs so it survives container restarts and the
# orchestrator can read it without docker exec.
sudo docker exec openclaw-current cat "$LOG_INSIDE" 2>/dev/null \
    | sudo tee "$LOG_OUTSIDE" >/dev/null 2>/dev/null || true

# Emit the structured fields the orchestrator parses. Empty strings if the
# flow did not produce a code in time — the orchestrator surfaces an error
# to the portal in that case.
echo "OAUTH_VERIFICATION_URI=${URI}"
echo "OAUTH_USER_CODE=${CODE}"
echo "OAUTH_EXPIRES_IN=${EXPIRES_IN:-600}"
echo "OAUTH_POLL_INTERVAL=${INTERVAL}"
echo "OAUTH_LOG_PATH=${LOG_OUTSIDE}"

# Always exit 0 — the actual OAuth completion is detected by polling
# `openclaw models auth list --json` (via oauth_status.sh) from the
# orchestrator. A non-zero exit here would mark the task as failed and
# the customer would never see the device-code modal.
exit 0

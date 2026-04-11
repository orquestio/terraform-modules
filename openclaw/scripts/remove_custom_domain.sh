#!/bin/bash
# =============================================================================
# remove_custom_domain.sh — Undo add_custom_domain.sh for a given domain.
#
# Contract:
#   remove_custom_domain.sh <domain>
#   exit 0  → domain is not configured on this host (cert gone, server block
#             gone, nginx reloaded). Idempotent: calling this on a domain that
#             was never added is a success.
#   exit 2  → invalid args
#   exit 5  → nginx -t failed after removing server block
#   exit 6  → nginx reload failed
#
# Invoked by the Orquestio orchestrator via AWS SSM send_command as root.
# stdout/stderr go to the SSM command invocation output.
# =============================================================================
set -euo pipefail

DOMAIN="${1:-}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [remove_custom_domain.sh] $*"; }
err() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [remove_custom_domain.sh] ERROR: $*" >&2; }

if [ -z "$DOMAIN" ] || [ "$#" -ne 1 ]; then
  err "usage: remove_custom_domain.sh <domain>"
  exit 2
fi

# Same validation as add_custom_domain.sh so we never build a path from
# untrusted input.
if [ "${#DOMAIN}" -gt 253 ]; then
  err "invalid domain '${DOMAIN}' (length > 253)"
  exit 2
fi
if ! [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
  err "invalid domain '${DOMAIN}' (must be lowercase hostname with at least one dot, chars [a-z0-9.-])"
  exit 2
fi

log "start (domain=${DOMAIN})"

# -----------------------------------------------------------------------------
# Step 1: certbot delete — tolerate "cert not found" as success.
# -----------------------------------------------------------------------------
CERT_PRESENT=0
if certbot certificates --cert-name "$DOMAIN" 2>/dev/null | grep -q "Certificate Name: ${DOMAIN}"; then
  CERT_PRESENT=1
fi

if [ "$CERT_PRESENT" -eq 1 ]; then
  log "deleting certbot certificate for ${DOMAIN}"
  CERTBOT_LOG=$(mktemp)
  trap 'rm -f "$CERTBOT_LOG"' EXIT
  if ! certbot delete --cert-name "$DOMAIN" --non-interactive >"$CERTBOT_LOG" 2>&1; then
    # Not fatal — operator can clean up manually. Log and continue so we still
    # remove the server block and reload nginx.
    err "certbot delete failed for ${DOMAIN} (continuing anyway):"
    tail -n 20 "$CERTBOT_LOG" >&2 || true
  else
    log "certbot delete succeeded"
  fi
else
  log "no certbot certificate for ${DOMAIN} (idempotent path)"
fi

# -----------------------------------------------------------------------------
# Step 2: remove per-domain server block file.
# -----------------------------------------------------------------------------
SAFE_NAME=$(echo "$DOMAIN" | tr '.-' '__')
SERVER_BLOCK="/etc/nginx/conf.d/custom-domain-${SAFE_NAME}.conf"

if [ -f "$SERVER_BLOCK" ]; then
  log "removing ${SERVER_BLOCK}"
  rm -f "$SERVER_BLOCK"
else
  log "${SERVER_BLOCK} not present (idempotent path)"
fi

# -----------------------------------------------------------------------------
# Step 3: nginx -t + reload.
# -----------------------------------------------------------------------------
if ! NGINX_TEST_OUT=$(nginx -t 2>&1); then
  err "nginx -t failed after removing server block for ${DOMAIN}:"
  echo "$NGINX_TEST_OUT" >&2
  exit 5
fi
log "nginx -t passed"

if ! systemctl reload nginx; then
  err "nginx reload failed after removing server block for ${DOMAIN}"
  exit 6
fi

log "remove_custom_domain complete — ${DOMAIN} no longer configured on this host"
exit 0

#!/bin/bash
# =============================================================================
# add_custom_domain.sh — Register a customer-owned domain with Let's Encrypt
#                       and install an nginx server block routing it to the
#                       local OpenClaw upstream.
#
# Contract:
#   add_custom_domain.sh <domain>
#     domain: lowercase hostname, ≤253 chars, at least 1 dot, chars [a-z0-9.-]
#   exit 0  → cert obtained, server block installed, nginx reloaded
#   exit 2  → invalid args / invalid hostname
#   exit 3  → DNS does not resolve to this host's public IP
#   exit 4  → certbot failed
#   exit 5  → nginx -t failed after writing server block
#   exit 6  → nginx reload failed
#
# Invoked by the Orquestio orchestrator via AWS SSM send_command as root.
# stdout/stderr go to the SSM command invocation output.
#
# Strategy: `certbot certonly --webroot` obtains the cert without touching
# nginx config. The main server block in nginx.conf already exposes
# /.well-known/acme-challenge/ from /var/www/html (provisioned by user_data.sh
# and active for any Host hitting :80 since main is the default_server). After
# issuance we write our OWN server block file referencing the cert and
# proxy_pass'ing to http://openclaw_backend (the upstream defined in
# /etc/nginx/conf.d/openclaw-upstream.conf). nginx.conf is NEVER touched.
# The same $auth_ok cookie-auth pattern as the main server block is replicated
# here ($auth_ok is defined by an http-level map in nginx.conf and is visible
# from any server block).
# =============================================================================
set -euo pipefail

DOMAIN="${1:-}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [add_custom_domain.sh] $*"; }
err() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [add_custom_domain.sh] ERROR: $*" >&2; }

if [ -z "$DOMAIN" ] || [ "$#" -ne 1 ]; then
  err "usage: add_custom_domain.sh <domain>"
  exit 2
fi

# Hostname validation:
#   - only lowercase letters, digits, dots, hyphens
#   - total length ≤ 253
#   - at least one dot (reject bare hostnames)
#   - must not start/end with a dot or hyphen
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
# Step 1: DNS check — customer must have pointed the domain at this EIP first.
# IMDSv2 (token-based) — modern Amazon Linux 2023 instances disable IMDSv1.
# -----------------------------------------------------------------------------
IMDS_TOKEN=$(curl -sf -X PUT --max-time 3 \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  http://169.254.169.254/latest/api/token || echo "")
if [ -z "$IMDS_TOKEN" ]; then
  err "could not obtain IMDSv2 session token"
  exit 3
fi
PUBLIC_IP=$(curl -sf --max-time 3 \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4 || echo "")
if [ -z "$PUBLIC_IP" ]; then
  err "could not determine this host's public IP from IMDSv2"
  exit 3
fi
log "this host public IP: ${PUBLIC_IP}"

RESOLVED_IPS=$(dig +short A "$DOMAIN" 2>/dev/null | grep -E '^[0-9.]+$' || true)
if [ -z "$RESOLVED_IPS" ]; then
  err "DNS has no A record for '${DOMAIN}' — the customer must create a CNAME or A record pointing to ${PUBLIC_IP} first, then retry"
  exit 3
fi
log "resolved A records for ${DOMAIN}: $(echo "$RESOLVED_IPS" | tr '\n' ' ')"

MATCH=0
while IFS= read -r ip; do
  if [ "$ip" = "$PUBLIC_IP" ]; then
    MATCH=1
    break
  fi
done <<< "$RESOLVED_IPS"

if [ "$MATCH" -ne 1 ]; then
  err "DNS for '${DOMAIN}' resolves to [$(echo "$RESOLVED_IPS" | tr '\n' ' ')] but this host is ${PUBLIC_IP} — the customer must update their DNS to point at ${PUBLIC_IP} first, then retry"
  exit 3
fi
log "DNS check passed"

# -----------------------------------------------------------------------------
# Step 2: webroot dir for ACME HTTP-01 challenges.
# The main server block in nginx.conf already serves /.well-known/acme-challenge/
# from /var/www/html (provisioned by user_data.sh as the default_server on :80).
# We just ensure the dir exists.
# -----------------------------------------------------------------------------
mkdir -p /var/www/html

# -----------------------------------------------------------------------------
# Step 3: obtain the certificate via webroot.
# -----------------------------------------------------------------------------
log "running certbot certonly --webroot for ${DOMAIN}"
CERTBOT_LOG=$(mktemp)
trap 'rm -f "$CERTBOT_LOG"' EXIT
if ! certbot certonly --webroot \
      -w /var/www/html \
      -d "$DOMAIN" \
      --non-interactive \
      --agree-tos \
      -m admin@orquestio.com \
      --cert-name "$DOMAIN" \
      >"$CERTBOT_LOG" 2>&1; then
  err "certbot failed for ${DOMAIN}"
  err "certbot output (tail 40):"
  tail -n 40 "$CERTBOT_LOG" >&2 || true
  exit 4
fi
log "certbot succeeded — cert at /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"

# -----------------------------------------------------------------------------
# Step 4: write per-domain server block.
# -----------------------------------------------------------------------------
# Sanitize filename: replace '.' and '-' with '_', lowercase (already lower).
SAFE_NAME=$(echo "$DOMAIN" | tr '.-' '__')
SERVER_BLOCK="/etc/nginx/conf.d/custom-domain-${SAFE_NAME}.conf"
log "writing server block to ${SERVER_BLOCK}"

cat > "$SERVER_BLOCK" <<EOF
# Managed by add_custom_domain.sh — customer BYO domain for ${DOMAIN}.
# DO NOT edit by hand. remove_custom_domain.sh will delete this file.
server {
    listen 443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    # ACME renewals (certbot --webroot).
    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/html;
    }

    # Login page served unauthenticated so the cookie-auth flow can complete.
    location = /login {
        root /etc/nginx/html;
        try_files /login.html =404;
    }
    location = /login.html {
        root /etc/nginx/html;
    }

    # Cookie-auth guard — \$auth_ok is defined by an http-level map in
    # /etc/nginx/nginx.conf and is visible from any server block.
    location / {
        if (\$auth_ok = "no") {
            return 302 /login;
        }
        proxy_pass http://openclaw_backend;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-User  "client";
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}

# Redirect plain HTTP for this custom domain to HTTPS (except ACME).
server {
    listen 80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

# -----------------------------------------------------------------------------
# Step 5: test + reload.
# -----------------------------------------------------------------------------
if ! NGINX_TEST_OUT=$(nginx -t 2>&1); then
  err "nginx -t failed after writing server block for ${DOMAIN}:"
  echo "$NGINX_TEST_OUT" >&2
  err "removing bad server block ${SERVER_BLOCK}"
  rm -f "$SERVER_BLOCK"
  exit 5
fi
log "nginx -t passed"

if ! systemctl reload nginx; then
  err "nginx reload failed after writing server block for ${DOMAIN}"
  exit 6
fi

log "add_custom_domain complete — ${DOMAIN} live on this host"
exit 0

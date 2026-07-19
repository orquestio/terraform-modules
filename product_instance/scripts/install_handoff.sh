#!/usr/bin/env bash
#
# install_handoff.sh — idempotently install the brokered-handoff nginx location
# and the inbound-Cookie strip into the shared cookie wall.
#
# WHY out-of-band (not in user_data.sh): the openclaw profile render of
# product_instance/user_data.sh must stay BYTE-IDENTICAL to the frozen
# modules/openclaw golden (render gate). Editing the nginx heredoc there would
# break the gate. Existing instances also carry lifecycle
# ignore_changes=[user_data], so a Terraform re-render would never reach them —
# SSM is the only retrofit channel. This script is the delivery mechanism for
# BOTH new instances (dispatched post-provision) and the existing fleet, exactly
# like rotate_password.sh rewrites conf.d + reloads.
#
# Idempotent: guarded by a sentinel; safe to run on every control-plane dispatch.
# Applies to the main server block (/etc/nginx/nginx.conf) AND every
# custom-domain-*.conf (location = is not inherited across server blocks).
#
# Security (see PRODUCT_PROFILE_CONTRACT.md / project_hermes_handoff_spec):
#   - the handoff location is OUTSIDE the $auth_ok guard (arrives cookieless);
#   - proxy_ssl_verify on so a spoofed api.orquestio.com anycast IP can't harvest
#     codes; X-Forwarded-Host is nginx's own $host, never a client value;
#   - inbound Cookie + Authorization are stripped to the edge and to the product.
set -euo pipefail

SENTINEL="# ORQUESTIO_HANDOFF_V1"
MAIN_CONF="/etc/nginx/nginx.conf"

# CA bundle for proxy_ssl_verify. Amazon Linux 2023 = /etc/pki/...; fall back to
# the Debian path just in case the base image changes.
CA_BUNDLE=""
for c in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
  if [ -f "$c" ]; then CA_BUNDLE="$c"; break; fi
done
if [ -z "$CA_BUNDLE" ]; then
  echo "install_handoff: no CA bundle found; refusing to install unverified TLS" >&2
  exit 1
fi

# Note the Authorization line sits immediately before Cookie so the shared
# Cookie-strip pass below does not append a duplicate inside this block.
read -r -d '' HANDOFF_BLOCK <<NGINX || true
        ${SENTINEL} — brokered login entry. Cookieless by design, deliberately
        # OUTSIDE the \$auth_ok guard. Proxies to the orchestrator edge which
        # validates the single-use code and returns Set-Cookie: oc_session.
        location = /auth/handoff {
            access_log off;
            resolver 169.254.169.253 valid=30s;
            set \$edge_host "api.orquestio.com";
            proxy_pass https://\$edge_host/auth/edge/handoff\$is_args\$args;
            proxy_ssl_server_name on;
            proxy_ssl_name api.orquestio.com;
            proxy_ssl_verify on;
            proxy_ssl_verify_depth 2;
            proxy_ssl_trusted_certificate ${CA_BUNDLE};
            proxy_set_header Host api.orquestio.com;
            proxy_set_header X-Forwarded-Host \$host;
            proxy_set_header X-Forwarded-Proto https;
            proxy_method GET;
            proxy_pass_request_body off;
            proxy_set_header Content-Length "";
            proxy_set_header Authorization "";
            proxy_set_header Cookie "";
        }
NGINX

install_into() {
  local f="$1"
  [ -f "$f" ] || return 0
  if grep -qF "$SENTINEL" "$f"; then
    return 0   # already installed
  fi
  local tmp
  tmp="$(mktemp)"

  # 1) Insert the handoff location before the first `location ` line in the
  #    server block (exact-match `= /auth/handoff` wins regardless of order).
  # 2) Strip inbound Cookie in every proxied location by appending
  #    `proxy_set_header Cookie "";` after each `proxy_set_header Authorization`
  #    line that is not already followed by a Cookie strip.
  awk -v block="$HANDOFF_BLOCK" '
    BEGIN { inserted = 0 }
    {
      buf[NR] = $0
    }
    END {
      for (i = 1; i <= NR; i++) {
        if (!inserted && buf[i] ~ /^[[:space:]]*location[[:space:]]/) {
          print block
          inserted = 1
        }
        print buf[i]
        if (buf[i] ~ /proxy_set_header[[:space:]]+Authorization/ &&
            buf[i+1] !~ /proxy_set_header[[:space:]]+Cookie/) {
          match(buf[i], /^[[:space:]]*/)
          print substr(buf[i], 1, RLENGTH) "proxy_set_header Cookie \"\";"
        }
      }
    }
  ' "$f" > "$tmp"

  # Only replace if awk actually inserted the block (sentinel now present).
  if grep -qF "$SENTINEL" "$tmp"; then
    cat "$tmp" > "$f"
  fi
  rm -f "$tmp"
}

install_into "$MAIN_CONF"
for cd in /etc/nginx/conf.d/custom-domain-*.conf; do
  [ -e "$cd" ] || continue
  install_into "$cd"
done

# Validate before reloading — never leave nginx in a broken state.
if ! nginx -t 2>/tmp/handoff_nginx_test.log; then
  echo "install_handoff: nginx -t FAILED, not reloading:" >&2
  cat /tmp/handoff_nginx_test.log >&2
  exit 1
fi
systemctl reload nginx
echo "install_handoff: OK (ca=${CA_BUNDLE})"

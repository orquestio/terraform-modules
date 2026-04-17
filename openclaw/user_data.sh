#!/bin/bash
# =============================================================================
# User Data — Arranca instancia de cliente con OpenClaw
# Auth: Nginx cookie-based login (custom page Orquestio) + trusted-proxy en OpenClaw
# El cliente inicia sesión con solo el password, sin fricciones, desde cualquier dispositivo.
# =============================================================================
set -euo pipefail

LOG="/var/log/orquestio-bootstrap.log"
exec > >(tee -a "$LOG") 2>&1
echo "[$(date)] Bootstrap starting for instance: ${instance_id}"

# --- 1. Montar EFS ---
echo "[$(date)] Mounting EFS: ${efs_id} via IP ${efs_mount_ip}"
EFS_MOUNT="/mnt/efs"
mkdir -p "$EFS_MOUNT"
mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 "${efs_mount_ip}:/" "$EFS_MOUNT"
mkdir -p "$EFS_MOUNT/config" "$EFS_MOUNT/workspace"
chown -R 1000:1000 "$EFS_MOUNT"
echo "${efs_mount_ip}:/ $EFS_MOUNT nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,_netdev 0 0" >> /etc/fstab
echo "[$(date)] EFS mounted"

# --- 2. Docker Hub login (imagen privada) ---
echo "[$(date)] Logging into Docker Hub..."
DOCKERHUB_CREDS=$(aws ssm get-parameter \
  --name /orquestio/prod/DOCKERHUB_TOKEN \
  --with-decryption \
  --region ${aws_region} \
  --query "Parameter.Value" --output text)
DH_USER=$(echo "$DOCKERHUB_CREDS" | python3 -c "import sys,json;print(json.load(sys.stdin)['username'])")
DH_TOKEN=$(echo "$DOCKERHUB_CREDS" | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
echo "$DH_TOKEN" | docker login -u "$DH_USER" --password-stdin
echo "[$(date)] Docker Hub login OK"

# --- 3. Pull imagen ---
echo "[$(date)] Pulling image: ${docker_image}"
docker pull "${docker_image}"

# --- 4a. Gateway password — persist the terraform-minted password everywhere ---
# The password lives in FOUR places that MUST stay aligned:
#   1. Terraform output "access_password" → orchestrator DB column `access_password`
#      → "Reveal Password" wizard in the Orquestio portal. Source of truth at
#      provisioning time; terraform seeds it via ${gateway_password}.
#   2. AWS Secrets Manager → "orquestio/instances/<id>/gateway-password". Mirror
#      maintained by user_data (bootstrap) and rotate_password.sh (rotations).
#   3. /mnt/efs/config/container.env → OPENCLAW_GATEWAY_PASSWORD (read at docker run).
#   4. openclaw.json → gateway.auth.password (must match the env var or OpenClaw
#      v2026.4.10 auto-rotates gateway.auth.mode to token on restart, breaking
#      the nginx cookie wall).
#   5. /etc/nginx/conf.d/gateway-auth.conf → SHA-256(password) cookie map.
# rotate_password.sh mutates 2-5 atomically (not 1 — that column only applies
# to the INITIAL provisioned password).
GATEWAY_PASSWORD="${gateway_password}"
GATEWAY_SECRET_NAME="orquestio/instances/${instance_id}/gateway-password"
echo "[$(date)] Mirroring gateway password to Secrets Manager: $GATEWAY_SECRET_NAME"
if aws secretsmanager describe-secret --secret-id "$GATEWAY_SECRET_NAME" --region ${aws_region} >/dev/null 2>&1; then
  aws secretsmanager put-secret-value \
    --secret-id "$GATEWAY_SECRET_NAME" \
    --secret-string "$GATEWAY_PASSWORD" \
    --region ${aws_region} >/dev/null
else
  aws secretsmanager create-secret \
    --name "$GATEWAY_SECRET_NAME" \
    --secret-string "$GATEWAY_PASSWORD" \
    --region ${aws_region} \
    --tags Key=Project,Value=orquestio Key=InstanceId,Value=${instance_id} >/dev/null
fi
GATEWAY_COOKIE_HASH=$(echo -n "$GATEWAY_PASSWORD" | sha256sum | cut -d' ' -f1)

# --- 4b. Create openclaw.json with auth pinned to the bootstrap password ---
if [ ! -f "$EFS_MOUNT/config/openclaw.json" ]; then
  echo "[$(date)] Creating OpenClaw config (auth: trusted-proxy, password pinned)..."
  cat > "$EFS_MOUNT/config/openclaw.json" << OCCONFIG
{
  "gateway": {
    "mode": "local",
    "auth": {
      "mode": "trusted-proxy",
      "trustedProxy": {
        "userHeader": "X-Forwarded-User"
      },
      "password": "$GATEWAY_PASSWORD"
    },
    "bind": "lan",
    "port": ${container_port},
    "trustedProxies": ["172.17.0.1", "127.0.0.1"],
    "controlUi": {
      "allowedOrigins": ["https://${instance_id}.orquestio.com"]
    }
  },
  "agents": {
    "defaults": {
      "workspace": "/home/node/.openclaw/workspace"
    }
  },
  "session": {
    "dmScope": "per-channel-peer"
  },
  "wizard": {
    "lastRunAt": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)",
    "lastRunVersion": "2026.4.10",
    "lastRunCommand": "onboard",
    "lastRunMode": "local"
  },
  "meta": {
    "lastTouchedVersion": "2026.4.10",
    "lastTouchedAt": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  }
}
OCCONFIG
  chown 1000:1000 "$EFS_MOUNT/config/openclaw.json"
fi

# --- 5. Arrancar OpenClaw ---
# Container name is "openclaw-current" so that upgrade.sh (Fase 4 Sprint 2.2)
# can reliably address it. Host port is 18789 initially; upgrade.sh will
# alternate between 18789 and 18790 across subsequent upgrades.
#
# --env-file /mnt/efs/config/container.env: runtime env vars set by
# apply_env_vars.sh. The file MUST exist before `docker run` or Docker errors
# out with "no such file" — we `touch` it here with 0600 perms so first boot
# succeeds with an empty env file, and subsequent calls to apply_env_vars.sh
# populate it. A plain `docker restart` does NOT re-read --env-file, which is
# why restart.sh does a full recreate (docker rm + docker run).
CONTAINER_ENV_FILE="$EFS_MOUNT/config/container.env"
if [ ! -f "$CONTAINER_ENV_FILE" ]; then
  touch "$CONTAINER_ENV_FILE"
  chmod 600 "$CONTAINER_ENV_FILE"
  chown 1000:1000 "$CONTAINER_ENV_FILE"
fi
# Pin OPENCLAW_GATEWAY_PASSWORD from the bootstrap secret so every
# restart.sh recreate preserves the same value OpenClaw wrote into
# openclaw.json. apply_env_vars.sh never touches this name.
TMP_BOOTSTRAP_ENV=$(mktemp)
if [ -s "$CONTAINER_ENV_FILE" ]; then
  grep -v '^OPENCLAW_GATEWAY_PASSWORD=' "$CONTAINER_ENV_FILE" > "$TMP_BOOTSTRAP_ENV" || true
fi
echo "OPENCLAW_GATEWAY_PASSWORD=$GATEWAY_PASSWORD" >> "$TMP_BOOTSTRAP_ENV"
mv "$TMP_BOOTSTRAP_ENV" "$CONTAINER_ENV_FILE"
chmod 600 "$CONTAINER_ENV_FILE"
chown 1000:1000 "$CONTAINER_ENV_FILE"

echo "[$(date)] Starting OpenClaw container"
docker run -d \
  --name openclaw-current \
  --restart unless-stopped \
  --env-file "$CONTAINER_ENV_FILE" \
  -e HOME=/home/node \
  -e TERM=xterm-256color \
  -e TZ=UTC \
  -v "$EFS_MOUNT/config:/home/node/.openclaw" \
  -v "$EFS_MOUNT/workspace:/home/node/.openclaw/workspace" \
  -p ${container_port}:${container_port} \
  "${docker_image}" \
  node openclaw.mjs gateway --bind lan --port ${container_port}
# NOTE: entry point changed from `dist/index.js` to `openclaw.mjs` in upstream
# v2026.4.9 (Docker CMD refactor). Older images (≤v2026.4.8) still use
# `dist/index.js`. Keep this command in sync with the docker_image version
# pinned in the blueprint/variables — a mismatch will cause the container
# to crash at startup with "Cannot find module dist/index.js".

# --- 5b. Install control plane scripts (tar.gz in SSM params; inline blew user_data limit) ---
# Sprint 3 (B.1) refactor: en vez de un único script, descargamos un tar.gz que
# contiene los scripts del control plane. Phase C Plan B agregó add/remove
# custom_domain + login.html, y el 2026-04-15 se separó configure_ai_models —
# el payload combinado superó el límite SSM Advanced de 8 KB por value, así
# que dividimos en 3 params:
#   - OPENCLAW_SCRIPTS_B64      → upgrade, restart
#   - OPENCLAW_SEC_SCRIPTS_B64  → rotate_password, apply_env_vars, restore_gateway_auth
#   - OPENCLAW_BYO_SCRIPTS_B64  → add_custom_domain, remove_custom_domain, login.html
#   - OPENCLAW_AI_SCRIPTS_B64   → configure_ai_models
# Los tres se extraen al mismo dir /opt/openclaw/scripts/.
mkdir -p /opt/openclaw/scripts /opt/openclaw
echo "${instance_id}" > /opt/openclaw/instance_id
chmod 644 /opt/openclaw/instance_id

for param in OPENCLAW_SCRIPTS_B64 OPENCLAW_SEC_SCRIPTS_B64 OPENCLAW_BYO_SCRIPTS_B64 OPENCLAW_AI_SCRIPTS_B64; do
  aws ssm get-parameter --name "/orquestio/prod/$param" \
    --region ${aws_region} --query "Parameter.Value" --output text \
    | base64 -d | tar -xzf - -C /opt/openclaw/scripts/
done
chmod +x /opt/openclaw/scripts/*.sh
echo "[$(date)] control plane scripts installed: $(ls /opt/openclaw/scripts/)"

# --- 6. CloudWatch Agent ---
echo "[$(date)] Starting CloudWatch Agent"
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

# --- 7. Nginx + certbot: cookie auth + login page + reverse proxy + BYO TLS ---
echo "[$(date)] Setting up Nginx + certbot"
dnf install -y -q nginx httpd-tools certbot python3-certbot-nginx cronie
systemctl enable --now crond
mkdir -p /var/www/html /etc/cron.d

# Daily certbot renewal cron — Let's Encrypt 60d renewal window. The
# /var/www/html webroot is shared across all custom domains on this host;
# add_custom_domain.sh writes per-domain server blocks to /etc/nginx/conf.d/.
cat > /etc/cron.d/certbot-renew << 'CRONFILE'
SHELL=/bin/bash
PATH=/sbin:/bin:/usr/sbin:/usr/bin
# Run twice daily at random offsets, reload nginx on success.
17 3 * * * root certbot renew --quiet --webroot -w /var/www/html --post-hook "systemctl reload nginx"
17 15 * * * root certbot renew --quiet --webroot -w /var/www/html --post-hook "systemctl reload nginx"
CRONFILE
chmod 644 /etc/cron.d/certbot-renew

# Cookie value = SHA-256 del password (bootstrap; rotate_password.sh rewrites this later)
COOKIE_VALUE="$GATEWAY_COOKIE_HASH"

# Login page con branding Orquestio — extraído del tar.gz a /opt/openclaw/scripts/login.html
# El bloque inline original fue removido en Phase C Plan B (excedía el
# 16384 byte limit del user_data después de añadir certbot + ACME loc).
mkdir -p /etc/nginx/html
cp /opt/openclaw/scripts/login.html /etc/nginx/html/login.html

# Upstream file — este archivo lo reescribe upgrade.sh durante rolling
# replacement para apuntar al container nuevo sin tocar el resto de la config
# de nginx. Sprint 2.2 depende de que viva en conf.d/ como archivo separado.
mkdir -p /etc/nginx/conf.d
cat > /etc/nginx/conf.d/openclaw-upstream.conf << UPSTREAMCONF
# Managed by /opt/openclaw/scripts/upgrade.sh — do not edit by hand.
upstream openclaw_backend {
    server 127.0.0.1:${container_port};
}
UPSTREAMCONF

# Cookie auth map — separado para que rotate_password.sh pueda reescribirlo
# atómicamente y hacer `systemctl reload nginx` sin tocar nginx.conf ni el
# server block. Debe ir en conf.d/ (se incluye ANTES del server block vía
# include /etc/nginx/conf.d/*.conf en nginx.conf).
cat > /etc/nginx/conf.d/gateway-auth.conf << GWAUTHCONF
# Managed by /opt/openclaw/scripts/rotate_password.sh — do not edit by hand.
# Cookie oc_session value = SHA-256(OPENCLAW_GATEWAY_PASSWORD).
map \$cookie_oc_session \$auth_ok {
    "$COOKIE_VALUE" "yes";
    default "no";
}
GWAUTHCONF

# Nginx config principal — el server block apunta al upstream openclaw_backend
# definido en /etc/nginx/conf.d/openclaw-upstream.conf. Cargamos TODOS los
# archivos de conf.d/*.conf con wildcard para que add_custom_domain.sh pueda
# inyectar nuevos server blocks (custom-domain-*.conf) sin tocar nginx.conf.
# El main server block es el default_server :80 — captura el internal
# subdomain (${instance_id}.orquestio.com) y, mientras un BYO domain todavía
# no tiene su 443 block, también captura el HTTP-01 challenge de certbot.
cat > /etc/nginx/nginx.conf << NGINXCONF
events { worker_connections 1024; }
http {
    # Cloudflare terminates TLS and proxies HTTP to the origin. Without
    # this flag, `return 302 /login` emits an absolute Location built from
    # the origin's $scheme (http) — the browser drops out of HTTPS and the
    # Secure cookie fails. Relative redirects sidestep the whole mess.
    absolute_redirect off;
    map_hash_bucket_size 128;

    include /etc/nginx/conf.d/*.conf;

    server {
        listen 80 default_server;
        server_name ${instance_id}.orquestio.com;

        # Let's Encrypt HTTP-01 challenges for any BYO domain on this host.
        # Served unauthenticated. Webroot dir is shared with the certbot
        # cron renewal job in /etc/cron.d/certbot-renew.
        location ^~ /.well-known/acme-challenge/ {
            default_type "text/plain";
            root /var/www/html;
        }

        location = /login {
            alias /etc/nginx/html/login.html;
            default_type text/html;
        }

        # Logout: expira la cookie oc_session en el browser y redirige a
        # /login. Serverless — ningún estado server-side que invalidar (el
        # password vive; esto es solo "borrar la cookie de este device").
        # Para invalidar TODAS las sesiones usar rotate_password desde el
        # portal (genera password nuevo → todas las cookies existentes
        # dejan de matchear el map de conf.d/gateway-auth.conf).
        location = /orquestio-logout {
            add_header Set-Cookie "oc_session=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax";
            return 302 /login;
        }

        location = /healthz {
            if (\$auth_ok = "no") {
                return 401 '{"error":"unauthorized"}';
            }
            proxy_pass http://openclaw_backend/healthz;
        }

        location / {
            if (\$auth_ok = "no") {
                return 302 /login;
            }
            proxy_pass http://openclaw_backend;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-User "client";
        }
    }
}
NGINXCONF

systemctl enable nginx
systemctl start nginx

# Guard: verify nginx is actually running. Intermittent failures observed
# (ai-test-006, 2026-04-17) where systemctl start returned 0 but the
# service died immediately after. Retry up to 3 times with a short delay.
for attempt in 1 2 3; do
  sleep 2
  if systemctl is-active --quiet nginx; then
    echo "[$(date)] nginx confirmed active (attempt $attempt)"
    break
  fi
  echo "[$(date)] WARNING: nginx not active after start, retry $attempt/3..."
  systemctl start nginx
done
if ! systemctl is-active --quiet nginx; then
  echo "[$(date)] CRITICAL: nginx failed to start after 3 retries"
  systemctl status nginx --no-pager || true
fi

echo "[$(date)] Bootstrap complete. Instance ready."
echo "[$(date)] Access: https://${instance_id}.orquestio.com"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

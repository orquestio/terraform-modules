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

# --- 4. Crear configuración de OpenClaw (trusted-proxy, sin pairing) ---
if [ ! -f "$EFS_MOUNT/config/openclaw.json" ]; then
  echo "[$(date)] Creating OpenClaw config (auth: trusted-proxy)..."
  cat > "$EFS_MOUNT/config/openclaw.json" << OCCONFIG
{
  "gateway": {
    "mode": "local",
    "auth": {
      "mode": "trusted-proxy",
      "trustedProxy": {
        "userHeader": "X-Forwarded-User"
      }
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
# update_env_var.sh. The file MUST exist before `docker run` or Docker errors
# out with "no such file" — we `touch` it here with 0600 perms so first boot
# succeeds with an empty env file, and subsequent calls to update_env_var.sh
# populate it. A plain `docker restart` does NOT re-read --env-file, which is
# why restart.sh does a full recreate (docker rm + docker run).
CONTAINER_ENV_FILE="$EFS_MOUNT/config/container.env"
if [ ! -f "$CONTAINER_ENV_FILE" ]; then
  touch "$CONTAINER_ENV_FILE"
  chmod 600 "$CONTAINER_ENV_FILE"
  chown 1000:1000 "$CONTAINER_ENV_FILE"
fi

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
#   - OPENCLAW_SCRIPTS_B64      → upgrade, restart, rotate_password, update_env_var
#   - OPENCLAW_BYO_SCRIPTS_B64  → add_custom_domain, remove_custom_domain, login.html
#   - OPENCLAW_AI_SCRIPTS_B64   → configure_ai_models
# Los tres se extraen al mismo dir /opt/openclaw/scripts/.
mkdir -p /opt/openclaw/scripts /opt/openclaw
echo "${instance_id}" > /opt/openclaw/instance_id
chmod 644 /opt/openclaw/instance_id

for param in OPENCLAW_SCRIPTS_B64 OPENCLAW_BYO_SCRIPTS_B64 OPENCLAW_AI_SCRIPTS_B64; do
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

# Cookie value = SHA-256 del password
COOKIE_VALUE=$(echo -n "${gateway_password}" | sha256sum | cut -d' ' -f1)

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

# Cookie auth map — vive en conf.d/ (NO inline en nginx.conf) para que
# rotate_password.sh pueda reescribirlo atómicamente y `systemctl reload
# nginx` sin tocar nginx.conf ni el server block. Si este map vive inline
# duplicado en http {}, la definición inline gana (last-defined-wins) y
# toda rotación posterior queda invisible — login se rompe. No mover.
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
    # Cloudflare termina TLS y proxea HTTP al origen. Sin este flag, un
    # `return 302 /login` emite Location absoluto con el $scheme del origen
    # (http) — el browser sale de HTTPS y la cookie Secure no se setea.
    # Redirect relativo evita el problema.
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
        # /login. Serverless — ningún estado server-side que invalidar.
        # Para invalidar TODAS las sesiones usar rotate_password desde el
        # portal (todas las cookies existentes dejan de matchear el map).
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

echo "[$(date)] Bootstrap complete. Instance ready."
echo "[$(date)] Access: https://${instance_id}.orquestio.com"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

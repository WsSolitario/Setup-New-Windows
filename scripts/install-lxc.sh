#!/usr/bin/env bash
set -Eeuo pipefail

# Instala la API dentro de un LXC Debian/Ubuntu administrado por Proxmox.
# Ejecutar dentro del contenedor como root, no en el nodo Proxmox.

readonly APP_NAME="workstation-setup"
readonly APP_USER="workstation"
readonly APP_GROUP="workstation"
readonly APP_DIR="/opt/${APP_NAME}"
readonly SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
readonly NGINX_SITE="/etc/nginx/sites-available/${APP_NAME}"
readonly REPOSITORY_URL="${REPOSITORY_URL:-https://github.com/WsSolitario/Setup-New-Windows.git}"
readonly NINITE_DOWNLOAD_URL="${NINITE_DOWNLOAD_URL:-https://ninite.com/anydesk-chrome-firefox-git-python3-revo-teams-teamviewer15-winrar-zoom/ninite.exe}"

DOMAIN=""
PUBLIC_BASE_URL=""
POSTGRES_PASSWORD=""
LOCAL_ADMIN_PASSWORD=""
ENABLE_NGINX="false"
ENABLE_TLS="false"
ENABLE_CLOUDFLARE_DNS="false"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
BRANCH="main"

log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

cleanup_on_error() {
  local line=$1
  printf '\nERROR: instalacion fallida en la linea %s.\n' "$line" >&2
}
trap 'cleanup_on_error "$LINENO"' ERR

usage() {
  cat <<'EOF'
Uso:
  sudo bash scripts/install-lxc.sh [opciones]

Opciones:
  --domain DOMINIO       Publica la API con Nginx en ese dominio.
  --tls                  Instala Certbot y solicita Let's Encrypt para --domain.
  --cloudflare-dns       Usa desafio DNS de Cloudflare (requiere CLOUDFLARE_API_TOKEN).
  --public-url URL       URL publica usada para generar setup.ps1.
  --branch RAMA          Rama Git a instalar (por defecto: main).
  --no-nginx             No instala ni configura Nginx.
  -h, --help             Muestra esta ayuda.

Variables opcionales:
  REPOSITORY_URL         URL del repositorio Git.
EOF
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Ejecuta este script como root dentro del LXC."
  [[ -f /etc/os-release ]] || die "Sistema operativo no soportado."
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "Se requiere Debian o Ubuntu; detectado: ${ID:-desconocido}." ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) [[ $# -ge 2 ]] || die "--domain necesita un valor"; DOMAIN="$2"; ENABLE_NGINX="true"; shift 2 ;;
      --tls) ENABLE_TLS="true"; ENABLE_NGINX="true"; shift ;;
      --cloudflare-dns) ENABLE_CLOUDFLARE_DNS="true"; ENABLE_TLS="true"; ENABLE_NGINX="true"; shift ;;
      --public-url) [[ $# -ge 2 ]] || die "--public-url necesita un valor"; PUBLIC_BASE_URL="$2"; shift 2 ;;
      --branch) [[ $# -ge 2 ]] || die "--branch necesita un valor"; BRANCH="$2"; shift 2 ;;
      --no-nginx) ENABLE_NGINX="false"; ENABLE_TLS="false"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Opcion desconocida: $1" ;;
    esac
  done

  if [[ "$ENABLE_TLS" == "true" && -z "$DOMAIN" ]]; then
    die "--tls requiere --domain DOMINIO."
  fi
  if [[ "$ENABLE_CLOUDFLARE_DNS" == "true" && -z "$CLOUDFLARE_API_TOKEN" ]]; then
    die "--cloudflare-dns requiere CLOUDFLARE_API_TOKEN en el entorno."
  fi
  if [[ -z "$PUBLIC_BASE_URL" ]]; then
    if [[ -n "$DOMAIN" ]]; then
      PUBLIC_BASE_URL="https://${DOMAIN}"
    else
      PUBLIC_BASE_URL="http://$(hostname -I | awk '{print $1}'):3000"
    fi
  fi
  [[ "$PUBLIC_BASE_URL" =~ ^https?://[^/]+$ ]] || die "--public-url debe tener formato https://dominio, sin barra final."
}

prompt_secrets() {
  if [[ -z "${POSTGRES_PASSWORD}" ]]; then
    read -r -s -p 'Contrasena de PostgreSQL para el usuario workstation: ' POSTGRES_PASSWORD; printf '\n'
  fi
  if [[ -z "${LOCAL_ADMIN_PASSWORD}" ]]; then
    read -r -s -p 'Contrasena de la cuenta local Plasencia para setup.ps1: ' LOCAL_ADMIN_PASSWORD; printf '\n'
  fi
  [[ ${#POSTGRES_PASSWORD} -ge 12 ]] || die 'La contrasena de PostgreSQL debe tener al menos 12 caracteres.'
  [[ -n "$LOCAL_ADMIN_PASSWORD" ]] || die 'La contrasena local no puede estar vacia.'
}

install_packages() {
  log 'Instalando dependencias del sistema'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl git gnupg openssl postgresql postgresql-contrib

  if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt 20 ]]; then
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
    printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main\n' > /etc/apt/sources.list.d/nodesource.list
    apt-get update
    apt-get install -y nodejs
  fi

  if [[ "$ENABLE_NGINX" == "true" ]]; then
    apt-get install -y --no-install-recommends nginx
  fi
  if [[ "$ENABLE_TLS" == "true" ]]; then
    apt-get install -y --no-install-recommends certbot python3-certbot-nginx
    if [[ "$ENABLE_CLOUDFLARE_DNS" == "true" ]]; then
      apt-get install -y --no-install-recommends python3-certbot-dns-cloudflare
    fi
  fi
}

configure_database() {
  log 'Configurando PostgreSQL'
  systemctl enable --now postgresql
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${APP_USER}') THEN
    CREATE ROLE ${APP_USER} LOGIN PASSWORD '${POSTGRES_PASSWORD//\'/\'\'}';
  ELSE
    ALTER ROLE ${APP_USER} WITH LOGIN PASSWORD '${POSTGRES_PASSWORD//\'/\'\'}';
  END IF;
END
\$\$;
SQL
  if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='workstations'" | grep -q 1; then
    runuser -u postgres -- createdb -O "${APP_USER}" workstations
  fi
  # Permite que el usuario de la API use el esquema sin abrir PostgreSQL a Internet.
  runuser -u postgres -- psql -d workstations -v ON_ERROR_STOP=1 -c "GRANT CONNECT ON DATABASE workstations TO ${APP_USER}; GRANT USAGE,CREATE ON SCHEMA public TO ${APP_USER};"
}

install_application() {
  log 'Descargando la aplicacion desde GitHub'
  install -d -m 0755 /opt
  if [[ -d "${APP_DIR}/.git" ]]; then
    git -C "$APP_DIR" fetch --depth=1 origin "$BRANCH"
    git -C "$APP_DIR" checkout -B "$BRANCH" "origin/$BRANCH"
    git -C "$APP_DIR" clean -fd -e artifacts/ninite.exe
  else
    rm -rf "$APP_DIR"
    git clone --depth=1 --branch "$BRANCH" "$REPOSITORY_URL" "$APP_DIR"
  fi
  install -d -o "$APP_USER" -g "$APP_GROUP" -m 0750 "$APP_DIR/artifacts"
  chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"
  runuser -u "$APP_USER" -- npm --prefix "$APP_DIR" ci --omit=dev
  runuser -u "$APP_USER" -- psql --version >/dev/null 2>&1 || true
  PGPASSWORD="$POSTGRES_PASSWORD" runuser -u "$APP_USER" -- env PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=workstations PGUSER="$APP_USER" psql -v ON_ERROR_STOP=1 -f "$APP_DIR/sql/init.sql"
  if [[ ! -s "$APP_DIR/artifacts/ninite.exe" ]]; then
    log 'Descargando Ninite desde ninite.com'
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
      "$NINITE_DOWNLOAD_URL" -o "$APP_DIR/artifacts/ninite.exe"
    chown "$APP_USER:$APP_GROUP" "$APP_DIR/artifacts/ninite.exe"
    chmod 0755 "$APP_DIR/artifacts/ninite.exe"
  fi
}

write_environment() {
  log 'Escribiendo configuracion privada de la API'
  install -d -m 0750 -o "$APP_USER" -g "$APP_GROUP" /etc/workstation-setup
  cat > /etc/workstation-setup/workstation-setup.env <<EOF
NODE_ENV=production
PORT=3000
TRUST_PROXY=1
PGHOST=127.0.0.1
PGPORT=5432
PGDATABASE=workstations
PGUSER=${APP_USER}
PGPASSWORD=${POSTGRES_PASSWORD}
PGSSL=false
PUBLIC_BASE_URL=${PUBLIC_BASE_URL}
LOCAL_ADMIN_USERNAME=Plasencia
LOCAL_ADMIN_FULL_NAME=Nombre Plasencia
LOCAL_ADMIN_PASSWORD=${LOCAL_ADMIN_PASSWORD}
NINITE_PATH=${APP_DIR}/artifacts/ninite.exe
EOF
  chown "$APP_USER:$APP_GROUP" /etc/workstation-setup/workstation-setup.env
  chmod 0600 /etc/workstation-setup/workstation-setup.env
}

configure_service() {
  log 'Configurando el servicio systemd'
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Workstation Setup API
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_DIR}
EnvironmentFile=/etc/workstation-setup/workstation-setup.env
ExecStart=/usr/bin/node ${APP_DIR}/src/server.js
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${APP_DIR}/artifacts

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$APP_NAME"
  sleep 1
  curl --fail --silent http://127.0.0.1:3000/health >/dev/null
}

configure_nginx() {
  [[ "$ENABLE_NGINX" == "true" ]] || return 0
  log "Configurando Nginx para ${DOMAIN}"
  cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  ln -sfn "$NGINX_SITE" "/etc/nginx/sites-enabled/${APP_NAME}"
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
  if [[ "$ENABLE_TLS" == "true" ]]; then
    log 'Solicitando certificado Lets Encrypt'
    if [[ "$ENABLE_CLOUDFLARE_DNS" == "true" ]]; then
      install -d -m 0700 /etc/letsencrypt
      printf 'dns_cloudflare_api_token = %s\n' "$CLOUDFLARE_API_TOKEN" > /etc/letsencrypt/cloudflare.ini
      chmod 0600 /etc/letsencrypt/cloudflare.ini
      if ! certbot run --non-interactive --agree-tos --register-unsafely-without-email \
          --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
          --nginx --redirect -d "$DOMAIN"; then
        rm -f /etc/letsencrypt/cloudflare.ini
        return 1
      fi
      rm -f /etc/letsencrypt/cloudflare.ini
    else
      certbot --nginx --non-interactive --agree-tos --register-unsafely-without-email \
        --redirect -d "$DOMAIN"
    fi
  fi
}

main() {
  require_root
  parse_args "$@"
  prompt_secrets
  install_packages
  getent group "$APP_GROUP" >/dev/null || groupadd --system "$APP_GROUP"
  id "$APP_USER" >/dev/null 2>&1 || useradd --system --gid "$APP_GROUP" --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
  configure_database
  install_application
  write_environment
  configure_service
  configure_nginx

  log 'Instalacion completada'
  printf 'API local: http://127.0.0.1:3000/health\n'
  printf 'URL publica configurada: %s\n' "$PUBLIC_BASE_URL"
  printf 'Servicio: systemctl status %s\n' "$APP_NAME"
  printf 'Ninite: copie el ejecutable autorizado en %s/artifacts/ninite.exe\n' "$APP_DIR"
}

main "$@"

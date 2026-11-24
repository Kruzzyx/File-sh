#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/pterodactyl/config.yml"
SERVICE_FILE="/etc/systemd/system/wings.service"
PANEL_DIR="/var/www/pterodactyl"

DRY_RUN=0
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--dry-run" ] || [ "$arg" = "--check" ]; then
    DRY_RUN=1
  else
    ARGS+=("$arg")
  fi
done

PANEL_DOMAIN="${ARGS[0]:-${PANEL_DOMAIN:-}}"
NODE_DOMAIN="${ARGS[1]:-${NODE_DOMAIN:-}}"
VPS_IP="${ARGS[2]:-${VPS_IP:-}}"
PTLA_KEY="${PTLA_KEY:-}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

warn() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" >&2
}

clean_domain() {
  local val="$1"
  val="${val#https://}"
  val="${val#http://}"
  val="${val%%/*}"
  printf '%s' "$val" | tr -d '[:space:]'
}

require_root() {
  if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "Jalankan script ini sebagai root." >&2
    exit 1
  fi
}

prompt_inputs() {
  if [ -z "$PANEL_DOMAIN" ]; then
    read -r -p "Masukkan Alamat VPS (Domain Panel): " PANEL_DOMAIN < /dev/tty
  fi
  if [ -z "$NODE_DOMAIN" ]; then
    read -r -p "Masukkan Node VPS (FQDN Node): " NODE_DOMAIN < /dev/tty
  fi
  if [ -z "$VPS_IP" ]; then
    read -r -p "Masukkan IP VPS (IPv4): " VPS_IP < /dev/tty
  fi

  PANEL_DOMAIN="$(clean_domain "$PANEL_DOMAIN")"
  NODE_DOMAIN="$(clean_domain "$NODE_DOMAIN")"
  VPS_IP="$(printf '%s' "$VPS_IP" | tr -d '[:space:]')"

  if [ -z "$PANEL_DOMAIN" ] || [ -z "$NODE_DOMAIN" ] || [ -z "$VPS_IP" ]; then
    echo "Alamat VPS, Node VPS, dan IP VPS wajib diisi." >&2
    exit 1
  fi

  log "Input -> Alamat VPS: ${PANEL_DOMAIN} | Node VPS: ${NODE_DOMAIN} | IP VPS: ${VPS_IP}"
}

resolve_ipv4() {
  local domain="$1"
  local ip=""

  if command -v getent >/dev/null 2>&1; then
    ip="$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1 {print $1}' | tr -d '[:space:]' || true)"
  fi
  if [ -z "$ip" ] && command -v dig >/dev/null 2>&1; then
    ip="$(dig +short A "$domain" 2>/dev/null | awk 'NR==1 {print $1}' | tr -d '[:space:]' || true)"
  fi
  if [ -z "$ip" ] && command -v host >/dev/null 2>&1; then
    ip="$(host -t A "$domain" 2>/dev/null | awk '/has address/ {print $4; exit}' | tr -d '[:space:]' || true)"
  fi

  printf '%s' "$ip"
}

check_domains_dns() {
  local node_ip
  local panel_ip

  node_ip="$(resolve_ipv4 "$NODE_DOMAIN")"
  panel_ip="$(resolve_ipv4 "$PANEL_DOMAIN")"

  if [ -z "$node_ip" ] || [ "$node_ip" != "$VPS_IP" ]; then
    echo "Maaf Nodes Tidak Tersambung dengan ipvps"
    warn "FQDN Node '${NODE_DOMAIN}' resolve ke '${node_ip:-NXDOMAIN}', tidak sama dengan IP VPS '${VPS_IP}'."
    return 1
  fi
  log "DNS FQDN Node '${NODE_DOMAIN}' tersambung dengan IP VPS (${node_ip})."

  if [ -z "$panel_ip" ] || [ "$panel_ip" != "$VPS_IP" ]; then
    echo "Maaf Domain Panel Tidak Tersambung dengan ipvps"
    warn "Domain Panel '${PANEL_DOMAIN}' resolve ke '${panel_ip:-NXDOMAIN}', tidak sama dengan IP VPS '${VPS_IP}'."
    return 1
  fi
  log "DNS Domain Panel '${PANEL_DOMAIN}' tersambung dengan IP VPS (${panel_ip})."

  return 0
}

fix_nginx_and_ssl() {
  log "Memeriksa Nginx dan sertifikat dasar..."

  if ! command -v nginx >/dev/null 2>&1; then
    warn "Nginx belum terpasang, melewati reload Nginx."
    return 0
  fi

  local panel_cert="/etc/ssl/${PANEL_DOMAIN}.pem"
  local panel_key="/etc/ssl/${PANEL_DOMAIN}.key"

  if [ ! -f "$panel_cert" ] || [ ! -f "$panel_key" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[DRY-RUN] Akan membuat sertifikat SAN fallback di ${panel_cert} dan ${panel_key}."
    else
      log "Sertifikat ${panel_cert} belum ditemukan. Membuat sertifikat SAN fallback..."
      mkdir -p /etc/ssl

      cat <<EOF > /etc/ssl/san.cnf
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = ${PANEL_DOMAIN}

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${PANEL_DOMAIN}
DNS.2 = ${NODE_DOMAIN}
EOF

      openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$panel_key" \
        -out "$panel_cert" \
        -config /etc/ssl/san.cnf >/dev/null 2>&1

      cp "$panel_cert" "/usr/local/share/ca-certificates/${PANEL_DOMAIN}.crt"
      update-ca-certificates >/dev/null 2>&1 || true
      log "Sertifikat SAN fallback terpasang."
    fi
  fi

  if nginx -t >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[DRY-RUN] nginx -t sukses; akan melakukan reload nginx."
    else
      systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx
      log "Nginx valid dan berhasil di-reload."
    fi
  else
    warn "nginx -t masih gagal. Periksa konfigurasi di /etc/nginx/sites-enabled/ dan /etc/nginx/conf.d/."
  fi
}

ensure_panel_node_ssl() {
  log "Memeriksa Communicate Over SSL di Panel untuk node '${NODE_DOMAIN}'..."

  if [ -d "$PANEL_DIR" ] && [ -f "${PANEL_DIR}/artisan" ] && command -v php >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[DRY-RUN] Akan mengecek & mengubah scheme node '${NODE_DOMAIN}' ke 'https' via php artisan di ${PANEL_DIR}."
      return 0
    fi

    local artisan_out
    artisan_out="$(cd "$PANEL_DIR" && php artisan tinker --execute="
\$node = \Pterodactyl\Models\Node::where('fqdn', '${NODE_DOMAIN}')->first();
if (!\$node) { echo 'NOT_FOUND'; exit; }
if (\$node->scheme === 'https') { echo 'ALREADY_HTTPS'; exit; }
\$node->scheme = 'https';
\$node->save();
echo 'UPDATED_TO_HTTPS';
" 2>/dev/null | tail -n 1 || true)"

    case "$artisan_out" in
      ALREADY_HTTPS)
        log "Communicate Over SSL di Panel sudah 'Use SSL Connection' (https)."
        return 0
        ;;
      UPDATED_TO_HTTPS)
        log "Communicate Over SSL di Panel berhasil dipindahkan dari 'http' ke 'https' (Use SSL Connection)."
        return 0
        ;;
      NOT_FOUND)
        warn "Node '${NODE_DOMAIN}' belum terdaftar di database Panel."
        return 0
        ;;
    esac
  fi

  if [ -n "$PTLA_KEY" ] && command -v python3 >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[DRY-RUN] Akan mengecek & mengubah scheme node '${NODE_DOMAIN}' ke 'https' via API https://${PANEL_DOMAIN}."
      return 0
    fi

    python3 - "https://${PANEL_DOMAIN}" "$PTLA_KEY" "$NODE_DOMAIN" <<'PY'
import json, sys, urllib.request, urllib.error

base_url, api_key, target_fqdn = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
headers = {
    "Authorization": f"Bearer {api_key}",
    "Accept": "application/json",
    "Content-Type": "application/json",
}

def req(method, path, payload=None):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    r = urllib.request.Request(f"{base_url}{path}", data=data, headers=headers, method=method)
    with urllib.request.urlopen(r, timeout=15) as resp:
        return json.loads(resp.read().decode("utf-8"))

try:
    nodes_resp = req("GET", "/api/application/nodes?per_page=100")
    matched = None
    for item in nodes_resp.get("data", []):
        attr = item.get("attributes", {})
        if attr.get("fqdn") == target_fqdn:
            matched = attr
            break

    if not matched:
        print(f"[WARN] Node '{target_fqdn}' tidak ditemukan via Application API.", file=sys.stderr)
        sys.exit(0)

    node_id = matched["id"]
    scheme = matched.get("scheme")
    if scheme == "https":
        print("Communicate Over SSL di Panel sudah 'Use SSL Connection' (https).")
        sys.exit(0)

    patch_body = {
        "name": matched["name"],
        "description": matched.get("description") or "",
        "location_id": matched["location_id"],
        "fqdn": matched["fqdn"],
        "scheme": "https",
        "behind_proxy": bool(matched.get("behind_proxy", False)),
        "maintenance_mode": bool(matched.get("maintenance_mode", False)),
        "memory": matched["memory"],
        "memory_overallocate": matched["memory_overallocate"],
        "disk": matched["disk"],
        "disk_overallocate": matched["disk_overallocate"],
        "upload_size": matched["upload_size"],
        "daemon_base": matched["daemon_base"],
        "daemon_listen": matched["daemon_listen"],
        "daemon_sftp": matched["daemon_sftp"],
    }
    req("PATCH", f"/api/application/nodes/{node_id}", patch_body)
    print("Communicate Over SSL di Panel berhasil dipindahkan dari 'http' ke 'https' (Use SSL Connection).")
except urllib.error.HTTPError as e:
    print(f"[WARN] Gagal update scheme node via API (HTTP {e.code}): {e.read().decode('utf-8', 'ignore')}", file=sys.stderr)
except Exception as e:
    print(f"[WARN] Error saat cek/update scheme node via API: {e}", file=sys.stderr)
PY
    return 0
  fi

  warn "Lewati auto-ubah Communicate Over SSL di Panel (folder ${PANEL_DIR} tidak ada dan PTLA_KEY belum diisi). Pastikan 'Use SSL Connection' dipilih di Panel."
}

install_wings_if_needed() {
  if [ "$DRY_RUN" -eq 1 ]; then
    command -v docker >/dev/null 2>&1 && log "[DRY-RUN] Docker sudah ada." || log "[DRY-RUN] Akan menginstal Docker."
    [ -x /usr/local/bin/wings ] && log "[DRY-RUN] Binary Wings sudah ada." || log "[DRY-RUN] Akan mengunduh binary Wings."
    [ -f "$SERVICE_FILE" ] && log "[DRY-RUN] Service Wings sudah ada." || log "[DRY-RUN] Akan membuat ${SERVICE_FILE}."
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    log "Menginstal Docker Engine..."
    curl -sSL https://get.docker.com/ | CHANNEL=stable sh
    systemctl enable --now docker
  else
    log "Docker sudah terpasang: $(docker --version)"
  fi

  mkdir -p /etc/pterodactyl /var/log/pterodactyl

  if [ ! -x /usr/local/bin/wings ]; then
    local arch
    case "$(uname -m)" in
      x86_64|amd64) arch="amd64" ;;
      aarch64|arm64) arch="arm64" ;;
      *)
        echo "Arsitektur tidak didukung: $(uname -m)" >&2
        exit 1
        ;;
    esac

    log "Mengunduh binary Wings (${arch})..."
    curl -fSL -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${arch}"
    chmod u+x /usr/local/bin/wings
    log "Binary Wings terpasang: $(/usr/local/bin/wings --version | head -n 1 || true)"
  else
    log "Binary Wings sudah tersedia di /usr/local/bin/wings."
  fi

  if [ ! -f "$SERVICE_FILE" ]; then
    log "Membuat unit service ${SERVICE_FILE}..."
    cat <<'EOF' > /etc/systemd/system/wings.service
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable wings >/dev/null 2>&1
  fi
}

check_node_config() {
  if [ ! -s "$CONFIG_FILE" ]; then
    warn "Konfigurasi node belum ada atau kosong di ${CONFIG_FILE}."
    return 1
  fi

  if ! grep -Eq "^remote:" "$CONFIG_FILE" || ! grep -Eq "^api:" "$CONFIG_FILE"; then
    warn "Konfigurasi di ${CONFIG_FILE} belum memuat field 'remote:' dan 'api:' yang valid."
    return 1
  fi

  log "Konfigurasi node ditemukan di ${CONFIG_FILE}."
  return 0
}

configure_wings_ssl() {
  local cert_file=""
  local key_file=""

  if command -v certbot >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[DRY-RUN] Akan menjalankan certbot untuk ${NODE_DOMAIN}."
    else
      log "Menjalankan certbot untuk ${NODE_DOMAIN}..."
      if certbot certonly --nginx -d "$NODE_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email >/dev/null 2>&1; then
        if [ -f "/etc/letsencrypt/live/${NODE_DOMAIN}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${NODE_DOMAIN}/privkey.pem" ]; then
          cert_file="/etc/letsencrypt/live/${NODE_DOMAIN}/fullchain.pem"
          key_file="/etc/letsencrypt/live/${NODE_DOMAIN}/privkey.pem"
          log "Sertifikat Let's Encrypt aktif untuk ${NODE_DOMAIN}."
        fi
      else
        warn "Certbot gagal untuk ${NODE_DOMAIN}. Menggunakan sertifikat SAN sebagai fallback."
      fi
    fi
  else
    warn "certbot tidak ditemukan. Menggunakan sertifikat SAN sebagai fallback."
  fi

  if [ -z "$cert_file" ] || [ -z "$key_file" ]; then
    cert_file="/etc/ssl/${PANEL_DOMAIN}.pem"
    key_file="/etc/ssl/${PANEL_DOMAIN}.key"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[DRY-RUN] Akan mengupdate ${CONFIG_FILE} -> enabled=true, cert=${cert_file}, key=${key_file}."
    return 0
  fi

  cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

  python3 - "$CONFIG_FILE" "$cert_file" "$key_file" <<'PY'
import sys, re

path, cert, key = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

content = re.sub(
    r"(ssl:\s*\n(?:\s+[^\n]+\n)*?\s+enabled:\s*)(false|true)",
    r"\1true",
    content,
    count=1
)
content = re.sub(
    r"(\s+cert:\s*).*$",
    rf"\1{cert}",
    content,
    count=1,
    flags=re.MULTILINE
)
content = re.sub(
    r"(\s+key:\s*).*$",
    rf"\1{key}",
    content,
    count=1,
    flags=re.MULTILINE
)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
PY

  log "Konfigurasi SSL Wings diperbarui: enabled=true, cert=${cert_file}"
}

start_and_verify_wings() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[DRY-RUN] Akan me-restart wings.service dan cek port 8080/2022."
    return 0
  fi

  log "Me-restart wings.service..."
  systemctl restart wings
  sleep 3

  if systemctl is-active --quiet wings; then
    log "wings.service berjalan normal (active)."
    ss -tulpn | grep -E "wings|:(8080|2022)\b" || true
  else
    warn "wings.service gagal aktif. Cek log dengan: journalctl -u wings -n 40 --no-pager"
    exit 1
  fi
}

require_root
prompt_inputs

if ! check_domains_dns; then
  exit 1
fi

fix_nginx_and_ssl
install_wings_if_needed
ensure_panel_node_ssl

if check_node_config; then
  configure_wings_ssl
  start_and_verify_wings
fi

log "Selesai."

#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# HoheitKI — Managed KI Server Installer v1.0
# يشتغل على Ubuntu 24.04 LTS فاضي
# الاستخدام:
#   curl -sSL https://setup.hoheitki.com/install.sh | \
#     PACKAGE=business \
#     COMPANY="Müller GmbH" \
#     DOMAIN="ai.mueller-gmbh.de" \
#     CLIENT_EMAIL="cto@mueller-gmbh.de" \
#     bash
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

# ─── الألوان ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; GOLD='\033[0;33m'; NC='\033[0m'; BOLD='\033[1m'

# ─── إعدادات الباقة ───────────────────────────────────────────────
PACKAGE="${PACKAGE:-business}"
COMPANY="${COMPANY:-HoheitKI Client}"
DOMAIN="${DOMAIN:-}"
CLIENT_EMAIL="${CLIENT_EMAIL:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-support@hoheitki.de}"
LOGO_URL="${LOGO_URL:-}"
BREVO_KEY="${BREVO_KEY:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(openssl rand -base64 16 | tr -d '=/+' | head -c 20)}"
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

# ─── النماذج حسب الباقة ───────────────────────────────────────────
case "$PACKAGE" in
  starter)
    MODELS=("llama3.2:latest")
    RAM_REQUIRED=10
    PACKAGE_NAME="KI-Starter"
    ENABLE_N8N=false
    ENABLE_RAG=true
    RAG_STORAGE="10g"
    ;;
  business)
    MODELS=("llama3.1:latest" "mistral:latest")
    RAM_REQUIRED=20
    PACKAGE_NAME="KI-Business"
    ENABLE_N8N=true
    ENABLE_RAG=true
    RAG_STORAGE="50g"
    ;;
  enterprise)
    MODELS=("mixtral:latest" "llama3.1:latest")
    RAM_REQUIRED=28
    PACKAGE_NAME="KI-Enterprise"
    ENABLE_N8N=true
    ENABLE_RAG=true
    RAG_STORAGE="200g"
    ;;
  *)
    echo -e "${RED}❌ PACKAGE غير صحيح. اختار: starter | business | enterprise${NC}"
    exit 1
    ;;
esac

# ─── Header ───────────────────────────────────────────────────────
clear
echo -e "${GOLD}"
echo "  ██╗  ██╗ ██████╗ ██╗  ██╗███████╗██╗████████╗██╗  ██╗██╗"
echo "  ██║  ██║██╔═══██╗██║  ██║██╔════╝██║╚══██╔══╝██║ ██╔╝██║"
echo "  ███████║██║   ██║███████║█████╗  ██║   ██║   █████╔╝ ██║"
echo "  ██╔══██║██║   ██║██╔══██║██╔══╝  ██║   ██║   ██╔═██╗ ██║"
echo "  ██║  ██║╚██████╔╝██║  ██║███████╗██║   ██║   ██║  ██╗██║"
echo "  ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝   ╚═╝   ╚═╝  ╚═╝╚═╝"
echo -e "${NC}"
echo -e "${BOLD}  Managed KI Server Installer v1.0${NC}"
echo -e "  Paket: ${GREEN}${PACKAGE_NAME}${NC} | Unternehmen: ${GREEN}${COMPANY}${NC}"
echo -e "  ─────────────────────────────────────────────────────"
echo ""

# ─── دالة الطباعة ─────────────────────────────────────────────────
log_phase() { echo -e "\n${GOLD}▶ PHASE $1: $2${NC}"; }
log_ok()    { echo -e "  ${GREEN}✅ $1${NC}"; }
log_info()  { echo -e "  ${BLUE}ℹ  $1${NC}"; }
log_warn()  { echo -e "  ${YELLOW}⚠  $1${NC}"; }
log_err()   { echo -e "  ${RED}❌ $1${NC}"; exit 1; }

# ─── فحص المتطلبات ────────────────────────────────────────────────
log_phase "0" "Systemprüfung"

[ "$EUID" -ne 0 ] && log_err "يجب التشغيل كـ root"

RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
if [ "$RAM_GB" -lt "$RAM_REQUIRED" ]; then
    log_err "RAM غير كافي: ${RAM_GB}GB موجود, ${RAM_REQUIRED}GB مطلوب"
fi
log_ok "RAM: ${RAM_GB}GB ✓"

OS=$(. /etc/os-release && echo "$ID $VERSION_ID")
log_ok "OS: $OS"
log_ok "Server IP: $SERVER_IP"
log_ok "Package: $PACKAGE_NAME"

# ─── Phase 1: Security ────────────────────────────────────────────
log_phase "1" "Security Hardening"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq \
    ufw fail2ban curl wget git unzip \
    nginx certbot python3-certbot-nginx \
    clamav clamav-daemon logwatch \
    openssl htop net-tools

log_ok "Pakete installiert"

# UFW Firewall
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 3000/tcp   # Open WebUI
ufw allow 5678/tcp   # N8N
ufw allow 11434/tcp comment 'Ollama API (internal)'
echo "y" | ufw enable
log_ok "Firewall konfiguriert"

# Fail2Ban
cat > /etc/fail2ban/jail.local << 'F2B'
[DEFAULT]
maxretry = 3
bantime  = 3600
findtime = 600

[sshd]
enabled = true
maxretry = 3
F2B
systemctl restart fail2ban
log_ok "Fail2Ban aktiviert"

# SSH Hardening
sed -i 's/#PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config 2>/dev/null || true
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
log_ok "SSH gehärtet"

# Auto Security Updates
apt-get install -y -qq unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true
log_ok "Auto-Updates konfiguriert"

# ─── Phase 2: Docker ──────────────────────────────────────────────
log_phase "2" "Docker Installation"

if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi
log_ok "Docker $(docker --version | cut -d' ' -f3 | tr -d ',')"

# ─── Phase 3: Ollama + Modelle ────────────────────────────────────
log_phase "3" "Ollama & KI-Modelle (kann 20-40 Min dauern)"

if ! command -v ollama &>/dev/null; then
    curl -fsSL https://ollama.com/install.sh | sh
    systemctl enable ollama
    systemctl start ollama
    sleep 5
fi
log_ok "Ollama installiert"

# تحميل النماذج
for MODEL in "${MODELS[@]}"; do
    log_info "Lade Modell: $MODEL ..."
    ollama pull "$MODEL" 2>&1 | tail -1
    log_ok "Modell geladen: $MODEL"
done

# Warm-up test
log_info "Teste KI-Antwort..."
RESPONSE=$(ollama run "${MODELS[0]}" "Antworte nur: KI-System bereit" 2>/dev/null | head -1)
log_ok "KI-Test: $RESPONSE"

# ─── Phase 4: Open WebUI ──────────────────────────────────────────
log_phase "4" "Open WebUI (Benutzeroberfläche)"

mkdir -p /opt/hoheitki/{webui,rag,n8n,monitoring,backups}

# docker-compose.yml
cat > /opt/hoheitki/docker-compose.yml << COMPOSE
version: '3.8'

services:
  webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: hoheitki_webui
    restart: unless-stopped
    ports:
      - "3000:8080"
    volumes:
      - /opt/hoheitki/webui:/app/backend/data
    environment:
      - OLLAMA_BASE_URL=http://host.docker.internal:11434
      - WEBUI_NAME=${COMPANY} KI
      - WEBUI_AUTH=true
      - DEFAULT_MODELS=${MODELS[0]}
      - WEBUI_SECRET_KEY=$(openssl rand -hex 32)
      - ENABLE_RAG_WEB_SEARCH=true
    extra_hosts:
      - "host.docker.internal:host-gateway"

  chromadb:
    image: chromadb/chroma:latest
    container_name: hoheitki_chromadb
    restart: unless-stopped
    ports:
      - "127.0.0.1:8000:8000"
    volumes:
      - /opt/hoheitki/rag:/chroma/chroma
COMPOSE

# إضافة N8N للباقات Business وما فوق
if [ "$ENABLE_N8N" = "true" ]; then
cat >> /opt/hoheitki/docker-compose.yml << N8NCOMPOSE

  n8n:
    image: n8nio/n8n:latest
    container_name: hoheitki_n8n
    restart: unless-stopped
    ports:
      - "5678:5678"
    volumes:
      - /opt/hoheitki/n8n:/home/node/.n8n
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=${ADMIN_PASSWORD}
      - N8N_HOST=${DOMAIN:-$SERVER_IP}
      - WEBHOOK_URL=https://${DOMAIN:-$SERVER_IP}:5678/
N8NCOMPOSE
fi

docker compose -f /opt/hoheitki/docker-compose.yml up -d
log_ok "Open WebUI gestartet"
if [ "$ENABLE_N8N" = "true" ]; then log_ok "N8N Automation gestartet"; fi

# انتظر WebUI يبدأ
log_info "Warte auf WebUI Start..."
for i in {1..30}; do
    if curl -s http://localhost:3000 &>/dev/null; then break; fi
    sleep 3
done
log_ok "WebUI erreichbar auf Port 3000"

# ─── Phase 5: Nginx + SSL ─────────────────────────────────────────
log_phase "5" "Nginx Reverse Proxy & SSL"

if [ -n "$DOMAIN" ]; then
    cat > /etc/nginx/sites-available/hoheitki << NGINX
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        client_max_body_size 100M;
    }

    location /n8n/ {
        proxy_pass http://localhost:5678/;
        proxy_set_header Host \$host;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX
    ln -sf /etc/nginx/sites-available/hoheitki /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx
    log_ok "Nginx konfiguriert für $DOMAIN"

    # SSL
    log_info "SSL Zertifikat wird erstellt..."
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
        --email "$ADMIN_EMAIL" --redirect 2>/dev/null && \
        log_ok "SSL aktiviert: https://$DOMAIN" || \
        log_warn "SSL fehlgeschlagen - manuell einrichten"
else
    log_warn "Kein Domain angegeben - WebUI auf http://$SERVER_IP:3000"
fi

# ─── Phase 6: Monitoring + Backup ─────────────────────────────────
log_phase "6" "Monitoring & Automatische Backups"

# Monitoring Script
cat > /opt/hoheitki/monitoring/health_check.sh << 'MONITOR'
#!/bin/bash
ADMIN_EMAIL="support@hoheitki.de"
CLIENT_EMAIL="CLIENT_EMAIL_PLACEHOLDER"

check_service() {
    if ! curl -s "http://localhost:$1" &>/dev/null; then
        echo "⚠️ Service auf Port $1 nicht erreichbar!" | \
            mail -s "[HoheitKI ALERT] Server Problem" "$ADMIN_EMAIL" "$CLIENT_EMAIL"
        # Restart
        docker compose -f /opt/hoheitki/docker-compose.yml restart 2>/dev/null
    fi
}

check_service 3000   # WebUI
ollama list &>/dev/null || systemctl restart ollama
MONITOR

sed -i "s/CLIENT_EMAIL_PLACEHOLDER/$CLIENT_EMAIL/" /opt/hoheitki/monitoring/health_check.sh
chmod +x /opt/hoheitki/monitoring/health_check.sh

# Backup Script
cat > /opt/hoheitki/backups/backup.sh << 'BACKUP'
#!/bin/bash
BACKUP_DIR="/opt/hoheitki/backups"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS=30

tar -czf "$BACKUP_DIR/hoheitki_backup_$DATE.tar.gz" \
    /opt/hoheitki/webui \
    /opt/hoheitki/rag \
    /opt/hoheitki/n8n \
    2>/dev/null

# احذف النسخ القديمة
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +$KEEP_DAYS -delete

echo "✅ Backup erstellt: hoheitki_backup_$DATE.tar.gz"
BACKUP
chmod +x /opt/hoheitki/backups/backup.sh

# Cron Jobs
(crontab -l 2>/dev/null; echo "*/5 * * * * /opt/hoheitki/monitoring/health_check.sh") | crontab -
(crontab -l 2>/dev/null; echo "0 2 * * * /opt/hoheitki/backups/backup.sh") | crontab -

log_ok "Monitoring konfiguriert (alle 5 Min)"
log_ok "Backup konfiguriert (täglich 02:00 Uhr)"

# ─── Phase 7: Branding ────────────────────────────────────────────
log_phase "7" "Unternehmens-Branding"

# إنشاء ملف الإعدادات
cat > /opt/hoheitki/config.json << CONFIG
{
  "company": "$COMPANY",
  "package": "$PACKAGE_NAME",
  "domain": "${DOMAIN:-$SERVER_IP}",
  "client_email": "$CLIENT_EMAIL",
  "models": $(printf '%s\n' "${MODELS[@]}" | jq -R . | jq -s .),
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "admin_password": "$ADMIN_PASSWORD",
  "n8n_enabled": $ENABLE_N8N,
  "rag_enabled": $ENABLE_RAG
}
CONFIG

log_ok "Konfiguration gespeichert: /opt/hoheitki/config.json"

# ─── Phase 8: Welcome Report ──────────────────────────────────────
log_phase "8" "Übergabe-Dokument & E-Mail"

ACCESS_URL="${DOMAIN:+https://$DOMAIN}"
ACCESS_URL="${ACCESS_URL:-http://$SERVER_IP:3000}"
N8N_URL="${DOMAIN:+https://$DOMAIN/n8n}"
N8N_URL="${N8N_URL:-http://$SERVER_IP:5678}"

# إنشاء ملف التسليم
cat > /opt/hoheitki/UEBERGABE.txt << UEBERGABE
═══════════════════════════════════════════════════════
  HOHEITKI — Übergabe-Dokument
  ${PACKAGE_NAME} für ${COMPANY}
  Installiert am: $(date '+%d.%m.%Y um %H:%M Uhr')
═══════════════════════════════════════════════════════

IHR KI-SERVER:
  IP-Adresse:  $SERVER_IP
  KI-Interface: $ACCESS_URL
  
ZUGANGSDATEN (bitte sicher aufbewahren!):
  Benutzername:  admin
  Passwort:      $ADMIN_PASSWORD

INSTALLIERTE KI-MODELLE:
$(for m in "${MODELS[@]}"; do echo "  ✅ $m"; done)

${ENABLE_N8N:+AUTOMATISIERUNG (N8N):
  URL:      $N8N_URL
  Benutzer: admin
  Passwort: $ADMIN_PASSWORD
}

SICHERHEIT:
  ✅ Firewall aktiv (UFW)
  ✅ Brute-Force-Schutz (Fail2Ban)
  ✅ Automatische Sicherheits-Updates
  ✅ Tägliches Backup (02:00 Uhr)
  ✅ Monitoring alle 5 Minuten

WICHTIGE VERZEICHNISSE:
  KI-Daten:  /opt/hoheitki/webui/
  Dokumente: /opt/hoheitki/rag/
  Backups:   /opt/hoheitki/backups/
  Config:    /opt/hoheitki/config.json

SUPPORT:
  E-Mail:  support@hoheitki.de
  Website: https://hoheitki.com

© $(date +%Y) HoheitKI — Alle Rechte vorbehalten
Madina LLC, Albuquerque NM, USA
═══════════════════════════════════════════════════════
UEBERGABE

cat /opt/hoheitki/UEBERGABE.txt

# إشعار HoheitKI API إن السيرفر جاهز → يضيف العميل لـ Brevo Sequence
HOHEITKI_API="https://api.hoheitki.com/api/v1/service"
if [ -n "$CLIENT_TOKEN" ]; then
    log_info "Benachrichtige HoheitKI API..."
    curl -s -X POST "${HOHEITKI_API}/webhook/server-ready" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "token=${CLIENT_TOKEN}&server_ip=${SERVER_IP}&domain=${DOMAIN}" \
        > /dev/null && log_ok "API benachrichtigt — Brevo Sequence gestartet" || \
        log_warn "API nicht erreichbar — manuell prüfen"
fi

# إرسال Email للعميل والـ Admin
if [ -n "$BREVO_KEY" ] && [ -n "$CLIENT_EMAIL" ]; then
    EMAIL_HTML="<div style='font-family:Arial;max-width:600px;background:#050608;color:#e2e8f0;border-radius:8px;overflow:hidden'>
<div style='background:#0a0c10;padding:25px;text-align:center;border-bottom:2px solid #d4af37'>
<span style='color:#fff;font-size:22px;font-weight:900'>HOHEIT<span style='color:#d4af37'>KI</span></span>
</div>
<div style='padding:35px'>
<h2 style='color:#fff'>Ihr KI-Server ist bereit! 🎉</h2>
<p style='color:#8a99ad'>Sehr geehrte Damen und Herren von <strong style='color:#d4af37'>${COMPANY}</strong>,</p>
<p style='color:#8a99ad'>Ihr persönlicher KI-Server wurde erfolgreich eingerichtet. Ab sofort läuft Ihre souveräne KI vollständig auf Ihrem eigenen Server in Deutschland.</p>
<div style='background:#0a0c10;border:1px solid #1c202e;border-left:4px solid #d4af37;border-radius:8px;padding:20px;margin:20px 0'>
<p style='color:#fff;margin:0 0 10px;font-weight:bold'>🔐 Ihre Zugangsdaten:</p>
<p style='color:#d4af37;font-size:18px;font-weight:900;margin:5px 0'>$ACCESS_URL</p>
<p style='color:#8a99ad;margin:5px 0'>Benutzer: <strong style='color:#fff'>admin</strong></p>
<p style='color:#8a99ad;margin:5px 0'>Passwort: <strong style='color:#fff'>$ADMIN_PASSWORD</strong></p>
</div>
<p style='color:#8a99ad'>Ihr Paket: <strong style='color:#d4af37'>${PACKAGE_NAME}</strong></p>
<p style='color:#8a99ad'>Installierte Modelle: <strong style='color:#fff'>$(IFS=', '; echo "${MODELS[*]}")</strong></p>
<div style='text-align:center;margin:25px 0'>
<a href='$ACCESS_URL' style='background:linear-gradient(180deg,#f5e298,#d4af37);color:#000;padding:16px 40px;border-radius:6px;font-weight:900;font-size:15px;text-decoration:none'>KI jetzt starten →</a>
</div>
<p style='color:#475569;font-size:13px'>Wir werden uns in Kürze für das Onboarding-Gespräch bei Ihnen melden. Bei Fragen: <a href='mailto:support@hoheitki.de' style='color:#d4af37'>support@hoheitki.de</a></p>
</div>
<div style='background:#0a0c10;padding:15px;text-align:center;color:#475569;font-size:12px'>
HoheitKI · support@hoheitki.de · hoheitki.com
</div></div>"

    curl -s -X POST "https://api.brevo.com/v3/smtp/email" \
        -H "api-key: $BREVO_KEY" \
        -H "content-type: application/json" \
        -d "{
            \"sender\":{\"name\":\"HoheitKI Team\",\"email\":\"noreply@hoheitki.de\"},
            \"to\":[{\"email\":\"$CLIENT_EMAIL\"},{\"email\":\"$ADMIN_EMAIL\"}],
            \"subject\":\"[HoheitKI] Ihr KI-Server ist bereit! 🎉\",
            \"htmlContent\":\"$EMAIL_HTML\"
        }" > /dev/null && log_ok "Übergabe-E-Mail gesendet an $CLIENT_EMAIL"
fi

# ─── Abschluss ────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║                                                   ║"
echo "  ║     ✅ INSTALLATION ERFOLGREICH ABGESCHLOSSEN!    ║"
echo "  ║                                                   ║"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  🌐 KI-Interface:  ${GOLD}${BOLD}$ACCESS_URL${NC}"
echo -e "  👤 Benutzer:      ${GREEN}admin${NC}"
echo -e "  🔑 Passwort:      ${GREEN}$ADMIN_PASSWORD${NC}"
if [ "$ENABLE_N8N" = "true" ]; then
echo -e "  ⚡ N8N Automation: ${GOLD}$N8N_URL${NC}"
fi
echo ""
echo -e "  📄 Übergabe-Dokument: ${BLUE}/opt/hoheitki/UEBERGABE.txt${NC}"
echo ""
echo -e "  ${YELLOW}⚠️  Bitte Passwort nach erstem Login ändern!${NC}"
echo ""

# وقت التثبيت
TOTAL_TIME=$SECONDS
echo -e "  ⏱️  Installationszeit: ${GREEN}$(($TOTAL_TIME/60)) Min $(($TOTAL_TIME%60)) Sek${NC}"
echo ""

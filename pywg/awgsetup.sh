#!/bin/bash
# ============================================================
# awg-server-setup.sh — установка AmneziaWG + опционально Xray
# Использование: bash awg-server-setup.sh
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()  { echo -e "${CYAN}  ▸${NC} $*"; }
ok()    { echo -e "${GREEN}  ✓${NC} $*"; }
warn()  { echo -e "${YELLOW}  ⚠${NC} $*"; }
die()   { echo -e "${RED}  ✗${NC} $*"; exit 1; }
sep()   { echo -e "${DIM}  ─────────────────────────────────────${NC}"; }
ask()   { read -rp "  $1" "$2"; }

wait_for_apt_locks() {
  local timeout="${1:-300}"
  local waited=0
  local lock_files=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/lib/apt/lists/lock
    /var/cache/apt/archives/lock
  )

  while fuser "${lock_files[@]}" >/dev/null 2>&1; do
    if (( waited >= timeout )); then
      die "Таймаут ожидания apt/dpkg lock (${timeout}s). Завершите другие apt/dpkg процессы и повторите запуск"
    fi

    if (( waited % 10 == 0 )); then
      info "Ожидаем освобождения apt/dpkg lock... (${waited}s)"
    fi

    sleep 2
    waited=$((waited + 2))
  done
}

apt_safe() {
  wait_for_apt_locks 300
  DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Lock::Timeout=120 "$@"
}

install_apt_packages() {
  local pkg
  local available=()
  local missing=()

  for pkg in "$@"; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      available+=("$pkg")
    else
      missing+=("$pkg")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Пропускаем недоступные пакеты: ${missing[*]}"
  fi

  [[ ${#available[@]} -eq 0 ]] && die "Нет доступных пакетов для установки"

  apt_safe install -y "${available[@]}"
}

trap 'die "Ошибка на строке $LINENO. Команда: $BASH_COMMAND"' ERR

AWG_DIR="/etc/amnezia/amneziawg"
XRAY_DIR="/opt/xray"
AWG_PORT=51820
AWG_SUBNET="10.8.0"
JC=4; JMIN=40; JMAX=70; S1=50; S2=100
H1=1407775011; H2=2140498648; H3=254021790; H4=3964887677
XRAY_PORT=2053
XRAY_SNI="www.microsoft.com"

# ══════════════════════════════════════════════
clear
echo ""
echo -e "${BOLD}${CYAN}  ╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}  ║     VPS Setup: AWG + Xray VLESS        ║${NC}"
echo -e "${BOLD}${CYAN}  ╚════════════════════════════════════════╝${NC}"
echo ""

# ── Определяем параметры сервера ──
WAN_IF=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me || curl -4 -s --max-time 5 api.ipify.org || hostname -I | awk '{print $1}')

echo -e "  ${BOLD}Параметры сервера:${NC}"
sep
echo -e "    IP:         ${GREEN}$SERVER_IP${NC}"
echo -e "    Интерфейс:  ${GREEN}$WAN_IF${NC}"
sep
echo ""

# ── Что устанавливать ──
echo -e "  ${BOLD}Что установить?${NC}"
echo ""
echo -e "    1) Только AmneziaWG"
echo -e "    2) Только Xray VLESS+Reality"
echo -e "    3) Всё (AmneziaWG + Xray)"
echo ""
ask "Выбор [1-3]: " INSTALL_CHOICE
echo ""

INSTALL_AWG=false
INSTALL_XRAY=false
[[ "$INSTALL_CHOICE" == "1" || "$INSTALL_CHOICE" == "3" ]] && INSTALL_AWG=true
[[ "$INSTALL_CHOICE" == "2" || "$INSTALL_CHOICE" == "3" ]] && INSTALL_XRAY=true

# ── Дополнительные вопросы ──
if $INSTALL_AWG; then
    echo -e "  ${DIM}Публичный ключ RU-VPS (оставьте пустым — добавите позже):${NC}"
    echo -e "  ${DIM}Узнать на ru-vps: sudo awg show | grep 'public key'${NC}"
    ask "Публичный ключ RU-VPS: " RU_PUBLIC_KEY
    echo ""
fi

if $INSTALL_XRAY; then
    echo -e "  ${DIM}Порт Xray (Enter = $XRAY_PORT):${NC}"
    ask "Порт Xray [$XRAY_PORT]: " XRAY_PORT_INPUT
    [[ -n "${XRAY_PORT_INPUT:-}" ]] && XRAY_PORT=$XRAY_PORT_INPUT

    echo -e "  ${DIM}SNI (Enter = $XRAY_SNI):${NC}"
    ask "SNI [$XRAY_SNI]: " XRAY_SNI_INPUT
    [[ -n "${XRAY_SNI_INPUT:-}" ]] && XRAY_SNI=$XRAY_SNI_INPUT
    echo ""
fi

# ── Подтверждение ──
echo -e "  ${BOLD}Итоговый план:${NC}"
sep
$INSTALL_AWG  && echo -e "    ${GREEN}●${NC} AmneziaWG сервер  — порт ${AWG_PORT}/udp, подсеть ${AWG_SUBNET}.0/24"
$INSTALL_XRAY && echo -e "    ${GREEN}●${NC} Xray VLESS+Reality — порт ${XRAY_PORT}/tcp, SNI ${XRAY_SNI}"
sep
echo ""
ask "Продолжить? [Y/n]: " CONFIRM
[[ "${CONFIRM,,}" == "n" ]] && exit 0
echo ""

# ══════════════════════════════════════════════
# БЛОК 1: Общие зависимости
# ══════════════════════════════════════════════
echo -e "${BOLD}  [1] Зависимости${NC}"
apt_safe update -qq

PKGS=(curl wget nano iproute2 iptables qrencode)
$INSTALL_AWG  && PKGS+=(wireguard-tools software-properties-common)
$INSTALL_XRAY && PKGS+=(ca-certificates gnupg lsb-release)

install_apt_packages "${PKGS[@]}"
ok "Пакеты установлены"

# ══════════════════════════════════════════════
# БЛОК 2: AmneziaWG
# ══════════════════════════════════════════════
if $INSTALL_AWG; then
    echo ""
    echo -e "${BOLD}  [2] AmneziaWG${NC}"

    if ! command -v awg &>/dev/null; then
        info "Добавляем PPA..."
        add-apt-repository -y ppa:amnezia/ppa > /dev/null 2>&1
        apt_safe update -qq
        apt_safe install -y -qq amneziawg amneziawg-tools
        ok "AmneziaWG установлен"
    else
        ok "Уже установлен"
    fi

    mkdir -p "$AWG_DIR/clients"

    if [[ -f "$AWG_DIR/server_private.key" ]]; then
        warn "Ключи уже существуют, используем их"
    else
        awg genkey | tee "$AWG_DIR/server_private.key" | awg pubkey > "$AWG_DIR/server_public.key"
        chmod 600 "$AWG_DIR/server_private.key"
        ok "Ключи сгенерированы"
    fi

    AWG_SERVER_PRIV=$(cat "$AWG_DIR/server_private.key")
    AWG_SERVER_PUB=$(cat "$AWG_DIR/server_public.key")

    [[ -f "$AWG_DIR/awg0.conf" ]] && cp "$AWG_DIR/awg0.conf" "$AWG_DIR/awg0.conf.bak.$(date +%Y%m%d-%H%M%S)"

    cat > "$AWG_DIR/awg0.conf" << CONF
[Interface]
PrivateKey = $AWG_SERVER_PRIV
Address = ${AWG_SUBNET}.1/24
ListenPort = $AWG_PORT
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

PostUp = iptables -A FORWARD -i awg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i awg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $WAN_IF -j MASQUERADE
CONF

    if [[ -n "${RU_PUBLIC_KEY:-}" ]]; then
        cat >> "$AWG_DIR/awg0.conf" << PEER

# ruvps
[Peer]
PublicKey = $RU_PUBLIC_KEY
AllowedIPs = ${AWG_SUBNET}.4/32
PEER
        ok "Peer ruvps добавлен"
    fi

    chmod 600 "$AWG_DIR/awg0.conf"

    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg-forward.conf
    sysctl --system > /dev/null 2>&1
    ok "IP forwarding включён"

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "$AWG_PORT/udp" > /dev/null
        ok "UFW: открыт $AWG_PORT/udp"
    fi

    systemctl stop "awg-quick@awg0" 2>/dev/null || true
    ip link del awg0 2>/dev/null || true
    systemctl reset-failed "awg-quick@awg0" 2>/dev/null || true
    systemctl enable --now "awg-quick@awg0"
    ok "Сервис запущен и в автозапуске"

    # Утилиты AWG
    cat > /usr/local/bin/awg-add-client << 'SCRIPT'
#!/bin/bash
set -euo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

CLIENT_NAME="${1:?Usage: awg-add-client <name>}"
AWG_DIR="/etc/amnezia/amneziawg"
CLIENTS_DIR="$AWG_DIR/clients"
SERVER_PUB=$(cat "$AWG_DIR/server_public.key")
SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')
SERVER_ENDPOINT="${SERVER_IP}:51820"

mkdir -p "$CLIENTS_DIR"
[[ -f "$CLIENTS_DIR/$CLIENT_NAME.conf" ]] && { echo -e "${RED}  ✗ Клиент '$CLIENT_NAME' уже существует${NC}"; exit 1; }

CLIENT_PRIV=$(awg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | awg pubkey)
LAST_IP=$(grep -r "AllowedIPs" "$AWG_DIR/awg0.conf" 2>/dev/null | grep -oP "10\.8\.0\.\K\d+" | sort -n | tail -1 || echo "1")
NEXT_IP=$((${LAST_IP:-1} + 1))

cat >> "$AWG_DIR/awg0.conf" << PEER

# $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.8.0.$NEXT_IP/32
PEER

cat > "$CLIENTS_DIR/$CLIENT_NAME.conf" << CONF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.8.0.$NEXT_IP/24
DNS = 1.1.1.1
Jc = 4
Jmin = 40
Jmax = 70
S1 = 50
S2 = 100
H1 = 1407775011
H2 = 2140498648
H3 = 254021790
H4 = 3964887677

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $SERVER_ENDPOINT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONF

awg set awg0 peer "$CLIENT_PUB" allowed-ips "10.8.0.$NEXT_IP/32"

echo ""
echo -e "${BOLD}${GREEN}  ✓ Клиент '$CLIENT_NAME' — IP: 10.8.0.$NEXT_IP${NC}"
echo -e "${DIM}  Файл: $CLIENTS_DIR/$CLIENT_NAME.conf${NC}"
echo ""
cat "$CLIENTS_DIR/$CLIENT_NAME.conf"
echo ""
command -v qrencode &>/dev/null && qrencode -t ansiutf8 < "$CLIENTS_DIR/$CLIENT_NAME.conf"
SCRIPT
    chmod +x /usr/local/bin/awg-add-client

    cat > /usr/local/bin/awg-status << 'SCRIPT'
#!/bin/bash
GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
echo ""
echo -e "${BOLD}${CYAN}  AmneziaWG — Статус${NC}"
echo -e "${DIM}  ─────────────────────────────────────${NC}"
awg show
echo -e "${DIM}  ─────────────────────────────────────${NC}"
echo -e "  ${BOLD}Клиенты:${NC}"
for f in /etc/amnezia/amneziawg/clients/*.conf; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f" .conf)
    ip=$(grep "Address" "$f" | grep -oP "10\.8\.0\.\d+")
    echo -e "    ${GREEN}●${NC} $name ${DIM}($ip)${NC}"
done
echo ""
SCRIPT
    chmod +x /usr/local/bin/awg-status
    ok "awg-add-client и awg-status установлены"
fi

# ══════════════════════════════════════════════
# БЛОК 3: Xray VLESS+Reality
# ══════════════════════════════════════════════
if $INSTALL_XRAY; then
    echo ""
    echo -e "${BOLD}  [3] Xray VLESS+Reality${NC}"

    # Docker
    if ! command -v docker &>/dev/null; then
        info "Устанавливаем Docker..."
        curl -fsSL https://get.docker.com | sh > /dev/null 2>&1
        systemctl enable docker > /dev/null 2>&1
        ok "Docker установлен"
    else
        ok "Docker уже есть: $(docker --version | cut -d' ' -f3 | tr -d ',')"
    fi

    # UUID
    UUID=$(cat /proc/sys/kernel/random/uuid)
    ok "UUID: $UUID"

    # X25519 ключи
    info "Генерируем X25519 ключи..."
    KEYS=$(docker run --rm --entrypoint xray teddysun/xray x25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$KEYS" | grep -E 'PrivateKey:|Private key:' | awk '{print $NF}')
    PUBLIC_KEY=$(echo  "$KEYS" | grep -E 'Password|Public key:' | awk '{print $NF}')
    [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]] && die "Не удалось получить X25519 ключи"
    ok "Ключи получены"

    # ShortId
    SHORT_ID=$(openssl rand -hex 8)

    mkdir -p "$XRAY_DIR/logs"

    cat > "$XRAY_DIR/docker-compose.yml" << YAML
services:
  xray:
    image: teddysun/xray
    container_name: xray
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./config.json:/etc/xray/config.json
      - ./logs:/var/log/xray
YAML

    cat > "$XRAY_DIR/config.json" << JSON
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error":  "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision", "email": "user" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${XRAY_SNI}:443",
          "xver": 0,
          "serverNames": ["$XRAY_SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    { "tag": "block",  "protocol": "blackhole" }
  ]
}
JSON

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "$XRAY_PORT/tcp" > /dev/null
        ok "UFW: открыт $XRAY_PORT/tcp"
    fi

    cd "$XRAY_DIR"
    docker compose up -d > /dev/null 2>&1
    sleep 2

    if docker ps | grep -q xray; then
        ok "Xray контейнер запущен"
    else
        warn "Контейнер не запустился — проверь: docker logs xray"
    fi

    # Клиентский URL и конфиг
    CLIENT_URL="vless://${UUID}@${SERVER_IP}:${XRAY_PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${XRAY_SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision#VLESS-${SERVER_IP}"

    cat > "$XRAY_DIR/client-config.json" << JSON
{
  "inbounds": [
    { "tag": "socks", "listen": "127.0.0.1", "port": 1080, "protocol": "socks", "settings": {"udp": true} },
    { "tag": "http",  "listen": "127.0.0.1", "port": 1081, "protocol": "http" }
  ],
  "outbounds": [
    {
      "tag": "vless-out",
      "protocol": "vless",
      "settings": {
        "vnext": [{ "address": "$SERVER_IP", "port": $XRAY_PORT,
          "users": [{ "id": "$UUID", "encryption": "none", "flow": "xtls-rprx-vision" }]
        }]
      },
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": {
          "serverName": "$XRAY_SNI", "fingerprint": "chrome",
          "publicKey": "$PUBLIC_KEY", "shortId": "$SHORT_ID"
        }
      }
    },
    { "tag": "direct", "protocol": "freedom" }
  ],
  "routing": { "rules": [{ "type": "field", "outboundTag": "vless-out", "network": "tcp,udp" }] }
}
JSON
    ok "Клиентские конфиги сохранены в $XRAY_DIR/"
fi

# ══════════════════════════════════════════════
# ИТОГ
# ══════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}  ╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}  ║            Готово!                     ║${NC}"
echo -e "${BOLD}${GREEN}  ╚════════════════════════════════════════╝${NC}"
echo ""

if $INSTALL_AWG; then
    echo -e "  ${BOLD}${CYAN}AmneziaWG:${NC}"
    echo -e "    Endpoint:      ${BOLD}${SERVER_IP}:${AWG_PORT}${NC}"
    echo -e "    Публичный ключ:${BOLD} $AWG_SERVER_PUB${NC}"
    echo -e "    Команды:        awg-add-client <name>  |  awg-status"
    echo ""
fi

if $INSTALL_XRAY; then
    echo -e "  ${BOLD}${CYAN}Xray VLESS+Reality:${NC}"
    echo -e "    Endpoint:  ${BOLD}${SERVER_IP}:${XRAY_PORT}${NC}"
    echo -e "    UUID:      ${BOLD}$UUID${NC}"
    echo -e "    PublicKey: ${BOLD}$PUBLIC_KEY${NC}"
    echo -e "    ShortId:   ${BOLD}$SHORT_ID${NC}"
    echo ""
    echo -e "  ${BOLD}Клиентский URL:${NC}"
    sep
    echo -e "  ${GREEN}$CLIENT_URL${NC}"
    sep
    echo ""
    echo -e "  ${DIM}client-config.json: $XRAY_DIR/client-config.json${NC}"
    echo ""
fi
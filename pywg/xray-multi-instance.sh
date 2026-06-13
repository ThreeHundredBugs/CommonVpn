#!/bin/bash
# xray-multi-setup.sh — установка нескольких Xray инстансов
# Использование: bash xray-multi-setup.sh [порт1,порт2,...]
# Переменные:    SNI=... ALIAS_PREFIX=... AWG_PORT=...
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
info() { echo -e "${CYAN}  ▸${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
die()  { echo -e "${RED}  ✗${NC} $*"; exit 1; }
sep()  { echo -e "${DIM}  ─────────────────────────────────────${NC}"; }
trap 'die "Ошибка на строке $LINENO. Команда: $BASH_COMMAND"' ERR
[[ $EUID -eq 0 ]] || die "Запустите скрипт от root"
XRAY_DIR="/opt/xray"
AWG_DIR="/etc/amnezia/amneziawg"
AWG_PORT="${AWG_PORT:-51820}"
SNI="${SNI:-www.microsoft.com}"
PORTS_CSV="${1:-2053,8443}"
ALIAS_PREFIX="${ALIAS_PREFIX:-main}"
command -v docker  >/dev/null 2>&1 || die "Docker не установлен"
command -v openssl >/dev/null 2>&1 || die "openssl не установлен"
SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me || curl -4 -s --max-time 5 api.ipify.org || hostname -I | awk '{print $1}')
[[ -n "$SERVER_IP" ]] || die "Не удалось определить внешний IP"
AWG_PUBKEY="NA"
[[ -f "$AWG_DIR/server_public.key" ]] && AWG_PUBKEY=$(cat "$AWG_DIR/server_public.key")
XRAY_PORTS=()
IFS=',' read -ra RAW_PORTS <<< "$PORTS_CSV"
for p in "${RAW_PORTS[@]}"; do
    p="${p//[[:space:]]/}"
    [[ -z "$p" ]] && continue
    [[ "$p" =~ ^[0-9]+$ ]]      || die "Некорректный порт: $p"
    (( p >= 1 && p <= 65535 ))  || die "Порт вне диапазона: $p"
    XRAY_PORTS+=("$p")
done
[[ ${#XRAY_PORTS[@]} -gt 0 ]] || die "Список портов пуст"
mkdir -p "$XRAY_DIR/instances"
clear
echo ""
echo -e "${BOLD}${CYAN}  ╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}  ║      Xray Multi-Instance Setup         ║${NC}"
echo -e "${BOLD}${CYAN}  ╚════════════════════════════════════════╝${NC}"
echo ""
sep
echo -e "  IP:      ${GREEN}$SERVER_IP${NC}"
echo -e "  SNI:     ${GREEN}$SNI${NC}"
echo -e "  Порты:   ${GREEN}${XRAY_PORTS[*]}${NC}"
echo -e "  AWG key: ${DIM}$AWG_PUBKEY${NC}"
sep
echo ""
EXPORT_FILE="$XRAY_DIR/ru-vps-lines.txt"
echo "#ALIAS|AWG_IP:PORT|AWG_PUBKEY|XRAY_IP|XRAY_PORT|XRAY_UUID|XRAY_PUBKEY|XRAY_SHORTID" > "$EXPORT_FILE"
for XRAY_PORT in "${XRAY_PORTS[@]}"; do
    echo -e "${BOLD}  ── Порт $XRAY_PORT ──${NC}"
    INSTANCE_DIR="$XRAY_DIR/instances/$XRAY_PORT"
    mkdir -p "$INSTANCE_DIR/logs"
    if docker ps --format '{{.Names}}' | grep -q "^xray-${XRAY_PORT}$"; then
        info "[$XRAY_PORT] Останавливаем старый контейнер..."
        (cd "$INSTANCE_DIR" && docker compose down >/dev/null 2>&1) || true
    fi
    UUID=$(cat /proc/sys/kernel/random/uuid)
    ok "[$XRAY_PORT] UUID: $UUID"
    info "[$XRAY_PORT] Генерируем X25519 ключи..."
    KEYS=$(docker run --rm --entrypoint xray teddysun/xray x25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$KEYS" | grep -E 'PrivateKey:|Private key:' | awk '{print $NF}')
    PUBLIC_KEY=$(echo  "$KEYS" | grep -E 'PublicKey:|Public key:|Password' | awk '{print $NF}')
    [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "[$XRAY_PORT] Не удалось получить X25519 ключи"
    ok "[$XRAY_PORT] Ключи получены"
    SHORT_ID=$(openssl rand -hex 8)
    cat > "$INSTANCE_DIR/docker-compose.yml" << YAML
services:
  xray:
    image: teddysun/xray
    container_name: xray-${XRAY_PORT}
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./config.json:/etc/xray/config.json
      - ./logs:/var/log/xray
YAML
    cat > "$INSTANCE_DIR/config.json" << JSON
{
  "log": { "loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log" },
  "inbounds": [{
    "tag": "vless-reality", "listen": "0.0.0.0", "port": $XRAY_PORT, "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision", "email": "user-${XRAY_PORT}" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "show": false, "dest": "${SNI}:443", "xver": 0,
        "serverNames": ["$SNI"], "privateKey": "$PRIVATE_KEY", "shortIds": ["$SHORT_ID"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
  }],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    { "tag": "block",  "protocol": "blackhole" }
  ]
}
JSON
    cat > "$INSTANCE_DIR/client-config.json" << JSON
{
  "inbounds": [
    { "tag": "socks", "listen": "127.0.0.1", "port": 1080, "protocol": "socks", "settings": {"udp": true} },
    { "tag": "http",  "listen": "127.0.0.1", "port": 1081, "protocol": "http" }
  ],
  "outbounds": [{
    "tag": "vless-out", "protocol": "vless",
    "settings": { "vnext": [{ "address": "$SERVER_IP", "port": $XRAY_PORT,
      "users": [{ "id": "$UUID", "encryption": "none", "flow": "xtls-rprx-vision" }]
    }]},
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": { "serverName": "$SNI", "fingerprint": "chrome", "publicKey": "$PUBLIC_KEY", "shortId": "$SHORT_ID" }
    }
  }, { "tag": "direct", "protocol": "freedom" }],
  "routing": { "rules": [{ "type": "field", "outboundTag": "vless-out", "network": "tcp,udp" }] }
}
JSON
    CLIENT_URL="vless://${UUID}@${SERVER_IP}:${XRAY_PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision#VLESS-${SERVER_IP}-${XRAY_PORT}"
    printf "XRAY_IP=%s\nXRAY_PORT=%s\nXRAY_UUID=%s\nXRAY_PUBKEY=%s\nXRAY_SHORTID=%s\nCLIENT_URL=%s\n" \
        "$SERVER_IP" "$XRAY_PORT" "$UUID" "$PUBLIC_KEY" "$SHORT_ID" "$CLIENT_URL" \
        > "$INSTANCE_DIR/connection.env"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "$XRAY_PORT/tcp" comment "Xray-${XRAY_PORT}" >/dev/null
        ok "[$XRAY_PORT] UFW: порт открыт"
    fi
    info "[$XRAY_PORT] Запускаем контейнер..."
    (cd "$INSTANCE_DIR" && docker compose up -d >/dev/null 2>&1)
    sleep 1
    if docker ps --format '{{.Names}}' | grep -q "^xray-${XRAY_PORT}$"; then
        ok "[$XRAY_PORT] Контейнер xray-${XRAY_PORT} запущен"
    else
        warn "[$XRAY_PORT] Контейнер не запустился: docker logs xray-${XRAY_PORT}"
    fi
    echo "${ALIAS_PREFIX}-${XRAY_PORT}|${SERVER_IP}:${AWG_PORT}|${AWG_PUBKEY}|${SERVER_IP}|${XRAY_PORT}|${UUID}|${PUBLIC_KEY}|${SHORT_ID}" >> "$EXPORT_FILE"
    echo ""
done
echo -e "${BOLD}${GREEN}  ╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}  ║            Готово!                     ║${NC}"
echo -e "${BOLD}${GREEN}  ╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Запущенные контейнеры:${NC}"
docker ps --format '  {{.Names}}\t{{.Status}}' | grep xray || echo "  (нет)"
echo ""
echo -e "  ${BOLD}Строки для servers.conf на RU-VPS:${NC}"
sep
cat "$EXPORT_FILE"
sep
echo ""
echo -e "  ${DIM}Инстансы:    $XRAY_DIR/instances/<port>/${NC}"
echo -e "  ${DIM}Экспорт:     $EXPORT_FILE${NC}"
echo -e "  ${DIM}Клиент URLs: cat $XRAY_DIR/instances/<port>/connection.env${NC}"
echo ""
echo -e "  ${BOLD}Полезные команды:${NC}"
echo -e "  ${DIM}docker ps                    — статус${NC}"
echo -e "  ${DIM}docker logs xray-<port>      — логи${NC}"
echo -e "  ${DIM}docker restart xray-<port>   — перезапуск${NC}"
echo ""
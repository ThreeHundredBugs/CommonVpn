#!/bin/bash
# ============================================================
# awg-get-server-line.sh — выводит строку для servers.conf
# Запускать на foreign/backup VPS
# ============================================================

GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; YELLOW='\033[1;33m'; NC='\033[0m'

sep() { echo -e "${DIM}  ─────────────────────────────────────${NC}"; }

AWG_DIR="/etc/amnezia/amneziawg"

# Ищем серверный xray config (inbounds с reality)
XRAY_CONFIG=""
for c in /opt/xray/config.json /home/*/pywg/xray/config.json; do
    [[ -f "$c" ]] && { XRAY_CONFIG="$c"; break; }
done

echo ""
echo -e "${BOLD}${CYAN}  awg-get-server-line${NC}"
echo -e "${DIM}  Собирает строку подключения для servers.conf на RU-VPS${NC}"
echo ""

read -rp "  Alias для этого сервера (например: backup1): " ALIAS
[[ -z "$ALIAS" ]] && { echo "Alias не может быть пустым"; exit 1; }
echo ""

# ── AWG ──
SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')
AWG_PORT=51820
AWG_PUBKEY=""

if [[ -f "$AWG_DIR/server_public.key" ]]; then
    AWG_PUBKEY=$(cat "$AWG_DIR/server_public.key")
    AWG_PORT=$(awk '/^ListenPort/{print $3; exit}' "$AWG_DIR/awg0.conf" 2>/dev/null || echo "51820")
else
    echo -e "${YELLOW}  ⚠ AWG не найден, введите вручную:${NC}"
    read -rp "  AWG PublicKey: " AWG_PUBKEY
    read -rp "  AWG Port [$AWG_PORT]: " P; [[ -n "$P" ]] && AWG_PORT=$P
fi

# ── Xray — читаем серверный inbound ──
XRAY_IP=""; XRAY_PORT=""; XRAY_UUID=""; XRAY_PUBKEY=""; XRAY_SHORTID=""

if [[ -n "$XRAY_CONFIG" ]]; then
    PARSED=$(python3 - "$XRAY_CONFIG" << 'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    cfg = json.load(f)

# Ищем inbound с reality (серверный конфиг)
for ib in cfg.get('inbounds', []):
    ss = ib.get('streamSettings', {})
    if ss.get('security') == 'reality':
        rs = ss['realitySettings']
        clients = ib.get('settings', {}).get('clients', [])
        uuid = clients[0]['id'] if clients else ''
        print(ib.get('port', ''))
        print(uuid)
        print(rs.get('privateKey', ''))
        print(rs.get('shortIds', [''])[0])
        sys.exit(0)

# Не нашли — пустой вывод
print('')
print('')
print('')
print('')
PYEOF
    )

    XRAY_PORT=$(echo "$PARSED"    | sed -n '1p')
    XRAY_UUID=$(echo "$PARSED"    | sed -n '2p')
    XRAY_PRIVKEY=$(echo "$PARSED" | sed -n '3p')
    XRAY_SHORTID=$(echo "$PARSED" | sed -n '4p')

    # Получаем PublicKey из PrivateKey через docker
    if [[ -n "$XRAY_PRIVKEY" ]]; then
        XRAY_PUBKEY=$(docker run --rm --entrypoint xray teddysun/xray x25519 -i "$XRAY_PRIVKEY" 2>/dev/null \
            | grep -E 'Password|Public key' | awk '{print $NF}' || echo "")
    fi

    XRAY_IP=$SERVER_IP
fi

# ── Если что-то не вытащилось — спрашиваем ──
if [[ -z "$XRAY_PORT" || -z "$XRAY_UUID" || -z "$XRAY_PUBKEY" || -z "$XRAY_SHORTID" ]]; then
    echo -e "${YELLOW}  ⚠ Xray: не все данные определены автоматически${NC}"
    echo -e "  ${DIM}Оставьте пустым если Xray не используется${NC}"
    echo ""
    [[ -z "$XRAY_IP"      ]] && { read -rp "  Xray IP [$SERVER_IP]: " V; XRAY_IP=${V:-$SERVER_IP}; }
    [[ -z "$XRAY_PORT"    ]] && { read -rp "  Xray Port: " XRAY_PORT; }
    [[ -z "$XRAY_UUID"    ]] && { read -rp "  Xray UUID: " XRAY_UUID; }
    [[ -z "$XRAY_PUBKEY"  ]] && { read -rp "  Xray PublicKey: " XRAY_PUBKEY; }
    [[ -z "$XRAY_SHORTID" ]] && { read -rp "  Xray ShortId: " XRAY_SHORTID; }
    echo ""
fi

# ── Итог ──
LINE="${ALIAS}|${SERVER_IP}:${AWG_PORT}|${AWG_PUBKEY}|${XRAY_IP}|${XRAY_PORT}|${XRAY_UUID}|${XRAY_PUBKEY}|${XRAY_SHORTID}"

echo ""
echo -e "${BOLD}${GREEN}  ╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}  ║        Строка для servers.conf         ║${NC}"
echo -e "${BOLD}${GREEN}  ╚════════════════════════════════════════╝${NC}"
echo ""
sep
echo -e "  ${BOLD}${GREEN}$LINE${NC}"
sep
echo ""
echo -e "  ${DIM}Добавить на RU-VPS:${NC}"
echo -e "  ${DIM}echo '$LINE' >> /etc/amnezia/amneziawg/servers.conf${NC}"
echo ""
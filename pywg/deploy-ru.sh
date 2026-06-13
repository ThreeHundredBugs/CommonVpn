#!/bin/bash
# deploy-ru.sh — обновление конфигов RU-хаба (Xray + AWG peers)
#
# Использование:
#   bash deploy-ru.sh                    — полный деплой (статус + перезапуск)
#   bash deploy-ru.sh --restart-only     — только перезапустить Xray контейнеры
#   bash deploy-ru.sh --add-peer         — добавить новый AWG peer интерактивно
#   bash deploy-ru.sh --status           — только статус контейнеров и AWG
#   bash deploy-ru.sh --dry-run          — показать что будет сделано
#
# Переменные окружения:
#   SSH_KEY, REMOTE_HOST, REMOTE_USER

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
die()  { echo -e "${RED}  ✗${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}${CYAN}[$1]${NC} $2"; }

SSH_KEY="${SSH_KEY:-~/.ssh/id_ed25519}"
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_HOST="${REMOTE_HOST:-}"

MODE="full"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --restart-only) MODE="restart" ;;
        --add-peer)     MODE="add-peer" ;;
        --status)       MODE="status" ;;
        --dry-run|-d)   DRY_RUN=true ;;
        --host=*)       REMOTE_HOST="${arg#--host=}" ;;
        --host)         ;;  # handled below
        *) die "Неизвестный аргумент: $arg" ;;
    esac
done

SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes)

# ── Заголовок ──
echo ""
echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}  ║         RU Hub — Deploy                  ║${NC}"
echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════╝${NC}"
echo ""

[[ -z "$REMOTE_HOST" ]] && read -rp "  IP RU сервера: " REMOTE_HOST
[[ -z "$REMOTE_HOST" ]] && die "IP сервера не указан"

REMOTE="${REMOTE_USER}@${REMOTE_HOST}"
echo -e "  Хост: ${YELLOW}${REMOTE}${NC}  |  Mode: ${BOLD}${MODE}${NC}"
${DRY_RUN} && echo -e "  ${YELLOW}⚠ DRY RUN${NC}"
echo ""

# ── SSH проверка ──
step "0" "Проверка SSH"
ssh "${SSH_OPTS[@]}" "${REMOTE}" "echo ok" > /dev/null \
    || die "Нет SSH доступа к ${REMOTE}"
ok "SSH OK"

# ══════════════════════════════════════════════
# Режим: --status
# ══════════════════════════════════════════════
if [[ "$MODE" == "status" ]]; then
    step "—" "Статус RU хаба"
    ssh "${SSH_OPTS[@]}" "${REMOTE}" << 'STATUS'
export PATH=$PATH:/usr/local/bin:/usr/bin
echo ""
echo "  === AWG ==="
awg show 2>/dev/null || echo "  awg не запущен"
echo ""
echo "  === Xray контейнеры ==="
docker ps --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | grep xray || echo "  нет запущенных"
echo ""
echo "  === servers-conf-lines.txt ==="
cat /opt/xray/instances/servers-conf-lines.txt 2>/dev/null || echo "  файл не найден"
echo ""
STATUS
    exit 0
fi

# ══════════════════════════════════════════════
# Режим: --add-peer
# ══════════════════════════════════════════════
if [[ "$MODE" == "add-peer" ]]; then
    step "—" "Добавление AWG peer"
    echo ""
    read -rp "  Имя нового peer: "        PEER_NAME
    read -rp "  PublicKey нового peer: "  PEER_PUBKEY
    read -rp "  AllowedIPs (напр. 10.8.0.3/32): " PEER_IP
    echo ""

    [[ -z "$PEER_PUBKEY" ]] && die "PublicKey не указан"
    [[ -z "$PEER_IP"     ]] && die "AllowedIPs не указан"

    if ${DRY_RUN}; then
        echo -e "  ${DIM}[dry-run] добавить peer $PEER_NAME ($PEER_PUBKEY) → $PEER_IP${NC}"
        exit 0
    fi

    ssh "${SSH_OPTS[@]}" "${REMOTE}" \
        "PEER_NAME='${PEER_NAME}' PEER_PUBKEY='${PEER_PUBKEY}' PEER_IP='${PEER_IP}' bash -s" << 'ADD_PEER'
AWG_CONF="/etc/amnezia/amneziawg/awg0.conf"

# Проверяем что peer ещё не добавлен
if grep -q "$PEER_PUBKEY" "$AWG_CONF" 2>/dev/null; then
    echo "  ⚠ Peer с таким ключом уже существует в $AWG_CONF"
    exit 0
fi

# Бэкап
cp "$AWG_CONF" "${AWG_CONF}.bak.$(date +%Y%m%d-%H%M%S)"

# Добавляем peer в конфиг
cat >> "$AWG_CONF" << PEER

# $PEER_NAME
[Peer]
PublicKey = $PEER_PUBKEY
AllowedIPs = $PEER_IP
PersistentKeepalive = 25
PEER

# Применяем без перезапуска (живое добавление)
awg set awg0 peer "$PEER_PUBKEY" allowed-ips "$PEER_IP" persistent-keepalive 25 2>/dev/null \
    && echo "  ✓ Peer $PEER_NAME добавлен (горячо, без перезапуска)" \
    || { systemctl restart awg-quick@awg0; echo "  ✓ Peer $PEER_NAME добавлен (перезапуск AWG)"; }
ADD_PEER
    ok "Peer добавлен"
    exit 0
fi

# ══════════════════════════════════════════════
# Режим: --restart-only
# ══════════════════════════════════════════════
if [[ "$MODE" == "restart" ]]; then
    step "—" "Перезапуск Xray контейнеров"
    ${DRY_RUN} && { echo "  [dry-run] docker restart xray-*"; exit 0; }

    ssh "${SSH_OPTS[@]}" "${REMOTE}" << 'RESTART'
export PATH=$PATH:/usr/local/bin
echo ""
for inst in /opt/xray/instances/*/; do
    port=$(basename "$inst")
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    if docker ps --format '{{.Names}}' | grep -q "^xray-${port}$"; then
        (cd "$inst" && docker compose restart > /dev/null 2>&1)
        echo "  ✓ xray-${port} перезапущен"
    else
        (cd "$inst" && docker compose up -d > /dev/null 2>&1)
        echo "  ✓ xray-${port} запущен"
    fi
done
echo ""
echo "  Статус:"
docker ps --format "  {{.Names}}  {{.Status}}" | grep xray || echo "  нет контейнеров"
RESTART
    ok "Готово"
    exit 0
fi

# ══════════════════════════════════════════════
# Полный деплой (default)
# ══════════════════════════════════════════════
step "1/3" "Проверка состояния на сервере"
ssh "${SSH_OPTS[@]}" "${REMOTE}" << 'CHECK'
export PATH=$PATH:/usr/local/bin
echo "  AWG:"; awg show awg0 2>/dev/null | grep -E 'interface:|peer:|endpoint:|latest|transfer' | sed 's/^/    /' || echo "    не запущен"
echo ""
echo "  Xray:"; docker ps --format "  {{.Names}}  {{.Status}}" 2>/dev/null | grep xray || echo "    нет контейнеров"
CHECK

step "2/3" "Перезапуск Xray (если нужно)"
if ${DRY_RUN}; then
    echo -e "  ${DIM}[dry-run] docker compose restart для каждого инстанса${NC}"
else
    ssh "${SSH_OPTS[@]}" "${REMOTE}" << 'RESTART_ALL'
export PATH=$PATH:/usr/local/bin
RESTARTED=0
for inst in /opt/xray/instances/*/; do
    port=$(basename "$inst")
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    if docker ps --format '{{.Names}}' | grep -q "^xray-${port}$"; then
        echo "  ✓ xray-${port} уже запущен"
    else
        (cd "$inst" && docker compose up -d > /dev/null 2>&1)
        echo "  ✓ xray-${port} запущен"
        RESTARTED=$((RESTARTED + 1))
    fi
done
[[ $RESTARTED -eq 0 ]] && echo "  Все контейнеры уже работали, перезапуск не нужен"
RESTART_ALL
fi

step "3/3" "Итоговый статус и servers.conf строки"
ssh "${SSH_OPTS[@]}" "${REMOTE}" << 'FINAL'
export PATH=$PATH:/usr/local/bin
echo ""
echo "  === Xray контейнеры ==="
docker ps --format "  {{.Names}}  {{.Status}}" | grep xray || echo "  нет"
echo ""
echo "  === AWG handshakes ==="
awg show awg0 latest-handshakes 2>/dev/null | awk '{
    age = systime() - $2
    peer = substr($1,1,12) "..."
    if ($2 == 0) print "  " peer ": нет хэндшейка"
    else         print "  " peer ": " age "с назад"
}' || echo "  awg не запущен"
echo ""
echo "  === servers.conf строки ==="
cat /opt/xray/instances/servers-conf-lines.txt 2>/dev/null || echo "  файл не найден — запусти ru-hub-init.sh"
FINAL

echo ""
ok "${BOLD}Деплой завершён!${NC}"
echo ""

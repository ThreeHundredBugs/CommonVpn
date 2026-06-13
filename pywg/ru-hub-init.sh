#!/bin/bash
# ru-hub-init.sh — инициализация нового хаб-сервера
#
# Что делает:
#   1. Устанавливает AmneziaWG CLIENT (awg0) → туннель к RU exit серверам
#   2. Настраивает проброс трафика wg-easy → awg0 (всё через туннель)
#   3. Создаёт wg-smart — нативный WireGuard SERVER для умного VPN (split-tunnel)
#   4. nftables smartvpn + ip rules + routing tables
#   5. dnsmasq на интерфейсе wg-smart (smart domain → nftset)
#   6. Генерирует AWG seeds, ключи, шаблон servers.conf
#
# Запуск ЛОКАЛЬНО:
#   bash ru-hub-init.sh
#   bash ru-hub-init.sh --host 1.2.3.4 --alias vdsina
#
# После запуска:
#   1. Добавь публичный ключ хаба в exit-сервер (инструкция будет выведена)
#   2. Заполни /etc/amnezia/amneziawg/servers.conf
#   3. bash awgswitch.sh — переключись на нужный exit-сервер
#   4. bash deploy-vdsina.sh — задеплой pywg + dnsmasq домены

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
die()  { echo -e "${RED}  ✗${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}${CYAN}[$1]${NC} $2"; }
sep()  { echo -e "${DIM}  ─────────────────────────────────────${NC}"; }

# ── Параметры ──
SSH_KEY="${SSH_KEY:-~/.ssh/id_ed25519}"
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_HOST="${REMOTE_HOST:-}"
ALIAS="${ALIAS:-vdsina}"

# AWG CLIENT — адрес в туннеле (должен быть уникален среди хабов)
AWG_HUB_ADDR="${AWG_HUB_ADDR:-10.8.0.7}"

# wg-smart SERVER — параметры
SMART_ADDR="${SMART_ADDR:-10.30.0.1}"
SMART_SUBNET="${SMART_SUBNET:-10.30.0.0/24}"
SMART_PORT="${SMART_PORT:-51822}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)       REMOTE_HOST="$2";   shift 2 ;;
        --alias)      ALIAS="$2";         shift 2 ;;
        --hub-addr)   AWG_HUB_ADDR="$2"; shift 2 ;;
        --smart-port) SMART_PORT="$2";    shift 2 ;;
        --key)        SSH_KEY="$2";       shift 2 ;;
        *) die "Неизвестный аргумент: $1" ;;
    esac
done

SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes)

# ── Заголовок ──
echo ""
echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}  ║     RU Hub Init — AWG CLIENT + wg-smart  ║${NC}"
echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  SSH ключ: ${DIM}${SSH_KEY}${NC}"
echo ""

[[ -z "$REMOTE_HOST" ]] && read -rp "  IP нового хаб-сервера: " REMOTE_HOST
[[ -z "$REMOTE_HOST" ]] && die "IP не указан"
[[ -z "$ALIAS" ]]       && read -rp "  Alias (напр. vdsina): "  ALIAS

REMOTE="${REMOTE_USER}@${REMOTE_HOST}"

echo ""
echo -e "  ${BOLD}Параметры:${NC}"
sep
echo -e "  Хост:            ${YELLOW}${REMOTE}${NC}"
echo -e "  Alias:           ${BOLD}${ALIAS}${NC}"
echo -e "  AWG hub addr:    ${BOLD}${AWG_HUB_ADDR}/24${NC}  (IP хаба в AWG туннеле)"
echo -e "  wg-smart:        ${BOLD}${SMART_ADDR}${NC}  порт ${SMART_PORT}/udp"
sep
echo ""
read -rp "  Продолжить? [Y/n]: " CONFIRM
[[ "${CONFIRM,,}" == "n" ]] && exit 0
echo ""

# ── SSH проверка ──
step "0/6" "Проверка SSH"
ssh "${SSH_OPTS[@]}" "${REMOTE}" "echo ok" > /dev/null \
    || die "Нет SSH доступа к ${REMOTE}. Ключ: ${SSH_KEY}"
ok "SSH OK"

# ══════════════════════════════════════════════════════
step "1-6/6" "Удалённая инициализация..."
echo ""

ssh "${SSH_OPTS[@]}" "${REMOTE}" \
    "AWG_HUB_ADDR='${AWG_HUB_ADDR}' SMART_ADDR='${SMART_ADDR}' SMART_SUBNET='${SMART_SUBNET}' SMART_PORT='${SMART_PORT}' ALIAS='${ALIAS}' bash -s" << 'REMOTE_INIT'
set -euo pipefail
export PATH=$PATH:/usr/local/bin:/usr/bin:/usr/local/sbin

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
info() { echo -e "${CYAN}  ▸${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
die()  { echo -e "${RED}  ✗${NC} $*" >&2; exit 1; }

AWG_DIR="/etc/amnezia/amneziawg"
SMART_CONF="/etc/wireguard/wg-smart.conf"

# ═══════════════════════════════════════════════════════
# [1] Пакеты
# ═══════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}  [1] Установка пакетов${NC}"

wait_apt() {
    local n=0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
          /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
        (( n++ )); [[ $n -gt 90 ]] && die "apt занят слишком долго"
        (( n % 5 == 0 )) && info "Ожидаем apt... (${n}×2с)"
        sleep 2
    done
}

wait_apt
DEBIAN_FRONTEND=noninteractive apt-get update -qq

# AmneziaWG
if ! command -v awg &>/dev/null; then
    info "Устанавливаем AmneziaWG..."
    if ! apt-cache show amneziawg &>/dev/null 2>&1; then
        add-apt-repository -y ppa:amnezia/ppa > /dev/null 2>&1 || true
        wait_apt; DEBIAN_FRONTEND=noninteractive apt-get update -qq
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq amneziawg amneziawg-tools \
        || die "Не удалось установить amneziawg"
    ok "AmneziaWG установлен"
else
    ok "AmneziaWG уже есть"
fi

# wireguard-tools (для wg-smart), dnsmasq, nftables
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    wireguard-tools dnsmasq nftables iproute2 iptables openssl curl 2>/dev/null
ok "wireguard-tools, dnsmasq, nftables установлены"

# ═══════════════════════════════════════════════════════
# [2] AWG seeds генерация
# ═══════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}  [2] AWG seeds${NC}"

# Используем стандартные seeds (совместимы со всеми существующими exit-серверами)
# Они должны совпадать между клиентом (хаб) и сервером (exit)
JC=4; JMIN=40; JMAX=70; S1=50; S2=100
H1=1407775011; H2=2140498648; H3=254021790; H4=3964887677

ok "Seeds (совместимы с exit-серверами): Jc=$JC Jmin=$JMIN Jmax=$JMAX S1=$S1 S2=$S2"
echo -e "  ${DIM}Для уникальных seeds запусти: bash awg-gen-seeds.sh${NC}"

# ═══════════════════════════════════════════════════════
# [3] AWG CLIENT конфиг (awg0)
# ═══════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}  [3] AmneziaWG CLIENT (awg0)${NC}"

mkdir -p "$AWG_DIR/backups" "$AWG_DIR/clients"

# Генерируем ключи клиента
if [[ -f "$AWG_DIR/client_private.key" ]]; then
    warn "Ключи уже существуют — используем их"
else
    awg genkey | tee "$AWG_DIR/client_private.key" | awg pubkey > "$AWG_DIR/client_public.key"
    chmod 600 "$AWG_DIR/client_private.key"
    ok "AWG ключи сгенерированы"
fi

AWG_PRIV=$(cat "$AWG_DIR/client_private.key")
AWG_PUB=$(cat "$AWG_DIR/client_public.key")

# Определяем wg-easy контейнер IP (из docker-compose.yml)
WG_EASY_IP="10.2.0.3"  # дефолт dwg-ui
for dc in ~/dwg-ui/docker-compose.yml /root/dwg-ui/docker-compose.yml /home/*/dwg-ui/docker-compose.yml; do
    [[ -f "$dc" ]] || continue
    # Ищем IP wg-easy в private_network
    DETECTED=$(python3 -c "
import re, sys
txt = open('$dc').read()
# Ищем ipv4_address у wg-easy сервиса
m = re.search(r'wg-easy.*?ipv4_address:\s*([\d.]+)', txt, re.DOTALL)
if m:
    print(m.group(1))
" 2>/dev/null || true)
    [[ -n "$DETECTED" ]] && { WG_EASY_IP="$DETECTED"; ok "wg-easy IP из docker-compose: $WG_EASY_IP"; break; }
done
[[ "$WG_EASY_IP" == "10.2.0.3" ]] && ok "wg-easy IP (дефолт): $WG_EASY_IP"

# WAN интерфейс
WAN_IF=$(ip route get 1.1.1.1 2>/dev/null \
    | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
[[ -z "$WAN_IF" ]] && WAN_IF=$(ip route | awk '/default/{print $5; exit}')
ok "WAN: $WAN_IF"

# Бэкап существующего конфига
[[ -f "$AWG_DIR/awg0.conf" ]] && \
    cp "$AWG_DIR/awg0.conf" "$AWG_DIR/backups/awg0.conf.bak.$(date +%Y%m%d-%H%M%S)"

cat > "$AWG_DIR/awg0.conf" << CONF
[Interface]
PrivateKey = $AWG_PRIV
Address = ${AWG_HUB_ADDR}/24
Table = off

Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

# Проброс wg-easy клиентов через AWG туннель + smart VPN routing
PostUp = \\
  ip route add default dev awg0 table 51820; \\
  ip route add default dev awg0 table smartvpn; \\
  iptables -t mangle -I PREROUTING 1 -s ${WG_EASY_IP} -p udp --sport 51820 -j ACCEPT; \\
  iptables -t mangle -I PREROUTING 2 -s ${WG_EASY_IP} -j MARK --set-mark 100; \\
  ip rule add fwmark 100 table 51820 priority 97; \\
  iptables -t nat -I POSTROUTING 1 -s ${WG_EASY_IP} -o awg0 -j MASQUERADE

PostDown = \\
  iptables -t nat -D POSTROUTING -s ${WG_EASY_IP} -o awg0 -j MASQUERADE; \\
  ip rule del fwmark 100 table 51820 priority 97; \\
  iptables -t mangle -D PREROUTING -s ${WG_EASY_IP} -j MARK --set-mark 100; \\
  iptables -t mangle -D PREROUTING -s ${WG_EASY_IP} -p udp --sport 51820 -j ACCEPT; \\
  ip route del default dev awg0 table smartvpn; \\
  ip route del default dev awg0 table 51820

# ── Peer будет добавлен через awgswitch.sh ──
# [Peer]
# PublicKey = <EXIT_SERVER_AWG_PUBKEY>
# Endpoint  = <EXIT_SERVER_IP>:51820
# AllowedIPs = 0.0.0.0/0
# PersistentKeepalive = 25
CONF
chmod 600 "$AWG_DIR/awg0.conf"
ok "awg0.conf создан (${AWG_HUB_ADDR}/24, wg-easy proxy: $WG_EASY_IP)"

# ═══════════════════════════════════════════════════════
# [4] Routing tables
# ═══════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}  [4] Routing tables${NC}"

# ip_forward
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg.conf
sysctl -w net.ipv4.ip_forward=1 > /dev/null
ok "ip_forward включён"

# Добавляем таблицу smartvpn в rt_tables (если ещё нет)
RT_TABLES="/etc/iproute2/rt_tables"
if ! grep -q "^200.*smartvpn" "$RT_TABLES" 2>/dev/null; then
    echo "200    smartvpn" >> "$RT_TABLES"
    ok "Таблица smartvpn (200) добавлена в rt_tables"
else
    ok "Таблица smartvpn уже есть"
fi

# ═══════════════════════════════════════════════════════
# [5] nftables — smartvpn таблица
# ═══════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}  [5] nftables smartvpn${NC}"

NFTABLES_CONF="/etc/nftables.d/smartvpn.conf"
mkdir -p /etc/nftables.d

cat > "$NFTABLES_CONF" << 'NFT'
table inet smartvpn {
    set smart_dst_ip {
        type ipv4_addr
        flags dynamic, timeout
        timeout 3600s
    }

    chain prerouting {
        type filter hook prerouting priority mangle;
        ip daddr @smart_dst_ip meta mark set 200
    }
}
NFT

# Добавляем include в основной nftables.conf
NFTABLES_MAIN="/etc/nftables.conf"
if ! grep -q "smartvpn.conf" "$NFTABLES_MAIN" 2>/dev/null; then
    echo 'include "/etc/nftables.d/smartvpn.conf"' >> "$NFTABLES_MAIN"
fi

# Применяем
systemctl enable nftables > /dev/null 2>&1 || true
nft -f "$NFTABLES_CONF" 2>/dev/null || nft -f "$NFTABLES_MAIN" 2>/dev/null || warn "nftables: применение отложено до перезагрузки"

# ip rule для smart mark (200 → table smartvpn)
# Добавим в awg0 PostUp/PostDown (уже есть table smartvpn там)
# Но ip rule нужен постоянно — добавим через systemd
cat > /etc/systemd/system/smartvpn-rules.service << SVCEOF
[Unit]
Description=Smart VPN ip rules
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'ip rule add fwmark 200 table smartvpn priority 96 2>/dev/null || true'
ExecStop=/bin/bash -c 'ip rule del fwmark 200 table smartvpn priority 96 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl enable smartvpn-rules > /dev/null 2>&1
systemctl start  smartvpn-rules 2>/dev/null || true
ok "nftables smartvpn + ip rule mark 200 настроены"

# ═══════════════════════════════════════════════════════
# [6] wg-smart — нативный WireGuard SERVER
# ═══════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}  [6] wg-smart (нативный WG сервер для smart VPN)${NC}"

# Генерируем ключи
if [[ -f /etc/wireguard/wg-smart-server.key ]]; then
    warn "Ключи wg-smart уже существуют"
else
    wg genkey | tee /etc/wireguard/wg-smart-server.key | wg pubkey > /etc/wireguard/wg-smart-server.pub
    chmod 600 /etc/wireguard/wg-smart-server.key
    ok "Ключи wg-smart сгенерированы"
fi

SMART_PRIV=$(cat /etc/wireguard/wg-smart-server.key)
SMART_PUB=$(cat  /etc/wireguard/wg-smart-server.pub)

# wg-smart.conf
# Клиенты получают DNS с 10.30.0.1 (dnsmasq)
# Умные домены → nftset → mark 200 → table smartvpn → awg0
# Остальной трафик клиентов — выходит напрямую через WAN (split tunnel)
[[ -f "$SMART_CONF" ]] && cp "$SMART_CONF" "${SMART_CONF}.bak.$(date +%Y%m%d-%H%M%S)"

cat > "$SMART_CONF" << WGSMART
[Interface]
PrivateKey = $SMART_PRIV
Address = ${SMART_ADDR}/24
ListenPort = $SMART_PORT
DNS = ${SMART_ADDR}

# NAT для wg-smart клиентов (прямой интернет и smart-домены)
PostUp   = iptables -t nat -A POSTROUTING -s ${SMART_SUBNET} -o $WAN_IF -j MASQUERADE; \\
           iptables -A FORWARD -i wg-smart -j ACCEPT; \\
           iptables -A FORWARD -o wg-smart -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${SMART_SUBNET} -o $WAN_IF -j MASQUERADE; \\
           iptables -D FORWARD -i wg-smart -j ACCEPT; \\
           iptables -D FORWARD -o wg-smart -j ACCEPT

# ── Клиенты добавляются ниже ──
# [Peer]
# PublicKey = <CLIENT_PUBKEY>
# AllowedIPs = 10.30.0.2/32
WGSMART
chmod 600 "$SMART_CONF"
ok "wg-smart.conf создан (${SMART_ADDR}/24, порт ${SMART_PORT}/udp)"

# Включаем сервис
systemctl enable  "wg-quick@wg-smart" > /dev/null 2>&1 || true
systemctl restart "wg-quick@wg-smart" 2>/dev/null || warn "wg-smart не запустился (запусти вручную: systemctl start wg-quick@wg-smart)"

# ═══════════════════════════════════════════════════════
# [7] dnsmasq для wg-smart
# ═══════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}  [7] dnsmasq (smart DNS на ${SMART_ADDR})${NC}"

# Отключаем systemd-resolved на порту 53 если нужно
if ss -lnup | grep -q ':53 ' && ! pgrep dnsmasq > /dev/null 2>&1; then
    if systemctl is-active systemd-resolved &>/dev/null; then
        sed -i 's/^#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf 2>/dev/null || true
        echo "DNSStubListener=no" >> /etc/systemd/resolved.conf
        systemctl restart systemd-resolved 2>/dev/null || true
        warn "Отключили DNS stub listener systemd-resolved"
    fi
fi

DNSMASQ_SMART="/etc/dnsmasq.d/wg-smart.conf"

# Базовый конфиг (домены будут добавлены через deploy-vdsina.sh)
cat > "$DNSMASQ_SMART" << DNSCONF
# wg-smart dnsmasq — Generated by ru-hub-init.sh
# Полный список доменов добавляется через deploy-vdsina.sh
interface=wg-smart
bind-interfaces
listen-address=${SMART_ADDR}
port=53

server=1.1.1.1
server=8.8.8.8
no-resolv
cache-size=10000

# Пример:
# nftset=/youtube.com/4#inet#smartvpn#smart_dst_ip
DNSCONF

systemctl enable dnsmasq > /dev/null 2>&1 || true
systemctl restart dnsmasq 2>/dev/null || warn "dnsmasq не запустился — проверь порт 53"
ok "dnsmasq настроен на ${SMART_ADDR}:53"

# ═══════════════════════════════════════════════════════
# [8] servers.conf + awg-monitor setup
# ═══════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}  [8] servers.conf шаблон${NC}"

SERVERS_FILE="$AWG_DIR/servers.conf"
if [[ ! -f "$SERVERS_FILE" ]]; then
    cat > "$SERVERS_FILE" << SCONF
# servers.conf — список exit-серверов для awgswitch / awg_monitor
# Формат: ALIAS|AWG_IP:PORT|AWG_PUBKEY|XRAY_IP|XRAY_PORT|XRAY_UUID|XRAY_PUBKEY|XRAY_SHORTID
#
# Пример (добавь реальные значения):
# delux|92.112.126.63:51820|4SgzBZEnmb9Pd7UmuC+OPp3PEaopPnzTbJt/s9+I4HQ=|92.112.126.63|8443|...|...|...
# backup1|5.145.176.160:51820|3oR29iW3Xm2aXW61Y2xmZO0b4svXeNriifwBDdSffyw=|5.145.176.160|2053|...|...|...
SCONF
    ok "servers.conf шаблон создан: $SERVERS_FILE"
else
    ok "servers.conf уже есть"
fi

# UFW
if command -v ufw &>/dev/null; then
    ufw allow "$SMART_PORT/udp" comment "wg-smart" > /dev/null 2>/dev/null || true
    ok "UFW: $SMART_PORT/udp открыт"
fi

# ═══════════════════════════════════════════════════════
# ИТОГ
# ═══════════════════════════════════════════════════════
SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null \
          || curl -4 -s --max-time 5 api.ipify.org 2>/dev/null \
          || hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}${GREEN}  ╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}  ║        Хаб инициализирован!              ║${NC}"
echo -e "${BOLD}${GREEN}  ╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Хаб:${NC}  $SERVER_IP  alias: $ALIAS"
echo ""
echo -e "  ${BOLD}${CYAN}AWG CLIENT публичный ключ:${NC}"
echo -e "  ${BOLD}${GREEN}${AWG_PUB}${NC}"
echo -e "  ${DIM}(добавь на каждый exit-сервер: awg set awg0 peer \"${AWG_PUB}\" allowed-ips \"${AWG_HUB_ADDR}/32\")${NC}"
echo ""
echo -e "  ${BOLD}${CYAN}wg-smart SERVER публичный ключ:${NC}"
echo -e "  ${BOLD}${GREEN}${SMART_PUB}${NC}"
echo -e "  Адрес: ${BOLD}${SERVER_IP}:${SMART_PORT}/udp${NC}"
echo ""
echo -e "  ${BOLD}Шаблон клиентского конфига для wg-smart:${NC}"
echo -e "  ${DIM}─────────────────────────────────────────────${NC}"
cat << CLIENTCONF
[Interface]
PrivateKey = <СГЕНЕРИРОВАТЬ: wg genkey>
Address = 10.30.0.2/24
DNS = ${SMART_ADDR}

[Peer]
PublicKey = ${SMART_PUB}
Endpoint = ${SERVER_IP}:${SMART_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CLIENTCONF
echo -e "  ${DIM}─────────────────────────────────────────────${NC}"
echo ""
echo -e "  ${BOLD}Следующие шаги:${NC}"
echo -e "  1. На exit-серверах добавь хаб как peer:"
echo -e "     ${DIM}awg set awg0 peer \"${AWG_PUB}\" allowed-ips \"${AWG_HUB_ADDR}/32\" persistent-keepalive 25${NC}"
echo -e "     ${DIM}# + добавь в /etc/amnezia/amneziawg/awg0.conf на exit-сервере${NC}"
echo ""
echo -e "  2. Заполни $AWG_DIR/servers.conf на этом хабе"
echo ""
echo -e "  3. bash awgswitch.sh (или awg_monitor.py --force) — переключись на exit-сервер"
echo ""
echo -e "  4. bash deploy-vdsina.sh — задеплой pywg + dnsmasq домены"
echo ""
REMOTE_INIT

ok "Инициализация завершена!"

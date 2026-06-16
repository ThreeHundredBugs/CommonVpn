#!/bin/bash
# ============================================================
# awg-server-setup.sh — установка AmneziaWG + WireGuard + опционально Xray
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
WG_DIR="/etc/wireguard"
XRAY_DIR="/opt/xray"
AWG_PORT=51820
WG_PORT=51821
AWG_SUBNET="10.8.0"
WG_SUBNET="10.9.0"
JC=4; JMIN=40; JMAX=70; S1=50; S2=100
H1=1407775011; H2=2140498648; H3=254021790; H4=3964887677
XRAY_PORT=2053
XRAY_SNI="www.microsoft.com"

# ══════════════════════════════════════════════
clear
echo ""
echo -e "${BOLD}${CYAN}  ╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}  ║   VPS Setup: AWG + WG + Xray VLESS    ║${NC}"
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
echo -e "    2) Только WireGuard (vanilla)"
echo -e "    3) Только Xray VLESS+Reality"
echo -e "    4) AWG + WireGuard"
echo -e "    5) AWG + Xray"
echo -e "    6) WireGuard + Xray"
echo -e "    7) Всё (AWG + WireGuard + Xray)"
echo ""
ask "Выбор [1-7]: " INSTALL_CHOICE
echo ""

INSTALL_AWG=false
INSTALL_WG=false
INSTALL_XRAY=false
case "$INSTALL_CHOICE" in
  1) INSTALL_AWG=true ;;
  2) INSTALL_WG=true ;;
  3) INSTALL_XRAY=true ;;
  4) INSTALL_AWG=true; INSTALL_WG=true ;;
  5) INSTALL_AWG=true; INSTALL_XRAY=true ;;
  6) INSTALL_WG=true; INSTALL_XRAY=true ;;
  7) INSTALL_AWG=true; INSTALL_WG=true; INSTALL_XRAY=true ;;
  *) die "Неверный выбор" ;;
esac

# ── Дополнительные вопросы ──
if $INSTALL_AWG; then
    echo -e "  ${DIM}Порт AmneziaWG (Enter = $AWG_PORT):${NC}"
    ask "Порт AWG [$AWG_PORT]: " AWG_PORT_INPUT
    [[ -n "${AWG_PORT_INPUT:-}" ]] && AWG_PORT=$AWG_PORT_INPUT

    echo -e "  ${DIM}Публичный ключ RU-VPS для AWG (оставьте пустым — добавите позже):${NC}"
    echo -e "  ${DIM}Узнать на ru-vps: sudo awg show | grep 'public key'${NC}"
    ask "Публичный ключ RU-VPS (AWG): " RU_PUBLIC_KEY
    echo ""
fi

if $INSTALL_WG; then
    echo -e "  ${DIM}Порт WireGuard (Enter = $WG_PORT):${NC}"
    ask "Порт WG [$WG_PORT]: " WG_PORT_INPUT
    [[ -n "${WG_PORT_INPUT:-}" ]] && WG_PORT=$WG_PORT_INPUT

    echo -e "  ${DIM}Публичный ключ RU-VPS для WG (оставьте пустым — добавите позже):${NC}"
    ask "Публичный ключ RU-VPS (WG): " WG_RU_PUBLIC_KEY
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
$INSTALL_AWG  && echo -e "    ${GREEN}●${NC} AmneziaWG сервер     — порт ${AWG_PORT}/udp, подсеть ${AWG_SUBNET}.0/24"
$INSTALL_WG   && echo -e "    ${GREEN}●${NC} WireGuard сервер     — порт ${WG_PORT}/udp,  подсеть ${WG_SUBNET}.0/24"
$INSTALL_XRAY && echo -e "    ${GREEN}●${NC} Xray VLESS+Reality   — порт ${XRAY_PORT}/tcp, SNI ${XRAY_SNI}"
sep
echo ""
ask "Продолжить? [Y/n]: " CONFIRM
[[ "${CONFIRM,,}" == "n" ]] && exit 0
echo ""

# ══════════════════════════════════════════════
# БЛОК 1: Общие зависимости
# ══════════════════════════════════════════════
echo -e "${BOLD}  [1] Зависимости${NC}"

# Чистим битые PPA от предыдущих запусков (особенно amnezia на unsupported дистрибутивах)
if ls /etc/apt/sources.list.d/amnezia-* >/dev/null 2>&1; then
    warn "Найдены старые amnezia PPA sources — удаляем перед обновлением"
    rm -f /etc/apt/sources.list.d/amnezia-*.list /etc/apt/sources.list.d/amnezia-*.sources
fi

apt_safe update -qq

PKGS=(curl wget nano iproute2 iptables qrencode)
$INSTALL_AWG  && PKGS+=(wireguard-tools software-properties-common)
$INSTALL_WG   && PKGS+=(wireguard wireguard-tools)
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
        # Определяем кодовое имя дистрибутива
        DISTRO_CODENAME=$(lsb_release -cs 2>/dev/null || (. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}"))

        AWG_INSTALLED=false
        info "Пробуем PPA amnezia/ppa (codename: $DISTRO_CODENAME)..."

        # Проверяем PPA в subshell — set -e не убьёт основной скрипт при падении
        PPA_OK=false
        if (set +e
            add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1 || exit 1
            apt-get update -qq >/dev/null 2>&1 || exit 1
            apt-cache show amneziawg >/dev/null 2>&1 || exit 1
        ); then
            PPA_OK=true
        fi

        if $PPA_OK; then
            apt_safe install -y -qq amneziawg amneziawg-tools
            AWG_INSTALLED=true
            ok "AmneziaWG установлен через PPA"
        else
            warn "PPA недоступен для $DISTRO_CODENAME — собираем из исходников через DKMS"
            # Чистим битый sources entry если успел добавиться
            add-apt-repository -y --remove ppa:amnezia/ppa >/dev/null 2>&1 || true
            apt-get update -qq 2>/dev/null || true

            # ── Зависимости для сборки ──
            info "Устанавливаем зависимости сборки..."
            apt_safe install -y -qq                 dkms build-essential pkg-config                 linux-headers-$(uname -r)                 libmnl-dev libelf-dev

            AWG_TMP=$(mktemp -d)
            AWG_SRC="$AWG_TMP/amneziawg-src"

            # ── Клонируем исходники ──
            info "Клонируем amneziawg-linux-kernel-module..."
            if command -v git &>/dev/null; then
                git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git "$AWG_SRC"                     || die "git clone не удался — проверьте доступ к github.com"
            else
                apt_safe install -y -qq git
                git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git "$AWG_SRC"                     || die "git clone не удался — проверьте доступ к github.com"
            fi

            # ── Собираем и устанавливаем модуль через DKMS ──
            AWG_VER=$(git -C "$AWG_SRC" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "1.0.0")
            AWG_DKMS_SRC="/usr/src/amneziawg-${AWG_VER}"

            info "Версия: $AWG_VER — копируем в /usr/src..."
            mkdir -p "$AWG_DKMS_SRC"
            cp -r "$AWG_SRC/src/"* "$AWG_DKMS_SRC/"

            # dkms.conf
            cat > "$AWG_DKMS_SRC/dkms.conf" << DKMSCONF
PACKAGE_NAME="amneziawg"
PACKAGE_VERSION="$AWG_VER"
BUILT_MODULE_NAME[0]="amneziawg"
DEST_MODULE_LOCATION[0]="/kernel/net/amneziawg/"
AUTOINSTALL="YES"
DKMSCONF

            dkms add     "amneziawg/${AWG_VER}" 2>/dev/null || true
            dkms build   "amneziawg/${AWG_VER}" || die "DKMS build провалился"
            dkms install "amneziawg/${AWG_VER}" --force || die "DKMS install провалился"

            # ── awg-tools: собираем бинарники ──
            info "Собираем amneziawg-tools..."
            AWG_TOOLS_SRC="$AWG_TMP/amneziawg-tools"
            if command -v git &>/dev/null; then
                git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-tools.git "$AWG_TOOLS_SRC"                     || die "git clone amneziawg-tools не удался"
            fi
            make -C "$AWG_TOOLS_SRC/src" -j"$(nproc)"
            # В amneziawg-tools бинарник называется wg — копируем как awg/awg-quick
            if [[ -f "$AWG_TOOLS_SRC/src/awg" ]]; then
                install -m 755 "$AWG_TOOLS_SRC/src/awg"       /usr/local/bin/awg
                install -m 755 "$AWG_TOOLS_SRC/src/awg-quick" /usr/local/bin/awg-quick
            elif [[ -f "$AWG_TOOLS_SRC/src/wg" ]]; then
                install -m 755 "$AWG_TOOLS_SRC/src/wg" /usr/local/bin/awg
                # wg-quick — директория с bash-скриптом внутри
                # wg-quick — директория с платформенными скриптами, берём linux.bash
                if [[ -f "$AWG_TOOLS_SRC/src/wg-quick/linux.bash" ]]; then
                    install -m 755 "$AWG_TOOLS_SRC/src/wg-quick/linux.bash" /usr/local/bin/awg-quick
                else
                    AWG_QUICK=$(find "$AWG_TOOLS_SRC" -type f -name "linux.bash" 2>/dev/null | head -1 || true)
                    [[ -n "$AWG_QUICK" ]] && install -m 755 "$AWG_QUICK" /usr/local/bin/awg-quick
                fi
            else
                die "Бинарник awg/wg не найден после сборки — проверьте вывод make"
            fi

            rm -rf "$AWG_TMP"

            # Загружаем модуль
            modprobe amneziawg 2>/dev/null || true

            AWG_INSTALLED=true
            ok "AmneziaWG собран и установлен из исходников (DKMS + tools)"
        fi

        $AWG_INSTALLED || die "Не удалось установить AmneziaWG"
    else
        ok "Уже установлен: $(awg --version 2>/dev/null || echo 'ok')"
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
        ok "Peer ruvps (AWG) добавлен"
    fi

    chmod 600 "$AWG_DIR/awg0.conf"

    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-vpn-forward.conf
    sysctl --system > /dev/null 2>&1
    ok "IP forwarding включён"

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "$AWG_PORT/udp" > /dev/null
        ok "UFW: открыт $AWG_PORT/udp"
    fi

    # Если awg установлен из исходников — systemd unit отсутствует, создаём
    if ! systemctl cat "awg-quick@.service" &>/dev/null; then
        info "Создаём systemd unit awg-quick@.service..."
        cat > /etc/systemd/system/awg-quick@.service << 'UNIT'
[Unit]
Description=AmneziaWG via awg-quick(8) for %I
After=network-online.target nss-lookup.target
Wants=network-online.target nss-lookup.target
PartOf=awg-quick.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/awg-quick up %i
ExecStop=/usr/local/bin/awg-quick down %i
Environment=WG_ENDPOINT_RESOLUTION_RETRIES=infinity

[Install]
WantedBy=multi-user.target awg-quick.target
UNIT
        systemctl daemon-reload
        ok "systemd unit создан"
    fi

    systemctl stop "awg-quick@awg0" 2>/dev/null || true
    ip link del awg0 2>/dev/null || true
    systemctl reset-failed "awg-quick@awg0" 2>/dev/null || true
    systemctl enable --now "awg-quick@awg0"
    ok "Сервис awg-quick@awg0 запущен"

    # ── Утилита awg-add-client ──
    cat > /usr/local/bin/awg-add-client << 'SCRIPT'
#!/bin/bash
set -euo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

CLIENT_NAME="${1:?Usage: awg-add-client <name>}"
AWG_DIR="/etc/amnezia/amneziawg"
CLIENTS_DIR="$AWG_DIR/clients"
SERVER_PUB=$(cat "$AWG_DIR/server_public.key")
SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')
SERVER_PORT=$(grep "ListenPort" "$AWG_DIR/awg0.conf" | awk '{print $3}')
JC=$(grep "^Jc"   "$AWG_DIR/awg0.conf" | awk '{print $3}')
JMIN=$(grep "^Jmin" "$AWG_DIR/awg0.conf" | awk '{print $3}')
JMAX=$(grep "^Jmax" "$AWG_DIR/awg0.conf" | awk '{print $3}')
S1=$(grep "^S1"   "$AWG_DIR/awg0.conf" | awk '{print $3}')
S2=$(grep "^S2"   "$AWG_DIR/awg0.conf" | awk '{print $3}')
H1=$(grep "^H1"   "$AWG_DIR/awg0.conf" | awk '{print $3}')
H2=$(grep "^H2"   "$AWG_DIR/awg0.conf" | awk '{print $3}')
H3=$(grep "^H3"   "$AWG_DIR/awg0.conf" | awk '{print $3}')
H4=$(grep "^H4"   "$AWG_DIR/awg0.conf" | awk '{print $3}')
SUBNET=$(grep "^Address" "$AWG_DIR/awg0.conf" | grep -oP "\d+\.\d+\.\d+")

mkdir -p "$CLIENTS_DIR"
[[ -f "$CLIENTS_DIR/$CLIENT_NAME.conf" ]] && { echo -e "${RED}  ✗ Клиент '$CLIENT_NAME' уже существует${NC}"; exit 1; }

CLIENT_PRIV=$(awg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | awg pubkey)
LAST_IP=$(grep -r "AllowedIPs" "$AWG_DIR/awg0.conf" 2>/dev/null | grep -oP "${SUBNET}\.\K\d+" | sort -n | tail -1 || echo "1")
NEXT_IP=$((${LAST_IP:-1} + 1))

cat >> "$AWG_DIR/awg0.conf" << PEER

# $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = ${SUBNET}.${NEXT_IP}/32
PEER

cat > "$CLIENTS_DIR/$CLIENT_NAME.conf" << CONF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = ${SUBNET}.${NEXT_IP}/24
DNS = 1.1.1.1
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $SERVER_PUB
Endpoint = ${SERVER_IP}:${SERVER_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONF

awg set awg0 peer "$CLIENT_PUB" allowed-ips "${SUBNET}.${NEXT_IP}/32"

echo ""
echo -e "${BOLD}${GREEN}  ✓ Клиент '$CLIENT_NAME' — IP: ${SUBNET}.${NEXT_IP}${NC}"
echo -e "${DIM}  Файл: $CLIENTS_DIR/$CLIENT_NAME.conf${NC}"
echo ""
cat "$CLIENTS_DIR/$CLIENT_NAME.conf"
echo ""
command -v qrencode &>/dev/null && qrencode -t ansiutf8 < "$CLIENTS_DIR/$CLIENT_NAME.conf"
SCRIPT
    chmod +x /usr/local/bin/awg-add-client

    # ── Утилита awg-status ──
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
    ip=$(grep "Address" "$f" | grep -oP "\d+\.\d+\.\d+\.\d+")
    echo -e "    ${GREEN}●${NC} $name ${DIM}($ip)${NC}"
done
echo ""
SCRIPT
    chmod +x /usr/local/bin/awg-status
    ok "awg-add-client и awg-status установлены"
fi

# ══════════════════════════════════════════════
# БЛОК 3: WireGuard (vanilla)
# ══════════════════════════════════════════════
if $INSTALL_WG; then
    echo ""
    echo -e "${BOLD}  [3] WireGuard (vanilla)${NC}"

    mkdir -p "$WG_DIR/clients"
    chmod 700 "$WG_DIR"

    if [[ -f "$WG_DIR/server_private.key" ]]; then
        warn "Ключи WG уже существуют, используем их"
    else
        wg genkey | tee "$WG_DIR/server_private.key" | wg pubkey > "$WG_DIR/server_public.key"
        chmod 600 "$WG_DIR/server_private.key"
        ok "Ключи WG сгенерированы"
    fi

    WG_SERVER_PRIV=$(cat "$WG_DIR/server_private.key")
    WG_SERVER_PUB=$(cat "$WG_DIR/server_public.key")

    [[ -f "$WG_DIR/wg0.conf" ]] && cp "$WG_DIR/wg0.conf" "$WG_DIR/wg0.conf.bak.$(date +%Y%m%d-%H%M%S)"

    cat > "$WG_DIR/wg0.conf" << CONF
[Interface]
PrivateKey = $WG_SERVER_PRIV
Address = ${WG_SUBNET}.1/24
ListenPort = $WG_PORT

PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $WAN_IF -j MASQUERADE
CONF

    if [[ -n "${WG_RU_PUBLIC_KEY:-}" ]]; then
        cat >> "$WG_DIR/wg0.conf" << PEER

# ruvps
[Peer]
PublicKey = $WG_RU_PUBLIC_KEY
AllowedIPs = ${WG_SUBNET}.4/32
PEER
        ok "Peer ruvps (WG) добавлен"
    fi

    chmod 600 "$WG_DIR/wg0.conf"

    # ip_forward уже включён выше (или включаем здесь если AWG не ставили)
    if ! $INSTALL_AWG; then
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-vpn-forward.conf
        sysctl --system > /dev/null 2>&1
        ok "IP forwarding включён"
    fi

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "$WG_PORT/udp" > /dev/null
        ok "UFW: открыт $WG_PORT/udp"
    fi

    systemctl stop "wg-quick@wg0" 2>/dev/null || true
    ip link del wg0 2>/dev/null || true
    systemctl reset-failed "wg-quick@wg0" 2>/dev/null || true
    systemctl enable --now "wg-quick@wg0"
    ok "Сервис wg-quick@wg0 запущен"

    # ── Утилита wg-add-client ──
    cat > /usr/local/bin/wg-add-client << 'SCRIPT'
#!/bin/bash
set -euo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

CLIENT_NAME="${1:?Usage: wg-add-client <name>}"
WG_DIR="/etc/wireguard"
CLIENTS_DIR="$WG_DIR/clients"
SERVER_PUB=$(cat "$WG_DIR/server_public.key")
SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')
SERVER_PORT=$(grep "ListenPort" "$WG_DIR/wg0.conf" | awk '{print $3}')
SUBNET=$(grep "^Address" "$WG_DIR/wg0.conf" | grep -oP "\d+\.\d+\.\d+")

mkdir -p "$CLIENTS_DIR"
[[ -f "$CLIENTS_DIR/$CLIENT_NAME.conf" ]] && { echo -e "${RED}  ✗ Клиент '$CLIENT_NAME' уже существует${NC}"; exit 1; }

CLIENT_PRIV=$(wg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)
CLIENT_PSK=$(wg genpsk)

LAST_IP=$(grep -r "AllowedIPs" "$WG_DIR/wg0.conf" 2>/dev/null | grep -oP "${SUBNET}\.\K\d+" | sort -n | tail -1 || echo "1")
NEXT_IP=$((${LAST_IP:-1} + 1))

cat >> "$WG_DIR/wg0.conf" << PEER

# $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUB
PresharedKey = $CLIENT_PSK
AllowedIPs = ${SUBNET}.${NEXT_IP}/32
PEER

cat > "$CLIENTS_DIR/$CLIENT_NAME.conf" << CONF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = ${SUBNET}.${NEXT_IP}/24
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
PresharedKey = $CLIENT_PSK
Endpoint = ${SERVER_IP}:${SERVER_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONF

# Добавляем peer без перезапуска сервиса
wg set wg0 peer "$CLIENT_PUB" preshared-key <(echo "$CLIENT_PSK") allowed-ips "${SUBNET}.${NEXT_IP}/32"

echo ""
echo -e "${BOLD}${GREEN}  ✓ Клиент '$CLIENT_NAME' — IP: ${SUBNET}.${NEXT_IP}${NC}"
echo -e "${DIM}  Файл: $CLIENTS_DIR/$CLIENT_NAME.conf${NC}"
echo ""
cat "$CLIENTS_DIR/$CLIENT_NAME.conf"
echo ""
command -v qrencode &>/dev/null && qrencode -t ansiutf8 < "$CLIENTS_DIR/$CLIENT_NAME.conf"
SCRIPT
    chmod +x /usr/local/bin/wg-add-client

    # ── Утилита wg-status ──
    cat > /usr/local/bin/wg-status << 'SCRIPT'
#!/bin/bash
GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
echo ""
echo -e "${BOLD}${CYAN}  WireGuard — Статус${NC}"
echo -e "${DIM}  ─────────────────────────────────────${NC}"
wg show
echo -e "${DIM}  ─────────────────────────────────────${NC}"
echo -e "  ${BOLD}Клиенты:${NC}"
for f in /etc/wireguard/clients/*.conf; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f" .conf)
    ip=$(grep "Address" "$f" | grep -oP "\d+\.\d+\.\d+\.\d+")
    echo -e "    ${GREEN}●${NC} $name ${DIM}($ip)${NC}"
done
echo ""
SCRIPT
    chmod +x /usr/local/bin/wg-status
    ok "wg-add-client и wg-status установлены"
fi

# ══════════════════════════════════════════════
# БЛОК 4: Xray VLESS+Reality
# ══════════════════════════════════════════════
if $INSTALL_XRAY; then
    echo ""
    echo -e "${BOLD}  [4] Xray VLESS+Reality${NC}"

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
    echo -e "    Endpoint:       ${BOLD}${SERVER_IP}:${AWG_PORT}${NC}"
    echo -e "    Публичный ключ: ${BOLD}$AWG_SERVER_PUB${NC}"
    echo -e "    Команды:        awg-add-client <name>  |  awg-status"
    echo ""
fi

if $INSTALL_WG; then
    echo -e "  ${BOLD}${CYAN}WireGuard (vanilla):${NC}"
    echo -e "    Endpoint:       ${BOLD}${SERVER_IP}:${WG_PORT}${NC}"
    echo -e "    Публичный ключ: ${BOLD}$WG_SERVER_PUB${NC}"
    echo -e "    Команды:        wg-add-client <name>   |  wg-status"
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
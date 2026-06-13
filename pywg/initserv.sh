#!/bin/bash
# ============================================================
# vps-init.sh — базовая настройка нового VPS
# Создаёт пользователя, настраивает SSH, UFW, fail2ban, docker
# Использование: bash vps-init.sh
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
info() { echo -e "${CYAN}  ▸${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
die()  { echo -e "${RED}  ✗${NC} $*"; exit 1; }
sep()  { echo -e "${DIM}  ─────────────────────────────────────${NC}"; }
ask()  { read -rp "  $1" "$2"; }

[[ $EUID -ne 0 ]] && die "Запускай от root"

# ══════════════════════════════════════════════
clear
echo ""
echo -e "${BOLD}${CYAN}  ╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}  ║        VPS Initial Setup               ║${NC}"
echo -e "${BOLD}${CYAN}  ╚════════════════════════════════════════╝${NC}"
echo ""

SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')
echo -e "  ${BOLD}Сервер:${NC} $SERVER_IP  ${DIM}($(hostname))${NC}"
echo ""

# ── Параметры ──
echo -e "  ${BOLD}Настройки:${NC}"
sep

ask "Имя нового пользователя [pot]: " NEW_USER
NEW_USER=${NEW_USER:-pot}

ask "SSH порт [22]: " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

echo ""
echo -e "  ${BOLD}Дополнительные открытые порты:${NC}"
echo -e "  ${DIM}Будут открыты автоматически: $SSH_PORT/tcp, 51820/udp, 2053/tcp, 8443/tcp${NC}"
echo -e "  ${DIM}Доп. порты через пробел (например: 80 443), Enter — пропустить:${NC}"
ask "Доп. порты: " EXTRA_PORTS

echo ""
echo -e "  ${BOLD}Установить?${NC}"
echo -e "    ${DIM}[1]${NC} Создать пользователя + sudo"
echo -e "    ${DIM}[2]${NC} Скопировать SSH ключи root → пользователь"
echo -e "    ${DIM}[3]${NC} Отключить root login / парольный SSH"
echo -e "    ${DIM}[4]${NC} UFW файрвол"
echo -e "    ${DIM}[5]${NC} fail2ban"
echo -e "    ${DIM}[6]${NC} Docker + добавить пользователя в группу"
echo -e "    ${DIM}[7]${NC} Базовые утилиты"
echo ""
ask "Всё из списка? [Y/n]: " DO_ALL
echo ""

if [[ "${DO_ALL,,}" != "n" ]]; then
    DO_USER=true; DO_SSH_COPY=true; DO_HARDEN=true
    DO_UFW=true;  DO_FAIL2BAN=true; DO_DOCKER=true; DO_UTILS=true
else
    ask "Создать пользователя? [Y/n]: "    X; [[ "${X,,}" != "n" ]] && DO_USER=true     || DO_USER=false
    ask "Скопировать SSH ключи? [Y/n]: "   X; [[ "${X,,}" != "n" ]] && DO_SSH_COPY=true || DO_SSH_COPY=false
    ask "Отключить root SSH? [Y/n]: "      X; [[ "${X,,}" != "n" ]] && DO_HARDEN=true   || DO_HARDEN=false
    ask "Настроить UFW? [Y/n]: "           X; [[ "${X,,}" != "n" ]] && DO_UFW=true      || DO_UFW=false
    ask "Установить fail2ban? [Y/n]: "     X; [[ "${X,,}" != "n" ]] && DO_FAIL2BAN=true || DO_FAIL2BAN=false
    ask "Установить Docker? [Y/n]: "       X; [[ "${X,,}" != "n" ]] && DO_DOCKER=true   || DO_DOCKER=false
    ask "Установить утилиты? [Y/n]: "      X; [[ "${X,,}" != "n" ]] && DO_UTILS=true    || DO_UTILS=false
fi

sep
echo ""

# ══════════════════════════════════════════════
# [1] Утилиты
# ══════════════════════════════════════════════
if $DO_UTILS; then
    echo -e "${BOLD}  [1] Утилиты${NC}"
    apt-get update -qq
    apt-get install -y -qq \
        curl wget nano vim htop git \
        iproute2 iptables net-tools \
        ufw fail2ban \
        ca-certificates gnupg lsb-release \
        software-properties-common \
        unzip jq qrencode \
        wireguard-tools 2>/dev/null
    ok "Утилиты установлены"
    echo ""
fi

# ══════════════════════════════════════════════
# [2] Пользователь
# ══════════════════════════════════════════════
if $DO_USER; then
    echo -e "${BOLD}  [2] Пользователь: $NEW_USER${NC}"

    if id "$NEW_USER" &>/dev/null; then
        warn "Пользователь $NEW_USER уже существует"
    else
        adduser --disabled-password --gecos "" "$NEW_USER"
        ok "Пользователь $NEW_USER создан"
    fi

    # sudo без пароля
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$NEW_USER"
    chmod 440 "/etc/sudoers.d/$NEW_USER"
    ok "sudo без пароля настроен"
    echo ""
fi

# ══════════════════════════════════════════════
# [3] Копируем SSH ключи root → пользователь
# ══════════════════════════════════════════════
if $DO_SSH_COPY; then
    echo -e "${BOLD}  [3] SSH ключи root → $NEW_USER${NC}"

    ROOT_AUTH="/root/.ssh/authorized_keys"
    USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6)
    USER_SSH="$USER_HOME/.ssh"

    if [[ -f "$ROOT_AUTH" ]]; then
        mkdir -p "$USER_SSH"
        cp "$ROOT_AUTH" "$USER_SSH/authorized_keys"
        chown -R "$NEW_USER:$NEW_USER" "$USER_SSH"
        chmod 700 "$USER_SSH"
        chmod 600 "$USER_SSH/authorized_keys"
        KEY_COUNT=$(wc -l < "$USER_SSH/authorized_keys")
        ok "Скопировано ключей: $KEY_COUNT"
    else
        warn "authorized_keys у root не найден — добавь ключ вручную:"
        echo -e "  ${DIM}ssh-copy-id -i ~/.ssh/id_rsa.pub $NEW_USER@$SERVER_IP -p $SSH_PORT${NC}"
    fi
    echo ""
fi

# ══════════════════════════════════════════════
# [4] Hardening SSH
# ══════════════════════════════════════════════
if $DO_HARDEN; then
    echo -e "${BOLD}  [4] Hardening SSH${NC}"

    SSHD="/etc/ssh/sshd_config"
    cp "$SSHD" "${SSHD}.bak.$(date +%Y%m%d-%H%M%S)"

    # Применяем настройки
    _sshd_set() {
        local key=$1 val=$2
        if grep -qE "^#?${key}" "$SSHD"; then
            sed -i "s|^#\?${key}.*|${key} ${val}|" "$SSHD"
        else
            echo "${key} ${val}" >> "$SSHD"
        fi
    }

    _sshd_set "Port"                    "$SSH_PORT"
    _sshd_set "PermitRootLogin"         "no"
    _sshd_set "PasswordAuthentication"  "no"
    _sshd_set "PubkeyAuthentication"    "yes"
    _sshd_set "AuthorizedKeysFile"      ".ssh/authorized_keys"
    _sshd_set "X11Forwarding"           "no"
    _sshd_set "MaxAuthTries"            "3"
    _sshd_set "LoginGraceTime"          "30"
    _sshd_set "ClientAliveInterval"     "120"
    _sshd_set "ClientAliveCountMax"     "3"
    _sshd_set "AllowAgentForwarding"    "no"
    _sshd_set "AllowTcpForwarding"      "yes"   # нужен для туннелей

    ok "PermitRootLogin     → no"
    ok "PasswordAuthentication → no"
    ok "MaxAuthTries        → 3"
    ok "Port               → $SSH_PORT"

    # Проверяем конфиг перед перезапуском
    if sshd -t 2>/dev/null; then
        # Ubuntu: ssh, Debian/others: sshd
        if systemctl list-units --type=service | grep -q "^  ssh\.service"; then
            systemctl restart ssh
        else
            systemctl restart sshd
        fi
        ok "SSH сервис перезапущен"
    else
        warn "Ошибка в sshd_config — перезапуск пропущен, проверь вручную:"
        sshd -t
    fi
    echo ""
fi

# ══════════════════════════════════════════════
# [5] UFW
# ══════════════════════════════════════════════
if $DO_UFW; then
    echo -e "${BOLD}  [5] UFW Файрвол${NC}"

    apt-get install -y -qq ufw 2>/dev/null

    # Сбрасываем и выставляем defaults
    ufw --force reset > /dev/null 2>&1
    ufw default deny incoming  > /dev/null
    ufw default allow outgoing > /dev/null

    # SSH
    ufw allow "$SSH_PORT/tcp" comment "SSH" > /dev/null
    ok "SSH:          $SSH_PORT/tcp"

    # AmneziaWG / WireGuard
    ufw allow 51820/udp comment "AmneziaWG" > /dev/null
    ok "AmneziaWG:    51820/udp"

    # Xray VLESS+Reality
    ufw allow 2053/tcp  comment "Xray-2053"  > /dev/null
    ufw allow 8443/tcp  comment "Xray-8443"  > /dev/null
    ok "Xray:         2053/tcp, 8443/tcp"

    # Доп. порты
    if [[ -n "${EXTRA_PORTS:-}" ]]; then
        for p in $EXTRA_PORTS; do
            ufw allow "$p" comment "custom" > /dev/null
            ok "Доп. порт:    $p"
        done
    fi

    ufw --force enable > /dev/null
    ok "UFW включён"
    echo ""
    ufw status numbered | sed 's/^/    /'
    echo ""
fi

# ══════════════════════════════════════════════
# [6] fail2ban
# ══════════════════════════════════════════════
if $DO_FAIL2BAN; then
    echo -e "${BOLD}  [6] fail2ban${NC}"

    apt-get install -y -qq fail2ban 2>/dev/null

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = $SSH_PORT
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 24h
EOF

    systemctl enable fail2ban > /dev/null 2>&1
    systemctl restart fail2ban
    ok "fail2ban запущен (SSH: 3 попытки → бан 24ч)"
    echo ""
fi

# ══════════════════════════════════════════════
# [7] Docker
# ══════════════════════════════════════════════
if $DO_DOCKER; then
    echo -e "${BOLD}  [7] Docker${NC}"

    if command -v docker &>/dev/null; then
        ok "Уже установлен: $(docker --version | cut -d' ' -f3 | tr -d ',')"
    else
        info "Устанавливаем Docker..."
        curl -fsSL https://get.docker.com | sh > /dev/null 2>&1
        systemctl enable docker > /dev/null 2>&1
        ok "Docker установлен"
    fi

    # Добавляем пользователя в группу docker
    if id "$NEW_USER" &>/dev/null; then
        usermod -aG docker "$NEW_USER"
        ok "$NEW_USER добавлен в группу docker"
    fi

    # Автозапуск
    systemctl enable docker > /dev/null 2>&1
    systemctl start docker
    ok "Docker запущен и в автозапуске"
    echo ""
fi

# ══════════════════════════════════════════════
# ИТОГ
# ══════════════════════════════════════════════
echo -e "${BOLD}${GREEN}  ╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}  ║            Готово!                     ║${NC}"
echo -e "${BOLD}${GREEN}  ╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Сервер:${NC}      $SERVER_IP"
echo -e "  ${BOLD}Пользователь:${NC} $NEW_USER"
echo -e "  ${BOLD}SSH порт:${NC}    $SSH_PORT"
echo ""
echo -e "  ${BOLD}${YELLOW}Подключение после настройки:${NC}"
sep
echo -e "  ssh $NEW_USER@$SERVER_IP -p $SSH_PORT"
sep
echo ""
if $DO_HARDEN; then
    echo -e "  ${BOLD}${RED}ВАЖНО:${NC} Root login отключён."
    echo -e "  Убедись что можешь зайти как $NEW_USER ДО закрытия этой сессии!"
    echo ""
fi
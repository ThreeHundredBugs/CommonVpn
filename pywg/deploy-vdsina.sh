#!/bin/bash
# deploy-vdsina.sh — деплой pywg + smart domain list на vdsina хаб
#
# Использование:
#   bash deploy-vdsina.sh                       — полный деплой (sync + restart)
#   bash deploy-vdsina.sh --no-restart          — только синхронизация, без перезапуска
#   bash deploy-vdsina.sh --sync-domains        — только синхронизировать smart-домены
#   bash deploy-vdsina.sh --pull-domains=HOST   — взять домены с другого хаба (HOST)
#   bash deploy-vdsina.sh --dry-run             — показать что будет, ничего не менять
#   bash deploy-vdsina.sh --status              — статус AWG/dnsmasq/pywg на хабе
#
# Переменные окружения:
#   SSH_KEY, REMOTE_HOST, REMOTE_USER, REMOTE_DIR
#   DOMAINS_SRC    — локальный файл с nftset-строками для dnsmasq (см. формат ниже)
#   PULL_FROM_HOST — хост-источник smart-доменов (если нет локального файла)
#
# Формат DOMAINS_SRC (dnsmasq nftset-строки):
#   nftset=/youtube.com/4#inet#smartvpn#smart_dst_ip
#   nftset=/googlevideo.com/4#inet#smartvpn#smart_dst_ip
#   ...

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
die()  { echo -e "${RED}  ✗${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}${CYAN}[$1]${NC} $2"; }

# ── Параметры ──
SSH_KEY="${SSH_KEY:-~/.ssh/id_ed25519}"
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_DIR="${REMOTE_DIR:-~/pywg}"

# Локальный файл с nftset-строками (если есть)
DOMAINS_SRC="${DOMAINS_SRC:-./smart-domains.conf}"

# Хаб-источник для pull доменов (если задан)
PULL_FROM_HOST="${PULL_FROM_HOST:-}"
PULL_FROM_USER="${PULL_FROM_USER:-pot}"

# Флаги
NO_RESTART=false
DRY_RUN=false
DOMAINS_ONLY=false
STATUS_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --no-restart|-n)     NO_RESTART=true ;;
        --dry-run|-d)        DRY_RUN=true ;;
        --sync-domains)      DOMAINS_ONLY=true ;;
        --status)            STATUS_ONLY=true ;;
        --pull-domains=*)    PULL_FROM_HOST="${arg#--pull-domains=}" ;;
        --host=*)            REMOTE_HOST="${arg#--host=}" ;;
        --key=*)             SSH_KEY="${arg#--key=}" ;;
        *) die "Неизвестный аргумент: $arg" ;;
    esac
done

SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes)
SSH_CMD=(ssh "${SSH_OPTS[@]}")
RSYNC_SSH="ssh ${SSH_OPTS[*]}"
REMOTE="${REMOTE_USER}@${REMOTE_HOST:-}"

# ── Заголовок ──
echo ""
echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}  ║      Vdsina Hub — Deploy                 ║${NC}"
echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════╝${NC}"
echo ""

[[ -z "${REMOTE_HOST:-}" ]] && read -rp "  IP vdsina хаба: " REMOTE_HOST
[[ -z "${REMOTE_HOST:-}" ]] && die "IP сервера не указан"
REMOTE="${REMOTE_USER}@${REMOTE_HOST}"

echo -e "  Хост:    ${YELLOW}${REMOTE}${NC}"
echo -e "  Ключ:    ${DIM}${SSH_KEY}${NC}"
echo -e "  Dir:     ${DIM}${REMOTE_DIR}${NC}"
${DRY_RUN}      && echo -e "  ${YELLOW}⚠ DRY RUN${NC}"
${DOMAINS_ONLY} && echo -e "  Mode:    ${BOLD}sync-domains only${NC}"
${STATUS_ONLY}  && echo -e "  Mode:    ${BOLD}status${NC}"
echo ""

# ── SSH проверка ──
step "0" "Проверка SSH"
"${SSH_CMD[@]}" "${REMOTE}" "echo ok" > /dev/null \
    || die "Нет SSH доступа к ${REMOTE}. Ключ: ${SSH_KEY}"
ok "SSH OK"

# ══════════════════════════════════════════════
# Режим: --status
# ══════════════════════════════════════════════
if ${STATUS_ONLY}; then
    step "—" "Статус vdsina хаба"
    "${SSH_CMD[@]}" "${REMOTE}" << 'STATUS'
export PATH=$PATH:/usr/local/bin:/usr/bin
echo ""
echo "  === AWG client ==="
awg show awg0 2>/dev/null | grep -E 'interface:|peer:|endpoint:|latest|transfer' | sed 's/^/    /' || echo "    awg0 не запущен"

echo ""
echo "  === wg-smart server ==="
wg show wg-smart 2>/dev/null | sed 's/^/    /' || echo "    wg-smart не запущен"

echo ""
echo "  === SmartVPN сервисы ==="
for svc in wg-quick@wg-smart dnsmasq smartvpn-nft.service smartvpn-route.service; do
    state=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    printf "    %-30s %s\n" "$svc" "$state"
done

echo ""
echo "  === SmartVPN nftset ==="
echo "    nftset smart_dst_ip entries: $(nft list set inet smartvpn smart_dst_ip 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | wc -l)"
DOMAINS_COUNT=$(grep -c '^nftset=' /etc/dnsmasq.d/wg-smart.conf 2>/dev/null || echo 0)
echo "    smart-domains в dnsmasq: $DOMAINS_COUNT"
echo ""
echo "  === SmartVPN DNS-проверка ==="
dig chatgpt.com @10.30.0.1 +short +time=3 2>/dev/null | head -3 | sed 's/^/    /' || echo "    dig не ответил"

echo ""
echo "  === pywg контейнеры ==="
if command -v docker &>/dev/null; then
    docker ps --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | grep -E 'wg-bot|xray' || echo "    нет контейнеров"
fi

echo ""
echo "  === servers.conf ==="
cat /etc/amnezia/amneziawg/servers.conf 2>/dev/null | grep -v '^#' | grep -v '^$' || echo "    файл не найден"
echo ""
STATUS
    exit 0
fi

# ══════════════════════════════════════════════
# Smart-domains: подготовка
# ══════════════════════════════════════════════

# Если есть seeds.txt и нет готового smart-domains.conf — генерируем
if [[ -f "./seeds.txt" ]] && { [[ ! -f "${DOMAINS_SRC:-}" ]] || [[ "${DOMAINS_SRC}" == "./smart-domains.conf" ]]; }; then
    if [[ -f "./build-smart-domains.sh" ]]; then
        step "domains" "Генерация smart-domains.conf из seeds.txt"
        bash ./build-smart-domains.sh ./seeds.txt ./smart-domains.conf
        DOMAINS_SRC="./smart-domains.conf"
    fi
fi

# Получаем домены с другого хаба если задан --pull-domains=HOST
DOMAINS_TMPFILE=""
if [[ -n "$PULL_FROM_HOST" ]]; then
    step "domains" "Получение smart-доменов с ${PULL_FROM_HOST}"
    DOMAINS_TMPFILE=$(mktemp /tmp/smart-domains-XXXXXX.conf)
    SRC_SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes)
    SRC_REMOTE="${PULL_FROM_USER}@${PULL_FROM_HOST}"

    if ssh "${SRC_SSH_OPTS[@]}" "${SRC_REMOTE}" "test -f /etc/dnsmasq.d/wg-smart.conf" 2>/dev/null; then
        rsync -az -e "ssh ${SRC_SSH_OPTS[*]}" \
            "${SRC_REMOTE}:/etc/dnsmasq.d/wg-smart.conf" "$DOMAINS_TMPFILE" \
            || die "Не удалось получить домены с ${SRC_REMOTE}"
        COUNT=$(grep -c '^nftset=' "$DOMAINS_TMPFILE" 2>/dev/null || echo 0)
        ok "Получено ${COUNT} nftset-строк с ${PULL_FROM_HOST}"
        DOMAINS_SRC="$DOMAINS_TMPFILE"
    else
        warn "wg-smart.conf не найден на ${SRC_REMOTE} — пропускаем sync доменов"
        rm -f "$DOMAINS_TMPFILE"
        DOMAINS_TMPFILE=""
    fi
elif [[ -f "$DOMAINS_SRC" ]]; then
    COUNT=$(grep -c '^nftset=' "$DOMAINS_SRC" 2>/dev/null || echo 0)
    ok "Локальный файл доменов: ${DOMAINS_SRC} (${COUNT} строк)"
else
    warn "Файл ${DOMAINS_SRC} не найден — smart-домены синхронизироваться не будут"
    warn "Создай файл или используй --pull-domains=ДРУГОЙ_ХАБ"
    [[ $DOMAINS_ONLY == true ]] && exit 0
fi

# ══════════════════════════════════════════════
# Режим: --sync-domains (только домены)
# ══════════════════════════════════════════════
if ${DOMAINS_ONLY}; then
    step "—" "Синхронизация smart-доменов"
    if [[ -f "$DOMAINS_SRC" ]]; then
        if ${DRY_RUN}; then
            echo -e "  ${DIM}[dry-run] push ${DOMAINS_SRC} → ${REMOTE}:/etc/dnsmasq.d/wg-smart.conf${NC}"
        else
            rsync -az -e "${RSYNC_SSH}" "$DOMAINS_SRC" "${REMOTE}:/etc/dnsmasq.d/wg-smart.conf"
            ok "smart-domains синхронизированы"
            "${SSH_CMD[@]}" "${REMOTE}" '
                dnsmasq --test 2>&1 || { echo "  ✗ dnsmasq --test: синтаксис битый, отменяем рестарт" >&2; exit 1; }
                systemctl restart wg-quick@wg-smart
                systemctl restart smartvpn-nft.service
                systemctl restart dnsmasq
                systemctl restart smartvpn-route.service
                echo "  ✓ SmartVPN стек перезапущен"
                echo "  → Прогрев DNS..."
                awk -F/ "/^nftset=\\/\// {print \$2}" /etc/dnsmasq.d/wg-smart.conf \
                    | sort -u \
                    | xargs -r -n1 -I{} dig @10.30.0.1 {} A +short +time=2 >/dev/null 2>&1 || true
                echo "  nftset: $(nft list set inet smartvpn smart_dst_ip 2>/dev/null | grep -oP "\d+\.\d+\.\d+\.\d+" | wc -l) IP"
            '
        fi
    fi
    [[ -n "$DOMAINS_TMPFILE" ]] && rm -f "$DOMAINS_TMPFILE"
    exit 0
fi

# ══════════════════════════════════════════════
# Полный деплой
# ══════════════════════════════════════════════

# Runtime-конфиги pywg (живут на сервере, не перезаписываем)
RUNTIME_CONFIGS=(
    "allowed_users.txt"
    "unlimited_users.txt"
    "subscribers.txt"
    ".env"
    "xray/config.json"
)

step "1/4" "Pull runtime-конфигов с хаба (защита данных)"
PULL_ERRORS=0
for file in "${RUNTIME_CONFIGS[@]}"; do
    remote_path="${REMOTE_DIR}/${file}"
    local_dir=$(dirname "./${file}")
    mkdir -p "$local_dir"

    if "${SSH_CMD[@]}" "${REMOTE}" "test -f ${remote_path}" 2>/dev/null; then
        if ${DRY_RUN}; then
            echo -e "  ${DIM}[dry-run] pull ← ${REMOTE}:${remote_path}${NC}"
        else
            if rsync -az -e "${RSYNC_SSH}" "${REMOTE}:${remote_path}" "./${file}" 2>/dev/null; then
                ok "pulled: ${file}"
            else
                warn "pull с ошибкой: ${file}"
                PULL_ERRORS=$((PULL_ERRORS + 1))
            fi
        fi
    else
        warn "нет на хабе (пропуск): ${file}"
    fi
done

if [[ $PULL_ERRORS -gt 0 ]]; then
    echo ""
    echo -e "  ${RED}Не удалось получить ${PULL_ERRORS} файл(ов).${NC}"
    read -rp "  Продолжить? Данные могут быть перезаписаны. [y/N]: " CONTINUE
    [[ "${CONTINUE,,}" == "y" ]] || { echo "Отменено."; exit 0; }
fi

step "2/4" "Push pywg на хаб"

RSYNC_PUSH_OPTS=(
    -az
    --progress
    -e "${RSYNC_SSH}"
    --exclude=".git/"
    --exclude="__pycache__/"
    --exclude="*.pyc"
    --exclude="*.pyo"
    --exclude="*.bak"
    --exclude="*.bak.*"
    --exclude=".env.example"
    --exclude="smart-domains.conf"  # деплоим отдельно ниже
    --exclude="id_*"
    --exclude="deploy.sh"
    --exclude="deploy-ru.sh"
    --exclude="deploy-vdsina.sh"
    --exclude="ru-hub-init.sh"
    --exclude="awgswitch.sh"
    --exclude="awgsetup.sh"
    --exclude="awggetstring.sh"
    --exclude="xray-multi-instance.sh"
    --exclude="initserv.sh"
)

if ${DRY_RUN}; then
    rsync "${RSYNC_PUSH_OPTS[@]}" --dry-run ./ "${REMOTE}:${REMOTE_DIR}/"
    ok "[dry-run] rsync завершён"
else
    rsync "${RSYNC_PUSH_OPTS[@]}" ./ "${REMOTE}:${REMOTE_DIR}/"
    ok "pywg синхронизирован"
fi

step "3/4" "Синхронизация smart-доменов"
if [[ -f "${DOMAINS_SRC:-}" ]]; then
    if ${DRY_RUN}; then
        echo -e "  ${DIM}[dry-run] push ${DOMAINS_SRC} → /etc/dnsmasq.d/wg-smart.conf${NC}"
    else
        rsync -az -e "${RSYNC_SSH}" "$DOMAINS_SRC" "${REMOTE}:/etc/dnsmasq.d/wg-smart.conf"
        COUNT=$(grep -c '^nftset=' "$DOMAINS_SRC" 2>/dev/null || echo 0)
        ok "smart-domains: ${COUNT} доменов → /etc/dnsmasq.d/wg-smart.conf"
        "${SSH_CMD[@]}" "${REMOTE}" '
            dnsmasq --test 2>&1 || { echo "  ✗ dnsmasq --test: синтаксис битый, отменяем рестарт" >&2; exit 1; }
            systemctl restart wg-quick@wg-smart
            systemctl restart smartvpn-nft.service
            systemctl restart dnsmasq
            systemctl restart smartvpn-route.service
            echo "  ✓ SmartVPN стек перезапущен"
        '
    fi
else
    warn "smart-domains не синхронизированы (файл не найден)"
fi

[[ -n "${DOMAINS_TMPFILE:-}" ]] && rm -f "$DOMAINS_TMPFILE"

# ── --no-restart останавливаем здесь ──
if ${NO_RESTART}; then
    echo ""
    ok "${BOLD}Sync-only завершён — контейнеры не перезапускались${NC}"
    echo ""
    echo -e "  Для ручного перезапуска pywg:"
    echo -e "  ${DIM}ssh ${REMOTE} 'cd ${REMOTE_DIR} && docker compose restart wg-bot'${NC}"
    echo ""
    exit 0
fi

if ${DRY_RUN}; then
    echo ""
    ok "[dry-run] готово"
    exit 0
fi

step "4/4" "Перезапуск pywg стека на хабе"
"${SSH_CMD[@]}" "${REMOTE}" "REMOTE_DIR='${REMOTE_DIR}' bash -s" << 'REMOTE_SCRIPT'
set -euo pipefail
export PATH=$PATH:/usr/local/bin:/usr/bin:/usr/local/sbin

TARGET_DIR="${REMOTE_DIR/#\~/$HOME}"
cd "$TARGET_DIR"

if docker compose version &>/dev/null 2>&1; then
    DC=(docker compose)
elif command -v docker-compose &>/dev/null; then
    DC=(docker-compose)
else
    echo "  ✗ docker compose не найден!" >&2; exit 1
fi
echo "  → Используем: ${DC[*]}"

echo "  → Остановка..."
"${DC[@]}" down --remove-orphans

echo "  → Обновление xray образа..."
"${DC[@]}" pull xray 2>/dev/null || echo "  ⚠ pull xray пропущен"

echo "  → Сборка wg-bot..."
"${DC[@]}" build --pull wg-bot

echo "  → Запуск стека..."
"${DC[@]}" up -d --force-recreate --remove-orphans

echo "  → Ожидание (8с)..."
sleep 8

echo ""
echo "  Контейнеры:"
"${DC[@]}" ps

echo ""
echo "  AWG клиент:"
awg show awg0 2>/dev/null | grep -E 'interface:|peer:|endpoint:' | sed 's/^/    /' || echo "    awg0 не запущен"

echo ""
echo "  dnsmasq:"
systemctl is-active dnsmasq 2>/dev/null | sed 's/^/    /' || echo "    не запущен"
REMOTE_SCRIPT

step "verify" "Проверка SmartVPN после деплоя"
"${SSH_CMD[@]}" "${REMOTE}" '
    echo "  → Прогрев DNS..."
    awk -F/ "/^nftset=\\/\// {print \$2}" /etc/dnsmasq.d/wg-smart.conf \
        | sort -u \
        | xargs -r -n1 -I{} dig @10.30.0.1 {} A +short +time=2 >/dev/null 2>&1 || true

    echo ""
    echo "  Сервисы SmartVPN:"
    for svc in wg-quick@wg-smart dnsmasq smartvpn-nft.service smartvpn-route.service; do
        state=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
        icon="✓"; [[ "$state" != "active" ]] && icon="✗"
        printf "    %s %-30s %s\n" "$icon" "$svc" "$state"
    done

    echo ""
    echo "  DNS-тест (chatgpt.com @10.30.0.1):"
    dig chatgpt.com @10.30.0.1 +short +time=3 2>/dev/null | head -3 | sed "s/^/    /" || echo "    ✗ нет ответа"

    echo ""
    echo "  nftset smart_dst_ip: $(nft list set inet smartvpn smart_dst_ip 2>/dev/null | grep -oP "\d+\.\d+\.\d+\.\d+" | wc -l) IP"

    echo ""
    echo "  Маршрут (104.18.32.47 через wg-smart):"
    ip route get 104.18.32.47 from 10.30.0.3 iif wg-smart mark 0x64 2>/dev/null | sed "s/^/    /" || echo "    ✗ маршрут не найден"
'

echo ""
ok "${BOLD}Деплой vdsina хаба завершён!${NC}"
echo ""

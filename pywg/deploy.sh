#!/bin/bash
# deploy.sh — деплой pywg на удалённый сервер
#
# Использование:
#   bash deploy.sh                  — полный деплой (pull configs → push → restart)
#   bash deploy.sh --no-restart     — только синхронизация файлов, контейнеры не трогать
#   bash deploy.sh --dry-run        — показать что будет сделано, ничего не менять
#
# Переменные окружения (override):
#   SSH_KEY, REMOTE_USER, REMOTE_HOST, REMOTE_DIR

set -euo pipefail

# ── Цвета ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
die()  { echo -e "${RED}  ✗${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}${CYAN}[$1]${NC} $2"; }

# ── Параметры подключения ──
SSH_KEY="${SSH_KEY:-~/.ssh/id_ed25519}"
REMOTE_USER="${REMOTE_USER:-pot}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_DIR="${REMOTE_DIR:-~/pywg}"

# ── Флаги ──
NO_RESTART=false
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --no-restart|-n) NO_RESTART=true ;;
        --dry-run|-d)    DRY_RUN=true ;;
        -*)              die "Неизвестный аргумент: $arg. Доступны: --no-restart, --dry-run" ;;
    esac
done

# ── SSH — используем массив для корректной обработки путей с пробелами ──
SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes)
SSH_CMD=(ssh "${SSH_OPTS[@]}")
RSYNC_SSH="ssh ${SSH_OPTS[*]}"   # строка для rsync -e
REMOTE="${REMOTE_USER}@${REMOTE_HOST}"

# ── Runtime-конфиги: живут на сервере, обновляются ботом ──
# Вытягиваются ДО push, чтобы не затереть данные пользователей
RUNTIME_CONFIGS=(
    "allowed_users.txt"
    "unlimited_users.txt"
    "subscribers.txt"
    ".env"
    "xray/config.json"
)

# ── Заголовок ──
echo ""
echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}  ║            pywg — deploy                 ║${NC}"
echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════╝${NC}"
echo -e "  Host: ${YELLOW}${REMOTE}${NC}  Dir: ${DIM}${REMOTE_DIR}${NC}"
echo -e "  Mode: ${BOLD}$( ${NO_RESTART} && echo 'sync-only (no restart)' || echo 'full deploy' )${NC}"
${DRY_RUN} && echo -e "  ${YELLOW}⚠ DRY RUN — изменения не применяются${NC}"
echo ""

# ══════════════════════════════════════════════
# [0/4] Проверка SSH
# ══════════════════════════════════════════════
[ -z "$REMOTE_HOST" ] && die "Укажи хост: REMOTE_HOST=1.2.3.4 bash deploy.sh"

step "0/4" "Проверка SSH соединения с ${REMOTE}"
"${SSH_CMD[@]}" "${REMOTE}" "echo ok" > /dev/null \
    || die "Нет SSH доступа к ${REMOTE}. Проверь SSH_KEY='${SSH_KEY}' и хост."
ok "SSH соединение установлено"

# ══════════════════════════════════════════════
# [1/4] Pull runtime-конфигов с сервера
# ══════════════════════════════════════════════
step "1/4" "Получение runtime-конфигов с сервера (защита данных пользователей)"

PULL_ERRORS=0
for file in "${RUNTIME_CONFIGS[@]}"; do
    remote_path="${REMOTE_DIR}/${file}"
    local_dir=$(dirname "./${file}")

    # Создаём локальную директорию (нужно для xray/config.json)
    mkdir -p "$local_dir"

    if "${SSH_CMD[@]}" "${REMOTE}" "test -f ${remote_path}" 2>/dev/null; then
        if ${DRY_RUN}; then
            echo -e "  ${DIM}[dry-run] pull ← ${REMOTE}:${remote_path}${NC}"
        else
            if rsync -az -e "${RSYNC_SSH}" "${REMOTE}:${remote_path}" "./${file}" 2>/dev/null; then
                ok "pulled: ${file}"
            else
                warn "pull завершился с ошибкой: ${file}"
                PULL_ERRORS=$((PULL_ERRORS + 1))
            fi
        fi
    else
        warn "нет на сервере (пропуск): ${file}"
    fi
done

if [[ $PULL_ERRORS -gt 0 ]]; then
    echo ""
    echo -e "  ${RED}Не удалось получить ${PULL_ERRORS} файл(ов) с сервера.${NC}"
    read -rp "  Продолжить деплой? Данные могут быть перезаписаны. [y/N]: " CONTINUE
    [[ "${CONTINUE,,}" == "y" ]] || { echo "Отменено."; exit 0; }
fi

# ══════════════════════════════════════════════
# [2/4] Push проекта на сервер
# ══════════════════════════════════════════════
step "2/4" "Синхронизация файлов на сервер"

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
    --exclude=".env.example"     # шаблон не нужен на сервере
    --exclude="id_*"             # не синхронизировать приватные ключи
    --exclude="deploy.sh"        # сам себя не деплоим (на сервере не нужен)
)

if ${DRY_RUN}; then
    rsync "${RSYNC_PUSH_OPTS[@]}" --dry-run ./ "${REMOTE}:${REMOTE_DIR}/"
    ok "[dry-run] rsync завершён"
else
    rsync "${RSYNC_PUSH_OPTS[@]}" ./ "${REMOTE}:${REMOTE_DIR}/"
    ok "Файлы синхронизированы"
fi

# ══════════════════════════════════════════════
# [3/4] Проверка содержимого на сервере
# ══════════════════════════════════════════════
step "3/4" "Содержимое удалённой директории"
"${SSH_CMD[@]}" "${REMOTE}" "ls -lah ${REMOTE_DIR} && ls -lah ${REMOTE_DIR}/xray 2>/dev/null || true"

# ── Если --no-restart, заканчиваем здесь ──
if ${NO_RESTART}; then
    echo ""
    ok "${BOLD}Sync-only: контейнеры не перезапускались${NC}"
    echo ""
    echo -e "  Чтобы применить изменения кода вручную:"
    echo -e "  ${DIM}ssh ${REMOTE} 'cd ${REMOTE_DIR} && docker compose restart wg-bot'${NC}"
    echo ""
    exit 0
fi

# ── Если --dry-run, заканчиваем здесь ──
if ${DRY_RUN}; then
    echo ""
    ok "[dry-run] готово — перезапуск не выполнялся"
    exit 0
fi

# ══════════════════════════════════════════════
# [4/4] Перезапуск docker compose стека
# ══════════════════════════════════════════════
step "4/4" "Перезапуск docker compose стека"

"${SSH_CMD[@]}" "${REMOTE}" "REMOTE_DIR='${REMOTE_DIR}' bash -s" << 'REMOTE_SCRIPT'
set -euo pipefail
export PATH=$PATH:/usr/local/bin:/usr/bin:/usr/local/sbin

TARGET_DIR="${REMOTE_DIR/#\~/$HOME}"
cd "$TARGET_DIR"

# Определяем docker compose: v2 (plugin) или v1 (standalone)
if docker compose version &>/dev/null 2>&1; then
    DC=(docker compose)
elif command -v docker-compose &>/dev/null; then
    DC=(docker-compose)
else
    echo "  ✗ docker compose не найден!" >&2; exit 1
fi
echo "  → Используем: ${DC[*]}"

echo ""
echo "  → Остановка старых контейнеров..."
"${DC[@]}" down --remove-orphans

echo "  → Обновление базового образа xray..."
"${DC[@]}" pull xray 2>/dev/null || echo "  ⚠ pull xray пропущен"

echo "  → Сборка образа wg-bot (с --pull, используем кэш слоёв)..."
"${DC[@]}" build --pull wg-bot

echo "  → Запуск стека..."
"${DC[@]}" up -d --force-recreate --remove-orphans

echo "  → Ожидание запуска (8с)..."
sleep 8

echo ""
echo "  → Статус контейнеров:"
"${DC[@]}" ps

echo ""
echo "  → Логи xray (последние 30 строк):"
"${DC[@]}" logs --tail=30 xray 2>/dev/null || true

echo ""
echo "  → Логи wg-bot (последние 30 строк):"
"${DC[@]}" logs --tail=30 wg-bot 2>/dev/null || true
REMOTE_SCRIPT

echo ""
ok "${BOLD}Деплой завершён успешно!${NC}"
echo ""

#!/bin/bash
# awg-gen-seeds.sh — генерация AWG obfuscation seeds
#
# AmneziaWG seeds должны СОВПАДАТЬ между клиентом и сервером.
# Сгенерированные значения нужно прописать в awg0.conf на обеих сторонах.
#
# Использование:
#   bash awg-gen-seeds.sh                 — интерактивный режим
#   bash awg-gen-seeds.sh --random        — полностью случайные seeds
#   bash awg-gen-seeds.sh --standard      — стандартные seeds (текущие exit-серверы)
#   bash awg-gen-seeds.sh --show-current  — показать seeds из текущего awg0.conf

set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
info() { echo -e "${CYAN}  ▸${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
sep()  { echo -e "${DIM}  ─────────────────────────────────────${NC}"; }

AWG_CONF="/etc/amnezia/amneziawg/awg0.conf"

MODE="interactive"
[[ "${1:-}" == "--random"       ]] && MODE="random"
[[ "${1:-}" == "--standard"     ]] && MODE="standard"
[[ "${1:-}" == "--show-current" ]] && MODE="show"

echo ""
echo -e "${BOLD}${CYAN}  ╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}  ║       AWG Seed Generator               ║${NC}"
echo -e "${BOLD}${CYAN}  ╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${DIM}Seeds управляют обфускацией AWG трафика.${NC}"
echo -e "  ${DIM}Клиент и сервер должны использовать одинаковые seeds.${NC}"
echo ""

# ── Показать текущие seeds ──
if [[ "$MODE" == "show" ]]; then
    if [[ -f "$AWG_CONF" ]]; then
        info "Seeds из $AWG_CONF:"
        sep
        grep -E '^\s*(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4)\s*=' "$AWG_CONF" | sed 's/^/  /' || echo "  seeds не найдены"
        sep
    else
        warn "$AWG_CONF не найден"
    fi
    echo ""
    exit 0
fi

# ── Стандартные seeds (совместимы с текущими exit-серверами) ──
if [[ "$MODE" == "standard" ]]; then
    JC=4; JMIN=40; JMAX=70; S1=50; S2=100
    H1=1407775011; H2=2140498648; H3=254021790; H4=3964887677
    info "Стандартные seeds (текущие exit-серверы):"
    MODE="print"
fi

# ── Случайные seeds ──
if [[ "$MODE" == "random" ]]; then
    info "Генерируем случайные seeds..."

    # Jc: 1–128 (число junk-пакетов)
    JC=$(( (RANDOM % 15) + 1 ))

    # Jmin, Jmax: 10–1280 байт, Jmin < Jmax
    JMIN=$(( (RANDOM % 60) + 10 ))
    JMAX=$(( JMIN + (RANDOM % 200) + 20 ))
    [[ $JMAX -gt 1280 ]] && JMAX=1280

    # S1, S2: 15–150 байт (дополнительный мусор)
    S1=$(( (RANDOM % 80) + 15 ))
    S2=$(( (RANDOM % 80) + 15 ))

    # H1–H4: случайные uint32 (используем /dev/urandom)
    H1=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
    H2=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
    H3=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
    H4=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')

    MODE="print"
fi

# ── Интерактивный режим ──
if [[ "$MODE" == "interactive" ]]; then
    echo -e "  ${BOLD}Выбери режим:${NC}"
    echo -e "    ${DIM}[1]${NC} Стандартные seeds  (совместимы с текущими exit-серверами)"
    echo -e "    ${DIM}[2]${NC} Случайные seeds     (для новой пары клиент+сервер)"
    echo -e "    ${DIM}[3]${NC} Показать текущие    (из $AWG_CONF)"
    echo ""
    read -rp "  Выбор [1]: " CHOICE
    CHOICE="${CHOICE:-1}"
    echo ""

    case "$CHOICE" in
        1)
            JC=4; JMIN=40; JMAX=70; S1=50; S2=100
            H1=1407775011; H2=2140498648; H3=254021790; H4=3964887677
            info "Стандартные seeds"
            MODE="print"
            ;;
        2)
            JC=$(( (RANDOM % 15) + 1 ))
            JMIN=$(( (RANDOM % 60) + 10 ))
            JMAX=$(( JMIN + (RANDOM % 200) + 20 ))
            [[ $JMAX -gt 1280 ]] && JMAX=1280
            S1=$(( (RANDOM % 80) + 15 ))
            S2=$(( (RANDOM % 80) + 15 ))
            H1=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
            H2=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
            H3=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
            H4=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
            info "Случайные seeds сгенерированы"
            MODE="print"
            ;;
        3)
            bash "$0" --show-current
            exit 0
            ;;
        *) echo "Неверный выбор"; exit 1 ;;
    esac
fi

# ── Вывод ──
echo ""
echo -e "${BOLD}${GREEN}  ╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}  ║           AWG Seeds                    ║${NC}"
echo -e "${BOLD}${GREEN}  ╚════════════════════════════════════════╝${NC}"
echo ""
sep
echo -e "  ${BOLD}Jc    = $JC${NC}          ${DIM}(junk packets per handshake: 1–128)${NC}"
echo -e "  ${BOLD}Jmin  = $JMIN${NC}         ${DIM}(min junk size, bytes)${NC}"
echo -e "  ${BOLD}Jmax  = $JMAX${NC}         ${DIM}(max junk size, bytes)${NC}"
echo -e "  ${BOLD}S1    = $S1${NC}         ${DIM}(extra header noise, bytes)${NC}"
echo -e "  ${BOLD}S2    = $S2${NC}        ${DIM}(extra header noise, bytes)${NC}"
echo -e "  ${BOLD}H1    = $H1${NC}"
echo -e "  ${BOLD}H2    = $H2${NC}"
echo -e "  ${BOLD}H3    = $H3${NC}"
echo -e "  ${BOLD}H4    = $H4${NC}"
sep
echo ""

echo -e "  ${BOLD}Блок для awg0.conf${NC} (скопируй на КЛИЕНТ и СЕРВЕР):"
sep
cat << CONF
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4
CONF
sep
echo ""

echo -e "  ${YELLOW}⚠ Помни: seeds ДОЛЖНЫ совпадать на клиенте и сервере.${NC}"
echo -e "  ${DIM}Клиент  → /etc/amnezia/amneziawg/awg0.conf (на хабе)${NC}"
echo -e "  ${DIM}Сервер  → /etc/amnezia/amneziawg/awg0.conf (на exit-сервере)${NC}"
echo ""

# ── Предложить записать в текущий awg0.conf ──
if [[ -f "$AWG_CONF" ]]; then
    echo -e "  ${DIM}Найден: $AWG_CONF${NC}"
    read -rp "  Обновить seeds в $AWG_CONF? [y/N]: " UPDATE
    if [[ "${UPDATE,,}" == "y" ]]; then
        cp "$AWG_CONF" "${AWG_CONF}.bak.$(date +%Y%m%d-%H%M%S)"

        # Заменяем каждый seed или добавляем если нет
        _set_seed() {
            local key=$1 val=$2
            if grep -qE "^${key}\s*=" "$AWG_CONF"; then
                sed -i "s|^${key}\s*=.*|${key} = ${val}|" "$AWG_CONF"
            else
                # Ищем место после [Interface] чтобы вставить
                sed -i "/^\[Interface\]/a ${key} = ${val}" "$AWG_CONF"
            fi
        }

        _set_seed "Jc"   "$JC"
        _set_seed "Jmin" "$JMIN"
        _set_seed "Jmax" "$JMAX"
        _set_seed "S1"   "$S1"
        _set_seed "S2"   "$S2"
        _set_seed "H1"   "$H1"
        _set_seed "H2"   "$H2"
        _set_seed "H3"   "$H3"
        _set_seed "H4"   "$H4"

        ok "Seeds обновлены в $AWG_CONF"
        warn "Перезапусти AWG: awg-quick down awg0 && awg-quick up awg0"
    fi
else
    echo -e "  ${DIM}(awg0.conf не найден — применение вручную)${NC}"
fi

echo ""

#!/usr/bin/env bash
# Генератор /etc/dnsmasq.d/wg-smart.conf из seeds.txt
# Использование: bash build-smart-domains.sh [seed.txt] [smart-domains.conf]
set -euo pipefail

SEED="${1:-seeds.txt}"
OUT="${2:-smart-domains.conf}"

[[ -f "$SEED" ]] || { echo "✗ seed-файл не найден: $SEED" >&2; exit 1; }

{
    echo "# Generated: $(date '+%F %T') from $(basename "$SEED")"
    echo "interface=wg-smart"
    echo "bind-interfaces"
    echo "listen-address=10.30.0.1"
    echo "port=53"
    echo ""
    echo "server=1.1.1.1"
    echo "server=8.8.8.8"
    echo "no-resolv"
    echo "cache-size=10000"
    echo ""

    grep -vE '^\s*#|^\s*$' "$SEED" \
        | sed 's/\r$//' \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's#^https\?://##; s#/.*##; s#^\*\.##; s#^\.##; s#\.$##' \
        | grep -E '^[a-z0-9][a-z0-9._-]*\.[a-z]{2,}$' \
        | sort -u \
        | while read -r d; do
            echo "nftset=/${d}/4#inet#smartvpn#smart_dst_ip"
          done
} > "$OUT"

COUNT=$(grep -c '^nftset=' "$OUT" 2>/dev/null || echo 0)
echo "✓ ${OUT}: ${COUNT} доменов"

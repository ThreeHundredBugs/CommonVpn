#!/usr/bin/env python3
"""
awg_monitor.py — автомониторинг и переключение AmneziaWG серверов

Использование:
  python3 awg_monitor.py               — проверка и переключение при необходимости
  python3 awg_monitor.py --status      — только отчёт, без переключения
  python3 awg_monitor.py --force       — переключить на лучший сервер немедленно
  python3 awg_monitor.py --notify-test — проверить TG уведомления

Cron (каждые 5 мин):
  */5 * * * * python3 /home/pot/pywg/awg_monitor.py >> /var/log/awg-monitor.log 2>&1
"""

from __future__ import annotations

import argparse
import asyncio
import fcntl
import json
import logging
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

import httpx
from dotenv import load_dotenv

# ══════════════════════════════════════════════════════════════════
#  Пути
# ══════════════════════════════════════════════════════════════════

AWG_CONF     = Path("/etc/amnezia/amneziawg/awg0.conf")
SERVERS_FILE = Path("/etc/amnezia/amneziawg/servers.conf")
BACKUP_DIR   = Path("/etc/amnezia/amneziawg/backups")
LAST_FILE    = Path("/etc/amnezia/amneziawg/last-switch.txt")
STATE_FILE   = Path("/etc/amnezia/amneziawg/monitor-state.json")
LOCK_FILE    = Path("/tmp/awg-monitor.lock")

# Поиск .env
_env = next(
    (p for p in [Path("/home/pot/pywg/.env"), *Path("/home").glob("*/pywg/.env")] if p.exists()),
    None,
)
if _env:
    load_dotenv(_env)

# Поиск Xray config
_xray_candidates = [Path("/home/pot/pywg/xray/config.json"), Path("/opt/xray/config.json"),
                    *Path("/home").glob("*/pywg/xray/config.json")]
XRAY_CONFIG      = next((p for p in _xray_candidates if p.exists()), None)
XRAY_COMPOSE_DIR = XRAY_CONFIG.parent.parent if XRAY_CONFIG else None

# ══════════════════════════════════════════════════════════════════
#  Параметры мониторинга
# ══════════════════════════════════════════════════════════════════

PING_COUNT         = 4    # пингов для замера latency
PING_TIMEOUT       = 3    # с — таймаут одного пинга
LATENCY_THRESHOLD  = 250  # мс — выше считается "плохим" каналом
SWITCH_IMPROVEMENT = 80   # мс — минимальный выигрыш для переключения на быстрый
FAIL_THRESHOLD     = 3    # подряд неудач → переключение
HANDSHAKE_MAX_AGE  = 180  # с — handshake старше этого + сервер недоступен → переключение

# ══════════════════════════════════════════════════════════════════
#  Логирование
# ══════════════════════════════════════════════════════════════════

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("awg-monitor")

# ══════════════════════════════════════════════════════════════════
#  Модель данных
# ══════════════════════════════════════════════════════════════════

@dataclass
class Server:
    alias:       str
    awg_ep:      str   # IP:PORT
    awg_key:     str
    xray_ip:     str = ""
    xray_port:   str = ""
    xray_uuid:   str = ""
    xray_pubkey: str = ""
    xray_shortid: str = ""
    # результаты проверки (заполняются при запуске)
    available:  bool = False
    latency_ms: int  = 9999
    fail_count: int  = 0

    @property
    def ip(self) -> str:
        return self.awg_ep.split(":")[0]

    @classmethod
    def from_line(cls, line: str) -> Server:
        parts = (line.strip().split("|") + [""] * 8)[:8]
        return cls(
            alias=parts[0], awg_ep=parts[1], awg_key=parts[2],
            xray_ip=parts[3], xray_port=parts[4], xray_uuid=parts[5],
            xray_pubkey=parts[6], xray_shortid=parts[7],
        )


def load_servers() -> list[Server]:
    lines = [l for l in SERVERS_FILE.read_text().splitlines()
             if l.strip() and not l.startswith("#")]
    return [Server.from_line(l) for l in lines]


def load_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {}


def save_state(current: str, servers: list[Server]) -> None:
    STATE_FILE.write_text(json.dumps({
        "current":     current,
        "fail_counts": {s.alias: s.fail_count for s in servers},
        "last_check":  datetime.now().isoformat(),
    }, indent=2, ensure_ascii=False))

# ══════════════════════════════════════════════════════════════════
#  Telegram
# ══════════════════════════════════════════════════════════════════

TG_TOKEN   = os.getenv("BOT_TOKEN", "")
TG_CHAT_ID = os.getenv("TG_ADMIN_CHAT_ID", "")
# Прокси для Telegram API: socks5://host:port или http://host:port
# Приоритет: TG_PROXY из .env → HTTPS_PROXY → HTTP_PROXY
TG_PROXY = (
    os.getenv("TG_PROXY")
    or os.getenv("HTTPS_PROXY")
    or os.getenv("HTTP_PROXY")
    or None
)


def tg_send(text: str) -> None:
    if not TG_TOKEN or not TG_CHAT_ID:
        log.warning("TG не настроен — добавьте TG_ADMIN_CHAT_ID в .env")
        return
    try:
        with httpx.Client(proxy=TG_PROXY, timeout=10) as client:
            r = client.post(
                f"https://api.telegram.org/bot{TG_TOKEN}/sendMessage",
                json={"chat_id": TG_CHAT_ID, "text": text, "parse_mode": "HTML"},
            )
        if not r.is_success:
            log.warning("TG: %s", r.text[:200])
    except Exception as exc:
        log.warning("TG: %s", exc)

# ══════════════════════════════════════════════════════════════════
#  Проверка серверов (asyncio — параллельно)
# ══════════════════════════════════════════════════════════════════

async def _ping(host: str) -> tuple[bool, int]:
    """Возвращает (available, avg_latency_ms)."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "ping", "-c", str(PING_COUNT), "-W", str(PING_TIMEOUT), "-q", host,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(
            proc.communicate(), timeout=PING_COUNT * PING_TIMEOUT + 3
        )
        if proc.returncode != 0:
            return False, 9999
        m = re.search(r"rtt[^=]+=\s*[\d.]+/([\d.]+)/", stdout.decode())
        return True, int(float(m.group(1))) if m else (True, 9999)
    except Exception:
        return False, 9999


async def probe_all(servers: list[Server]) -> None:
    """Пингует все серверы параллельно и записывает результаты в server.available / latency_ms."""
    results = await asyncio.gather(*[_ping(s.ip) for s in servers])
    for srv, (avail, lat) in zip(servers, results):
        srv.available  = avail
        srv.latency_ms = lat

# ══════════════════════════════════════════════════════════════════
#  AWG helpers
# ══════════════════════════════════════════════════════════════════

def handshake_age() -> int:
    """Секунд с последнего handshake; 9999 если нет."""
    try:
        out = subprocess.check_output(
            ["awg", "show", "awg0", "latest-handshakes"],
            stderr=subprocess.DEVNULL,
        ).decode().split()
        ts = int(out[1]) if len(out) >= 2 else 0
        return (int(datetime.now().timestamp()) - ts) if ts else 9999
    except Exception:
        return 9999


def current_endpoint() -> str:
    try:
        for line in AWG_CONF.read_text().splitlines():
            if line.startswith("Endpoint ="):
                return line.split("=", 1)[1].strip()
    except Exception:
        pass
    return ""

# ══════════════════════════════════════════════════════════════════
#  Проверка рассинхронизации AWG ↔ Xray
# ══════════════════════════════════════════════════════════════════

def xray_current_outbound() -> dict:
    """Возвращает {'address', 'port', 'uuid', 'pubkey', 'shortId'} из xray/config.json.
    Возвращает пустой dict если конфиг не найден или не читается."""
    if not XRAY_CONFIG:
        return {}
    try:
        cfg   = json.loads(XRAY_CONFIG.read_text())
        vnext = cfg["outbounds"][0]["settings"]["vnext"][0]
        rs    = cfg["outbounds"][0]["streamSettings"]["realitySettings"]
        return {
            "address": vnext.get("address", ""),
            "port":    str(vnext.get("port", "")),
            "uuid":    vnext["users"][0].get("id", ""),
            "pubkey":  rs.get("publicKey", ""),
            "shortId": rs.get("shortId", ""),
        }
    except Exception as exc:
        log.warning("Не удалось прочитать xray config: %s", exc)
        return {}


def check_and_fix_xray_sync(cur_srv: Server | None) -> None:
    """Сравнивает текущий xray/config.json с ожидаемыми параметрами cur_srv.
    Если расхождение — исправляет конфиг и перезапускает xray."""
    if not cur_srv or not cur_srv.xray_ip or not XRAY_CONFIG:
        return

    actual = xray_current_outbound()
    if not actual:
        return

    expected = {
        "address": cur_srv.xray_ip,
        "port":    cur_srv.xray_port,
        "uuid":    cur_srv.xray_uuid,
        "pubkey":  cur_srv.xray_pubkey,
        "shortId": cur_srv.xray_shortid,
    }

    mismatches = {k: (actual.get(k), v) for k, v in expected.items() if actual.get(k) != v}
    if not mismatches:
        return

    detail = ", ".join(f"{k}: {a!r}→{e!r}" for k, (a, e) in mismatches.items())
    log.warning("Xray рассинхронизирован с AWG (%s): %s", cur_srv.alias, detail)

    # Исправляем
    try:
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        (XRAY_CONFIG.parent / f"{XRAY_CONFIG.name}.bak.{ts}").write_text(XRAY_CONFIG.read_text())

        cfg   = json.loads(XRAY_CONFIG.read_text())
        vnext = cfg["outbounds"][0]["settings"]["vnext"][0]
        vnext["address"]        = cur_srv.xray_ip
        vnext["port"]           = int(cur_srv.xray_port)
        vnext["users"][0]["id"] = cur_srv.xray_uuid
        rs = cfg["outbounds"][0]["streamSettings"]["realitySettings"]
        rs["publicKey"] = cur_srv.xray_pubkey
        rs["shortId"]   = cur_srv.xray_shortid
        XRAY_CONFIG.write_text(json.dumps(cfg, indent=2))

        _restart_xray()
        log.info("Xray синхронизирован → %s:%s", cur_srv.xray_ip, cur_srv.xray_port)

        tg_send(
            f"🔧 <b>AmneziaWG: исправлена рассинхронизация Xray</b>\n\n"
            f"AWG указывал на <code>{cur_srv.alias}</code>, но Xray был настроен на другой сервер.\n\n"
            f"Исправлено:\n"
            + "\n".join(f"  • {k}: <code>{a}</code> → <code>{e}</code>"
                        for k, (a, e) in mismatches.items())
        )
    except Exception as exc:
        log.error("Не удалось исправить Xray конфиг: %s", exc)
        tg_send(
            f"⚠️ <b>AmneziaWG: Xray рассинхронизирован!</b>\n\n"
            f"AWG: <code>{cur_srv.alias}</code>\n"
            f"Xray указывает на: <code>{actual.get('address')}:{actual.get('port')}</code>\n\n"
            f"Автоисправление не удалось: {exc}\n"
            f"Требуется ручное вмешательство."
        )


# ══════════════════════════════════════════════════════════════════
#  Переключение сервера
# ══════════════════════════════════════════════════════════════════

def do_switch(srv: Server) -> None:
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)

    # Бэкап
    cur_text = AWG_CONF.read_text()
    cur_ep   = current_endpoint()
    cur_key  = next(
        (l.split("=", 1)[1].strip() for l in cur_text.splitlines() if l.startswith("PublicKey =")),
        "",
    )
    backup = BACKUP_DIR / f"awg0.conf.{ts}"
    backup.write_text(cur_text)
    LAST_FILE.write_text(f"{cur_ep}|{cur_key}|{backup}")

    # Обновляем AWG конфиг
    conf = re.sub(r"^PublicKey = .*", f"PublicKey = {srv.awg_key}", cur_text, count=1, flags=re.MULTILINE)
    conf = re.sub(r"^Endpoint = .*",  f"Endpoint = {srv.awg_ep}",   conf,     flags=re.MULTILINE)
    AWG_CONF.write_text(conf)
    subprocess.run(["systemctl", "restart", "awg-quick@awg0"], check=True)
    log.info("AWG перезапущен → %s", srv.awg_ep)

    # Обновляем Xray
    if srv.xray_ip and XRAY_CONFIG:
        (XRAY_CONFIG.parent / f"{XRAY_CONFIG.name}.bak.{ts}").write_text(XRAY_CONFIG.read_text())
        cfg   = json.loads(XRAY_CONFIG.read_text())
        vnext = cfg["outbounds"][0]["settings"]["vnext"][0]
        vnext["address"]        = srv.xray_ip
        vnext["port"]           = int(srv.xray_port)
        vnext["users"][0]["id"] = srv.xray_uuid
        rs = cfg["outbounds"][0]["streamSettings"]["realitySettings"]
        rs["publicKey"] = srv.xray_pubkey
        rs["shortId"]   = srv.xray_shortid
        XRAY_CONFIG.write_text(json.dumps(cfg, indent=2))

        if XRAY_COMPOSE_DIR:
            _restart_xray()


def _restart_xray() -> None:
    for docker_cmd in (["docker", "compose"], ["docker-compose"]):
        for extra in (["restart", "xray-proxy"], ["restart"]):
            try:
                subprocess.run(
                    docker_cmd + extra,
                    cwd=XRAY_COMPOSE_DIR, check=True,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                log.info("Xray контейнер перезапущен")
                return
            except (subprocess.CalledProcessError, FileNotFoundError):
                continue

# ══════════════════════════════════════════════════════════════════
#  Форматирование
# ══════════════════════════════════════════════════════════════════

def _icon(ms: int) -> str:
    return "🟢" if ms < 50 else "🟡" if ms < 150 else "🔴" if ms < 9999 else "⛔"

def _lat(ms: int) -> str:
    return f"{ms}мс" if ms < 9999 else "недоступен"

# ══════════════════════════════════════════════════════════════════
#  Главная логика
# ══════════════════════════════════════════════════════════════════

async def run(args: argparse.Namespace) -> None:
    if not AWG_CONF.exists():
        log.error("AWG конфиг не найден: %s", AWG_CONF); sys.exit(1)
    if not SERVERS_FILE.exists():
        log.error("Файл серверов не найден: %s", SERVERS_FILE); sys.exit(1)

    servers = load_servers()
    if not servers:
        log.error("Нет серверов в %s", SERVERS_FILE); sys.exit(1)

    # Загружаем накопленные счётчики неудач из предыдущих запусков
    state = load_state()
    fail_counts: dict[str, int] = state.get("fail_counts", {})
    for srv in servers:
        srv.fail_count = fail_counts.get(srv.alias, 0)

    cur_ep  = current_endpoint()
    cur_srv = next((s for s in servers if s.awg_ep == cur_ep), None)
    cur_alias = cur_srv.alias if cur_srv else f"unknown({cur_ep})"
    hs_age  = handshake_age()

    log.info("=== Проверка. Текущий: %s (%s), handshake: %dс ===", cur_alias, cur_ep, hs_age)

    # ── Проверка рассинхронизации AWG ↔ Xray ──
    check_and_fix_xray_sync(cur_srv)

    # ── Параллельная проверка всех серверов ──
    await probe_all(servers)

    for srv in servers:
        srv.fail_count = 0 if srv.available else srv.fail_count + 1
        log.info(
            "  %-12s %-25s %s%s",
            srv.alias, srv.awg_ep,
            _lat(srv.latency_ms),
            f" (подряд недоступен: {srv.fail_count})" if not srv.available else "",
        )

    save_state(cur_alias, servers)

    best = min((s for s in servers if s.available), key=lambda s: s.latency_ms, default=None)

    # ── Режим --notify-test ──
    if args.notify_test:
        tg_send("✅ <b>awg-monitor</b>: TG уведомления работают!")
        log.info("Тест TG отправлен")
        return

    # ── Режим --status ──
    if args.status:
        print(f"\n{'─'*54}")
        print(f"  Текущий: {cur_alias}  |  handshake: {hs_age}с")
        # Состояние Xray
        xray_out = xray_current_outbound()
        if xray_out:
            xray_match = (
                cur_srv and cur_srv.xray_ip
                and xray_out.get("address") == cur_srv.xray_ip
                and xray_out.get("uuid")    == cur_srv.xray_uuid
            )
            sync_mark = "✓ sync" if xray_match else "✗ РАССИНХРОНИЗИРОВАН"
            print(f"  Xray: {xray_out.get('address')}:{xray_out.get('port')}  [{sync_mark}]")
        print(f"{'─'*54}")
        for s in servers:
            marks = ("← текущий " if s.awg_ep == cur_ep else "") + \
                    ("★ лучший"   if best and s.alias == best.alias else "")
            fail  = f"  fail:{s.fail_count}" if s.fail_count else ""
            print(f"  {_icon(s.latency_ms)} {s.alias:<14} {s.awg_ep:<26} {_lat(s.latency_ms):<12} {marks}{fail}")
        print(f"{'─'*54}\n")
        return

    # ── Решение о переключении ──
    cur_lat   = cur_srv.latency_ms if cur_srv else 9999
    cur_avail = cur_srv.available  if cur_srv else False
    cur_fail  = cur_srv.fail_count if cur_srv else 0

    reason: str | None = None

    if not cur_avail and cur_fail >= FAIL_THRESHOLD:
        reason = f"текущий сервер недоступен ({cur_fail} проверок подряд)"

    if hs_age >= HANDSHAKE_MAX_AGE and not cur_avail:
        reason = f"нет AWG-хэндшейка ({hs_age}с) и сервер недоступен"

    if (cur_lat > LATENCY_THRESHOLD and best and best.alias != cur_alias
            and (cur_lat - best.latency_ms) > SWITCH_IMPROVEMENT):
        reason = f"медленный канал ({cur_lat}мс), найден быстрее: {best.alias} ({best.latency_ms}мс)"

    if args.force and best and best.alias != cur_alias:
        reason = "принудительное переключение на лучший сервер"

    if not reason:
        log.info("Переключение не нужно. %s: %s, handshake: %dс", cur_alias, _lat(cur_lat), hs_age)
        return

    if not best:
        tg_send(
            f"⛔ <b>AmneziaWG: все серверы недоступны!</b>\n\n"
            f"Текущий: <code>{cur_alias}</code>\n"
            f"Причина тревоги: {reason}\n\n"
            f"Требуется ручное вмешательство."
        )
        log.error("Все серверы недоступны!")
        sys.exit(1)

    if best.alias == cur_alias:
        log.info("Лучший сервер — текущий (%s). Переключение не нужно.", cur_alias)
        return

    # ── Выполняем переключение ──
    log.info("Переключение: %s → %s | %s", cur_alias, best.alias, reason)
    do_switch(best)

    await asyncio.sleep(6)
    new_hs = handshake_age()
    hs_ok  = f"✅ хэндшейк {new_hs}с назад" if new_hs < 30 else "❌ нет хэндшейка"

    table = "\n".join(
        f"{_icon(s.latency_ms)} <code>{s.alias}</code>: {_lat(s.latency_ms)}"
        + (" ✅" if s.alias == best.alias else "")
        + (" (был)" if s.alias == cur_alias else "")
        for s in servers
    )
    xray_line = f"\n🔀 Xray: <code>{best.xray_ip}:{best.xray_port}</code>" if best.xray_ip else ""

    tg_send(
        f"🔄 <b>AmneziaWG: автопереключение</b>\n\n"
        f"📤 Был: <code>{cur_alias}</code> — {_lat(cur_lat)}\n"
        f"📥 Стал: <code>{best.alias}</code> ({best.awg_ep}) — {_lat(best.latency_ms)}"
        f"{xray_line}\n\n"
        f"💬 <i>{reason}</i>\n"
        f"{hs_ok}\n\n"
        f"<b>Все серверы:</b>\n{table}"
    )
    log.info("Готово: %s → %s", cur_alias, best.alias)


def main() -> None:
    parser = argparse.ArgumentParser(description="awg-monitor — автопереключение AmneziaWG")
    parser.add_argument("--status",      action="store_true", help="только отчёт, без переключения")
    parser.add_argument("--force",       action="store_true", help="переключить на лучший сервер немедленно")
    parser.add_argument("--notify-test", action="store_true", help="тест Telegram уведомлений")
    args = parser.parse_args()

    lock_fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log.info("Уже выполняется другой экземпляр. Выход.")
        sys.exit(0)

    try:
        asyncio.run(run(args))
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()


if __name__ == "__main__":
    main()

# bot_api.py
import asyncio
import fcntl
import io
import ipaddress
import json
import logging
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional, List, Set

import qrcode
import requests
from dotenv import load_dotenv
from telegram import Update, InlineKeyboardMarkup, InlineKeyboardButton, InputFile
from telegram.ext import ApplicationBuilder, CommandHandler, CallbackQueryHandler, ContextTypes

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

# ══════════════════════════════════════════════════════════════════
#                         КОНФИГУРАЦИЯ
# ══════════════════════════════════════════════════════════════════
# Загружаем переменные окружения из .env файла
load_dotenv()

# Проверяем платформу для fcntl (только Linux/macOS)
if sys.platform == "win32":
    log.warning("⚠️ fcntl не доступен на Windows. SmartWG не будет работать корректно.")

# Загружаем конфиг из переменных окружения
BOT_TOKEN   = os.getenv("BOT_TOKEN", "").strip()
WG_API_BASE = os.getenv("WG_API_BASE", "http://localhost:51821/api")
WG_PASSWORD = os.getenv("WG_PASSWORD", "").strip()
ADMIN_USERNAME_RAW = os.getenv("ADMIN_USERNAME", "")
ADMIN_ALLOW_USERNAME = "@" + (ADMIN_USERNAME_RAW.lstrip("@"))

if not BOT_TOKEN:
    raise RuntimeError(
        "❌ BOT_TOKEN not configured. Create .env file or set environment variable."
    )
if not WG_PASSWORD:
    raise RuntimeError(
        "❌ WG_PASSWORD not configured. Create .env file or set environment variable."
    )

MAX_CONFIGS_PER_USER = 4
ALLOWED_FILE         = Path(__file__).parent / "allowed_users.txt"
UNLIMITED_FILE       = Path(__file__).parent / "unlimited_users.txt"
SUBSCRIBERS_FILE     = Path(__file__).parent / "subscribers.txt"
ACCESS_STATE_FILE    = Path(__file__).parent / "access_state.json"
REGULAR_NAME_TAG     = "vpn"
FUNDRAISE_IMAGE_FILE = Path(__file__).parent / "image.png"
FUNDRAISE_URL        = "https://tbank.ru/cf/6GrWfpdMpGG"
TG_PROXY_LINK        = "socks5://10.30.0.1:1080"
TG_PROXY_TG_LINK     = "tg://socks?server=10.30.0.1&port=1080"
REQUEST_COOLDOWN_DAYS = 30

WEBHOOK_URL    = os.getenv("WEBHOOK_URL", "").strip()
WEBHOOK_PORT   = int(os.getenv("WEBHOOK_PORT", "8443"))
WEBHOOK_SECRET = os.getenv("WEBHOOK_SECRET", "").strip() or None


# ══════════════════════════════════════════════════════════════════
#              WG-EASY API — ОБЫЧНЫЙ VPN (без изменений)
# ══════════════════════════════════════════════════════════════════
class WGEasyAPI:
    """REST-клиент для wg-easy (Docker, порт 51821)."""

    def __init__(self, base: str, password: str):
        self.base = base.rstrip("/")
        self.password = password
        self.s = requests.Session()
        self._login()

    def _login(self):
        r = self.s.post(f"{self.base}/session", json={"password": self.password}, timeout=20)
        if r.status_code not in (200, 204):
            raise RuntimeError(f"WG-Easy login failed: {r.status_code} {r.text}")
        r2 = self.s.get(f"{self.base}/session", timeout=20)
        if r2.status_code != 200 or not r2.json().get("authenticated", False):
            raise RuntimeError("WG-Easy session not authenticated")

    def _req(self, method: str, path: str, **kw) -> requests.Response:
        url = f"{self.base}{path}"
        try:
            r = self.s.request(method, url, timeout=30, **kw)
        except requests.RequestException:
            self._login()
            r = self.s.request(method, url, timeout=30, **kw)
        if r.status_code == 401:
            self._login()
            r = self.s.request(method, url, timeout=30, **kw)
        if r.status_code == 401:
            raise RuntimeError("WG-Easy auth failed after retry")
        return r

    def list_clients(self) -> list[dict]:
        r = self._req("GET", "/wireguard/client")
        if r.status_code not in (200, 204):
            raise RuntimeError(f"List clients error: {r.status_code} {r.text}")
        return r.json()

    def create_client(self, name: str) -> dict:
        r = self._req("POST", "/wireguard/client", json={"name": name})
        if r.status_code not in (200, 204):
            raise RuntimeError(f"Create client error: {r.status_code} {r.text}")
        return r.json()

    def get_configuration(self, client_id: str) -> str:
        r = self._req("GET", f"/wireguard/client/{client_id}/configuration")
        if r.status_code not in (200, 204):
            raise RuntimeError(f"Get configuration error: {r.status_code} {r.text}")
        return r.text


# ══════════════════════════════════════════════════════════════════
#              SMART WG MANAGER — УМНЫЙ VPN
# ══════════════════════════════════════════════════════════════════
class SmartWGManager:
    """
    Управляет интерфейсом wg-smart (хостовой WireGuard, без Docker).
    Все операции с конфигом атомарны через fcntl-блокировку.
    Приватные ключи хранятся ТОЛЬКО в .conf-файлах клиентов — не логируются.
    """
    SMART_DIR        = Path("/etc/wireguard/smart")
    CLIENTS_JSON     = SMART_DIR / "clients.json"
    CLIENTS_CONF_DIR = SMART_DIR / "clients"
    SERVER_CONF      = Path("/etc/wireguard/wg-smart.conf")
    SERVER_ENDPOINT  = "736-lukovxoladya.xyz:51830"
    SERVER_IP        = "10.30.0.1"
    NETWORK          = "10.30.0.0/24"
    DNS              = "10.30.0.1"
    MTU              = 1280

    def __init__(self):
        self.SMART_DIR.mkdir(parents=True, exist_ok=True)
        self.CLIENTS_CONF_DIR.mkdir(parents=True, exist_ok=True)
        self._lock_path = self.SMART_DIR / ".lock"
        self._lock_path.touch()

    # ── внутренние методы ─────────────────────────────────────────

    def _load_clients(self) -> dict:
        if not self.CLIENTS_JSON.exists():
            return {}
        try:
            return json.loads(self.CLIENTS_JSON.read_text())
        except (json.JSONDecodeError, OSError):
            return {}

    def _save_clients(self, clients: dict) -> None:
        self.CLIENTS_JSON.write_text(json.dumps(clients, indent=2, ensure_ascii=False))
        os.chmod(self.CLIENTS_JSON, 0o600)

    def _next_ip(self, clients: dict) -> str:
        used = {v["ip"] for v in clients.values()}
        for host in ipaddress.IPv4Network(self.NETWORK).hosts():
            ip = str(host)
            if ip != self.SERVER_IP and ip not in used:
                return ip
        raise RuntimeError("Нет свободных IP в подсети 10.30.0.0/24")

    @staticmethod
    def _generate_keys() -> tuple[str, str]:
        privkey = subprocess.check_output(["wg", "genkey"]).decode().strip()
        pubkey  = subprocess.check_output(["wg", "pubkey"], input=privkey.encode()).decode().strip()
        return privkey, pubkey

    def _server_pubkey(self) -> str:
        try:
            pk = subprocess.check_output(
                ["wg", "show", "wg-smart", "public-key"], stderr=subprocess.DEVNULL
            ).decode().strip()
            if pk:
                return pk
        except Exception:
            pass
        conf = self.SERVER_CONF.read_text()
        for line in conf.splitlines():
            if line.strip().lower().startswith("privatekey"):
                raw = line.split("=", 1)[1].strip()
                return subprocess.check_output(
                    ["wg", "pubkey"], input=raw.encode()
                ).decode().strip()
        raise RuntimeError("Не удалось получить публичный ключ сервера wg-smart")

    def _append_peer(self, client_name: str, pubkey: str, ip: str) -> None:
        block = f"\n[Peer]\n# {client_name}\nPublicKey = {pubkey}\nAllowedIPs = {ip}/32\n"
        with self.SERVER_CONF.open("a") as f:
            f.write(block)

    @staticmethod
    def _syncconf() -> None:
        res = subprocess.run(
            ["bash", "-c", "wg syncconf wg-smart <(wg-quick strip wg-smart)"],
            capture_output=True, text=True,
        )
        if res.returncode != 0:
            raise RuntimeError(f"wg syncconf failed: {res.stderr.strip()}")

    def _build_conf(self, privkey: str, ip: str, server_pubkey: str) -> str:
        return (
            f"[Interface]\n"
            f"PrivateKey = {privkey}\n"
            f"Address = {ip}/32\n"
            f"DNS = {self.DNS}\n"
            f"MTU = {self.MTU}\n"
            f"\n"
            f"[Peer]\n"
            f"PublicKey = {server_pubkey}\n"
            f"Endpoint = {self.SERVER_ENDPOINT}\n"
            f"AllowedIPs = 0.0.0.0/0\n"
            f"PersistentKeepalive = 25\n"
        )

    # ── публичный API ─────────────────────────────────────────────

    def list_user_clients(self, username_at: str) -> list[dict]:
        uname = username_at.lstrip("@")
        result = []
        for name, data in self._load_clients().items():
            m = re.fullmatch(rf"{re.escape(uname)}-smart-(\d+)", name)
            if m:
                result.append({"name": name, "ip": data["ip"], "n": int(m.group(1))})
        return sorted(result, key=lambda x: x["n"])

    def list_user_ordinals(self, username_at: str) -> list[int]:
        return [c["n"] for c in self.list_user_clients(username_at)]

    def next_ordinal(self, username_at: str) -> int:
        ords = self.list_user_ordinals(username_at)
        return (max(ords) + 1) if ords else 1

    def create_client(self, username_at: str, n: int) -> tuple[str, str]:
        """Создаёт нового smart-клиента атомарно. Возвращает (conf_text, client_name)."""
        uname       = username_at.lstrip("@")
        client_name = f"{uname}-smart-{n}"
        conf_file   = self.CLIENTS_CONF_DIR / f"{client_name}.conf"

        with open(self._lock_path, "w") as lf:
            fcntl.flock(lf, fcntl.LOCK_EX)
            try:
                clients = self._load_clients()
                if client_name in clients:
                    raise RuntimeError(f"Клиент {client_name} уже существует")

                ip             = self._next_ip(clients)
                privkey, pubkey = self._generate_keys()
                server_pub     = self._server_pubkey()
                conf_text      = self._build_conf(privkey, ip, server_pub)

                conf_file.write_text(conf_text)
                os.chmod(conf_file, 0o600)

                clients[client_name] = {"ip": ip, "pubkey": pubkey, "conf_path": str(conf_file)}
                self._save_clients(clients)
                self._append_peer(client_name, pubkey, ip)
                self._syncconf()

                log.info("SmartWG: created %s @ %s", client_name, ip)
                return conf_text, client_name
            finally:
                fcntl.flock(lf, fcntl.LOCK_UN)

    def get_client_conf(self, username_at: str, n: int) -> tuple[str, str]:
        """Возвращает (conf_text, client_name) для существующего клиента."""
        uname       = username_at.lstrip("@")
        client_name = f"{uname}-smart-{n}"
        clients     = self._load_clients()
        if client_name not in clients:
            raise RuntimeError(f"Умный конфиг #{n} не найден")
        return Path(clients[client_name]["conf_path"]).read_text(), client_name

    def get_status(self) -> str:
        try:
            return subprocess.check_output(
                ["wg", "show", "wg-smart"], stderr=subprocess.DEVNULL, text=True
            ) or "нет данных"
        except Exception:
            return "⚠️ Интерфейс wg-smart недоступен"


# ══════════════════════════════════════════════════════════════════
#                    АВТОРИЗАЦИЯ И УТИЛИТЫ
# ══════════════════════════════════════════════════════════════════

def normalize_username(name: str) -> str:
    name = (name or "").strip()
    if not name:
        return ""
    return name if name.startswith("@") else f"@{name}"


def load_allowed_usernames() -> Set[str]:
    allowed: Set[str] = set()
    if ALLOWED_FILE.exists():
        for line in ALLOWED_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                allowed.add(normalize_username(line))
    return allowed


def load_unlimited_usernames() -> Set[str]:
    s: Set[str] = set()
    if UNLIMITED_FILE.exists():
        for line in UNLIMITED_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                s.add(normalize_username(line))
    return s


def load_subscriber_chat_ids() -> Set[int]:
    ids: Set[int] = set()
    if SUBSCRIBERS_FILE.exists():
        for line in SUBSCRIBERS_FILE.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                ids.add(int(line))
            except ValueError:
                continue
    return ids


def save_subscriber_chat_ids(chat_ids: Set[int]) -> None:
    SUBSCRIBERS_FILE.parent.mkdir(parents=True, exist_ok=True)
    data = "\n".join(str(cid) for cid in sorted(chat_ids))
    if data:
        data += "\n"
    SUBSCRIBERS_FILE.write_text(data, encoding="utf-8")


def add_subscriber_chat_id(chat_id: int) -> None:
    ids = load_subscriber_chat_ids()
    if chat_id not in ids:
        ids.add(chat_id)
        save_subscriber_chat_ids(ids)


def remove_subscriber_chat_id(chat_id: int) -> None:
    ids = load_subscriber_chat_ids()
    if chat_id in ids:
        ids.remove(chat_id)
        save_subscriber_chat_ids(ids)


def max_configs_for(username_at: str) -> Optional[int]:
    return None if normalize_username(username_at) in load_unlimited_usernames() else MAX_CONFIGS_PER_USER


def is_allowed(user) -> bool:
    return bool(user and user.username and normalize_username(user.username) in load_allowed_usernames())


def is_admin(user) -> bool:
    return bool(user and user.username and normalize_username(user.username) == ADMIN_ALLOW_USERNAME)


def add_allowed_username(username_at: str) -> bool:
    username_at = normalize_username(username_at)
    if not username_at:
        raise ValueError("Пустой username")
    if not re.fullmatch(r"@[A-Za-z0-9_]{5,32}", username_at):
        raise ValueError("Некорректный username")
    existing = load_allowed_usernames()
    if username_at in existing:
        return False
    ALLOWED_FILE.parent.mkdir(parents=True, exist_ok=True)
    prefix = ""
    if ALLOWED_FILE.exists() and ALLOWED_FILE.stat().st_size > 0:
        with ALLOWED_FILE.open("rb") as f:
            f.seek(-1, 2)
            if f.read(1) != b"\n":
                prefix = "\n"
    with ALLOWED_FILE.open("a", encoding="utf-8") as f:
        f.write(prefix + username_at + "\n")
    return True


def _default_access_state() -> dict:
    return {
        "admin_chat_id": 0,
        "blocked_user_ids": [],
        "blocked_usernames": [],
        "last_request_by_user_id": {},
        "pending_by_user_id": {},
    }


def load_access_state() -> dict:
    if not ACCESS_STATE_FILE.exists():
        return _default_access_state()
    try:
        raw = json.loads(ACCESS_STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return _default_access_state()
    state = _default_access_state()
    for k in state:
        if k in raw and isinstance(raw[k], type(state[k])):
            state[k] = raw[k]
    return state


def save_access_state(state: dict) -> None:
    ACCESS_STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    ACCESS_STATE_FILE.write_text(
        json.dumps(state, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    os.chmod(ACCESS_STATE_FILE, 0o600)


def set_admin_chat_id(chat_id: int) -> None:
    state = load_access_state()
    state["admin_chat_id"] = int(chat_id)
    save_access_state(state)


def get_admin_chat_id() -> int:
    state = load_access_state()
    return int(state.get("admin_chat_id") or 0)


def is_blocked(user) -> bool:
    if not user:
        return False
    state = load_access_state()
    uid = user.id
    uname = normalize_username(user.username)
    if uid in {int(x) for x in state.get("blocked_user_ids", [])}:
        return True
    return bool(uname and uname in {normalize_username(x) for x in state.get("blocked_usernames", [])})


def mark_user_blocked(user_id: int, username_at: str = "") -> None:
    state = load_access_state()
    blocked_ids = {int(x) for x in state.get("blocked_user_ids", [])}
    blocked_ids.add(int(user_id))
    state["blocked_user_ids"] = sorted(blocked_ids)
    if username_at:
        blocked_names = {normalize_username(x) for x in state.get("blocked_usernames", []) if normalize_username(x)}
        blocked_names.add(normalize_username(username_at))
        state["blocked_usernames"] = sorted(blocked_names)
    state.get("pending_by_user_id", {}).pop(str(user_id), None)
    save_access_state(state)


def save_pending_request(user, chat_id: int) -> int:
    now_ts = int(time.time())
    uid = int(user.id)
    state = load_access_state()
    last_map = state.get("last_request_by_user_id", {})
    prev_ts = int(last_map.get(str(uid), 0) or 0)
    cooldown_s = REQUEST_COOLDOWN_DAYS * 24 * 60 * 60
    if prev_ts and (now_ts - prev_ts) < cooldown_s:
        return max(0, cooldown_s - (now_ts - prev_ts))

    last_map[str(uid)] = now_ts
    state["last_request_by_user_id"] = last_map
    state.setdefault("pending_by_user_id", {})[str(uid)] = {
        "user_id": uid,
        "username": normalize_username(user.username),
        "first_name": user.first_name or "",
        "chat_id": int(chat_id),
        "requested_at": now_ts,
    }
    save_access_state(state)
    return 0


def pop_pending_request(user_id: int) -> Optional[dict]:
    state = load_access_state()
    pending = state.get("pending_by_user_id", {})
    data = pending.pop(str(int(user_id)), None)
    state["pending_by_user_id"] = pending
    save_access_state(state)
    return data


def get_pending_request(user_id: int) -> Optional[dict]:
    state = load_access_state()
    return state.get("pending_by_user_id", {}).get(str(int(user_id)))


def _to_int(v) -> int:
    try:
        return int(v)
    except Exception:
        return 0


def _client_total_bytes(c: dict) -> int:
    rx_keys = ["transferRx", "receivedBytes", "rxBytes", "totalRx", "rx"]
    tx_keys = ["transferTx", "sentBytes",     "txBytes", "totalTx", "tx"]
    rx = next((_to_int(c[k]) for k in rx_keys if k in c), 0)
    tx = next((_to_int(c[k]) for k in tx_keys if k in c), 0)
    transfer = c.get("transfer")
    if isinstance(transfer, dict):
        if rx == 0:
            rx = _to_int(transfer.get("rx") or transfer.get("received") or transfer.get("download"))
        if tx == 0:
            tx = _to_int(transfer.get("tx") or transfer.get("sent") or transfer.get("upload"))
    return max(0, rx) + max(0, tx)


def read_usage_from_api(api: WGEasyAPI) -> List[tuple[str, int]]:
    rows = [
        (str(c.get("name") or "unknown"), _client_total_bytes(c))
        for c in api.list_clients()
        if isinstance(c, dict)
    ]
    return sorted(rows, key=lambda x: x[1], reverse=True)


def human_bytes(n: int) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    val, idx = float(max(0, n)), 0
    while val >= 1024 and idx < len(units) - 1:
        val /= 1024
        idx += 1
    return f"{val:.2f} {units[idx]}"


def conf_to_qr_png_bytes(conf_text: str) -> bytes:
    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_Q)
    qr.add_data(conf_text)
    qr.make(fit=True)
    buf = io.BytesIO()
    qr.make_image().save(buf, format="PNG")
    return buf.getvalue()


INSTALL_INSTRUCTION = (
    "\n\n"
    "📋 <b>Как установить конфиг:</b>\n\n"
    "1️⃣ Установите приложение <b>WireGuard</b>:\n"
    "   📱 <b>iPhone/iPad</b> — App Store → поиск «WireGuard»\n"
    "   📱 <b>Android</b> — Google Play → поиск «WireGuard»\n"
    "   💻 <b>Windows/Mac</b> — зайдите на wireguard.com/install\n\n"
    "2️⃣ Откройте приложение WireGuard и нажмите <b>«+»</b>\n\n"
    "3️⃣ Выберите способ импорта:\n"
    "   📄 <b>Через файл:</b> «Создать из файла» → найдите скачанный .conf\n"
    "   📷 <b>Через QR:</b> «Создать из QR-кода» → наведите камеру на QR\n"
    "      <i>(удобно: откройте QR на одном устройстве, сканируйте другим)</i>\n\n"
    "4️⃣ Нажмите на тумблер рядом с профилем — VPN включён ✅"
)

FUNDRAISE_BASE_TEXT = (
    "Собираю на восстановление и покупку ВАЗ-2101. "
    "Поддержка добровольная, ничего взамен не обещаю."
)

TG_PROXY_TEXT = (
    "📱 <b>Прокси для Telegram</b>\n\n"
    "Этот прокси работает только с включённым умным VPN (wg-smart).\n\n"
    f"<a href=\"{TG_PROXY_TG_LINK}\">👇 Нажмите чтобы добавить прокси в Telegram</a>\n\n"
    f"Или скопируйте вручную: <code>{TG_PROXY_LINK}</code>\n"
    "Затем: Настройки → Смещенные параметры → Подключение → Тип прокси → SOCKS5."
)


async def send_conf_and_qr(
    chat_id: int,
    filename: str,
    conf_text: str,
    app,
    caption: str = "",
):
    file_buf      = io.BytesIO(conf_text.encode())
    file_buf.name = filename
    await app.bot.send_document(
        chat_id=chat_id,
        document=InputFile(file_buf, filename=filename),
        caption=caption + INSTALL_INSTRUCTION,
        parse_mode="HTML",
    )
    png = conf_to_qr_png_bytes(conf_text)
    await app.bot.send_photo(
        chat_id=chat_id,
        photo=png,
        caption="📷 QR-код — отсканируйте в приложении WireGuard с другого устройства",
    )


# ══════════════════════════════════════════════════════════════════
#              ОБЫЧНЫЙ VPN — вспомогательные функции
# ══════════════════════════════════════════════════════════════════

def _extract_ordinal(client_name: str, username_at: str) -> Optional[int]:
    """Поддерживает новый формат uservpnN и legacy user#N/user-N."""
    uname = username_at.lstrip("@")
    value = client_name or ""
    for pattern in (
        rf"{re.escape(uname)}{re.escape(REGULAR_NAME_TAG)}(\d+)",
        rf"{re.escape(uname)}[#-](\d+)",
    ):
        m = re.fullmatch(pattern, value)
        if m:
            n = int(m.group(1))
            return n if n > 0 else None
    return None


def api_user_clients(api: WGEasyAPI, username_at: str) -> list[dict]:
    return [
        c for c in api.list_clients()
        if isinstance(c, dict) and _extract_ordinal(str(c.get("name") or ""), username_at) is not None
    ]


def list_user_ordinals(api: WGEasyAPI, username_at: str) -> list[int]:
    ords = [_extract_ordinal(str(c.get("name") or ""), username_at) for c in api_user_clients(api, username_at)]
    return sorted(n for n in ords if n is not None)


def next_ordinal_regular(api: WGEasyAPI, username_at: str) -> int:
    ords = list_user_ordinals(api, username_at)
    return (max(ords) + 1) if ords else 1


def _find_client_by_ordinal(api: WGEasyAPI, username_at: str, n: int) -> Optional[dict]:
    for c in api_user_clients(api, username_at):
        if _extract_ordinal(str(c.get("name") or ""), username_at) == n:
            return c
    return None


def _chunk(lst, n):
    return [lst[i:i + n] for i in range(0, len(lst), n)]


def build_regular_client_name(username_at: str, n: int) -> str:
    """Безопасное имя без спецсимволов для WireGuard-клиентов."""
    uname = username_at.lstrip("@")
    return f"{uname}-{REGULAR_NAME_TAG}-{n}"


def parse_positive_ordinal_arg(args: list[str], default: int = 1) -> Optional[int]:
    if not args:
        return default
    try:
        n = int(args[0])
        return n if n > 0 else None
    except (ValueError, TypeError):
        return None


# ══════════════════════════════════════════════════════════════════
#                  ТЕКСТЫ И КЛАВИАТУРЫ
# ══════════════════════════════════════════════════════════════════

_BTN_BACK_MAIN = InlineKeyboardButton("◀️ Главное меню", callback_data="menu:main")


def main_menu_text() -> str:
    return (
        "🔐 <b>VPN Bot</b>\n\n"
        "Выберите тип подключения:\n\n"
        "🧠 <b>Умный VPN</b> <i>(рекомендуем)</i>\n"
        "   Автоматически направляет через VPN только нужные сайты.\n"
        "   Для большинства пользователей это лучший выбор.\n\n"
        "🌐 <b>Обычный VPN</b>\n"
        "   Весь трафик идёт через VPN-сервер.\n"
        "   Подходит, если нужен полный тоннель.\n\n"
        "💡 <b>Если не разбираетесь в настройках, лучше выбирайте «Умный VPN».</b>"
    )


def main_menu_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("🧠🔥  УМНЫЙ VPN (РЕКОМЕНДУЕМ)", callback_data="menu:smart")],
        [InlineKeyboardButton("🌐  Обычный VPN", callback_data="menu:regular")],
        [InlineKeyboardButton("❓  Помощь / Инструкция", callback_data="menu:help")],
    ])


def regular_menu(api: WGEasyAPI, uname: str) -> tuple[str, InlineKeyboardMarkup]:
    try:
        ords  = list_user_ordinals(api, uname)
        limit = max_configs_for(uname)
    except Exception:
        ords, limit = [], MAX_CONFIGS_PER_USER

    if ords:
        count_line = f"Ваших конфигов: <b>{len(ords)}</b>  •  Нажмите номер, чтобы получить"
    else:
        count_line = "Конфигов пока нет — создайте первый!"

    limit_line = f"\nЛимит: {limit} конфигов" if (limit and len(ords) >= limit) else ""
    text = f"🌐 <b>Обычный VPN</b>\n\n{count_line}{limit_line}"

    rows: list[list[InlineKeyboardButton]] = []
    if ords:
        rows += _chunk(
            [InlineKeyboardButton(f"📄  Конфиг #{n}", callback_data=f"get_n:{n}") for n in ords], 2
        )
    if limit is None or len(ords) < limit:
        next_n = (max(ords) + 1) if ords else 1
        rows.append([InlineKeyboardButton(f"➕  Создать конфиг #{next_n}", callback_data="new_conf")])
    rows.append([_BTN_BACK_MAIN])

    return text, InlineKeyboardMarkup(rows)


def smart_menu(smart: SmartWGManager, uname: str) -> tuple[str, InlineKeyboardMarkup]:
    try:
        ords  = smart.list_user_ordinals(uname)
        limit = max_configs_for(uname)
    except Exception:
        ords, limit = [], MAX_CONFIGS_PER_USER

    if ords:
        count_line = f"Ваших конфигов: <b>{len(ords)}</b>  •  Нажмите номер, чтобы получить"
    else:
        count_line = "Конфигов пока нет — создайте первый!"

    limit_line = f"\nЛимит: {limit} конфигов" if (limit and len(ords) >= limit) else ""
    text = f"🧠 <b>Умный VPN</b>\n\n{count_line}{limit_line}"

    rows: list[list[InlineKeyboardButton]] = []
    if ords:
        rows += _chunk(
            [InlineKeyboardButton(f"📄  Конфиг #{n}", callback_data=f"get_smart:{n}") for n in ords], 2
        )
    if limit is None or len(ords) < limit:
        next_n = (max(ords) + 1) if ords else 1
        rows.append([InlineKeyboardButton(f"➕  Создать умный конфиг #{next_n}", callback_data="new_smart")])
    rows.append([_BTN_BACK_MAIN])

    return text, InlineKeyboardMarkup(rows)


HELP_TEXT = (
    "❓ <b>Помощь — VPN Bot</b>\n\n"
    "<b>Типы VPN:</b>\n"
    "🌐 <b>Обычный</b> — весь трафик шифруется и идёт через VPN\n"
    "🧠 <b>Умный</b> — только нужные/заблокированные сайты через VPN,\n"
    "   остальное — напрямую без потери скорости\n\n"
    "<b>Команды:</b>\n"
    "<code>/start</code>      — главное меню\n"
    "<code>/new</code>        — создать обычный конфиг\n"
    "<code>/new_smart</code>  — создать умный конфиг\n"
    "<code>/get N</code>      — скачать обычный конфиг №N\n"
    "<code>/get_smart N</code>— скачать умный конфиг №N\n"
    "<code>/usage</code>      — трафик по обычному VPN\n"
    f"<code>/allow @user</code>— добавить пользователя (только {ADMIN_ALLOW_USERNAME})\n"
    f"<code>/fundraise</code>  — рассылка сбора (только {ADMIN_ALLOW_USERNAME})\n\n"
    "──────────────────────────\n"
    "📲 <b>Как установить WireGuard:</b>\n\n"
    "① Скачайте приложение <b>WireGuard</b>:\n"
    "   • iPhone / iPad → App Store → «WireGuard»\n"
    "   • Android → Google Play → «WireGuard»\n"
    "   • Windows / Mac → wireguard.com/install\n\n"
    "② Откройте WireGuard, нажмите <b>«+»</b>\n\n"
    "③ Выберите способ добавления:\n\n"
    "   📄 <b>Через файл .conf:</b>\n"
    "   Нажмите «Создать из файла или архива»\n"
    "   → Найдите скачанный файл с расширением .conf\n"
    "   → Нажмите на него\n\n"
    "   📷 <b>Через QR-код:</b>\n"
    "   Нажмите «Создать из QR-кода»\n"
    "   → Откройте QR на одном устройстве\n"
    "   → Отсканируйте другим устройством\n\n"
    "④ Нажмите тумблер рядом с профилем — VPN включён ✅\n\n"
    "💡 <i>Один конфиг = одно устройство.\n"
    "Для телефона и ноутбука создайте отдельные конфиги.</i>\n\n"
    "🧠 <b>Совет:</b> если не разбираетесь в настройках, выбирайте кнопку <b>«УМНЫЙ VPN (РЕКОМЕНДУЕМ)»</b>."
)


# ══════════════════════════════════════════════════════════════════
#                    ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ══════════════════════════════════════════════════════════════════

def _get_api(context: ContextTypes.DEFAULT_TYPE) -> WGEasyAPI:
    if "api" not in context.bot_data:
        context.bot_data["api"] = WGEasyAPI(WG_API_BASE, WG_PASSWORD)
    return context.bot_data["api"]


def _get_smart(context: ContextTypes.DEFAULT_TYPE) -> SmartWGManager:
    if "smart" not in context.bot_data:
        context.bot_data["smart"] = SmartWGManager()
    return context.bot_data["smart"]


async def _check_access(update: Update, context: ContextTypes.DEFAULT_TYPE) -> Optional[str]:
    user    = update.effective_user
    chat_id = update.effective_chat.id
    if is_admin(user):
        set_admin_chat_id(chat_id)

    if is_blocked(user):
        await context.bot.send_message(
            chat_id=chat_id,
            text=f"⛔ Доступ отклонён. Обратитесь к администратору ({ADMIN_ALLOW_USERNAME}).",
        )
        return None

    if not is_allowed(user):
        uname = normalize_username(user.username)
        wait_s = save_pending_request(user, chat_id)
        if wait_s > 0:
            days_left = max(1, (wait_s + 86399) // 86400)
            await context.bot.send_message(
                chat_id=chat_id,
                text=(
                    "⏳ Ваша заявка уже отправлялась недавно. "
                    f"Повторно можно отправить через ~{days_left} дн."
                ),
            )
            return None

        # Кнопки для модерации заявки доступны только администратору.
        kb = InlineKeyboardMarkup([
            [
                InlineKeyboardButton("✅ Добавить", callback_data=f"req:approve:{user.id}"),
                InlineKeyboardButton("❌ Отклонить", callback_data=f"req:reject:{user.id}"),
            ],
            [InlineKeyboardButton("⛔ Заблокировать", callback_data=f"req:block:{user.id}")],
        ])
        req_text = (
            "📩 <b>Новая заявка на доступ</b>\n\n"
            f"ID: <code>{user.id}</code>\n"
            f"Username: <code>{uname or 'нет username'}</code>\n"
            f"Имя: <code>{(user.first_name or '').strip() or 'не указано'}</code>"
        )

        try:
            admin_chat_id = get_admin_chat_id()
            if admin_chat_id:
                await context.bot.send_message(admin_chat_id, req_text, reply_markup=kb, parse_mode="HTML")
            else:
                log.warning("Admin chat id is not set; run /start from admin account once")
        except Exception as e:
            log.warning("Failed to notify admin about access request: %s", e)

        await context.bot.send_message(
            chat_id=chat_id,
            text="📨 Заявка отправлена администратору. Ожидайте решение.",
        )
        return None
    add_subscriber_chat_id(chat_id)
    return normalize_username(user.username)


async def _check_callback_access(update: Update, context: ContextTypes.DEFAULT_TYPE) -> Optional[str]:
    """Единая точка проверки доступа для callback-кнопок."""
    user = update.effective_user
    if is_blocked(user):
        await update.callback_query.edit_message_text("⛔ Доступ отклонён.")
        return None
    if not is_allowed(user):
        await update.callback_query.edit_message_text("⛔ Нет доступа.")
        return None
    add_subscriber_chat_id(update.effective_chat.id)
    return normalize_username(user.username)


async def _edit_or_send(q, chat_id, text, kb, app, parse_mode="HTML"):
    """Пытается отредактировать сообщение, при ошибке шлёт новое."""
    try:
        await q.edit_message_text(text, reply_markup=kb, parse_mode=parse_mode)
    except Exception:
        await app.bot.send_message(chat_id, text, reply_markup=kb, parse_mode=parse_mode)


# ══════════════════════════════════════════════════════════════════
#                     ОБРАБОТЧИКИ КОМАНД
# ══════════════════════════════════════════════════════════════════

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uname = await _check_access(update, context)
    if not uname:
        return
    await update.message.reply_text(
        main_menu_text(),
        reply_markup=main_menu_keyboard(),
        parse_mode="HTML",
    )


async def help_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await context.bot.send_message(
        update.effective_chat.id,
        HELP_TEXT,
        reply_markup=InlineKeyboardMarkup([[
            InlineKeyboardButton("🔐  Открыть меню", callback_data="menu:main")
        ]]),
        parse_mode="HTML",
    )


async def new_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uname = await _check_access(update, context)
    if not uname:
        return
    api     = _get_api(context)
    chat_id = update.effective_chat.id
    try:
        ords  = await asyncio.to_thread(list_user_ordinals, api, uname)
        limit = max_configs_for(uname)
        if limit is not None and len(ords) >= limit:
            await context.bot.send_message(chat_id, f"⚠️ Достигнут лимит {limit} конфигов.")
        else:
            new_n       = (max(ords) + 1) if ords else 1
            client_name = build_regular_client_name(uname, new_n)
            created   = await asyncio.to_thread(api.create_client, client_name)
            conf_text = await asyncio.to_thread(api.get_configuration, created["id"])
            await send_conf_and_qr(
                chat_id, f"{client_name}.conf", conf_text, context.application,
                caption=f"🌐 <b>Обычный VPN</b> — новый конфиг <b>#{new_n}</b>",
            )
    except Exception as e:
        await context.bot.send_message(chat_id, f"❌ Ошибка: {e}")
    text, kb = await asyncio.to_thread(regular_menu, api, uname)
    await context.bot.send_message(chat_id, text, reply_markup=kb, parse_mode="HTML")


async def new_smart_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uname = await _check_access(update, context)
    if not uname:
        return
    smart   = _get_smart(context)
    chat_id = update.effective_chat.id
    try:
        ords  = await asyncio.to_thread(smart.list_user_ordinals, uname)
        limit = max_configs_for(uname)
        if limit is not None and len(ords) >= limit:
            await context.bot.send_message(chat_id, f"⚠️ Достигнут лимит {limit} умных конфигов.")
        else:
            new_n = (max(ords) + 1) if ords else 1
            conf_text, client_name = await asyncio.to_thread(smart.create_client, uname, new_n)
            await send_conf_and_qr(
                chat_id, f"{client_name}.conf", conf_text, context.application,
                caption=f"🧠 <b>Умный VPN</b> — новый конфиг <b>#{new_n}</b>",
            )
            await context.bot.send_message(chat_id, TG_PROXY_TEXT, parse_mode="HTML")
    except Exception as e:
        await context.bot.send_message(chat_id, f"❌ Ошибка: {e}")
    text, kb = await asyncio.to_thread(smart_menu, smart, uname)
    await context.bot.send_message(chat_id, text, reply_markup=kb, parse_mode="HTML")


async def get_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uname = await _check_access(update, context)
    if not uname:
        return
    api     = _get_api(context)
    chat_id = update.effective_chat.id
    n = parse_positive_ordinal_arg(context.args, default=1)
    if n is None:
        await context.bot.send_message(chat_id, "❌ Неверный номер конфига. Используйте: /get 1")
        return
    try:
        client = await asyncio.to_thread(_find_client_by_ordinal, api, uname, n)
        if client:
            conf_text = await asyncio.to_thread(api.get_configuration, client["id"])
            name      = str(client.get("name") or build_regular_client_name(uname, n))
            await send_conf_and_qr(
                chat_id, f"{name}.conf", conf_text, context.application,
                caption=f"🌐 <b>Обычный VPN</b> — конфиг <b>#{n}</b>",
            )
        else:
            await context.bot.send_message(chat_id, f"❌ Обычный конфиг #{n} не найден.")
    except Exception as e:
        await context.bot.send_message(chat_id, f"❌ Ошибка: {e}")
    text, kb = await asyncio.to_thread(regular_menu, api, uname)
    await context.bot.send_message(chat_id, text, reply_markup=kb, parse_mode="HTML")


async def get_smart_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uname = await _check_access(update, context)
    if not uname:
        return
    smart   = _get_smart(context)
    chat_id = update.effective_chat.id
    n = parse_positive_ordinal_arg(context.args, default=1)
    if n is None:
        await context.bot.send_message(chat_id, "❌ Неверный номер конфига. Используйте: /get_smart 1")
        return
    try:
        conf_text, client_name = await asyncio.to_thread(smart.get_client_conf, uname, n)
        await send_conf_and_qr(
            chat_id, f"{client_name}.conf", conf_text, context.application,
            caption=f"🧠 <b>Умный VPN</b> — конфиг <b>#{n}</b>",
        )
        await context.bot.send_message(chat_id, TG_PROXY_TEXT, parse_mode="HTML")
    except Exception as e:
        await context.bot.send_message(chat_id, f"❌ Ошибка: {e}")
    text, kb = await asyncio.to_thread(smart_menu, smart, uname)
    await context.bot.send_message(chat_id, text, reply_markup=kb, parse_mode="HTML")


async def usage_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not (is_allowed(update.effective_user) or is_admin(update.effective_user)):
        await context.bot.send_message(update.effective_chat.id, "⛔ Нет доступа к /usage")
        return
    try:
        api   = _get_api(context)
        rows  = await asyncio.to_thread(read_usage_from_api, api)
        total = sum(v for _, v in rows)
        lines = [
            "📊 <b>WG-Easy — трафик</b>",
            f"Всего: <b>{human_bytes(total)}</b>",
            "",
        ]
        for i, (name, b) in enumerate(rows[:30], 1):
            lines.append(f"{i}. <code>{name}</code>: {human_bytes(b)}")
        if len(rows) > 30:
            lines.append(f"…ещё {len(rows) - 30}")
        await context.bot.send_message(
            update.effective_chat.id, "\n".join(lines), parse_mode="HTML"
        )
    except Exception as e:
        await context.bot.send_message(update.effective_chat.id, f"❌ Ошибка /usage: {e}")


async def allow_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user):
        await context.bot.send_message(
            update.effective_chat.id,
            f"⛔ Только {ADMIN_ALLOW_USERNAME} может добавлять пользователей",
        )
        return
    if not context.args:
        await context.bot.send_message(update.effective_chat.id, "Использование: /allow @username")
        return
    target = normalize_username(context.args[0])
    try:
        created = add_allowed_username(target)
        msg = f"✅ Добавлен: {target}" if created else f"ℹ️ Уже есть: {target}"
        await context.bot.send_message(update.effective_chat.id, msg)
    except Exception as e:
        err = str(e)
        if "Read-only file system" in err:
            err = "allowed_users.txt смонтирован read-only. Уберите :ro в docker-compose."
        await context.bot.send_message(update.effective_chat.id, f"❌ Ошибка: {err}")


async def fundraise_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user):
        await context.bot.send_message(
            update.effective_chat.id,
            f"⛔ Команда доступна только {ADMIN_ALLOW_USERNAME}",
        )
        return

    if not FUNDRAISE_IMAGE_FILE.exists():
        await context.bot.send_message(
            update.effective_chat.id,
            f"❌ Не найдена картинка для рассылки: {FUNDRAISE_IMAGE_FILE.name}",
        )
        return

    if not re.fullmatch(r"https?://\S+", FUNDRAISE_URL):
        await context.bot.send_message(
            update.effective_chat.id,
            "❌ В коде задана некорректная FUNDRAISE_URL",
        )
        return

    image_bytes = FUNDRAISE_IMAGE_FILE.read_bytes()
    caption = f"🚗 <b>Сбор средств</b>\n\n{FUNDRAISE_BASE_TEXT}\n\n🔗 {FUNDRAISE_URL}"
    subscribers = load_subscriber_chat_ids()
    if not subscribers:
        await context.bot.send_message(update.effective_chat.id, "ℹ️ Подписчиков пока нет.")
        return

    sent = 0
    failed = 0
    removed = 0

    for chat_id in sorted(subscribers):
        try:
            photo_buf = io.BytesIO(image_bytes)
            photo_buf.name = FUNDRAISE_IMAGE_FILE.name
            await context.bot.send_photo(
                chat_id=chat_id,
                photo=InputFile(photo_buf, filename=FUNDRAISE_IMAGE_FILE.name),
                caption=caption,
                parse_mode="HTML",
            )
            sent += 1
        except Exception as e:
            failed += 1
            err = str(e).lower()
            if "forbidden" in err or "bot was blocked" in err or "chat not found" in err:
                remove_subscriber_chat_id(chat_id)
                removed += 1

    await context.bot.send_message(
        update.effective_chat.id,
        f"✅ Рассылка завершена. Отправлено: {sent}, ошибок: {failed}, удалено неактивных: {removed}.",
    )


# ══════════════════════════════════════════════════════════════════
#                     ОБРАБОТЧИК КНОПОК
# ══════════════════════════════════════════════════════════════════

async def on_button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    data = q.data or ""

    if data.startswith("req:"):
        if not is_admin(update.effective_user):
            await q.edit_message_text("⛔ Только администратор может обрабатывать заявки.")
            return
        parts = data.split(":")
        if len(parts) != 3:
            await q.edit_message_text("❌ Неверные данные заявки.")
            return

        action, raw_uid = parts[1], parts[2]
        try:
            target_uid = int(raw_uid)
        except ValueError:
            await q.edit_message_text("❌ Неверный ID пользователя.")
            return

        req = get_pending_request(target_uid)
        if not req:
            await q.edit_message_text("ℹ️ Заявка уже обработана или устарела.")
            return

        target_chat_id = int(req.get("chat_id") or 0)
        target_username = normalize_username(req.get("username") or "")

        if action == "approve":
            if not target_username:
                await q.edit_message_text(
                    "❌ Нельзя добавить: у пользователя нет username в Telegram."
                )
                return
            created = add_allowed_username(target_username)
            pop_pending_request(target_uid)
            await q.edit_message_text(
                f"✅ {'Добавлен' if created else 'Уже был в списке'}: {target_username}"
            )
            if target_chat_id:
                await context.bot.send_message(
                    target_chat_id,
                    "✅ Доступ одобрен. Нажмите /start чтобы открыть меню.",
                )
            return

        if action == "reject":
            pop_pending_request(target_uid)
            await q.edit_message_text(
                f"❌ Заявка отклонена: {target_username or target_uid}"
            )
            if target_chat_id:
                await context.bot.send_message(
                    target_chat_id,
                    "❌ Заявка отклонена администратором.",
                )
            return

        if action == "block":
            mark_user_blocked(target_uid, target_username)
            await q.edit_message_text(
                f"⛔ Пользователь заблокирован: {target_username or target_uid}"
            )
            if target_chat_id:
                await context.bot.send_message(
                    target_chat_id,
                    "⛔ Вы заблокированы и не можете отправлять новые заявки.",
                )
            return

        await q.edit_message_text("❌ Неизвестное действие.")
        return

    uname = await _check_callback_access(update, context)
    if not uname:
        return
    chat_id = update.effective_chat.id
    api     = _get_api(context)
    smart   = _get_smart(context)
    app     = context.application

    # ── навигация ────────────────────────────────────────────────

    if data == "menu:main":
        await _edit_or_send(q, chat_id, main_menu_text(), main_menu_keyboard(), app)
        return

    if data == "menu:regular":
        text, kb = await asyncio.to_thread(regular_menu, api, uname)
        await _edit_or_send(q, chat_id, text, kb, app)
        return

    if data == "menu:smart":
        text, kb = await asyncio.to_thread(smart_menu, smart, uname)
        await _edit_or_send(q, chat_id, text, kb, app)
        return

    if data == "menu:help":
        kb = InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Назад", callback_data="menu:main")]])
        await _edit_or_send(q, chat_id, HELP_TEXT, kb, app)
        return

    # ── получить обычный конфиг ──────────────────────────────────

    if data.startswith("get_n:"):
        try:
            n = int(data.split(":", 1)[1])
        except Exception:
            n = 1
        try:
            client = await asyncio.to_thread(_find_client_by_ordinal, api, uname, n)
            if client:
                conf_text = await asyncio.to_thread(api.get_configuration, client["id"])
                name      = str(client.get("name") or build_regular_client_name(uname, n))
                await send_conf_and_qr(
                    chat_id, f"{name}.conf", conf_text, app,
                    caption=f"🌐 <b>Обычный VPN</b> — конфиг <b>#{n}</b>",
                )
            else:
                await app.bot.send_message(chat_id, f"❌ Конфиг #{n} не найден.")
        except Exception as e:
            await app.bot.send_message(chat_id, f"❌ Ошибка: {e}")
        text, kb = await asyncio.to_thread(regular_menu, api, uname)
        await _edit_or_send(q, chat_id, text, kb, app)
        return

    # ── создать новый обычный конфиг ─────────────────────────────

    if data == "new_conf":
        try:
            ords  = await asyncio.to_thread(list_user_ordinals, api, uname)
            limit = max_configs_for(uname)
            if limit is not None and len(ords) >= limit:
                await app.bot.send_message(chat_id, f"⚠️ Достигнут лимит {limit} конфигов.")
            else:
                new_n       = (max(ords) + 1) if ords else 1
                client_name = build_regular_client_name(uname, new_n)
                created   = await asyncio.to_thread(api.create_client, client_name)
                conf_text = await asyncio.to_thread(api.get_configuration, created["id"])
                await send_conf_and_qr(
                    chat_id, f"{client_name}.conf", conf_text, app,
                    caption=f"🌐 <b>Обычный VPN</b> — новый конфиг <b>#{new_n}</b>",
                )
        except Exception as e:
            await app.bot.send_message(chat_id, f"❌ Ошибка: {e}")
        text, kb = await asyncio.to_thread(regular_menu, api, uname)
        await _edit_or_send(q, chat_id, text, kb, app)
        return

    # ── получить умный конфиг ────────────────────────────────────

    if data.startswith("get_smart:"):
        try:
            n = int(data.split(":", 1)[1])
        except Exception:
            n = 1
        try:
            conf_text, client_name = await asyncio.to_thread(smart.get_client_conf, uname, n)
            await send_conf_and_qr(
                chat_id, f"{client_name}.conf", conf_text, app,
                caption=f"🧠 <b>Умный VPN</b> — конфиг <b>#{n}</b>",
            )
            await app.bot.send_message(chat_id, TG_PROXY_TEXT, parse_mode="HTML")
        except Exception as e:
            await app.bot.send_message(chat_id, f"❌ Ошибка: {e}")
        text, kb = await asyncio.to_thread(smart_menu, smart, uname)
        await _edit_or_send(q, chat_id, text, kb, app)
        return

    # ── создать новый умный конфиг ───────────────────────────────

    if data == "new_smart":
        try:
            ords  = await asyncio.to_thread(smart.list_user_ordinals, uname)
            limit = max_configs_for(uname)
            if limit is not None and len(ords) >= limit:
                await app.bot.send_message(chat_id, f"⚠️ Достигнут лимит {limit} умных конфигов.")
            else:
                new_n = (max(ords) + 1) if ords else 1
                conf_text, client_name = await asyncio.to_thread(smart.create_client, uname, new_n)
                await send_conf_and_qr(
                    chat_id, f"{client_name}.conf", conf_text, app,
                    caption=f"🧠 <b>Умный VPN</b> — новый конфиг <b>#{new_n}</b>",
                )
                await app.bot.send_message(chat_id, TG_PROXY_TEXT, parse_mode="HTML")
        except Exception as e:
            await app.bot.send_message(chat_id, f"❌ Ошибка: {e}")
        text, kb = await asyncio.to_thread(smart_menu, smart, uname)
        await _edit_or_send(q, chat_id, text, kb, app)
        return


# ══════════════════════════════════════════════════════════════════
#                          ЗАПУСК
# ══════════════════════════════════════════════════════════════════

def run_bot():
    app = ApplicationBuilder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start",     start))
    app.add_handler(CommandHandler("help",      help_cmd))
    app.add_handler(CommandHandler("new",       new_cmd))
    app.add_handler(CommandHandler("new_smart", new_smart_cmd))
    app.add_handler(CommandHandler("get",       get_cmd))
    app.add_handler(CommandHandler("get_smart", get_smart_cmd))
    app.add_handler(CommandHandler("usage",     usage_cmd))
    app.add_handler(CommandHandler("allow",     allow_cmd))
    app.add_handler(CommandHandler("fundraise", fundraise_cmd))
    app.add_handler(CallbackQueryHandler(on_button))

    if WEBHOOK_URL:
        log.info("Starting webhook mode: %s (port %d)", WEBHOOK_URL, WEBHOOK_PORT)
        app.run_webhook(
            listen="0.0.0.0",
            port=WEBHOOK_PORT,
            url_path=BOT_TOKEN,
            webhook_url=f"{WEBHOOK_URL}/{BOT_TOKEN}",
            secret_token=WEBHOOK_SECRET,
            drop_pending_updates=True,
        )
    else:
        log.info("Starting polling mode.")
        app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    run_bot()

# pywg — Telegram-бот для управления VPN

Telegram-бот для выдачи WireGuard-конфигов пользователям через [wg-easy](https://github.com/wg-easy/wg-easy) API. Поддерживает AmneziaWG обфускацию, Xray VLESS+Reality прокси, автопереключение между exit-серверами и смарт-роутинг.

## Что умеет

- Пользователь пишет боту — получает QR-код с готовым `.conf` файлом
- Белый список пользователей (`allowed_users.txt`) и список без лимита (`unlimited_users.txt`)
- Максимум N конфигов на пользователя (настраивается в `.env`)
- Администратор получает уведомления о новых запросах
- Автопереключение между exit-серверами (`awg_monitor.py`) по latency/доступности
- Смарт-роутинг: заблокированные домены идут через VPN, остальной трафик — напрямую

## Архитектура

```
Пользователь Telegram
       ↓
  Telegram Bot (bot_api.py)
       ↓
  wg-easy API (51821)       ← управляет WireGuard конфигами
       ↓
  Xray VLESS+Reality        ← прокси для Telegram API (если РФ-сервер)
       ↓
  AmneziaWG туннель         ← обфусцированный WireGuard до exit-сервера
       ↓
  Exit VPS (зарубежный)
```

### Компоненты

| Компонент | Назначение |
|-----------|-----------|
| `bot_api.py` | Telegram-бот, выдаёт WG-конфиги пользователям |
| `awg_monitor.py` | Мониторинг и автопереключение между AmneziaWG серверами |
| `docker-compose.yml` | Docker-стек: `wg-bot` + `xray-proxy` |
| `xray/config.json` | Конфиг клиентского Xray (VLESS+Reality outbound) |

## Быстрый старт

### 1. Подготовка сервера

```bash
# Первоначальная настройка нового VPS (пользователь, UFW, Docker)
bash initserv.sh
```

### 2. Настройка exit-сервера (зарубежный VPS)

```bash
# Установка AmneziaWG сервера + Xray VLESS+Reality
bash awgsetup.sh

# Получить строку подключения для servers.conf (запускать на exit-сервере)
bash awggetstring.sh
```

### 3. Настройка хаб-сервера (опционально, для смарт-роутинга)

```bash
# Инициализация хаба: AWG-клиент + wg-smart сервер + dnsmasq + nftables
bash ru-hub-init.sh --host YOUR_HUB_IP --alias myhub
```

### 4. Деплой бота

```bash
cp .env.example .env
# Заполни .env своими значениями

# Деплой на основной VPS
REMOTE_HOST=YOUR_VPS_IP bash deploy.sh

# Или запустить локально (для разработки)
docker compose up -d
```

### 5. awg_monitor — автопереключение серверов

Заполни `/etc/amnezia/amneziawg/servers.conf`:
```
# Формат: ALIAS|AWG_IP:PORT|AWG_PUBKEY|XRAY_IP|XRAY_PORT|XRAY_UUID|XRAY_PUBKEY|XRAY_SHORTID
server1|92.112.1.1:51820|<pubkey>|92.112.1.1|2053|<uuid>|<xray_pubkey>|<shortid>
server2|5.145.1.1:51820|<pubkey>|5.145.1.1|8443|<uuid>|<xray_pubkey>|<shortid>
```

Запуск вручную:
```bash
python3 awg_monitor.py --status   # текущее состояние
python3 awg_monitor.py --force    # переключить на лучший прямо сейчас
python3 awg_monitor.py --notify-test  # тест Telegram-уведомлений
```

Cron (каждые 5 минут):
```bash
*/5 * * * * cd /home/pot/pywg && /home/pot/pywg/.venv/bin/python awg_monitor.py >> /var/log/awg-monitor.log 2>&1
```

## Конфигурация

Скопируй `.env.example` в `.env` и заполни:

```env
BOT_TOKEN=         # Токен от @BotFather
WG_PASSWORD=       # Пароль wg-easy
WG_API_BASE=       # URL API wg-easy (http://127.0.0.1:51821/api)
ADMIN_USERNAME=    # Username администратора (без @)
TG_ADMIN_CHAT_ID=  # Chat ID для уведомлений
HTTP_PROXY=        # Прокси для Telegram API (если сервер в РФ)
WEBHOOK_URL=       # https://bot.YOUR_DOMAIN (опционально)
```

## Скрипты

| Скрипт | Назначение |
|--------|-----------|
| `initserv.sh` | Первичная настройка VPS: пользователь, SSH hardening, UFW, Docker |
| `awgsetup.sh` | Установка AmneziaWG сервера + Xray VLESS+Reality на exit-VPS |
| `awggetstring.sh` | Генерирует строку для `servers.conf` (запускать на exit-сервере) |
| `awg-gen-seeds.sh` | Генерация AWG obfuscation seeds (должны совпадать клиент/сервер) |
| `ru-hub-init.sh` | Инициализация хаб-сервера (AWG-клиент + wg-smart + dnsmasq + nftables) |
| `xray-multi-instance.sh` | Установка нескольких Xray-инстансов на exit-VPS (разные порты) |
| `deploy.sh` | Деплой бота на основной VPS |
| `deploy-ru.sh` | Управление RU-хабом (статус, перезапуск, добавление AWG peer) |
| `deploy-vdsina.sh` | Деплой бота + smart-доменов на хаб-VPS |
| `build-smart-domains.sh` | Генерация `smart-domains.conf` из `seeds.txt` |

## Смарт-роутинг (split-tunnel)

`seeds.txt` — список доменов, которые должны идти через VPN. Из него генерируется `smart-domains.conf` — конфиг для dnsmasq с nftset-правилами.

```bash
# Сгенерировать конфиг из seeds.txt
bash build-smart-domains.sh seeds.txt smart-domains.conf

# Задеплоить на хаб
bash deploy-vdsina.sh --sync-domains
```

## Webhook через Cloudflare Tunnel (для РФ-серверов)

Если Telegram не может достучаться до сервера напрямую (например, IP заблокирован):

```bash
# Запустить cloudflared на сервере
docker run -d \
  --name cloudflared \
  --restart unless-stopped \
  --network host \
  cloudflare/cloudflared:latest \
  tunnel --no-autoupdate run --token YOUR_TUNNEL_TOKEN
```

В `.env`:
```env
WEBHOOK_URL=https://bot.YOUR_DOMAIN
WEBHOOK_PORT=8443
WEBHOOK_SECRET=random_secret_string
```

Преимущества перед прямым Nginx: не нужен белый IP, Telegram не обращается к серверу напрямую, автоматический SSL.

## Файлы данных

| Файл | Назначение |
|------|-----------|
| `allowed_users.txt` | Разрешённые Telegram-пользователи (username без @) |
| `unlimited_users.txt` | Пользователи без лимита конфигов |
| `subscribers.txt` | Chat ID подписчиков рассылки (заполняется ботом) |
| `seeds.txt` | Домены для смарт-роутинга |
| `xray/config.json` | Конфиг Xray-клиента (заполни реальными данными exit-сервера) |

> **⚠️ Важно:** Никогда не коммить `.env` — он в `.gitignore`. Используй `.env.example` как шаблон.

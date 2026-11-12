#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  deploy.sh — поднять VLESS + XTLS-Reality (Vision) одной командой.
#
#  Что делает:
#    1. Проверяет наличие Docker + docker compose.
#    2. Генерирует секреты (UUID, x25519-пара, shortId) в .env — один раз,
#       при повторных запусках переиспользует существующие.
#    3. Рендерит config/config.json из .env.
#    4. Валидирует конфиг через `xray -test` ДО запуска.
#    5. Поднимает контейнер (docker compose up -d).
#    6. Печатает VLESS-ссылку и QR-код для клиентов (Hiddify / v2rayNG / Streisand).
#
#  Повторный запуск безопасен (идемпотентность): секреты не меняются,
#  конфиг перерисовывается, контейнер обновляется при изменениях.
#
#  Сбросить и перегенерировать всё заново:  ./deploy.sh --regen
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"

# ─── Значения по умолчанию ───────────────────────────────────────────────────
XRAY_IMAGE="ghcr.io/xtls/xray-core:26.11.9"
LISTEN_PORT="443"
REALITY_SNI="www.nvidia.com"
REALITY_DEST="www.nvidia.com:443"
SERVER_HOST=""
UUID=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
SHORT_ID=""
REGEN="false"
LABEL="AnyModel-RU-Reality"

# ─── Вывод ───────────────────────────────────────────────────────────────────
c_reset=$'\033[0m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_bld=$'\033[1m'
log()  { printf '%s[ * ]%s %s\n'  "$c_grn" "$c_reset" "$*"; }
warn() { printf '%s[ ! ]%s %s\n'  "$c_yel" "$c_reset" "$*" >&2; }
die()  { printf '%s[ x ]%s %s\n'  "$c_red" "$c_reset" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Использование: ./deploy.sh [опции]

  --host <IP|домен>     публичный адрес сервера (по умолчанию определяется сам)
  --port <N>            публичный порт (по умолчанию 443)
  --sni  <домен>        домен-маскировка для ClientHello (по умолчанию www.nvidia.com)
  --dest <домен:443>    куда сервер ходит за TLS-рукопожатием (по умолчанию www.nvidia.com:443)
  --regen               перегенерировать все секреты заново (старый клиентский конфиг станет невалиден)
  -h, --help            эта справка

Совет: прежде чем менять --sni/--dest, проверьте домен:  ./scripts/check-dest.sh <домен>
EOF
}

# ─── Загрузка существующего .env (секреты + прежние настройки) ───────────────
# Делаем ДО разбора аргументов, чтобы флаги (--sni/--dest/--host/--port)
# перекрывали сохранённые значения, а не наоборот.
if [ -f "$ROOT/.env" ]; then
  log "Нашёл .env — переиспользую существующие секреты и настройки."
  # shellcheck disable=SC1091
  set -a; . "$ROOT/.env"; set +a
fi

# ─── Разбор аргументов ───────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --host) SERVER_HOST="${2:?}"; shift 2;;
    --port) LISTEN_PORT="${2:?}"; shift 2;;
    --sni)  REALITY_SNI="${2:?}"; shift 2;;
    --dest) REALITY_DEST="${2:?}"; shift 2;;
    --regen) REGEN="true"; shift;;
    -h|--help) usage; exit 0;;
    *) die "неизвестный аргумент: $1 (см. --help)";;
  esac
done

# ─── Проверка окружения ──────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || die "Docker не установлен. См. https://docs.docker.com/engine/install/"
docker info >/dev/null 2>&1 || die "Docker-демон недоступен (нет прав? запусти через sudo или добавь юзера в группу docker)."
if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  die "Нужен docker compose (plugin v2) или docker-compose."
fi

# Запуск разовых подкоманд xray (uuid, x25519, -test) в одноразовом контейнере.
xray_run() { docker run --rm --entrypoint xray "$XRAY_IMAGE" "$@"; }

if [ "$REGEN" = "true" ]; then
  warn "--regen: сбрасываю секреты, старый клиентский конфиг перестанет работать."
  UUID=""; REALITY_PRIVATE_KEY=""; REALITY_PUBLIC_KEY=""; SHORT_ID=""
fi

# ─── Генерация недостающих секретов ──────────────────────────────────────────
log "Проверяю наличие образа $XRAY_IMAGE ..."
docker image inspect "$XRAY_IMAGE" >/dev/null 2>&1 || { log "Тяну образ..."; docker pull "$XRAY_IMAGE" >/dev/null; }

if [ -z "${UUID:-}" ]; then
  UUID="$(xray_run uuid | tr -d '\r\n')"
  log "Сгенерирован UUID."
fi

if [ -z "${REALITY_PRIVATE_KEY:-}" ] || [ -z "${REALITY_PUBLIC_KEY:-}" ]; then
  keys="$(xray_run x25519)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$keys" | grep -i 'private' | awk -F': ' '{print $NF; exit}' | tr -d '\r\n ')"
  REALITY_PUBLIC_KEY="$(printf '%s\n'  "$keys" | grep -i 'public'  | awk -F': ' '{print $NF; exit}' | tr -d '\r\n ')"
  [ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] || die "не удалось разобрать x25519-ключи"
  log "Сгенерирована x25519-пара."
fi

if [ -z "${SHORT_ID:-}" ]; then
  SHORT_ID="$(od -An -tx1 -N8 /dev/urandom | tr -d ' \r\n')"
  log "Сгенерирован shortId."
fi

# ─── Определение внешнего адреса ─────────────────────────────────────────────
if [ -z "${SERVER_HOST:-}" ]; then
  log "SERVER_HOST не задан — определяю внешний IP..."
  for svc in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
    SERVER_HOST="$(curl -fsS --max-time 8 "$svc" 2>/dev/null | tr -d '\r\n ' || true)"
    [ -n "$SERVER_HOST" ] && break
  done
  [ -n "$SERVER_HOST" ] || die "не смог определить внешний IP — задай вручную: ./deploy.sh --host <IP>"
  log "Внешний адрес: $SERVER_HOST"
fi

# ─── Сохранение .env ─────────────────────────────────────────────────────────
umask 077
cat > "$ROOT/.env" <<EOF
# Сгенерировано deploy.sh $(date -u +%Y-%m-%dT%H:%M:%SZ). НЕ КОММИТИТЬ.
XRAY_IMAGE=$XRAY_IMAGE
SERVER_HOST=$SERVER_HOST
LISTEN_PORT=$LISTEN_PORT
REALITY_SNI=$REALITY_SNI
REALITY_DEST=$REALITY_DEST
UUID=$UUID
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
SHORT_ID=$SHORT_ID
EOF
log ".env сохранён (права 600)."

# ─── Рендер серверного конфига ───────────────────────────────────────────────
mkdir -p "$ROOT/config"
cat > "$ROOT/config/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": 8443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$REALITY_DEST",
          "xver": 0,
          "serverNames": [ "$REALITY_SNI" ],
          "privateKey": "$REALITY_PRIVATE_KEY",
          "shortIds": [ "$SHORT_ID" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ]
}
EOF
log "config/config.json отрендерен."

# ─── Валидация конфига до запуска ────────────────────────────────────────────
log "Проверяю конфиг (xray -test)..."
if ! docker run --rm --user 0:0 --entrypoint xray -v "$ROOT/config":/etc/xray:ro "$XRAY_IMAGE" \
      run -test -config /etc/xray/config.json >/tmp/xray-test.log 2>&1; then
  cat /tmp/xray-test.log >&2
  die "конфиг не прошёл валидацию"
fi
log "Конфиг валиден."

# ─── Запуск ──────────────────────────────────────────────────────────────────
log "Поднимаю контейнер..."
LISTEN_PORT="$LISTEN_PORT" XRAY_IMAGE="$XRAY_IMAGE" "${DC[@]}" up -d
sleep 2
# Проверяем через `docker ps` (а не `compose ps --status`): флаг --status есть
# только в compose v2, а мы допускаем фоллбэк на legacy docker-compose.
if ! docker ps --filter 'name=^/reality-xray$' --filter 'status=running' --format '{{.Names}}' | grep -q .; then
  warn "Контейнер не в статусе running — смотрим логи:"
  "${DC[@]}" logs --tail 30 || true
  die "запуск не удался"
fi
log "Контейнер запущен."

# ─── Клиентская ссылка + QR ──────────────────────────────────────────────────
VLESS_URL="vless://${UUID}@${SERVER_HOST}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F&type=tcp#${LABEL}"
printf '%s\n' "$VLESS_URL" > "$ROOT/client-link.txt"

echo
printf '%s══════════════════════════════════════════════════════════════════%s\n' "$c_bld" "$c_reset"
printf '%s  Туннель поднят. Клиентский конфиг ниже.%s\n' "$c_grn$c_bld" "$c_reset"
printf '%s══════════════════════════════════════════════════════════════════%s\n' "$c_bld" "$c_reset"
echo
echo "  Сервер : ${SERVER_HOST}:${LISTEN_PORT}"
echo "  SNI    : ${REALITY_SNI}"
echo "  Ядро   : ${XRAY_IMAGE}"
echo
echo "  VLESS-ссылка (также сохранена в client-link.txt):"
echo
printf '  %s\n' "$VLESS_URL"
echo

if command -v qrencode >/dev/null 2>&1; then
  echo "  QR-код (отсканируй камерой в Hiddify / v2rayNG / Streisand):"
  echo
  qrencode -t ANSIUTF8 "$VLESS_URL"
  qrencode -o "$ROOT/client-qr.png" "$VLESS_URL" 2>/dev/null && echo "  (также сохранён client-qr.png)"
else
  warn "qrencode не установлен — QR не нарисован. Поставь 'apt install -y qrencode' и запусти ./scripts/show-link.sh"
fi
echo
log "Готово. Проверить работу туннеля из вне можно так: ./scripts/bench/client-bench.sh --smoke"

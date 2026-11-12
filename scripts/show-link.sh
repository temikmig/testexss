#!/usr/bin/env bash
# Печатает VLESS-ссылку и QR из уже сгенерированного .env.
# Удобно, когда туннель давно поднят, а конфиг нужен ещё раз.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "Нет .env — сначала запусти ./deploy.sh" >&2; exit 1; }
set -a; . ./.env; set +a

LABEL="AnyModel-RU-Reality"
VLESS_URL="vless://${UUID}@${SERVER_HOST}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F&type=tcp#${LABEL}"

printf '%s\n' "$VLESS_URL" > client-link.txt
echo "Сервер: ${SERVER_HOST}:${LISTEN_PORT}  |  SNI: ${REALITY_SNI}"
echo
printf '%s\n\n' "$VLESS_URL"

if command -v qrencode >/dev/null 2>&1; then
  qrencode -t ANSIUTF8 "$VLESS_URL"
  qrencode -o client-qr.png "$VLESS_URL" 2>/dev/null && echo "(сохранён client-qr.png)"
else
  echo "qrencode не установлен — поставь 'apt install -y qrencode' для QR-кода."
fi

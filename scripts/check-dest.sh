#!/usr/bin/env bash
# Проверяет пригодность домена как «донора» для маскировки Reality.
# Хороший кандидат должен отвечать: TLS 1.3 + (желательно) пост-квантовый обмен,
# принимать соединение с SNI, не быть вашим доменом и в идеале жить в той же ASN,
# что и ваш VPS.
#
# Использование:  ./scripts/check-dest.sh www.nvidia.com [ещё домены...]
set -euo pipefail
cd "$(dirname "$0")/.."

XRAY_IMAGE="${XRAY_IMAGE:-ghcr.io/xtls/xray-core:26.11.9}"
[ -f .env ] && { set -a; . ./.env; set +a; }

[ $# -ge 1 ] || { echo "Укажи хотя бы один домен. Пример: $0 www.nvidia.com www.samsung.com" >&2; exit 1; }

docker image inspect "$XRAY_IMAGE" >/dev/null 2>&1 || docker pull "$XRAY_IMAGE" >/dev/null

for d in "$@"; do
  echo "──────────────────────────────────────────────────────────────"
  echo "Проверяю: $d"
  out="$(docker run --rm --entrypoint xray "$XRAY_IMAGE" tls ping "$d" 2>&1 || true)"
  echo "$out" | grep -iE 'TLS Version|Post-Quantum|Handshake (succeeded|failure)|Certificate chain' \
    | sed 's/^/   /' || true
  if echo "$out" | grep -qi 'TLS Version:.*1.3'; then
    echo "   => TLS 1.3: OK"
  else
    echo "   => TLS 1.3 не обнаружен — домен НЕ подходит."
  fi
done
echo "──────────────────────────────────────────────────────────────"
echo "Вердикт: бери домен с TLS 1.3 (а лучше и с Post-Quantum X25519MLKEM768),"
echo "который НЕ принадлежит тебе и живёт рядом по сети с твоим VPS."

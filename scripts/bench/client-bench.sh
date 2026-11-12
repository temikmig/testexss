#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  client-bench.sh — замеры туннеля с КЛИЕНТСКОЙ стороны.
#
#  Поднимает временный Xray-клиент (SOCKS5 на 127.0.0.1:10808), который дозванивается
#  до сервера по VLESS+Reality, и гоняет через него замеры:
#     • пропускная способность (direct vs tunnel)
#     • задержка под нагрузкой (connect/TTFB/total)
#     • масштабирование по числу параллельных потоков
#
#  Запускать на клиентской машине (своей или на втором VPS) из каталога с .env.
#  Чтобы корректно снять CPU/RAM сервера — параллельно запусти на сервере
#  scripts/bench/server-monitor.sh.
#
#  Режимы:
#     ./scripts/bench/client-bench.sh --smoke   # быстрая проверка, что туннель жив
#     ./scripts/bench/client-bench.sh           # полный бенчмарк
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/../.."

[ -f .env ] || { echo "Нет .env — нужен сгенерированный конфиг (скопируй .env с сервера или запусти ./deploy.sh)" >&2; exit 1; }
set -a; . ./.env; set +a

XRAY_IMAGE="${XRAY_IMAGE:-ghcr.io/xtls/xray-core:26.11.9}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
# Архитектура образа. Образ мультиарх, но если в локальном кэше уже лежит чужой
# arch (напр. amd64 на Apple Silicon), docker возьмёт его и клиент пойдёт через
# QEMU — замеры будут занижены. Тогда: XRAY_PLATFORM=linux/arm64 ./client-bench.sh
XRAY_PLATFORM="${XRAY_PLATFORM:-}"
PROXY="--socks5-hostname 127.0.0.1:${SOCKS_PORT}"
CLIENT="reality-bench-client"
CLIENT_CFG="bench/client-config.json"
OUTDIR="bench/out"
MODE="${1:-full}"

# Параметры нагрузки (можно переопределить переменными окружения)
THROUGHPUT_BYTES="${THROUGHPUT_BYTES:-52428800}"   # 50 MiB на одиночный замер
STREAM_BYTES="${STREAM_BYTES:-20971520}"           # 20 MiB на поток в sweep
LAT_SAMPLES="${LAT_SAMPLES:-20}"
CONCURRENCY_LEVELS="${CONCURRENCY_LEVELS:-1 4 16 64 128}"
DL_URL="${DL_URL:-https://speed.cloudflare.com/__down?bytes=}"
LAT_URL="${LAT_URL:-https://www.google.com/generate_204}"

mkdir -p "$OUTDIR"
STAMP="$(date -u +%Y%m%d-%H%M%S)"

cleanup() { docker rm -f "$CLIENT" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# ─── Рендер клиентского конфига ──────────────────────────────────────────────
cat > "$CLIENT_CFG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "listen": "0.0.0.0", "port": 10808, "protocol": "socks",
      "settings": { "udp": true }, "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] } }
  ],
  "outbounds": [
    { "protocol": "vless",
      "settings": { "vnext": [ { "address": "$SERVER_HOST", "port": $LISTEN_PORT,
        "users": [ { "id": "$UUID", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
      "streamSettings": { "network": "tcp", "security": "reality",
        "realitySettings": { "serverName": "$REALITY_SNI", "fingerprint": "chrome",
          "publicKey": "$REALITY_PUBLIC_KEY", "shortId": "$SHORT_ID", "spiderX": "/" } } }
  ]
}
EOF

echo "[*] Поднимаю клиент ($CLIENT) -> $SERVER_HOST:$LISTEN_PORT, SOCKS5 на 127.0.0.1:$SOCKS_PORT"
cleanup
docker run -d --name "$CLIENT" \
  ${XRAY_PLATFORM:+--platform "$XRAY_PLATFORM"} \
  --add-host=host.docker.internal:host-gateway \
  -p "127.0.0.1:${SOCKS_PORT}:10808" \
  -v "$(pwd)/$CLIENT_CFG":/etc/xray/config.json:ro \
  --entrypoint xray "$XRAY_IMAGE" run -config /etc/xray/config.json >/dev/null

# ─── Ждём готовности SOCKS ───────────────────────────────────────────────────
echo -n "[*] Жду готовности туннеля"
UP="false"
for i in $(seq 1 20); do
  if curl -s $PROXY --max-time 6 -o /dev/null "https://www.google.com/generate_204" 2>/dev/null; then UP="true"; break; fi
  echo -n "."; sleep 1
done
echo
if [ "$UP" != "true" ]; then
  echo "[x] Туннель не поднялся. Логи клиента:" >&2
  docker logs --tail 30 "$CLIENT" >&2 || true
  exit 1
fi

# ─── SMOKE: проверка выхода трафика через сервер ─────────────────────────────
IP_DIRECT="$(curl -s --max-time 10 https://api.ipify.org || echo '?')"
IP_TUNNEL="$(curl -s $PROXY --max-time 10 https://api.ipify.org || echo '?')"
echo "─────────────────────────────────────────────"
echo "  Внешний IP напрямую : $IP_DIRECT"
echo "  Внешний IP в туннеле : $IP_TUNNEL   (должен совпадать с IP сервера)"
echo "─────────────────────────────────────────────"
if [ "$MODE" = "--smoke" ] || [ "$MODE" = "smoke" ]; then
  [ "$IP_TUNNEL" != "?" ] && echo "[OK] Туннель работает: трафик выходит через сервер." || { echo "[x] Туннель не отдаёт трафик" >&2; exit 1; }
  exit 0
fi

# ─── Хелперы ─────────────────────────────────────────────────────────────────
# Пропускная способность: печатает Мбит/с для скачивания $1 байт ($2 = "" direct | $PROXY)
dl_mbps() {
  local bytes="$1"; shift
  local spd
  spd="$(curl -s "$@" --max-time 120 -o /dev/null -w '%{speed_download}' "${DL_URL}${bytes}" 2>/dev/null || echo 0)"
  awk -v s="$spd" 'BEGIN{printf "%.1f", s*8/1000000}'
}
# Задержка: печатает time_total в мс для одного запроса ($@ = прокси или пусто)
lat_ms() {
  local t
  t="$(curl -s "$@" --max-time 15 -o /dev/null -w '%{time_total}' "$LAT_URL" 2>/dev/null || echo 0)"
  awk -v t="$t" 'BEGIN{printf "%.0f", t*1000}'
}

# ─── 1. Пропускная способность ───────────────────────────────────────────────
echo
echo "== 1. Пропускная способность (${THROUGHPUT_BYTES} байт) =="
MB_DIRECT="$(dl_mbps "$THROUGHPUT_BYTES")"
MB_TUNNEL="$(dl_mbps "$THROUGHPUT_BYTES" $PROXY)"
printf "   direct : %s Мбит/с\n" "$MB_DIRECT"
printf "   tunnel : %s Мбит/с\n" "$MB_TUNNEL"

# ─── 2. Задержка (одиночные запросы) ─────────────────────────────────────────
echo
echo "== 2. Задержка, $LAT_SAMPLES запросов (min/avg/max, мс) =="
LATCSV="$OUTDIR/latency-$STAMP.csv"; echo "mode,ms" > "$LATCSV"
for mode in direct tunnel; do
  vals=()
  for i in $(seq 1 "$LAT_SAMPLES"); do
    if [ "$mode" = "tunnel" ]; then v="$(lat_ms $PROXY)"; else v="$(lat_ms)"; fi
    vals+=("$v"); echo "$mode,$v" >> "$LATCSV"
  done
  printf '%s\n' "${vals[@]}" | awk -v m="$mode" '{a[NR]=$1; s+=$1; if(min==""||$1<min)min=$1; if($1>max)max=$1}
    END{printf "   %-7s: min=%d  avg=%.0f  max=%d\n", m, min, s/NR, max}'
done

# ─── 3. Масштабирование по потокам ───────────────────────────────────────────
echo
echo "== 3. Параллельные потоки (по ${STREAM_BYTES} байт каждый, через туннель) =="
CONCCSV="$OUTDIR/concurrency-$STAMP.csv"; echo "streams,ok,failed,wall_s,aggregate_mbps" > "$CONCCSV"
printf "   %-8s %-6s %-8s %-9s %s\n" "потоки" "ok" "fail" "время,с" "сумм.Мбит/с"
for C in $CONCURRENCY_LEVELS; do
  tmp="$(mktemp -d)"
  start="$(date +%s.%N)"
  for n in $(seq 1 "$C"); do
    ( curl -s $PROXY --max-time 120 -o /dev/null -w '%{size_download}' "${DL_URL}${STREAM_BYTES}" > "$tmp/$n" 2>/dev/null || echo 0 > "$tmp/$n" ) &
  done
  wait
  end="$(date +%s.%N)"
  total_bytes=0; ok=0; fail=0
  for n in $(seq 1 "$C"); do
    b="$(cat "$tmp/$n" 2>/dev/null || echo 0)"; b="${b:-0}"
    if [ "$b" -ge "$STREAM_BYTES" ] 2>/dev/null; then ok=$((ok+1)); else fail=$((fail+1)); fi
    total_bytes=$((total_bytes + b))
  done
  rm -rf "$tmp"
  wall="$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.2f", b-a}')"
  mbps="$(awk -v tb="$total_bytes" -v w="$wall" 'BEGIN{if(w>0)printf "%.1f", tb*8/1000000/w; else print 0}')"
  printf "   %-8s %-6s %-8s %-9s %s\n" "$C" "$ok" "$fail" "$wall" "$mbps"
  echo "$C,$ok,$fail,$wall,$mbps" >> "$CONCCSV"
done

echo
echo "[*] Результаты сохранены:"
echo "    $LATCSV"
echo "    $CONCCSV"
echo "[*] CPU/RAM сервера за это время — в CSV от server-monitor.sh (запускался на сервере)."

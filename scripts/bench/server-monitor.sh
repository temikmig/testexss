#!/usr/bin/env bash
# Снимает утилизацию ресурсов контейнером reality-xray во время нагрузки.
# Запускать НА СЕРВЕРЕ (VPS) параллельно с client-bench.sh на клиенте.
#
# Использование:
#   ./scripts/bench/server-monitor.sh [длительность_сек] [интервал_сек] [файл.csv]
# По умолчанию: 120 сек, шаг 1 сек, вывод в bench/out/server-YYYYmmdd-HHMMSS.csv
set -euo pipefail
cd "$(dirname "$0")/../.."

DURATION="${1:-120}"
INTERVAL="${2:-1}"
OUT="${3:-bench/out/server-$(date -u +%Y%m%d-%H%M%S).csv}"
CONTAINER="reality-xray"
mkdir -p "$(dirname "$OUT")"

docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "Контейнер $CONTAINER не найден — сначала ./deploy.sh" >&2; exit 1; }

NPROC="$(nproc 2>/dev/null || echo '?')"
echo "ts_unix,cpu_pct,mem_used,mem_pct,net_io,block_io,load1" > "$OUT"
echo "Мониторю $CONTAINER $DURATION сек (шаг $INTERVAL с), ядер: $NPROC -> $OUT"
echo "Примечание: CPU% в docker stats считается относительно ВСЕХ ядер (100% = 1 ядро)."

END=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$END" ]; do
  TS=$(date +%s)
  LINE=$(docker stats --no-stream --format '{{.CPUPerc}};{{.MemUsage}};{{.MemPerc}};{{.NetIO}};{{.BlockIO}}' "$CONTAINER" 2>/dev/null || echo 'NA;NA;NA;NA;NA')
  LOAD1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 'NA')
  IFS=';' read -r CPU MEM MEMP NET BLK <<EOF
$LINE
EOF
  # Экранируем запятые внутри полей (docker пишет "12MiB / 512MiB")
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$TS" "${CPU// /}" "${MEM// /}" "${MEMP// /}" "${NET// /}" "${BLK// /}" "$LOAD1" >> "$OUT"
  sleep "$INTERVAL"
done

echo "Готово. Короткая сводка:"
awk -F, 'NR>1{gsub(/%/,"",$2); c=$2+0; if(c>max)max=c; sum+=c; n++} END{if(n)printf "  CPU%%: avg=%.1f max=%.1f  (замеров: %d)\n", sum/n, max, n}' "$OUT"
echo "  Пик памяти (поле mem_used):"
awk -F, 'NR>1{print $3}' "$OUT" | sort -h 2>/dev/null | tail -1 | sed 's/^/    /'

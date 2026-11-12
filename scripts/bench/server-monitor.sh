#!/usr/bin/env bash
# Снимает утилизацию ресурсов контейнером reality-xray во время нагрузки.
# Запускать НА СЕРВЕРЕ (VPS) параллельно с client-bench.sh на клиенте.
#
# Использование:
#   ./scripts/bench/server-monitor.sh [длительность_сек] [интервал_сек] [файл.csv]
# По умолчанию: 120 сек, шаг 1 сек, вывод в bench/out/server-YYYYmmdd-HHMMSS.csv
#
# ПОЧЕМУ cgroup, А НЕ `docker stats`: докеровский CPU% и NetIO — агрегаты, которые
# приходится парсить из текста ("12MiB / 512MiB"), а cgroup v2 и netns дают те же
# числа напрямую и без форматирования.
#
# ПОЧЕМУ СЫРЫЕ СЧЁТЧИКИ: в CSV пишутся абсолютные значения (мкс CPU, байты), а
# проценты и Мбит/с считаются постфактум из соседних строк. Сырьё нельзя испортить
# ошибкой в арифметике на горячем пути, и его всегда можно пересчитать заново.
#
# ГРАБЛЯ СИНХРОНИЗАЦИИ (стоила отладки 12.11.2026): если запускать монитор как
# `ssh host "nohup ./server-monitor.sh ... &"`, ssh может держать соединение
# десятки секунд, и окно монитора истекает ДО начала клиентской нагрузки — в CSV
# будет честный, но бесполезный простой. Запускать через `ssh -f` (или проверять
# по ts_ms, что окно накрыло прогон).
set -euo pipefail
cd "$(dirname "$0")/../.."

DURATION="${1:-120}"
INTERVAL="${2:-1}"
OUT="${3:-bench/out/server-$(date -u +%Y%m%d-%H%M%S).csv}"
CONTAINER="reality-xray"
mkdir -p "$(dirname "$OUT")"

docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "Контейнер $CONTAINER не найден — сначала ./deploy.sh" >&2; exit 1; }
PID="$(docker inspect -f '{{.State.Pid}}' "$CONTAINER")"
[ "$PID" != "0" ] || { echo "Контейнер $CONTAINER не запущен." >&2; exit 1; }
CG="$(awk -F: '{print $3; exit}' "/proc/$PID/cgroup")"
BASE="/sys/fs/cgroup${CG}"
CLK="$(getconf CLK_TCK)"
NPROC="$(nproc 2>/dev/null || echo 1)"

echo "ts_ms,cpu_usec,cpu_ticks,mem_bytes,rx_bytes,tx_bytes,load1" > "$OUT"
echo "Мониторю $CONTAINER $DURATION сек (шаг $INTERVAL с), ядер: $NPROC -> $OUT"
echo "Источник: cgroup v2 + /proc/$PID/stat + netns. В CSV сырые счётчики, проценты — в сводке."

END=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$END" ]; do
  TS_MS="$(date +%s%3N)"
  CPU_US="$(awk '/^usage_usec/{print $2; exit}' "$BASE/cpu.stat" 2>/dev/null || echo '')"
  CPU_TK="$(awk '{print $14+$15; exit}' "/proc/$PID/stat" 2>/dev/null || echo '')"
  MEM="$(cat "$BASE/memory.current" 2>/dev/null || echo '')"
  NET="$(nsenter -t "$PID" -n cat /proc/net/dev 2>/dev/null | awk '$1 ~ /^eth0:/{print $2","$10; exit}')"
  LOAD1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo '')"
  printf '%s,%s,%s,%s,%s,%s\n' "$TS_MS" "${CPU_US:-NA}" "${CPU_TK:-NA}" "${MEM:-NA}" "${NET:-NA,NA}" "${LOAD1:-NA}" >> "$OUT"
  sleep "$INTERVAL"
done

echo "Готово. Сводка (дельты между соседними замерами):"
awk -F, -v clk="$CLK" '
  NR<2 {next}
  $2=="NA" {bad++; next}
  {
    ts=$1/1000; cu=$2+0; mem=$4+0; rx=$5+0; tx=$6+0; l=$7+0;
    if (prev_ts!="") {
      dt = ts - prev_ts;
      if (dt > 0) {
        cpu = (cu - prev_cu)/10000/dt;          # usage_usec -> % одного ядра
        rxm = (rx - prev_rx)*8/1000000/dt;
        txm = (tx - prev_tx)*8/1000000/dt;
        n++; cs += cpu; if (cpu > cmax) cmax = cpu;
        if (rxm > rmax) rmax = rxm;
        if (txm > xmax) xmax = txm;
        if (txm > 1) { ln++; lcs += cpu; if (cpu > lcmax) lcmax = cpu; }
      }
    } else { rx_start = rx; tx_start = tx; }
    if (mem > mmax) mmax = mem;
    if (l > lomax) lomax = l;
    prev_ts=ts; prev_cu=cu; prev_rx=rx; prev_tx=tx; rx_end=rx; tx_end=tx;
  }
  END{
    if (!n) { print "  нет пригодных замеров" ; if (bad) printf "  строк NA: %d\n", bad; exit }
    printf "  CPU%%  (100%% = 1 ядро): avg %.2f  max %.2f   (интервалов: %d)\n", cs/n, cmax, n;
    if (ln) printf "  CPU%%  под нагрузкой:   avg %.2f  max %.2f   (интервалов с tx>1 Мбит/с: %d)\n", lcs/ln, lcmax, ln;
    else    printf "  CPU%%  под нагрузкой:   нагрузка не зафиксирована (tx нигде не превысил 1 Мбит/с)\n";
    printf "  RAM   пик:              %.1f MiB\n", mmax/1048576;
    printf "  Сеть  пик:              rx %.1f  tx %.1f Мбит/с\n", rmax, xmax;
    printf "  Сеть  всего за окно:    rx %.1f  tx %.1f MiB\n", (rx_end-rx_start)/1048576, (tx_end-tx_start)/1048576;
    printf "  load1 max:              %.2f\n", lomax;
    if (bad) printf "  (пропущено строк NA: %d)\n", bad;
  }' "$OUT"

#!/usr/bin/env bash
# Опциональный тюнинг ХОСТА (не контейнера) под высокую пропускную способность:
# включает BBR и fq-qdisc + расширяет сетевые буферы. Меняет системные sysctl,
# поэтому вынесено в отдельный осознанный шаг. Требует root.
#
# Откатить: удалить файл /etc/sysctl.d/99-reality-tune.conf и перезагрузить sysctl.
set -euo pipefail

[ "$(id -u)" = "0" ] || { echo "Запускай под root: sudo $0" >&2; exit 1; }

CONF=/etc/sysctl.d/99-reality-tune.conf
cat > "$CONF" <<'EOF'
# Тюнинг под VLESS/Reality-туннель (добавлено scripts/tune-host.sh)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = 8192
EOF

sysctl --system >/dev/null

# net.core.default_qdisc действует только на НОВЫЕ интерфейсы: на уже поднятом eth0
# остался бы fq_codel до перезагрузки. Применяем fq к активному интерфейсу сразу.
IFACE="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
if [ -n "${IFACE:-}" ] && command -v tc >/dev/null 2>&1; then
  if tc qdisc replace dev "$IFACE" root fq 2>/dev/null; then
    echo "qdisc fq применён к $IFACE (без перезагрузки)."
  else
    echo "ВНИМАНИЕ: не удалось применить fq к $IFACE — вступит в силу после перезагрузки." >&2
  fi
fi

echo "Применено. Текущий congestion control: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "qdisc по умолчанию: $(sysctl -n net.core.default_qdisc)"
if ! sysctl -n net.ipv4.tcp_congestion_control | grep -q bbr; then
  echo "ВНИМАНИЕ: BBR не активировался — ядро может не поддерживать tcp_bbr." >&2
fi

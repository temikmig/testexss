# Анти-DPI туннель: VLESS + XTLS-Reality (Vision)

Отказоустойчивый сетевой доступ для пользователей из РФ поверх ТСПУ/DPI.
Поднимается на чистом VPS одной командой, клиент подключается стандартными
приложениями (Hiddify, v2rayNG, Streisand) по VLESS-ссылке или QR.

Ядро — [Xray-core](https://github.com/XTLS/Xray-core) (пин `v26.11.9`) в Docker.
Выбор протокола и подробный разбор устойчивости к фильтрации — в [отчёте](report/REPORT.md).

---

## Почему именно так (коротко)

- **VLESS + Reality** на сегодня — то, что реально живёт под ТСПУ: нет собственного
  домена и сертификата, сервер «одалживает» TLS-рукопожатие настоящего крупного сайта,
  поэтому для DPI и активного зондирования соединение неотличимо от похода на этот сайт.
- **Vision (`xtls-rprx-vision`)** сглаживает размеры/тайминги пакетов, уменьшая
  признаки «TLS-в-TLS».
- Классика (WireGuard, OpenVPN, Shadowsocks-legacy) детектируется по сигнатурам и
  статистике — см. отчёт.

---

## Требования

- VPS с Linux (Ubuntu/Debian и т.п.), 1 vCPU / 1 GB RAM достаточно.
- Root или пользователь в группе `docker`.
- Открытый **443/tcp** наружу.
- Docker + docker compose. Если их нет:
  ```bash
  curl -fsSL https://get.docker.com | sh
  ```

## Быстрый старт (2 команды)

```bash
git clone https://github.com/temikmig/testexss.git && cd testexss
sudo ./deploy.sh
```

Скрипт сам: сгенерирует секреты (UUID, x25519-пару, shortId), отрендерит конфиг,
проверит его `xray -test`, поднимет контейнер и напечатает **VLESS-ссылку + QR-код**.

Хочешь QR в терминале — поставь `qrencode` (`apt install -y qrencode`) до запуска.

### Полезные опции

```bash
sudo ./deploy.sh --sni www.samsung.com --dest www.samsung.com:443   # другой домен-маскировка
sudo ./deploy.sh --host 203.0.113.10                                # задать адрес вручную
sudo ./deploy.sh --port 443                                         # порт (по умолчанию 443)
sudo ./deploy.sh --regen                                            # перегенерировать все секреты
```

Показать ссылку/QR ещё раз (туннель уже поднят):
```bash
./scripts/show-link.sh
```

---

## Подключение клиента

1. Скопируй VLESS-ссылку из вывода (или `client-link.txt`), либо отсканируй QR.
2. Вставь в **Hiddify** / **v2rayNG** / **Streisand** (импорт из буфера / скан QR).
3. Готово — весь трафик идёт через туннель.

## Выбор домена-маскировки

Домен-«донор» (SNI/dest) заметно влияет на незаметность. Хороший кандидат:
TLS 1.3 + HTTP/2, желательно пост-квантовый обмен, **не твой** домен, в идеале — в
той же ASN/подсети, что и VPS. Проверить кандидата:

```bash
./scripts/check-dest.sh www.nvidia.com www.samsung.com www.swift.com
```

По умолчанию стоит `www.nvidia.com` (TLS 1.3, X25519MLKEM768, живёт на Akamai — доступен
отовсюду). Детали компромисса — в отчёте.

## Нагрузочное тестирование

Методика и скрипты — в [`scripts/bench/README.md`](scripts/bench/README.md). Вкратце:

```bash
# на сервере:
./scripts/bench/server-monitor.sh 180
# на клиентской машине (с тем же .env):
./scripts/bench/client-bench.sh            # полный бенч
./scripts/bench/client-bench.sh --smoke    # быстрая проверка живости
```

Результаты и цифры — в разделе «Нагрузочное тестирование» [отчёта](report/REPORT.md).

## Опциональный тюнинг хоста (BBR)

```bash
sudo ./scripts/tune-host.sh    # включает BBR + fq, расширяет сетевые буферы
```

---

## Управление

```bash
docker compose ps           # статус
docker compose logs -f      # логи
docker compose restart      # перезапуск
docker compose down         # остановить и удалить контейнер (секреты в .env сохранятся)
```

## Структура репозитория

```
├── deploy.sh                    # бутстрап «в одну команду»
├── docker-compose.yml           # сервис xray (hardened: read-only FS, cap_drop ALL)
├── .env.example                 # пример переменных (реальный .env генерируется)
├── config/
│   └── config.example.json      # пример серверного конфига (рабочий рендерится в config.json)
├── scripts/
│   ├── show-link.sh             # повторно показать VLESS-ссылку / QR
│   ├── check-dest.sh            # проверить домен-маскировку (xray tls ping)
│   ├── tune-host.sh             # BBR + сетевой тюнинг хоста
│   └── bench/
│       ├── server-monitor.sh    # семплинг CPU/RAM сервера
│       ├── client-bench.sh      # замеры throughput/latency/concurrency
│       └── README.md            # методика бенчмарка
└── report/REPORT.md             # отчёт: разведка, обоснование, цифры, ограничения
```

## Безопасность

- `.env`, рабочий `config/config.json`, ссылки и QR — **в git не попадают** (`.gitignore`).
  Приватный x25519-ключ = доступ к твоему серверу, храни как SSH-ключ.
- Контейнер урезан: `cap_drop: ALL`, `read_only` FS, `no-new-privileges`. Процесс внутри
  работает под root (чтобы прочитать `config.json` с правами 600), но **без единой
  capability** — эскалировать нечем.
- Reality слушает на 443; внутри контейнера — непривилегированный 8443.

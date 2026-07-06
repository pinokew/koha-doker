# Koha Docker Build (`pinokew/koha`)

[![Docker Hub](https://img.shields.io/badge/Docker%20Hub-pinokew%2Fkoha-blue?logo=docker)](https://hub.docker.com/r/pinokew/koha)
[![GitHub Workflow](https://github.com/pinokew/koha-docker-build/actions/workflows/build-and-push.yml/badge.svg)](https://github.com/pinokew/koha-docker-build/actions/workflows/build-and-push.yml)
[![Koha Version](https://img.shields.io/badge/Koha-25.05-2c7a7b)](https://koha-community.org/)
[![Base Image](https://img.shields.io/badge/Base%20Image-debian%3Abookworm-0b7285)](https://hub.docker.com/_/debian)

Репозиторій збірки Docker-образу Koha для публікації в Docker Hub. Він містить Dockerfile, runtime-конфіги, bootstrap pipeline на `s6-overlay`, quality/security перевірки та CI/CD пайплайн публікації образу.

Це саме **build repo**. Тут немає production-compose, Helm chart, Kubernetes manifests або середовищних секретів. Завдання репозиторію: зібрати, перевірити, опублікувати та задокументувати контейнерний артефакт `pinokew/koha`.

## Зміст

- [Поточний статус](#поточний-статус)
- [Про репозиторій](#про-репозиторій)
- [Архітектура стеку](#архітектура-стеку)
- [Топологія репозиторію](#топологія-репозиторію)
- [Топологія системи](#топологія-системи)
- [Контракт образу](#контракт-образу)
- [Runtime bootstrap pipeline](#runtime-bootstrap-pipeline)
- [Змінні середовища](#змінні-середовища)
- [Швидкий старт](#швидкий-старт)
- [Порти, дані та персистентність](#порти-дані-та-персистентність)
- [CI/CD](#cicd)
- [Безпека](#безпека)
- [Локальна розробка та перевірки](#локальна-розробка-та-перевірки)
- [Troubleshooting](#troubleshooting)
- [Документація та changelog](#документація-та-changelog)

## Поточний статус

| Параметр | Значення |
|---|---|
| Поточна цільова версія Koha | `25.05` |
| Базовий образ | `debian:bookworm` |
| Менеджер процесів | `s6-overlay 3.2.0.2` |
| HTTP endpoints | `8080` OPAC, `8081` Intranet |
| Build pipeline | GitHub Actions |
| Registry | Docker Hub (`pinokew/koha`) |
| Статус репозиторію | Active build repository |

### Що вже реалізовано

- Автоматизована збірка та публікація образу в Docker Hub.
- Runtime bootstrap через пронумеровані shell-кроки.
- Ідемпотентне створення Koha instance на першому запуску.
- Інтегровані сервіси `apache2`, `plack`, `cron`, background workers і Zebra-компоненти.
- Security та policy gates у CI: Gitleaks, Hadolint, Shellcheck, Trivy, локальні policy scripts.
- Генерація SBOM та provenance attestation під час publish.

### Важливі обмеження поточного дизайну

- Репозиторій не відповідає за production orchestration та не містить deploy-маніфестів середовища.
- Образ орієнтований на один Koha instance у контейнері.
- Значення `KOHA_INSTANCE` параметризоване у bootstrap-скриптах, але частина `s6-overlay` run-файлів жорстко орієнтована на `library`; тому підтримуваним і перевіреним режимом вважайте саме instance `library`.
- База даних не входить в образ; MariaDB/MySQL має надаватися зовнішнім сервісом.
- RabbitMQ/STOMP endpoint потрібен для `koha-create` і фонового процесингу.

## Про репозиторій

### Що входить у scope

- `Dockerfile` і все, що копіюється в image.
- Runtime-конфіги в `files/`.
- Setup pipeline в `scripts/koha-setup/`.
- CI workflow `.github/workflows/build-and-push.yml`.
- Policy-скрипти перевірки секретів і портів.
- Архітектурна та release-документація рівня build/image.

### Що не входить у scope

- Production compose/Helm/Kubernetes конфігурація.
- Секрети, ключі, реальні `.env` файли середовищ.
- Операційні runbook-и конкретного інсталяційного майданчика.
- Backup-стратегії та моніторинг зовнішніх сервісів MariaDB, RabbitMQ, memcached, Elasticsearch.

### Яку проблему вирішує цей репозиторій

Koha сама по собі має складний runtime-контракт: системні пакети, Apache vhost, plack, workers, індексація, Koha-конфіги, права на каталоги та ініціалізація бази. Цей репозиторій зводить ці вимоги до одного контейнерного артефакту з повторюваним bootstrap-процесом і контрольованими quality/security перевірками.

## Архітектура стеку

### Технологічна зведена таблиця

| Шар | Технологія | Призначення |
|---|---|---|
| Base OS | Debian Bookworm | Базове середовище контейнера |
| Init / process supervision | s6-overlay | PID 1, orchestration сервісів у контейнері |
| Application | Koha 25.05 (`koha-core`) | ILS / бібліотечна система |
| Web server | Apache 2 | OPAC та staff/intranet endpoints |
| PSGI app server | Starman / plack | Виконання Koha через plack |
| Search engine | Zebra (`idzebra-2.0`) | Індексація та пошук за замовчуванням стеку образу |
| DB client path | `koha-mysql` / MySQL client config | Доступ до зовнішньої MariaDB/MySQL |
| Message broker integration | RabbitMQ/STOMP parameters | Queue/background processing contract для Koha |
| Cache integration | memcached settings in `koha-sites.conf` | Runtime cache endpoint для Koha |
| CI quality | Hadolint, Shellcheck | Статичні перевірки Dockerfile та shell |
| CI security | Gitleaks, Trivy | Секрети, config scan, image scan |
| Supply chain artifacts | SBOM, provenance attestation | Прозорість build-артефакту |

### Архітектурні принципи

- Один контейнер містить повний Koha runtime, але не містить stateful зовнішніх залежностей.
- Конфігурація передається через env variables під час запуску контейнера.
- Bootstrap має бути ідемпотентним для повторних стартів з персистентними volume.
- Пайплайн build repo не зберігає секрети та не вимагає середовищних override-файлів усередині image.
- Зовнішньо публікуються лише HTTP-порти Koha; інші порти входять до image contract, але зазвичай не повинні бути відкриті на хості без окремої потреби.

## Топологія репозиторію

```text
koha-docker-build/
├── .github/workflows/build-and-push.yml   # CI checks, build, publish, SBOM, attestation
├── Dockerfile                             # Збірка образу Koha
├── README.md                              # Цей документ
├── README.example.md                      # Приклад структури деталізованого README
├── ARCHITECTURE.md                        # Межі відповідальності та build-архітектура
├── CHANGELOG.md                           # Короткий індекс changelog томів
├── CHANGELOGS/                            # Детальні release-зміни
├── archive/                               # Історичні/архівні файли та workflow artifacts
├── docker/pinokew/ports.conf              # Контракт HTTP Listen портів образу
├── files/                                 # Файли, що копіюються всередину image
│   ├── etc/apache2/                       # Apache envvars, confs, vhost templates
│   ├── etc/cron.*                         # Cron tasks для Koha
│   ├── etc/koha-envvars/                  # Default envdir значення для s6 сервісів
│   ├── etc/logrotate.d/                   # Rotation для koha-core логів
│   └── etc/s6-overlay/                    # s6 service definitions і dependency graph
└── scripts/
    ├── check-internal-ports-policy.sh     # Перевірка портового контракту
    ├── check-secrets-hygiene.sh           # Перевірка секретів та .dockerignore/.gitignore правил
    └── koha-setup/                        # Runtime setup pipeline
        ├── 00-runner.sh                   # Головний раннер кроків
        ├── lib/koha-setup-common.sh       # Спільна нормалізація env та helper-функції
        └── steps/                         # Пронумеровані bootstrap кроки
```

### Ключові директорії

| Шлях | Призначення |
|---|---|
| `files/` | Вміст, який потрапляє в root filesystem образу |
| `scripts/koha-setup/steps/` | Послідовні runtime-кроки першого старту та повторних стартів |
| `docker/pinokew/ports.conf` | Еталонний список HTTP Listen портів для policy check |
| `.github/workflows/build-and-push.yml` | Єдине джерело істини для CI/CD поведінки build repo |
| `ARCHITECTURE.md` | Зафіксовані межі відповідальності build repo |

## Топологія системи

```text
                         ┌──────────────────────────────┐
                         │        External User         │
                         │  Browser / Staff Operator    │
                         └──────────────┬───────────────┘
                                        │ HTTP
                      ┌─────────────────▼─────────────────┐
                      │        Koha Container Image       │
                      │         pinokew/koha              │
                      │                                   │
                      │  /init (s6-overlay)               │
                      │    ├─ setup runner                │
                      │    ├─ apache2                     │
                      │    ├─ plack/starman              │
                      │    ├─ cron                        │
                      │    ├─ background workers          │
                      │    └─ zebra services              │
                      └───────┬──────────────┬────────────┘
                              │              │
                    ┌─────────▼──────┐   ┌──▼──────────────┐
                    │ MariaDB/MySQL  │   │ RabbitMQ/STOMP  │
                    │ external DB    │   │ external broker │
                    └────────────────┘   └─────────────────┘
                              │
                    ┌─────────▼──────┐   ┌─────────────────┐
                    │ memcached      │   │ Elasticsearch   │
                    │ optional/default│  │ optional        │
                    └────────────────┘   └─────────────────┘
```

### Після завершення bootstrap контейнер тримає такі процеси

| Компонент | Роль |
|---|---|
| `apache2` | Публічний HTTP frontend для OPAC та staff interface |
| `starman` / plack | PSGI runtime для Koha |
| `cron` | Планові внутрішні задачі |
| `background_jobs_worker.pl` | Фонові завдання Koha |
| `background_jobs_worker.pl --queue long_tasks` | Окрема черга довгих задач |
| `zebrasrv` / `rebuild_zebra.pl` | Пошук та індексація для Zebra-based режиму |

## Контракт образу

### Що робить Dockerfile

1. Бере `debian:bookworm` за базу.
2. Встановлює системні залежності та Apache.
3. Підключає офіційний Koha apt repository для `25.05`.
4. Генерує локалі `en_US.UTF-8` і `uk_UA.UTF-8`.
5. Встановлює `koha-core`, `idzebra-2.0`, `logrotate` та допоміжні perl/system пакети.
6. Патчить `/usr/sbin/koha-create`, щоб створення каталогів логів було безпечним при повторному запуску.
7. Вмикає потрібні Apache modules та вимикає default site.
8. Копіює runtime-файли з `files/` і setup pipeline зі `scripts/koha-setup/`.
9. Нормалізує текстові файли через `dos2unix`.
10. Експонує порти `2100`, `6001`, `8080`, `8081` і стартує через `/init`.

### Підтримувана модель запуску

- Один контейнер = один Koha instance.
- Підтримуваний і перевірений instance name: `library`.
- Перший старт створює instance та базову конфігурацію.
- Повторний старт із персистентним `KOHA_CONF` не повинен повторно викликати `koha-create`.
- Реальна конфігурація формується з env variables на старті, а не bake-иться окремим середовищним образом.

### Теги образів

| Тег | Значення | Рекомендоване використання |
|---|---|---|
| `pinokew/koha:25.05` | Версіонований release tag | staging / контрольовані оновлення |
| `pinokew/koha:latest` | Останній publish з `main` | локальні випробування |
| `pinokew/koha:sha-<git_sha>` | Immutable tag build-конкретного коміту | forensic / audit / rollback mapping |
| `pinokew/koha@sha256:<digest>` | Immutable digest | production-рівень pinning |

## Runtime bootstrap pipeline

Контейнер стартує через `s6-overlay`, а основний bootstrap виконує `scripts/koha-setup/00-runner.sh`. Раннер автоматично знаходить пронумеровані shell-скрипти та виконує їх по порядку.

### Поведінка раннера

- За замовчуванням required steps: `00-env-checks.sh` і `06-koha-create.sh`.
- `06-koha-create.sh` завжди примусово залишається required step, навіть якщо користувач передав власний список required кроків.
- Optional steps можуть падати без фейлу контейнера, якщо не увімкнено `KOHA_SETUP_FAIL_FAST=true`.
- Після виконання кроків раннер додатково перевіряє, що `KOHA_CONF` існує і не порожній.

### Кроки bootstrap

| Крок | Скрипт | Призначення |
|---|---|---|
| `00` | `00-env-checks.sh` | Нормалізує env і перевіряє DB-змінні |
| `01` | `01-create-user.sh` | Створює системного користувача `${KOHA_INSTANCE}-koha` |
| `02` | `02-directories-permissions.sh` | Готує каталоги log/run/spool/cache/lib і права доступу |
| `03` | `03-log4perl.sh` | Генерує `/etc/koha/log4perl.conf` |
| `04` | `04-deploy-configs.sh` | Підтягує DB credentials у `/etc/mysql/koha-common.cnf`, генерує `/etc/koha/passwd`, синхронізує memcached settings |
| `05` | `05-patch-koha-create.sh` | Патчить `koha-create` для сумісності з образом: bypass `mpm_itk`, tolerate `cgid_module`, idempotent user/restart behavior |
| `06` | `06-koha-create.sh` | Створює Koha instance, якщо `KOHA_CONF` ще відсутній |
| `07` | `07-db-import.sh` | Імпортує `kohastructure.sql`, якщо БД порожня |
| `08` | `08-apache-config.sh` | Рендерить `ports.conf`, `ServerName`, `SetEnv KOHA_CONF` і vhost порти |
| `09` | `09-start-services.sh` | Вмикає plack, workers і, за потреби, Elasticsearch indexer |
| `10` | `10-languages.sh` | Синхронізує встановлені мови та system preferences |

### Ідемпотентність і повторні старти

Ключове правило: якщо файл `KOHA_CONF` вже існує і не порожній, `06-koha-create.sh` пропускає повторний виклик `koha-create`. Саме тому для стабільних restart/recreate сценаріїв варто використовувати персистентні volumes для Koha-конфігів і runtime state.

### Кастомізація виконання кроків

| Змінна | Призначення | Приклад |
|---|---|---|
| `KOHA_SETUP_FAIL_FAST` | Зупинити весь bootstrap на першому optional failure | `true` |
| `KOHA_SETUP_REQUIRED_STEPS` | Власний список required steps | `00-env-checks.sh 06-koha-create.sh 08-apache-config.sh` |
| `KOHA_SETUP_SKIP_STEPS` | Пропустити деякі кроки за іменем або glob | `10-*` |
| `KOHA_SETUP_ONLY_STEPS` | Виконати тільки конкретні кроки | `00-env-checks.sh 06-koha-create.sh` |
| `KOHA_SETUP_STEPS_DIR` | Альтернативна директорія кроків | `/custom-steps` |
| `KOHA_SETUP_STEP_GLOB` | Маска файлів кроків | `[0-9][0-9]-*.sh` |

## Змінні середовища

Нижче наведені змінні, які реально використовуються bootstrap-кодом цього репозиторію.

### Обов'язкові для БД

| Змінна | Альтернатива | Default | Призначення |
|---|---|---|---|
| `MYSQL_SERVER` | `DB_HOST` | `db` | Хост MariaDB/MySQL |
| `MYSQL_USER` | `DB_USER` | `koha_db` | Користувач БД |
| `MYSQL_PASSWORD` | `DB_PASS` | `password` | Пароль користувача БД |
| `DB_NAME` | - | `koha_library` | Назва Koha бази |
| `DB_ROOT_PASS` | - | `password` | Root password для генерації `/etc/mysql/koha-common.cnf` |

`00-env-checks.sh` вимагає наявність DB-параметрів. Навіть якщо частина з них має default values, у реальному деплої їх слід задавати явно.

### Обов'язкові або практично обов'язкові для брокера повідомлень

| Змінна | Альтернатива | Default | Призначення |
|---|---|---|---|
| `MB_HOST` | - | `rabbitmq` | Хост брокера |
| `MB_PORT` | - | `61613` | Порт STOMP endpoint |
| `MB_USER` | `RABBITMQ_USER` | `guest` | Користувач брокера |
| `MB_PASS` | `RABBITMQ_PASS` | `guest` | Пароль брокера |

### Koha runtime

| Змінна | Default | Призначення |
|---|---|---|
| `KOHA_INSTANCE` | `library` | Назва instance; це підтримуваний режим образу |
| `KOHA_CONF` | `/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml` | Основний Koha config |
| `KOHA_DOMAIN` | `myDNSname.org` | Базовий домен для Apache `ServerName` |
| `KOHA_OPAC_PORT` | `8080` | HTTP порт OPAC |
| `KOHA_INTRANET_PORT` | `8081` | HTTP порт staff/intranet |
| `KOHA_OPAC_PREFIX` | порожньо | Prefix для hostname OPAC |
| `KOHA_OPAC_SUFFIX` | порожньо | Suffix для hostname OPAC |
| `KOHA_INTRANET_PREFIX` | порожньо | Prefix для hostname intranet |
| `KOHA_INTRANET_SUFFIX` | `-intra` | Suffix для hostname intranet |
| `KOHA_OPAC_SERVERNAME` | порожньо | Повний override `ServerName` для OPAC |
| `KOHA_INTRANET_SERVERNAME` | порожньо | Повний override `ServerName` для intranet |
| `TZ` | `Europe/Kyiv` | Часова зона контейнера |
| `KOHA_TIMEZONE` | використовується як fallback для `TZ` | `Europe/Kyiv` | Альтернативне джерело timezone |
| `KOHA_LANGS` | порожньо | Список мов через пробіл, наприклад `uk-UA en` |

### Пошук, кеш та додаткові інтеграції

| Змінна | Default | Призначення |
|---|---|---|
| `USE_ELASTICSEARCH` | `false` | Перемикач альтернативного search backend |
| `KOHA_ES_INDEXER_AUTOSTART` | `true` | Запуск legacy `koha-es-indexer` усередині основного container; встановіть `false`, якщо indexing виконує окремий service |
| `ELASTICSEARCH_HOST` | `elasticsearch` | Endpoint Elasticsearch при `USE_ELASTICSEARCH=true` |
| `USE_MEMCACHED` | `yes` | Синхронізується в `koha-sites.conf` |
| `MEMCACHED_SERVERS` | `memcached:11211` | Адреса memcached для Koha |

### Важливі зауваження до конфігурації

- Якщо ви не надаєте memcached сервіс, перевизначте `USE_MEMCACHED` або `MEMCACHED_SERVERS` відповідно до свого середовища.
- Якщо ви змінюєте `KOHA_INSTANCE` на значення, відмінне від `library`, перевіряйте сумісність вручну: статичні `s6-overlay` run-файли в поточному стеку не повністю узгоджені з довільними instance names.
- `KOHA_CONF` і `/etc/koha-envvars/*` формують спільний контракт між bootstrap-кроками та `s6` сервісами.

## Швидкий старт

### Передумови

| Інструмент | Мінімум |
|---|---|
| Docker Engine | 24.x+ |
| Docker Compose plugin | 2.x+ |
| MariaDB/MySQL | сумісний зовнішній сервер |
| RabbitMQ | сервіс з доступним STOMP endpoint |
| memcached | рекомендовано, якщо лишаєте default cache settings |

### Мінімальний `compose.yaml`

```yaml
services:
  koha:
    image: pinokew/koha:25.05
    container_name: koha
    depends_on:
      mysql:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
      memcached:
        condition: service_started
    environment:
      MYSQL_SERVER: mysql
      MYSQL_USER: koha
      MYSQL_PASSWORD: koha_pass
      DB_NAME: koha_library
      DB_ROOT_PASS: root_pass
      MB_HOST: rabbitmq
      MB_PORT: 61613
      MB_USER: guest
      MB_PASS: guest
      KOHA_INSTANCE: library
      TZ: Europe/Kyiv
      KOHA_LANGS: "uk-UA en"
      USE_MEMCACHED: "yes"
      MEMCACHED_SERVERS: memcached:11211
    ports:
      - "8080:8080"
      - "8081:8081"
    volumes:
      - koha_etc:/etc/koha
      - koha_lib:/var/lib/koha
      - koha_logs:/var/log/koha
      - koha_cache:/var/cache/koha
      - koha_spool:/var/spool/koha
    restart: unless-stopped

  mysql:
    image: mariadb:11
    environment:
      MARIADB_ROOT_PASSWORD: root_pass
      MARIADB_DATABASE: koha_library
      MARIADB_USER: koha
      MARIADB_PASSWORD: koha_pass
    volumes:
      - mysql_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 12

  rabbitmq:
    image: rabbitmq:3-management
    environment:
      RABBITMQ_DEFAULT_USER: guest
      RABBITMQ_DEFAULT_PASS: guest
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 10s
      timeout: 5s
      retries: 12

  memcached:
    image: memcached:1.6-alpine

volumes:
  koha_etc:
  koha_lib:
  koha_logs:
  koha_cache:
  koha_spool:
  mysql_data:
```

### Перший запуск

```bash
docker compose up -d
docker compose logs -f koha
```

Що ви побачите під час першої ініціалізації:

1. Раннер виконає кроки `00`-`10`.
2. Буде створено користувача `library-koha`.
3. `koha-create` створить instance, якщо конфіг ще відсутній.
4. За потреби буде імпортовано базову структуру БД.
5. Apache і plack будуть налаштовані на порти `8080` і `8081`.
6. Мовні пакети будуть встановлені відповідно до `KOHA_LANGS`.

### Доступ після старту

- OPAC: `http://localhost:8080`
- Staff/Intranet: `http://localhost:8081`

### Що робити для чистого bootstrap

Якщо потрібно перевідтворити початковий сценарій з нуля, зупиніть контейнер і видаліть volume, які містять Koha runtime state та БД:

```bash
docker compose down -v
docker compose up -d
```

## Порти, дані та персистентність

### Портовий контракт образу

| Порт | Тип | Призначення |
|---|---|---|
| `8080` | зовнішній HTTP | OPAC |
| `8081` | зовнішній HTTP | Staff/Intranet |
| `2100` | внутрішній/image contract | Сервісний порт Koha/Zebra stack |
| `6001` | внутрішній/image contract | Сервісний порт Koha/Zebra stack |

Policy-скрипт `scripts/check-internal-ports-policy.sh` перевіряє, що HTTP contract зведений до `8080/8081`, а image-level `EXPOSE` не виходить за дозволений набір `2100 6001 8080 8081`.

### Які дані варто зберігати у volume

| Шлях у контейнері | Чому варто зберігати |
|---|---|
| `/etc/koha` | Тут лежить `KOHA_CONF` і службові Koha-конфіги |
| `/var/lib/koha` | Runtime state та бібліотечні дані Koha поза DB |
| `/var/log/koha` | Логи Apache, plack, Zebra і Koha |
| `/var/cache/koha` | Cache/plack template cache |
| `/var/spool/koha` | Черги/тимчасові артефакти Koha |

### Чому це важливо

Без персистентних volume container recreation втратить згенеровану конфігурацію instance, навіть якщо зовнішня БД залишиться цілою. Контейнер може стартувати знову, але відтворюватиме початковий bootstrap, що не завжди бажано для вже налаштованого середовища.

## CI/CD

Workflow: `.github/workflows/build-and-push.yml`

### Job `ci-checks`

Запускається для `pull_request` і `push` у `main`.

| Перевірка | Що робить |
|---|---|
| `Gitleaks` | Пошук secrets у git tree |
| `Hadolint` | Лінтинг усіх Dockerfile |
| `Shellcheck` | Лінтинг shell-скриптів під `scripts/` |
| `check-secrets-hygiene.sh` | Перевіряє, що `.env` не трекається, ключі не закомічені, `.dockerignore` і `.gitignore` захищають build context |
| `check-internal-ports-policy.sh` | Валідує Dockerfile `EXPOSE` та Apache портовий контракт |
| `Trivy config` | Сканує репозиторій на HIGH/CRITICAL config problems |

### Job `build-and-publish`

Запускається тільки якщо:

- подія не є `pull_request`;
- гілка дорівнює `main`;
- owner репозиторію дорівнює `pinokew`.

Послідовність дій:

1. Перевірка наявності `DOCKERHUB_USERNAME` і `DOCKERHUB_TOKEN`.
2. Логін у Docker Hub.
3. Build локального scan image.
4. `Trivy image` scan для зібраного образу.
5. Build і push тегів `25.05`, `latest`, `sha-<git_sha>`.
6. Синхронізація `README.md` у Docker Hub description.
7. Генерація SBOM у форматі SPDX JSON.
8. Публікація build provenance attestation.

### Supply-chain артефакти

- SBOM зберігається як GitHub Actions artifact.
- Provenance attestation публікується для registry subject.
- Immutable digest із publish job варто використовувати як production reference.

## Безпека

### Модель безпеки репозиторію

- У репозиторій не повинні потрапляти `.env` файли, ключі, сертифікати та інший секретний матеріал.
- Runtime secrets очікуються через environment variables або зовнішній секрет-менеджмент deploy-рівня.
- Build pipeline містить окремі перевірки на secret hygiene та policy portability.

### Що перевіряється автоматично

| Контроль | Реалізація |
|---|---|
| Секрети в коді | `Gitleaks` |
| Трекинг `.env` | `scripts/check-secrets-hygiene.sh` |
| Ключі/сертифікати в git | `scripts/check-secrets-hygiene.sh` |
| Захист Docker build context | перевірка `.dockerignore` і `.gitignore` |
| Dockerfile best practices | `Hadolint` |
| Shell safety | `Shellcheck` |
| Config/image vulnerabilities | `Trivy config` і `Trivy image` |

### Security notes для операторів образу

- Не bake-те production secrets у похідні образи.
- Не публікуйте на хості порти `2100` і `6001`, якщо у вашому сценарії це не є свідомою вимогою.
- Для production використовуйте immutable digest замість `latest`.
- Слідкуйте за сумісністю зовнішніх сервісів MariaDB, RabbitMQ/STOMP, memcached і, за потреби, Elasticsearch.

## Локальна розробка та перевірки

### Локальна збірка образу

```bash
docker build -t koha-test:local .
```

### Запуск quality checks вручну

```bash
docker run --rm -v "$PWD:/work" -w /work \
  koalaman/shellcheck:latest -x $(find scripts -type f -name '*.sh' | sort)

docker run --rm -v "$PWD:/work" -w /work \
  hadolint/hadolint hadolint Dockerfile

bash ./scripts/check-secrets-hygiene.sh
bash ./scripts/check-internal-ports-policy.sh
```

### Коли варто міняти що

- `Dockerfile` змінюється, коли треба оновити системний стек або сам спосіб збірки image.
- `files/` змінюється, коли змінюється runtime contract усередині контейнера.
- `scripts/koha-setup/steps/` змінюється, коли змінюється порядок або логіка bootstrap.
- `ARCHITECTURE.md` і цей README потрібно оновлювати, якщо змінюється scope або поведінка образу.

## Troubleshooting

### Контейнер стартує, але Koha не піднімається повністю

Перевірте bootstrap-логи:

```bash
docker compose logs -f koha
```

Шукайте повідомлення виду:

- `FAIL: required step ...`
- `ERROR: koha-create failed`
- `required Koha config missing`

### `koha-create` не може завершитися

Типові причини:

- неправильні `MYSQL_*` / `DB_*` параметри;
- недоступний RabbitMQ/STOMP endpoint;
- відсутній або конфліктний `KOHA_CONF` state;
- проблеми з Apache syntax check до запуску `koha-create`.

### База виглядає порожньою

Крок `07-db-import.sh` імпортує `kohastructure.sql` тільки якщо запит до `systempreferences` не проходить. Якщо зовнішня БД неконсистентна або partially initialized, перевіряйте її окремо.

### Після recreate контейнера середовище поводиться як нове

Це очікувано, якщо не було збережено `/etc/koha` і пов'язані runtime каталоги у volume. Для стабільного середовища використовуйте named volumes або bind mounts.

### Мови не відповідають очікуваному набору

`10-languages.sh`:

- видаляє мови, яких немає в `KOHA_LANGS`;
- встановлює відсутні мови зі списку `KOHA_LANGS`;
- оновлює `systempreferences.language` та `systempreferences.opaclanguages`, якщо таблиця існує.

### Портовий контракт порушено після зміни конфігів

Запустіть:

```bash
bash ./scripts/check-internal-ports-policy.sh
```

Скрипт звіряє `Dockerfile`, `docker/pinokew/ports.conf` і Apache vhost template.

## Документація та changelog

- `ARCHITECTURE.md` фіксує межі відповідальності build repo, CI/CD контракт і runtime-модель.
- `CHANGELOG.md` є коротким індексом changelog-томів.
- Детальні зміни накопичуються в `CHANGELOGS/CHANGELOG_<YEAR>_VOL_<NN>.md`.

## Підсумок

`koha-docker-build` це репозиторій артефакту, а не репозиторій середовища. Його головна цінність у передбачуваній збірці `pinokew/koha`, контрольованому bootstrap контейнера, валідації безпеки та відтворюваному publish-пайплайні. Якщо ви використовуєте цей образ у staging або production, найважливіше зафіксувати зовнішні залежності, зберігати Koha runtime state у volume і pin-ити deploy на immutable digest.

Останнє оновлення: березень 2026

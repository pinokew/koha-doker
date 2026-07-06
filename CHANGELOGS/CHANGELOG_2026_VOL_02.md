# Changelog 2026 Vol 02

Дата старту тому: 2026-03-03  
Репозиторій: `koha-docker-build`

## Анотація

Том відкрито після досягнення soft limit у `CHANGELOG_2026_VOL_01.md`.
Цей том фіксує подальші зміни build-репозиторію, документації та CI/runtime контрактів.

## 11) Оновлення 2026-03-03: актуалізація документації репозиторію

### 11.1. Оновлено `ARCHITECTURE.md`

1. Зафіксовано актуальні межі відповідальності build-репо.
2. Оновлено опис структури репозиторію з урахуванням `CHANGELOGS/`.
3. Оновлено CI/CD секції під поточний `.github/workflows/build-and-push.yml`.
4. Зафіксовано idempotent-контракт startup step `06-koha-create.sh`.

### 11.2. Оновлено `README.md`

1. Виправлено посилання на deploy-репо.
2. Оновлено опис тегів/артефактів образу (включно з digest-форматом).
3. Оновлено секцію CI/CD та перелік runtime env.
4. Додано явну примітку про idempotent-поведінку `koha-create`.

### 11.3. Переведено `CHANGELOG.md` у формат індексу

1. `CHANGELOG.md` тепер містить тільки статус активного тому та список томів.
2. Деталізовані записи продовжуються в `CHANGELOGS/CHANGELOG_2026_VOL_02.md`.

## 12) Оновлення 2026-07-06: керований autostart Elasticsearch indexer

### 12.1. Runtime contract

1. Додано `KOHA_ES_INDEXER_AUTOSTART` із backward-compatible default `true`.
2. `09-start-services.sh` запускає legacy `koha-es-indexer` лише коли одночасно
   `USE_ELASTICSEARCH=true` і `KOHA_ES_INDEXER_AUTOSTART=true`.
3. Значення `false` дозволяє deploy-стеку передати indexing окремому service без дубльованого
   RabbitMQ consumer.

### 12.2. Перевірка

1. `bash -n scripts/koha-setup/lib/koha-setup-common.sh scripts/koha-setup/steps/09-start-services.sh`.
2. `shellcheck scripts/koha-setup/lib/koha-setup-common.sh scripts/koha-setup/steps/09-start-services.sh`.

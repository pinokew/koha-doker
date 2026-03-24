# Build Repo Architecture (Koha Image)

Дата: 2026-03-03
Репозиторій: `koha-docker-build`

## 1) Призначення

Цей репозиторій відповідає за:
- складання Docker-образу `pinokew/koha`;
- runtime bootstrap логіку всередині контейнера;
- CI quality/security gates;
- публікацію образу в Docker Hub.

Цей репозиторій **не** відповідає за продакшн-оркестрацію середовища (compose/infra) та runtime-секрети конкретного оточення.

## 2) Межі відповідальності

1. Входить у build-repo:
- `Dockerfile` і все, що копіюється в image (`files/`, `scripts/koha-setup/`);
- CI workflow `.github/workflows/build-and-push.yml`;
- локальні policy-скрипти (`scripts/check-*.sh`);
- документація image-рівня (`README.md`, `ARCHITECTURE.md`, changelog томи).

2. Не входить у build-repo:
- production `docker-compose`/Helm/K8s конфіг середовища;
- секрети, ключі, токени, env-файли реального оточення;
- клієнтські/інфраструктурні runbook-и експлуатації.

## 3) Поточна структура репозиторію

```text
koha-docker-build/
  .github/workflows/build-and-push.yml
  Dockerfile
  files/                           # runtime-конфіги в image
  scripts/koha-setup/              # setup pipeline (s6 steps)
  scripts/check-secrets-hygiene.sh
  scripts/check-internal-ports-policy.sh
  docker/pinokew/ports.conf
  .gitleaks.toml
  .trivyignore
  README.md
  ARCHITECTURE.md
  CHANGELOG.md                     # індекс changelog-томів
  CHANGELOGS/                      # детальні changelog томи
```

## 4) CI/CD пайплайн (актуально)

Workflow: `.github/workflows/build-and-push.yml`

1. `ci-checks`:
- `Gitleaks` (кастомний `.gitleaks.toml` якщо існує);
- `Hadolint` (через Docker Hub image);
- `Shellcheck` (через Docker Hub image);
- локальні policy-скрипти:
  - `check-secrets-hygiene.sh`
  - `check-internal-ports-policy.sh`
- `Trivy config` (HIGH/CRITICAL, з `.trivyignore`).

2. `build-and-publish` (тільки `main`, тільки owner-repo):
- build scan-image (`local/koha-scan:<sha>`);
- `Trivy image` scan;
- build + push `pinokew/koha` tags (`25.05`, `latest`, `sha-...`);
- Docker Hub description update;
- SBOM artifact (SPDX JSON);
- provenance attestation.

## 5) Runtime bootstrap контракт

1. Entry point: `/init` (s6-overlay).
2. Setup runner: `scripts/koha-setup/00-runner.sh`.
3. Критично required step: `06-koha-create.sh`.
4. Idempotency правило:
- якщо `${KOHA_CONF}` уже існує і не порожній, `06-koha-create.sh` пропускає `koha-create`;
- це захищає live-конфіг від перезапису при restart/recreate.

## 6) Security/Policy контракт

1. Секрети:
- `.env` не трекається git;
- key/cert-like файли не повинні комітитись;
- Docker build contexts мають `.dockerignore` правила для `.env`.

2. Порти:
- політика перевіряється `check-internal-ports-policy.sh`;
- для режиму без compose перевіряються `Dockerfile EXPOSE`, `docker/pinokew/ports.conf`, Apache vhost.

3. Trivy:
- `DS-0002`/`DS-0029` винесені в `.trivyignore` (поточний root-based bootstrap дизайн);
- для image scan явно задані DB repositories (`ghcr.io/...`) для стабільного завантаження БД.

## 7) Контракт артефакту для deploy-repo

Після релізу build-repo має віддати в deploy-repo:
- `pinokew/koha:<version>`;
- immutable digest `pinokew/koha@sha256:...`;
- короткий release note: що змінилось у runtime/CI/security.

Rollback у deploy-repo виконується поверненням попереднього digest.

## 8) Changelog модель

1. `CHANGELOG.md` — короткий індекс томів + статус активного.
2. Деталі змін — у `CHANGELOGS/CHANGELOG_<YEAR>_VOL_<NN>.md`.
3. При досягненні soft limit (~300 рядків) створюється новий том.

## 9) Що не додаємо в build-repo

- production-специфічні compose/infra конфіги;
- приватні env/backup/key матеріали;
- workaround-и, що живуть лише всередині контейнера без фіксації в source.

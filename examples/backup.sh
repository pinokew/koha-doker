#!/usr/bin/env bash
set -euo pipefail

# === Завантаження змінних з .env ===
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
else
  echo "❌ Файл .env не знайдено! Запуск неможливий."
  exit 1
fi

# === Налаштування шляху ===
# Беремо шлях з .env, або дефолтний, якщо змінна порожня
BACKUP_ROOT="${BACKUP_PATH:-./backups}"
TS="$(date +'%Y-%m-%d_%H-%M-%S')"
BACKUP_DIR="$BACKUP_ROOT/$TS"

# Отримуємо ID твого користувача, щоб потім передати права
USER_ID=$(id -u)
GROUP_ID=$(id -g)

# === 0. Визначення реальних назв томів ===
# Залиш як є, або зміни, якщо docker volume ls показує інші назви
VOL_DB="mariadb-koha"        
VOL_CONFIG="koha_config"     
VOL_DATA="koha_data"         
VOL_ES="es-data"             

echo "📂 Бекапи будуть збережені в: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# === 1. Дамп бази даних Koha (MariaDB) ===
echo "💾 [1/4] Створюю SQL-дамп бази даних ${DB_NAME}..."

# Використовуємо mariadb-dump (або mysqldump як запасний варіант)
docker compose exec -T db sh -c "if command -v mariadb-dump > /dev/null; then mariadb-dump --single-transaction --quick -u\"${DB_USER}\" -p\"${DB_PASS}\" \"${DB_NAME}\"; else mysqldump --single-transaction --quick -u\"${DB_USER}\" -p\"${DB_PASS}\" \"${DB_NAME}\"; fi" > "$BACKUP_DIR/${DB_NAME}.sql"

if [ -s "$BACKUP_DIR/${DB_NAME}.sql" ]; then
    echo "✅ Дамп БД успішно збережено."
else
    echo "❌ ПОМИЛКА: Файл дампу порожній!"
    exit 1
fi

# === 2. Бекап тома mariadb-koha ===
echo "📦 [2/4] Архівую том DB ($VOL_DB)..."
docker run --rm \
  -v "$VOL_DB":/volume \
  -v "$BACKUP_DIR":/backup \
  alpine sh -c "cd /volume && tar -czf /backup/mariadb_volume.tar.gz ." || echo "⚠️ Том $VOL_DB не знайдено, пропускаю."

# === 3. Бекап томів Koha ===
echo "📦 [3/4] Архівую томи Koha..."

docker run --rm \
  -v "$VOL_CONFIG":/volume \
  -v "$BACKUP_DIR":/backup \
  alpine sh -c "cd /volume && tar -czf /backup/koha_config.tar.gz ." || echo "⚠️ Том $VOL_CONFIG не знайдено."

docker run --rm \
  -v "$VOL_DATA":/volume \
  -v "$BACKUP_DIR":/backup \
  alpine sh -c "cd /volume && tar -czf /backup/koha_data.tar.gz ." || echo "⚠️ Том $VOL_DATA не знайдено."

# === 4. Бекап тома Elasticsearch ===
echo "📦 [4/4] Архівую том Elasticsearch..."
docker run --rm \
  -v "$VOL_ES":/volume \
  -v "$BACKUP_DIR":/backup \
  alpine sh -c "cd /volume && tar -czf /backup/es_data.tar.gz ." || echo "⚠️ Том $VOL_ES не знайдено."

# === 🔥 ФІНАЛЬНИЙ ЕТАП: ВИПРАВЛЕННЯ ПРАВ ДОСТУПУ 🔥 ===
echo "🔐 Змінюємо власника файлів з 'root' на користувача ID: $USER_ID..."

# Ми запускаємо Alpine, монтуємо папку бекапів і виконуємо chown для всього вмісту
# Це робить тебе власником усіх файлів
docker run --rm \
  -v "$BACKUP_DIR":/data \
  alpine sh -c "chown -R $USER_ID:$GROUP_ID /data"

echo "🎉 --- БЕКАП ЗАВЕРШЕНО ---"
echo "✅ Тепер ти повний власник усіх файлів у: $BACKUP_DIR"
ls -lh "$BACKUP_DIR"
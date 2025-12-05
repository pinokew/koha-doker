#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# НАЛАШТУВАННЯ (ЗМІНИ ЦЕЙ РЯДОК ПЕРЕД ЗАПУСКОМ)
# ==============================================================================
RESTORE_SOURCE_DIR="/home/pinokew/backups/2025-12-05_10-00-00"
# ==============================================================================

# Перевірка наявності .env
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
else
  echo "❌ Файл .env не знайдено! Відновлення неможливе."
  exit 1
fi

# Перевірка, чи існує папка з бекапом
if [ ! -d "$RESTORE_SOURCE_DIR" ]; then
  echo "❌ Помилка: Директорія бекапу не існує: $RESTORE_SOURCE_DIR"
  echo "👉 Відкрий скрипт і відредагуй змінну RESTORE_SOURCE_DIR"
  exit 1
fi

echo "⚠️  УВАГА! Цей скрипт ПОВНІСТЮ видалить поточні дані в Koha і замінить їх бекапом."
echo "📂 Джерело відновлення: $RESTORE_SOURCE_DIR"
echo "⏳ У тебе є 10 секунд, щоб скасувати (Ctrl+C)..."
sleep 10

# === 0. Визначення назв томів ===
VOL_DB="mariadb-koha"
VOL_CONFIG="koha_config"
VOL_DATA="koha_data"
VOL_ES="es-data"

# === 1. Зупинка системи ===
echo "🛑 [1/6] Зупиняю контейнери..."
docker compose down
echo "✅ Контейнери зупинено."

# === 2. Відновлення томів (Файли) ===
restore_volume() {
  local vol_name=$1
  local file_name=$2

  if [ -f "$RESTORE_SOURCE_DIR/$file_name" ]; then
    echo "📦 Відновлюю том $vol_name з файлу $file_name..."
    docker run --rm \
      -v "$vol_name":/target \
      -v "$RESTORE_SOURCE_DIR":/backup \
      alpine sh -c "rm -rf /target/* && cd /target && tar -xzf /backup/$file_name"
    echo "   -> Готово."
  else
    echo "⚠️  Архів $file_name не знайдено, пропускаю відновлення тому $vol_name."
  fi
}

echo "♻️  [2/6] Відновлення вмісту томів..."
restore_volume "$VOL_DB" "mariadb_volume.tar.gz"
restore_volume "$VOL_CONFIG" "koha_config.tar.gz"
restore_volume "$VOL_DATA" "koha_data.tar.gz"
restore_volume "$VOL_ES" "es_data.tar.gz"
echo "✅ Томи відновлено."

# === 3. Запуск бази даних для заливки SQL ===
echo "🚀 [3/6] Запускаю контейнер бази даних (db)..."
docker compose up -d db

echo "⏳ Чекаю готовності бази даних..."
until docker compose exec -T db mariadb-admin -u"${DB_USER}" -p"${DB_PASS}" ping >/dev/null 2>&1; do
  echo -n "."
  sleep 2
done
echo " База прокинулась!"

# === 4. Заливка SQL дампу ===
SQL_FILE="$RESTORE_SOURCE_DIR/${DB_NAME}.sql"

if [ -f "$SQL_FILE" ]; then
  echo "📥 [4/6] Імпортую SQL дамп: $SQL_FILE..."
  cat "$SQL_FILE" | docker compose exec -T db mariadb -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}"
  echo "✅ SQL дамп успішно імпортовано."
else
  echo "❌ Помилка: SQL файл не знайдено ($SQL_FILE)!"
fi

# === 5. Повний запуск ===
echo "🚀 [5/6] Запускаю всю систему..."
docker compose up -d

# === 6. Переіндексація (НОВИЙ КРОК) ===
echo "⏳ Даємо Koha 15 секунд на повний старт перед індексацією..."
sleep 15

# Визначаємо назву інстансу (з .env або дефолт 'library')
TARGET_INSTANCE="${KOHA_INSTANCE:-library}"

echo "🔍 [6/6] Запускаю примусову переіндексацію для інстансу: $TARGET_INSTANCE..."
# -d (delete index), -v (verbose)
docker compose exec -T koha koha-elasticsearch --rebuild -d -v "$TARGET_INSTANCE"

echo "🎉 --- ВІДНОВЛЕННЯ ЗАВЕРШЕНО ---"
echo "Всі книги мають бути доступні в пошуку."
#!/usr/bin/env bash
set -euo pipefail

# === ПЕРЕВІРКА ENV ===
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
else
  echo "❌ .env не знайдено!"
  exit 1
fi

RESTORE_SOURCE_DIR=${RESTORE_SOURCE_DIR}

if [ ! -d "$RESTORE_SOURCE_DIR" ]; then
  echo "❌ Папка бекапу не існує: $RESTORE_SOURCE_DIR"
  exit 1
fi

echo "⚠️  УВАГА! Гібридне відновлення: Файли з архівів + База з SQL."
echo "📂 Джерело: $RESTORE_SOURCE_DIR"
echo "⏳ 5 секунд на скасування..."
sleep 5

# === 0. Змінні ===
VOL_DB=${VOL_DB_PATH}
VOL_CONFIG=${VOL_KOHA_CONF}
VOL_DATA=${VOL_KOHA_DATA}
VOL_ES=${VOL_ES_PATH}

# === 1. Зупинка ===
echo "🛑 [1/6] Зупиняю контейнери..."
docker compose down --remove-orphans

# === 2. Відновлення ФАЙЛІВ (Тільки Config, Data, ES) ===
# Функція для розпаковки і виправлення прав
restore_files() {
  local vol_path=$1
  local file_name=$2
  local uid=$3
  local gid=$4

  if [ -f "$RESTORE_SOURCE_DIR/$file_name" ]; then
    echo "📦 Відновлюю файли в $vol_path..."
    docker run --rm \
      -v "$vol_path":/target \
      -v "$RESTORE_SOURCE_DIR":/backup \
      alpine sh -c "
        rm -rf /target/* && \
        cd /target && \
        tar -xzf /backup/$file_name && \
        echo '🔧 Права доступу -> $uid:$gid' && \
        chown -R $uid:$gid /target
      "
    echo "   -> Готово."
  else
    echo "⚠️  Архів $file_name не знайдено (це ок, якщо ти так планував)."
  fi
}

echo "♻️  [2/6] Відновлення файлових томів..."

# УВАГА: Ми НЕ відновлюємо mariadb_volume.tar.gz, щоб уникнути проблем з паролями.
# Базу створимо чистою і заллємо SQL.

# Config (root:root)
restore_files "$VOL_CONFIG" "koha_config.tar.gz" 0 0

# Data & ES (koha:koha -> 1000:1000)
restore_files "$VOL_DATA" "koha_data.tar.gz" 1000 1000
restore_files "$VOL_ES" "es_data.tar.gz" 1000 1000

echo "✅ Файли відновлено."

# === 3. Старт чистої бази ===
echo "🚀 [3/6] Запускаю чисту базу даних..."
# Оскільки папка mysql_data пуста, Docker створить нову базу
# і встановить паролі, які прописані в .env!
docker compose up -d db

echo "⏳ Чекаю ініціалізації бази (30 сек)..."
# Треба дати час на перше створення системних таблиць
sleep 30

until docker compose exec -T db mariadb-admin -u"${DB_USER}" -p"${DB_PASS}" ping >/dev/null 2>&1; do
  echo -n "."
  sleep 3
done
echo " База готова до прийому даних!"

# === 4. Заливка SQL (Найважливіший крок) ===
SQL_FILE="$RESTORE_SOURCE_DIR/${DB_NAME}.sql"

if [ -f "$SQL_FILE" ]; then
  echo "📥 [4/6] Імпортую SQL дамп ($SQL_FILE)..."
  
  # Оскільки база свіжа (створена з .env), пароль root з .env точно підійде!
  # Спочатку дропаємо пусту базу, яку створив докер, щоб залити твою.
  docker compose exec -T db mariadb -u root -p"${DB_ROOT_PASS}" -e "DROP DATABASE IF EXISTS ${DB_NAME}; CREATE DATABASE ${DB_NAME};"
  
  # Заливаємо дані
  cat "$SQL_FILE" | docker compose exec -T db mariadb -u root -p"${DB_ROOT_PASS}" "${DB_NAME}"
  
  echo "✅ SQL успішно імпортовано."
else
  echo "❌ КРИТИЧНО: SQL файл не знайдено! База буде пустою."
  exit 1
fi

# === 5. Запуск Koha ===
echo "🚀 [5/6] Запускаю Koha..."
docker compose up -d

# === 6. Індексація ===
echo "⏳ Чекаємо 20 сек перед індексацією..."
sleep 20

TARGET_INSTANCE="${KOHA_INSTANCE:-library}"
echo "🔍 [6/6] Переіндексація..."
# Тепер таблиці точно є, помилки не буде
docker compose exec -T koha koha-elasticsearch --rebuild -d -v "$TARGET_INSTANCE"

echo "🎉 ВІДНОВЛЕННЯ УСПІШНЕ!"
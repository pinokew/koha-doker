#!/usr/bin/env bash
set -euo pipefail

# Перевірка наявності .env
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
else
  echo "❌ Файл .env не знайдено! Відновлення неможливе."
  exit 1
fi

# Папка відновлення
RESTORE_SOURCE_DIR=${RESTORE_SOURCE_DIR}

if [ ! -d "$RESTORE_SOURCE_DIR" ]; then
  echo "❌ Помилка: Директорія бекапу не існує: $RESTORE_SOURCE_DIR"
  exit 1
fi

echo "⚠️  УВАГА! Скрипт замінить поточну інсталяцію бекапом."
echo "📂 Джерело: $RESTORE_SOURCE_DIR"
echo "⏳ 5 секунд на скасування..."
sleep 5

# === 0. Визначення назв томів ===
VOL_DB=${VOL_DB_PATH}
VOL_CONFIG=${VOL_KOHA_CONF}
VOL_DATA=${VOL_KOHA_DATA}
VOL_ES=${VOL_ES_PATH}

# === 1. Зупинка ===
echo "🛑 [1/5] Зупиняю контейнери..."
docker compose down --remove-orphans
echo "✅ Зупинено."

# === 2. Відновлення томів + FIX ПРАВ ДОСТУПУ ===
restore_volume() {
  local vol_path=$1
  local file_name=$2
  local uid=$3
  local gid=$4

  if [ -f "$RESTORE_SOURCE_DIR/$file_name" ]; then
    echo "📦 Відновлюю $vol_path..."
    
    # Магія тут: розпаковуємо -> міняємо власника (chown)
    docker run --rm \
      -v "$vol_path":/target \
      -v "$RESTORE_SOURCE_DIR":/backup \
      alpine sh -c "
        rm -rf /target/* && \
        cd /target && \
        tar -xzf /backup/$file_name && \
        echo '🔧 Fix permissions to $uid:$gid' && \
        chown -R $uid:$gid /target
      "
    echo "   -> Готово."
  else
    echo "⚠️  Файл $file_name не знайдено!"
  fi
}

echo "♻️  [2/5] Відновлення файлів..."

# 999 - це стандартний ID для MariaDB (mysql)
restore_volume "$VOL_DB" "mariadb_volume.tar.gz" 999 999

# Для конфігів Koha (root або 1000, ставимо root, щоб було як в оригіналі)
restore_volume "$VOL_CONFIG" "koha_config.tar.gz" 0 0

# Дані Koha та Elasticsearch (зазвичай 1000)
restore_volume "$VOL_DATA" "koha_data.tar.gz" 1000 1000
restore_volume "$VOL_ES" "es_data.tar.gz" 1000 1000

echo "✅ Томи відновлено, права виправлено."

# === 3. Запуск бази (Перевірка) ===
echo "🚀 [3/5] Запускаю базу даних..."
docker compose up -d db

echo "⏳ Чекаю готовності..."
# Чекаємо довше, бо базі треба прочитати старі логи
until docker compose exec -T db mariadb-admin -u"${DB_USER}" -p"${DB_PASS}" ping >/dev/null 2>&1; do
  echo -n "."
  sleep 3
done
echo " База жива!"

# === 4. SQL (ПРОПУСКАЄМО) ===
# Ми його пропускаємо, бо Крок 2 відновив базу повністю.
# Спроба залити SQL викличе помилку Access Denied через старі паролі в бекапі.
echo "⏩ [4/5] SQL імпорт пропущено (фізичного відновлення достатньо)."

# === 5. Повний старт ===
echo "🚀 [5/5] Запускаю Koha та ES..."
docker compose up -d

echo "⏳ Чекаємо 20 сек перед індексацією..."
sleep 20

# Переіндексація
TARGET_INSTANCE="${KOHA_INSTANCE:-library}"
echo "🔍 Індексація для: $TARGET_INSTANCE..."
docker compose exec -T koha koha-elasticsearch --rebuild -d -v "$TARGET_INSTANCE"

echo "🎉 ВІДНОВЛЕННЯ ЗАВЕРШЕНО!"
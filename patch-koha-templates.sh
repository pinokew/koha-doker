#!/usr/bin/env bash
set -euo pipefail
# ==============================================================================
# 0. AUTO-LOAD .ENV
# ==============================================================================
# Визначаємо директорію, де знаходиться САМЕ ЦЕЙ скрипт
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
    echo "📄 Знайдено .env файл: $ENV_FILE"
    echo "🔄 Завантажую змінні..."
    # set -a автоматично робить всі змінні, що ми завантажимо, доступними (export)
    set -a
    . "$ENV_FILE"
    set +a
else
    echo "⚠️  УВАГА: Файл .env не знайдено в $SCRIPT_DIR!"
    echo "   Скрипт спробує використати змінні оточення або дефолтні значення."
fi

# ==============================================================================
# 1. КОНФІГУРАЦІЯ ШЛЯХІВ
# ==============================================================================
# Тепер ці шляхи можна задати в .env як KOHA_OFFICIAL_TEMPLATES_DIR та KOHA_TARGET_TEMPLATES_DIR
# Якщо в .env їх немає, використовуються твої дефолтні значення.

OFFICIAL_DIR="${KOHA_OFFICIAL_TEMPLATES_DIR:-$HOME/koha-official/debian/templates}"
TARGET_DIR="${KOHA_TARGET_TEMPLATES_DIR:-$HOME/koha-doker/files/docker/templates}"

echo "---------------------------------------------------"
echo "📂 Джерело шаблонів (.in):  $OFFICIAL_DIR"
echo "📂 Цільова папка (out):     $TARGET_DIR"
echo "---------------------------------------------------"

# Перевірка існування джерела
if [ ! -d "$OFFICIAL_DIR" ]; then
    echo "❌ ПОМИЛКА: Папка з офіційними шаблонами не існує!"
    echo "   Перевір шлях: $OFFICIAL_DIR"
    exit 1
fi

mkdir -p "$TARGET_DIR"

# --- MAPPING VARIABLES ---
export MYSQL_SERVER="${MYSQL_SERVER:-${DB_HOST:-db}}"
export MYSQL_USER="${MYSQL_USER:-${DB_USER:-koha_db}}"
export MYSQL_PASSWORD="${MYSQL_PASSWORD:-${DB_PASS:-password}}"
export DB_NAME="${DB_NAME:-koha_library}"
export DB_ROOT_PASS="${DB_ROOT_PASS:-password}"

# --- 1. koha-common.cnf ---
echo "=== 1) Generating koha-common.cnf ==="
cat > "$TARGET_DIR/koha-common.cnf" << EOF
[client]
host     = ${MYSQL_SERVER}
user     = root
password = ${DB_ROOT_PASS}
EOF

# --- 2. koha-sites.conf ---
echo "=== 2) Patching koha-sites.conf ==="
cp "$OFFICIAL_DIR/koha-sites.conf" "$TARGET_DIR/koha-sites.conf"

sed -i "s|^DOMAIN=.*|DOMAIN=\"${KOHA_DOMAIN}\"|" "$TARGET_DIR/koha-sites.conf"
sed -i "s|^INTRAPORT=.*|INTRAPORT=\"${KOHA_INTRANET_PORT}\"|" "$TARGET_DIR/koha-sites.conf"
sed -i "s|^INTRAPREFIX=.*|INTRAPREFIX=\"${KOHA_INTRANET_PREFIX}\"|" "$TARGET_DIR/koha-sites.conf"
sed -i "s|^INTRASUFFIX=.*|INTRASUFFIX=\"${KOHA_INTRANET_SUFFIX}\"|" "$TARGET_DIR/koha-sites.conf"
sed -i "s|^OPACPORT=.*|OPACPORT=\"${KOHA_OPAC_PORT}\"|" "$TARGET_DIR/koha-sites.conf"
sed -i "s|^OPACPREFIX=.*|OPACPREFIX=\"${KOHA_OPAC_PREFIX}\"|" "$TARGET_DIR/koha-sites.conf"
sed -i "s|^OPACSUFFIX=.*|OPACSUFFIX=\"${KOHA_OPAC_SUFFIX}\"|" "$TARGET_DIR/koha-sites.conf"
sed -i "s|^ZEBRA_MARC_FORMAT=.*|ZEBRA_MARC_FORMAT=\"${ZEBRA_MARC_FORMAT}\"|" "$TARGET_DIR/koha-sites.conf"
sed -i "s|^ZEBRA_LANGUAGE=.*|ZEBRA_LANGUAGE=\"${ZEBRA_LANGUAGE}\"|" "$TARGET_DIR/koha-sites.conf"
sed -i "s|^USE_MEMCACHED=.*|USE_MEMCACHED=\"${USE_MEMCACHED}\"|" "$TARGET_DIR/koha-sites.conf"
sed -i "s|^MEMCACHED_SERVERS=.*|MEMCACHED_SERVERS=\"${MEMCACHED_SERVERS}\"|" "$TARGET_DIR/koha-sites.conf"

if ! grep -q 'BIBLIOS_INDEXING_MODE' "$TARGET_DIR/koha-sites.conf"; then
  cat >> "$TARGET_DIR/koha-sites.conf" << EOF

BIBLIOS_INDEXING_MODE="${BIBLIOS_INDEXING_MODE}"
AUTHORITIES_INDEXING_MODE="${AUTHORITIES_INDEXING_MODE}"
EOF
fi

# --- 3. SIPconfig.xml ---
echo "=== 3) Patching SIPconfig.xml ==="
cp "$OFFICIAL_DIR/SIPconfig.xml" "$TARGET_DIR/SIPconfig.xml"
perl -0pi -e "s|<accounts>.*?</accounts>|  <accounts>\n      ${SIP_CONF_ACCOUNTS:-}\n  </accounts>|s" "$TARGET_DIR/SIPconfig.xml"
perl -0pi -e "s|<institutions>.*?</institutions>|<institutions>\n    ${SIP_CONF_LIBS:-}\n</institutions>|s" "$TARGET_DIR/SIPconfig.xml"

# --- 4. koha-conf-site.xml.in (FULL PATCH) ---
echo "=== 4) Patching koha-conf-site.xml.in ==="
cp "$OFFICIAL_DIR/koha-conf-site.xml.in" "$TARGET_DIR/koha-conf-site.xml.in"
CONF_IN="$TARGET_DIR/koha-conf-site.xml.in"

# 4.1 Database Credentials & TLS
sed -i "s|__DB_NAME__|${DB_NAME}|g" "$CONF_IN"
sed -i "s|__DB_USER__|${MYSQL_USER}|g" "$CONF_IN"
sed -i "s|__DB_PASS__|${MYSQL_PASSWORD}|g" "$CONF_IN"
sed -i "s|__DB_HOST__|${MYSQL_SERVER}|g" "$CONF_IN"
sed -i "s|<hostname>db</hostname>|<hostname>${MYSQL_SERVER}</hostname>|g" "$CONF_IN"
# Вимикаємо TLS для внутрішнього з'єднання Docker
sed -i "s|__DB_USE_TLS__|0|g" "$CONF_IN"
sed -i "s|__DB_TLS_CA_CERTIFICATE__||g" "$CONF_IN"
sed -i "s|__DB_TLS_CLIENT_CERTIFICATE__||g" "$CONF_IN"
sed -i "s|__DB_TLS_CLIENT_KEY__||g" "$CONF_IN"

# 4.2 TimeZone
sed -i "s|__TIMEZONE__|${KOHA_TIMEZONE}|g" "$CONF_IN"
sed -i "s|<timezone>.*</timezone>|<timezone>${KOHA_TIMEZONE}</timezone>|g" "$CONF_IN"

# 4.3 Memcached
sed -i "s|__MEMCACHED_SERVERS__|${MEMCACHED_SERVERS}|g" "$CONF_IN"
sed -i "s|__MEMCACHED_NAMESPACE__|${KOHA_INSTANCE}|g" "$CONF_IN"

# 4.4 Paths & Directories (CRITICAL FIXES)
# Замінюємо абстрактні шляхи на реальні Docker шляхи
sed -i "s|__KOHA_CONF_DIR__|/etc/koha|g" "$CONF_IN"
sed -i "s|__LOG4PERL_CONF__|/etc/koha/log4perl.conf|g" "$CONF_IN"
sed -i "s|__TEMPLATE_CACHE_DIR__|/var/cache/koha/${KOHA_INSTANCE}/templates|g" "$CONF_IN"
sed -i "s|__PLUGINS_DIR__|/var/lib/koha/${KOHA_INSTANCE}/plugins|g" "$CONF_IN"
sed -i "s|__UPLOAD_PATH__|/var/lib/koha/${KOHA_INSTANCE}/uploads|g" "$CONF_IN"
sed -i "s|__TMP_PATH__|/tmp|g" "$CONF_IN"
sed -i "s|__LOG_DIR__|/var/log/koha/${KOHA_INSTANCE}|g" "$CONF_IN"

# 4.5 Elasticsearch
sed -i "s|__ELASTICSEARCH_SERVER__|${ELASTICSEARCH_HOST}|g" "$CONF_IN"

# 4.6 RabbitMQ
sed -i "s|__MESSAGE_BROKER_HOST__|${MB_HOST:-rabbitmq}|g" "$CONF_IN"
sed -i "s|__MESSAGE_BROKER_PORT__|${MB_PORT:-61613}|g" "$CONF_IN"
sed -i "s|__MESSAGE_BROKER_USER__|${RABBITMQ_USER:-guest}|g" "$CONF_IN"
sed -i "s|__MESSAGE_BROKER_PASS__|${RABBITMQ_PASS:-guest}|g" "$CONF_IN"
sed -i "s|__MESSAGE_BROKER_VHOST__|/|g" "$CONF_IN"

# 4.7 Plugins & Security
sed -i "s|<enable_plugins>0</enable_plugins>|<enable_plugins>1</enable_plugins>|g" "$CONF_IN"
sed -i "s|<plugins_restricted>1</plugins_restricted>|<plugins_restricted>0</plugins_restricted>|g" "$CONF_IN"
sed -i "s|-->[[:space:]]*</plugin_repos>|</plugin_repos>|g" "$CONF_IN"
sed -i "s|<koha_trusted_proxies>.*</koha_trusted_proxies>|<koha_trusted_proxies>127.0.0.1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16</koha_trusted_proxies>|g" "$CONF_IN"

# 4.8 Secrets & Keys (Generate random if running, or placeholders)
# Генеруємо рандомні ключі, щоб Koha не скаржилася
RANDOM_KEY=$(openssl rand -base64 16 | tr -d '/+=')
sed -i "s|__BCRYPT_SETTINGS__|${RANDOM_KEY}|g" "$CONF_IN"
sed -i "s|__ENCRYPTION_KEY__|${RANDOM_KEY}|g" "$CONF_IN"
sed -i "s|__API_SECRET__|${RANDOM_KEY}|g" "$CONF_IN"

# 4.9 Zebra (Fill defaults to verify XML validness, even if we use ES)
sed -i "s|__ZEBRA_MARC_FORMAT__|${ZEBRA_MARC_FORMAT}|g" "$CONF_IN"
sed -i "s|__ZEBRA_PASS__|zebrastripes|g" "$CONF_IN"
sed -i "s|__ZEBRA_SRU_HOST__|localhost|g" "$CONF_IN"
sed -i "s|__SRU_BIBLIOS_PORT__|9998|g" "$CONF_IN"
sed -i "s|__ZEBRA_SRU_BIBLIOS_PORT__|9998|g" "$CONF_IN"
# Коментуємо блоки SRU, щоб не висіли зайві порти
sed -i "s|__START_SRU_PUBLICSERVER__|<!--|g" "$CONF_IN"
sed -i "s|__END_SRU_PUBLICSERVER__|-->|g" "$CONF_IN"

# 4.10 SMTP (Defaults)
sed -i "s|__SMTP_HOST__|localhost|g" "$CONF_IN"
sed -i "s|__SMTP_PORT__|25|g" "$CONF_IN"
sed -i "s|__SMTP_TIMEOUT__|60|g" "$CONF_IN"
sed -i "s|__SMTP_SSL_MODE__|disabled|g" "$CONF_IN"
sed -i "s|__SMTP_USER_NAME__||g" "$CONF_IN"
sed -i "s|__SMTP_PASSWORD__||g" "$CONF_IN"
sed -i "s|__SMTP_DEBUG__|0|g" "$CONF_IN"

# 4.11 Cookies
sed -i "s|__KEEP_COOKIE__|koha_cookie|g" "$CONF_IN"

# 4.12 Koha Instance & Plack
sed -i "s|__KOHASITE__|${KOHA_INSTANCE}|g" "$CONF_IN"
sed -i "s|<run_in_plack>.*</run_in_plack>|<run_in_plack>0</run_in_plack>|g" "$CONF_IN"

echo "Templates patched successfully."
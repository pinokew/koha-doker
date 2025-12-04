#!/bin/bash
# 02-setup-koha.sh — Clean Runtime Entrypoint (KDV Project)
# Updated: 04.12.2025 (Fix Dangling Symlinks)

set -e

# --- 1. Variable Mapping & Checks ---
export MYSQL_SERVER="${MYSQL_SERVER:-${DB_HOST:-db}}"
export MYSQL_USER="${MYSQL_USER:-${DB_USER:-koha_db}}"
export MYSQL_PASSWORD="${MYSQL_PASSWORD:-${DB_PASS:-password}}"
export DB_NAME="${DB_NAME:-koha_library}"

if [ -z "$MYSQL_SERVER" ] || [ -z "$DB_NAME" ] || [ -z "$MYSQL_USER" ] || [ -z "$MYSQL_PASSWORD" ]; then
    echo "ERROR: Database environment variables missing!"
    exit 1
fi

: "${MB_HOST:=rabbitmq}"
: "${MB_PORT:=61613}"
: "${MB_USER:=${RABBITMQ_USER:-guest}}"
: "${MB_PASS:=${RABBITMQ_PASS:-guest}}"

export MB_HOST MB_PORT MB_USER MB_PASS

set -u
export KOHA_INSTANCE=${KOHA_INSTANCE:-library}
export KOHA_USER="${KOHA_INSTANCE}-koha"

# --- 2. Create User ---
if ! id -u "${KOHA_USER}" > /dev/null 2>&1; then
    echo "Creating system user '${KOHA_USER}' (UID 1000)..."
    addgroup --gid 1000 "${KOHA_USER}" || true
    adduser --no-create-home --disabled-password --gecos "" --uid 1000 --ingroup "${KOHA_USER}" "${KOHA_USER}" || echo "User creation warning"
    mkdir -p "/home/${KOHA_USER}"
    chown "${KOHA_USER}:${KOHA_USER}" "/home/${KOHA_USER}"
fi

# --- 3. Directories & Permissions ---
echo "Setting up directories..."
for d in "/var/log/koha/apache" \
         "/var/log/koha/${KOHA_INSTANCE}" \
         "/var/run/koha/${KOHA_INSTANCE}" \
         "/var/spool/koha/${KOHA_INSTANCE}" \
         "/var/cache/koha/${KOHA_INSTANCE}" \
         "/var/lib/koha/${KOHA_INSTANCE}" \
         "/var/lib/koha/${KOHA_INSTANCE}/plugins"; do
  mkdir -p "$d" 2>/dev/null || true
done

# Permissions
chown -R "${KOHA_USER}:${KOHA_USER}" /var/log/koha /var/run/koha
chmod -R 755 /var/log/koha /var/run/koha

chown -R "${KOHA_USER}:${KOHA_USER}" /var/spool/koha /var/cache/koha /var/lib/koha
chmod -R g+rwX /var/spool/koha /var/cache/koha /var/lib/koha

# --- 4. Log4perl Config ---
echo "Generating log4perl.conf..."
# Видаляємо, якщо є посилання або старий файл
rm -f /etc/koha/log4perl.conf
cat >/etc/koha/log4perl.conf <<EOF
log4perl.rootLogger = INFO, LOGFILE
log4perl.appender.LOGFILE = Log::Log4perl::Appender::File
log4perl.appender.LOGFILE.filename = /var/log/koha/${KOHA_INSTANCE}/koha.log
log4perl.appender.LOGFILE.mode = append
log4perl.appender.LOGFILE.layout = Log::Log4perl::Layout::PatternLayout
log4perl.appender.LOGFILE.layout.ConversionPattern = %d [%p] %m%n
EOF
chown root:root /etc/koha/log4perl.conf
chmod 644 /etc/koha/log4perl.conf

# --- 5. Deploy Pre-Patched Configs (FIXED: Remove before copy) ---
echo "Deploying configs from /docker/templates/..."

# koha-sites.conf
rm -f /etc/koha/koha-sites.conf
cp /docker/templates/koha-sites.conf /etc/koha/koha-sites.conf

# koha-common.cnf (ТУТ БУЛА ПОМИЛКА)
rm -f /etc/mysql/koha-common.cnf
cp /docker/templates/koha-common.cnf /etc/mysql/koha-common.cnf
chmod 640 /etc/mysql/koha-common.cnf

# SIPconfig.xml
rm -f /etc/koha/SIPconfig.xml
cp /docker/templates/SIPconfig.xml /etc/koha/SIPconfig.xml

# koha-conf.xml (FORCE OVERWRITE)
mkdir -p "/etc/koha/sites/${KOHA_INSTANCE}"
rm -f "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
cp /docker/templates/koha-conf-site.xml.in "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"

# Set permissions for config (CRITICAL 750)
chown -R "${KOHA_USER}:${KOHA_USER}" "/etc/koha/sites/${KOHA_INSTANCE}"
chmod 750 "/etc/koha/sites/${KOHA_INSTANCE}"
chmod 640 "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"

# Global Symlink
rm -f /etc/koha/koha-conf.xml
ln -sf "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml" /etc/koha/koha-conf.xml

# koha-common passwd
rm -f /etc/koha/passwd
echo -n "${KOHA_INSTANCE}:${MYSQL_USER}:${MYSQL_PASSWORD}:${DB_NAME}:${MYSQL_SERVER}" > /etc/koha/passwd
chmod 640 /etc/koha/passwd
chown root:${KOHA_USER} /etc/koha/passwd

# --- 6. Patch koha-create ---
if [ -x /usr/sbin/koha-create ]; then
  if ! grep -q "mpm_itk check bypassed" /usr/sbin/koha-create; then
    sed -i 's/Koha requires mpm_itk.*die/echo "WARNING: mpm_itk check bypassed." 1>\&2\n    #die/g' /usr/sbin/koha-create || true
    sed -i 's/die "User \$username already exists\."/echo "User exists." 1>\&2/' /usr/sbin/koha-create || true
    sed -i 's/die "Group \$username already exists\."/echo "Group exists." 1>\&2/' /usr/sbin/koha-create || true
  fi
fi

source /usr/share/koha/bin/koha-functions.sh

# --- 7. Koha Create (DB Init Logic) ---
: "${TZ:=${KOHA_TIMEZONE:-Europe/Kyiv}}"
echo "Running koha-create logic..."
set +e
ES_PARAMS=""
if [[ "${USE_ELASTICSEARCH:-false}" = "true" ]]; then
  ES_PARAMS="--elasticsearch-server ${ELASTICSEARCH_HOST}"
fi
koha-create --timezone "${TZ}" --use-db "${KOHA_INSTANCE}" ${ES_PARAMS:+$ES_PARAMS} \
  --mb-host "${MB_HOST}" --mb-port "${MB_PORT}" --mb-user "${MB_USER}" --mb-pass "${MB_PASS}"
set -e

# FORCE RESTORE CONFIG (In case koha-create messed it up)
rm -f "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
cp /docker/templates/koha-conf-site.xml.in "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
chown "${KOHA_USER}:${KOHA_USER}" "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
chmod 640 "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"

# --- 8. DB Import (Safe Mode) ---
if ! koha-mysql "${KOHA_INSTANCE}" -e "SELECT * FROM systempreferences LIMIT 1;" >/dev/null 2>&1; then
    echo "WARNING: Database empty. Importing structure..."
    STRUCT_FILE=$(find /usr/share/koha -name "kohastructure.sql" | head -n 1)
    if [ -n "$STRUCT_FILE" ]; then
        grep -vi "TIME_ZONE" "$STRUCT_FILE" | koha-mysql "${KOHA_INSTANCE}"
        echo "INFO: Imported structure."
    fi
fi

# --- 9. Apache Config ---
sed -i "s/^export APACHE_RUN_USER=.*/export APACHE_RUN_USER=${KOHA_USER}/" /etc/apache2/envvars
sed -i "s/^export APACHE_RUN_GROUP=.*/export APACHE_RUN_GROUP=${KOHA_USER}/" /etc/apache2/envvars
sed -i '/^[[:space:]]*AssignUserID[[:space:]].*$/d' "/etc/apache2/sites-available/${KOHA_INSTANCE}.conf" || true

if [ -f "/etc/apache2/sites-available/${KOHA_INSTANCE}.conf" ]; then
  ln -sf "../sites-available/${KOHA_INSTANCE}.conf" "/etc/apache2/sites-enabled/${KOHA_INSTANCE}.conf"
fi

# --- 10. Start Services ---
a2enmod proxy proxy_http headers rewrite cgi || true
a2dismod mpm_itk || true
echo "ServerName localhost" > /etc/apache2/conf-available/fqdn.conf
a2enconf fqdn || true

# Patch plack.psgi
if [ -f "/etc/koha/plack.psgi" ]; then
  sed -i "s|__KOHA_CONF_DIR__|/etc/koha|g" /etc/koha/plack.psgi
  sed -i "s|__TEMPLATE_CACHE_DIR__|/var/cache/koha/${KOHA_INSTANCE}/plack-tmpl|g" /etc/koha/plack.psgi
fi

# Clean locks
rm -f "/var/run/koha/${KOHA_INSTANCE}/plack.pid"
rm -f "/var/run/koha/${KOHA_INSTANCE}/plack.sock"

echo "Starting koha-plack..."
koha-plack --enable "${KOHA_INSTANCE}" || true
koha-plack --start "${KOHA_INSTANCE}" || true

koha-worker --start "${KOHA_INSTANCE}" || true
koha-worker --start --queue long_tasks "${KOHA_INSTANCE}" || true

if [[ "${USE_ELASTICSEARCH:-false}" = "true" ]]; then
    if koha-mysql "${KOHA_INSTANCE}" -e "SHOW TABLES LIKE 'systempreferences';" | grep -q systempreferences; then
        /usr/sbin/koha-es-indexer --start "${KOHA_INSTANCE}" || true
    fi
fi

# --- Мови (KOHA_LANGS) ---
echo "KOHA_LANGS at startup: '${KOHA_LANGS:-}'"

# Тимчасово вимикаємо зупинку при помилках, бо переклад не є критичним для старту ядра
set +e

# 1. Видалення зайвих мов (якщо їх немає в змінній KOHA_LANGS)
EXISTING_LANGS=$(koha-translate -l 2>/dev/null || echo "")
for i in ${EXISTING_LANGS}; do
  if [ -z "${KOHA_LANGS:-}" ] || ! echo "${KOHA_LANGS}" | grep -q -w "$i"; then
    echo "Removing language $i"
    koha-translate -r "$i"
  else
    # echo "Checking language $i" # Зайвий шум в логах
    :
  fi
done

# 2. Встановлення нових мов
if [ -n "${KOHA_LANGS:-}" ]; then
  echo "Installing languages (KOHA_LANGS=${KOHA_LANGS})"
  # Оновлюємо список наявних мов
  EXISTING_LANGS=$(koha-translate -l 2>/dev/null || echo "")
  
  for i in ${KOHA_LANGS}; do
    if ! echo "${EXISTING_LANGS}" | grep -q -w "$i"; then
      echo "Installing language $i..."
      koha-translate -i "$i" || echo "WARNING: Failed to install language $i"
    else
      echo "Language $i already present"
    fi
  done

  # 3. (Важливо!) Активація мов у налаштуваннях Koha (System Preferences)
  # Перетворюємо пробіли на коми для SQL (uk-UA en -> uk-UA,en)
  LANGS_CSV=$(echo "${KOHA_LANGS}" | tr ' ' ',')
  
  # Перевіряємо, чи база доступна, і оновлюємо налаштування
  if koha-mysql "${KOHA_INSTANCE}" -e "SHOW TABLES LIKE 'systempreferences';" | grep -q systempreferences; then
      echo "Updating systempreferences: language, opaclanguages -> $LANGS_CSV"
      koha-mysql "${KOHA_INSTANCE}" -e \
        "UPDATE systempreferences SET value='$LANGS_CSV' WHERE variable IN ('language', 'opaclanguages');"
  fi
fi

# Повертаємо суворий режим помилок
set -u

echo "Setup Finished."
exit 0
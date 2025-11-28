#!/bin/bash

set -u

if [ -f /proc/1/environ ]; then
    while IFS='=' read -r -d '' key value 2>/dev/null || [ -n "$key" ]; do
        case "$key" in
            MYSQL_USER|MYSQL_PASSWORD|DB_NAME|MYSQL_SERVER|MB_HOST|MB_PORT|MB_USER|MB_PASS)
                export "$key"="$value"
                ;;
        esac
    done < /proc/1/environ
fi
# --- RabbitMQ credentials (з docker-compose environment) ---
export MB_HOST="${MB_HOST:-rabbitmq}"
export MB_PORT="${MB_PORT:-61613}"
export MB_USER="${MB_USER:-guest}"
export MB_PASS="${MB_PASS:-guest}"

# --- ПАТЧ KOHA-CREATE: обхід вимог Apache та existing user/group в Docker (KDV) ---
if [ -x /usr/sbin/koha-create ]; then
  if ! grep -q "mpm_itk check bypassed inside Docker (KDV setup)" /usr/sbin/koha-create; then
    echo "Patching koha-create: bypass mpm_itk, mod_cgi, mod_rewrite & user/group-exists checks for Docker..."

    # 1) Обхід перевірки mpm_itk
    perl -0pi -e 's/(Koha requires mpm_itk to be enabled within Apache in order to run\.\n.*?EOM\s*\n\s*)die/\1echo "WARNING: mpm_itk check bypassed inside Docker (KDV setup), proceeding without it." 1>&2\n        #die/s' /usr/sbin/koha-create \
      || echo "WARNING: koha-create mpm_itk patch failed, please check manually."

    # 2) Обхід перевірки mod_cgi
    perl -0pi -e 's/(Koha requires mod_cgi to be enabled within Apache in order to run\.\n.*?EOM\s*\n\s*)die/\1echo "WARNING: mod_cgi check bypassed inside Docker (KDV setup), proceeding without it." 1>&2\n        #die/s' /usr/sbin/koha-create \
      || echo "WARNING: koha-create mod_cgi patch failed, please check manually."

    # 3) Обхід перевірки mod_rewrite
    perl -0pi -e 's/(Koha requires mod_rewrite to be enabled within Apache in order to run\.\n.*?EOM\s*\n\s*)die/\1echo "WARNING: mod_rewrite check bypassed inside Docker (KDV setup), proceeding without it." 1>&2\n        #die/s' /usr/sbin/koha-create \
      || echo "WARNING: koha-create mod_rewrite patch failed, please check manually."

    # 4) Обхід фаталів "User ... already exists."
    sed -i 's/die "User \$username already exists\."/echo "WARNING: instance user already exists (Docker KDV), continuing." 1>\&2/' /usr/sbin/koha-create \
      || echo "WARNING: koha-create user-exists patch failed, please check manually."
    
    # 5) Обхід фаталів "Group ... already exists."
    sed -i 's/die "Group \$username already exists\."/echo "WARNING: instance group already exists (Docker KDV), continuing." 1>\&2/' /usr/sbin/koha-create \
      || echo "WARNING: koha-create group-exists patch failed, please check manually."
  fi
fi

# --- Базові змінні ---
export KOHA_INSTANCE=${KOHA_INSTANCE:-library}
export KOHA_INTRANET_PORT=8081
export KOHA_OPAC_PORT=8080
export MEMCACHED_SERVERS=${MEMCACHED_SERVERS:-memcached}

# DB змінні беруться з docker-compose.yaml
# Якщо не визначені — помилка (set -u)
: "${MYSQL_SERVER:?MYSQL_SERVER not set}"
: "${DB_NAME:?DB_NAME not set}"
: "${MYSQL_USER:?MYSQL_USER not set}"
: "${MYSQL_PASSWORD:?MYSQL_PASSWORD not set}"

export MYSQL_SERVER
export DB_NAME
export MYSQL_USER
export MYSQL_PASSWORD

export ZEBRA_MARC_FORMAT=${ZEBRA_MARC_FORMAT:-marc21}
export KOHA_PLACK_NAME=${KOHA_PLACK_NAME:-koha}
export KOHA_ES_NAME=${KOHA_ES_NAME:-es}

# --- koha-sites.conf та koha-common.cnf ---
envsubst < /docker/templates/koha-sites.conf > /etc/koha/koha-sites.conf

rm -f /etc/mysql/koha-common.cnf
envsubst < /docker/templates/koha-common.cnf > /etc/mysql/koha-common.cnf
chmod 660 /etc/mysql/koha-common.cnf


# Функції Koha
source /usr/share/koha/bin/koha-functions.sh

# --- Користувач/група інстансу (library-koha) ---
if ! id "${KOHA_INSTANCE}-koha" >/dev/null 2>&1; then
  addgroup --system "${KOHA_INSTANCE}-koha" || true
  adduser --system \
    --ingroup "${KOHA_INSTANCE}-koha" \
    --home "/var/lib/koha/${KOHA_INSTANCE}" \
    --no-create-home \
    --disabled-login \
    "${KOHA_INSTANCE}-koha" || true
fi

# --- Elasticsearch параметри для koha-create ---
ES_PARAMS=""
if [[ "${USE_ELASTICSEARCH:-false}" = "true" ]]; then
  ES_PARAMS="--elasticsearch-server ${ELASTICSEARCH_HOST}"
fi

# --- Файлова система: логи, кеш, спулі, run ---

# Логи Apache + Koha
mkdir -p /var/log/koha /var/log/koha/apache "/var/log/koha/${KOHA_INSTANCE}"
touch \
  "/var/log/koha/${KOHA_INSTANCE}/opac-error.log" \
  "/var/log/koha/${KOHA_INSTANCE}/intranet-error.log" \
  "/var/log/koha/${KOHA_INSTANCE}/plack.log"

# Кеш, спулі, дані Koha, run
for d in \
  /var/spool/koha \
  "/var/spool/koha/${KOHA_INSTANCE}" \
  /var/cache/koha \
  "/var/cache/koha/${KOHA_INSTANCE}" \
  /var/lib/koha \
  "/var/lib/koha/${KOHA_INSTANCE}" \
  /var/run/koha \
  "/var/run/koha/${KOHA_INSTANCE}"
do
  [ -d "$d" ] || mkdir -p "$d"
done

# Власник + права
chown -R "${KOHA_INSTANCE}-koha:${KOHA_INSTANCE}-koha" \
  /var/log/koha \
  /var/spool/koha \
  /var/cache/koha \
  /var/lib/koha \
  /var/run/koha

chmod 755 /var/log/koha /var/log/koha/apache "/var/log/koha/${KOHA_INSTANCE}" \
          /var/run/koha "/var/run/koha/${KOHA_INSTANCE}"
chmod -R g+rwX /var/spool/koha /var/cache/koha /var/lib/koha
chmod g+s "/var/spool/koha/${KOHA_INSTANCE}" || true

# DEBUG: перевірка змінних перед записом
echo "DEBUG: Variables before writing /etc/koha/passwd:"
echo "  MYSQL_USER=${MYSQL_USER}"
echo "  MYSQL_PASSWORD=${MYSQL_PASSWORD}"
echo "  DB_NAME=${DB_NAME}"
echo "  MYSQL_SERVER=${MYSQL_SERVER}"

# Запис у /etc/koha/passwd
echo -n "${KOHA_INSTANCE}:${MYSQL_USER}:${MYSQL_PASSWORD}:${DB_NAME}:${MYSQL_SERVER}" > /etc/koha/passwd

# --- Створення / оновлення інстансу ---
# Гарантуємо, що TZ завжди визначений навіть при set -u
: "${TZ:=${KOHA_TIMEZONE:-Europe/Kyiv}}"

if ! is_instance "${KOHA_INSTANCE}" || [ ! -f "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml" ]; then
  echo "DEBUG: About to call koha-create with:"
  echo "  TZ=${TZ}"
  echo "  KOHA_INSTANCE=${KOHA_INSTANCE}"
  echo "  ES_PARAMS=${ES_PARAMS}"
  echo "  MB_HOST=${MB_HOST}"
  echo "  MB_PORT=${MB_PORT}"
  echo "  MB_USER=${MB_USER}"
  echo "  MB_PASS=${MB_PASS}"
  koha-create --timezone "${TZ}" --use-db "${KOHA_INSTANCE}" \
    ${ES_PARAMS:+$ES_PARAMS} \
    --mb-host "${MB_HOST}" --mb-port "${MB_PORT}" --mb-user "${MB_USER}" --mb-pass "${MB_PASS}"
else
  koha-create-dirs "${KOHA_INSTANCE}"
fi


# --- Глобальний symlink koha-conf.xml ---
if [ -f "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml" ]; then
  ln -sf "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml" /etc/koha/koha-conf.xml
fi

# --- Права на koha-conf.xml та /etc/koha/sites/$INSTANCE ---
if [ -d "/etc/koha/sites/${KOHA_INSTANCE}" ]; then
  chown -R "${KOHA_INSTANCE}-koha:${KOHA_INSTANCE}-koha" "/etc/koha/sites/${KOHA_INSTANCE}"
  chmod 750 "/etc/koha/sites/${KOHA_INSTANCE}" || true
  if [ -f "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml" ]; then
    chmod 640 "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml" || true
  fi
fi


# Це гарантує, що koha-conf.xml ЗАВЖДИ має пароль з .env,
# навіть якщо інстанс вже був створений.
# Гарантує, що koha-conf.xml ЗАВЖДИ має DB_USER/DB_PASS з .env
# --- АВТОМАТИЧНЕ ВИПРАВЛЕННЯ БАЗИ ДАНИХ (Метод PERL) ---
if [ -f "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml" ]; then
    echo "Updating Database credentials in koha-conf.xml..."
    
    # Використовуємо perl для точної заміни в блоці <config>
    perl -i -pe '
        BEGIN { $in_config = 0; }
        $in_config = 1 if /<config>/;
        if ($in_config) {
            s|<database>[^<]*</database>|<database>'"${DB_NAME}"'</database>|g;
            s|<user>[^<]*</user>|<user>'"${MYSQL_USER}"'</user>|g;
            s|<pass>[^<]*</pass>|<pass>'"${MYSQL_PASSWORD}"'</pass>|g;
        }
        $in_config = 0 if /<\/config>/;
    ' "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
fi

# --- АВТОМАТИЧНЕ ВИПРАВЛЕННЯ RABBITMQ (Метод SED) ---
if [ -f "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml" ]; then
    echo "Updating RabbitMQ credentials in koha-conf.xml..."
    sed -i "s|<username>.*</username>|<username>${MB_USER}</username>|g" "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
    sed -i "s|<password>.*</password>|<password>${MB_PASS}</password>|g" "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
    sed -i "s|<vhost>.*</vhost>|<vhost>/</vhost>|g" "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
fi

# --- АВТОМАТИЧНЕ ВИПРАВЛЕННЯ PLACK WORKER (Метод SED) ---
if [ -f "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml" ]; then
    echo "Disabling Plack queue processing (run_in_plack=0)..."
    if ! grep -q "<run_in_plack>" "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"; then
        sed -i "s|</background_jobs_worker>|    <run_in_plack>0</run_in_plack>\n</background_jobs_worker>|g" "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
    else
        sed -i "s|<run_in_plack>.*</run_in_plack>|<run_in_plack>0</run_in_plack>|g" "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
    fi
fi


# --- Apache: модулі, ServerName, юзер ---
a2enmod proxy proxy_http headers || true
a2dismod mpm_itk || true

echo "ServerName localhost" > /etc/apache2/conf-available/fqdn.conf
a2enconf fqdn || true

# запускаємо Apache під користувачем інстансу
sed -i "s/^export APACHE_RUN_USER=.*/export APACHE_RUN_USER=${KOHA_INSTANCE}-koha/" /etc/apache2/envvars
sed -i "s/^export APACHE_RUN_GROUP=.*/export APACHE_RUN_GROUP=${KOHA_INSTANCE}-koha/" /etc/apache2/envvars

# видаляємо AssignUserID (mpm_itk)
sed -i '/^[[:space:]]*AssignUserID[[:space:]].*$/d' "/etc/apache2/sites-available/${KOHA_INSTANCE}.conf" || true

# --- Plack ---
koha-plack --enable "${KOHA_INSTANCE}" || true

# --- Воркери (черги) ---
# НЕ запускаємо es_indexer_daemon.pl напряму, тільки background_jobs_worker

# Загальний воркер (для різних завдань)
# --- Воркери (черги) ---
koha-worker --start "${KOHA_INSTANCE}" || true
koha-worker --start --queue long_tasks "${KOHA_INSTANCE}" || true

# ВИПРАВЛЕНО: Запускаємо ПРАВИЛЬНИЙ демон ES-індексації
/usr/sbin/koha-es-indexer --start "${KOHA_INSTANCE}" || true

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

# --- Перезапуск Apache (s6 далі вже керує) ---
#service apache2 stop || true
#service apache2 start || true

# --- Увімкнення Довірених Проксі (Reverse Proxy) ---
if [ -f "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml" ]; then
    echo "Updating trusted proxies..."
    # Ця команда знаходить тег <koha_trusted_proxies> і замінює його вміст.
    sed -i "s|<koha_trusted_proxies>.*</koha_trusted_proxies>|<koha_trusted_proxies>127.0.0.1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16</koha_trusted_proxies>|g" "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
fi
# --- КІНЕЦЬ БЛОКУ ---

# --- АВТОМАТИЧНЕ УВІМКНЕННЯ ПЛАГІНІВ (Метод SED) ---
if [ -f "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml" ]; then
    echo "Enabling plugins (enable_plugins=1)..."
    sed -i "s|<enable_plugins>.*</enable_plugins>|<enable_plugins>1</enable_plugins>|g" "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
fi
# --- КІНЕЦЬ БЛОКУ ---
# --- Дозволяємо завантаження плагінів (plugins_restricted=0) ---
# (Згідно з інструкцією, це дозволяє завантажувати .kpz файли)
if [ -f "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml" ]; then
    echo "Allowing plugin uploads (plugins_restricted=0)..."
    sed -i "s|<plugins_restricted>.*</plugins_restricted>|<plugins_restricted>0</plugins_restricted>|g" "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
fi

# --- Увімкнення "Магазину плагінів" (Repo) ---
# (Розкоментовує <repo>...</repo> всередині koha-conf.xml)
if [ -f "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml" ]; then
    echo "Enabling plugin repositories..."
    # Видаляємо коментар ЯКИЙ ЙДЕ ПЕРЕД </plugin_repos>
    sed -i "s|-->[[:space:]]*</plugin_repos>|</plugin_repos>|g" "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
fi
# --- КІНЕЦЬ БЛОКІВ ---

echo "by mzhk"

exit 0

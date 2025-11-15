#!/command/with-contenv bash
set -u

# --- Базові змінні ---
export KOHA_INSTANCE=${KOHA_INSTANCE:-library}
export KOHA_INTRANET_PORT=8081
export KOHA_OPAC_PORT=8080
export MEMCACHED_SERVERS=${MEMCACHED_SERVERS:-memcached}
export MYSQL_SERVER=${MYSQL_SERVER:-db}
export DB_NAME=${DB_NAME:-koha_default}
export MYSQL_USER=${MYSQL_USER:-koha_default}
export MYSQL_PASSWORD=${MYSQL_PASSWORD:-$(pwgen -s 15 1)}
export ZEBRA_MARC_FORMAT=${ZEBRA_MARC_FORMAT:-marc21}
export KOHA_PLACK_NAME=${KOHA_PLACK_NAME:-koha}
export KOHA_ES_NAME=${KOHA_ES_NAME:-es}

# RabbitMQ settings
export MB_HOST=${MB_HOST:-rabbitmq}
export MB_PORT=${MB_PORT:-61613}
#export MB_USER=${MB_USER:-guest}
#export MB_PASS=${MB_PASS:-guest}

# --- koha-sites.conf та koha-common.cnf ---
envsubst < /docker/templates/koha-sites.conf > /etc/koha/koha-sites.conf

rm -f /etc/mysql/koha-common.cnf
envsubst < /docker/templates/koha-common.cnf > /etc/mysql/koha-common.cnf
chmod 660 /etc/mysql/koha-common.cnf

# Запис у /etc/koha/passwd
echo -n "${KOHA_INSTANCE}:${MYSQL_USER}:${MYSQL_PASSWORD}:${DB_NAME}:${MYSQL_SERVER}" > /etc/koha/passwd

# Функції Koha
source /usr/share/koha/bin/koha-functions.sh

MB_PARAMS="--mb-host ${MB_HOST} --mb-port ${MB_PORT} --mb-user ${MB_USER} --mb-pass ${MB_PASS}"

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

# --- Створення / оновлення інстансу ---
if ! is_instance "${KOHA_INSTANCE}" || [ ! -f "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml" ]; then
  koha-create --timezone "${TZ}" --use-db "${KOHA_INSTANCE}" \
    ${ES_PARAMS} \
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
# --- АВТОМАТИЧНЕ ВИПРАВЛЕННЯ БАЗИ ДАНИХ (Метод SED) ---
if [ -f "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml" ]; then
    echo "Updating Database credentials in koha-conf.xml..."
    sed -i "s|<user>.*</user>|<user>${MYSQL_USER}</user>|g" "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
    sed -i "s|<pass>.*</pass>|<pass>${MYSQL_PASSWORD}</pass>|g" "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
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

echo "by mzhk"

exit 0

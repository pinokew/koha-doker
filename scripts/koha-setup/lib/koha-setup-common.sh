#!/usr/bin/env bash
# Спільні змінні середовища та допоміжні функції для runtime-кроків Koha.

init_koha_setup_env() {
  export MYSQL_SERVER="${MYSQL_SERVER:-${DB_HOST:-db}}"
  export MYSQL_USER="${MYSQL_USER:-${DB_USER:-koha_db}}"
  export MYSQL_PASSWORD="${MYSQL_PASSWORD:-${DB_PASS:-password}}"
  export DB_NAME="${DB_NAME:-koha_library}"

  : "${MB_HOST:=rabbitmq}"
  : "${MB_PORT:=61613}"
  : "${MB_USER:=${RABBITMQ_USER:-guest}}"
  : "${MB_PASS:=${RABBITMQ_PASS:-guest}}"
  export MB_HOST MB_PORT MB_USER MB_PASS

  : "${KOHA_INSTANCE:=library}"
  export KOHA_INSTANCE
  export KOHA_USER="${KOHA_INSTANCE}-koha"
  : "${KOHA_DOMAIN:=myDNSname.org}"
  : "${KOHA_CONF:=/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml}"
  : "${KOHA_OPAC_PORT:=8080}"
  : "${KOHA_INTRANET_PORT:=8081}"
  : "${KOHA_OPAC_PREFIX:=}"
  : "${KOHA_OPAC_SUFFIX:=}"
  : "${KOHA_INTRANET_PREFIX:=}"
  : "${KOHA_INTRANET_SUFFIX:=-intra}"
  : "${KOHA_OPAC_SERVERNAME:=}"
  : "${KOHA_INTRANET_SERVERNAME:=}"
  export KOHA_DOMAIN KOHA_CONF
  export KOHA_OPAC_PORT KOHA_INTRANET_PORT
  export KOHA_OPAC_PREFIX KOHA_OPAC_SUFFIX
  export KOHA_INTRANET_PREFIX KOHA_INTRANET_SUFFIX
  export KOHA_OPAC_SERVERNAME KOHA_INTRANET_SERVERNAME

  : "${TZ:=${KOHA_TIMEZONE:-Europe/Kyiv}}"
  export TZ

  : "${USE_ELASTICSEARCH:=false}"
  : "${KOHA_ES_INDEXER_AUTOSTART:=true}"
  : "${ELASTICSEARCH_HOST:=elasticsearch}"
  : "${USE_MEMCACHED:=yes}"
  : "${MEMCACHED_SERVERS:=memcached:11211}"
  export USE_ELASTICSEARCH KOHA_ES_INDEXER_AUTOSTART ELASTICSEARCH_HOST
  export USE_MEMCACHED MEMCACHED_SERVERS
}

require_db_env() {
  if [ -z "${MYSQL_SERVER}" ] || [ -z "${DB_NAME}" ] || [ -z "${MYSQL_USER}" ] || [ -z "${MYSQL_PASSWORD}" ]; then
    echo "ERROR: Database environment variables missing!"
    return 1
  fi
}

source_koha_functions_if_present() {
  if [ -f /usr/share/koha/bin/koha-functions.sh ]; then
    # shellcheck disable=SC1091
    source /usr/share/koha/bin/koha-functions.sh
    return 0
  fi

  echo "WARNING: /usr/share/koha/bin/koha-functions.sh not found, continuing."
  return 0
}

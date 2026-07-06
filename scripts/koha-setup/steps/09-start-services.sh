#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/koha-setup-common.sh"

init_koha_setup_env

a2enmod proxy proxy_http headers rewrite cgi cgid || true
a2dismod mpm_itk || true
echo "ServerName localhost" > /etc/apache2/conf-available/fqdn.conf
a2enconf fqdn || true

run_with_warning() {
  local label="$1"
  shift
  local rc=0

  set +e
  "$@"
  rc=$?
  set -e

  if [ "${rc}" -ne 0 ]; then
    echo "WARNING: ${label} failed with exit ${rc}: $*"
  fi
}

if [ -f /etc/koha/plack.psgi ]; then
  sed -i "s|__KOHA_CONF_DIR__|/etc/koha|g" /etc/koha/plack.psgi
  sed -i "s|__TEMPLATE_CACHE_DIR__|/var/cache/koha/${KOHA_INSTANCE}/plack-tmpl|g" /etc/koha/plack.psgi
fi

rm -f "/var/run/koha/${KOHA_INSTANCE}/plack.pid"
rm -f "/var/run/koha/${KOHA_INSTANCE}/plack.sock"

echo "Starting koha-plack..."
run_with_warning "koha-plack enable" koha-plack --enable "${KOHA_INSTANCE}"
run_with_warning "koha-plack start" koha-plack --start "${KOHA_INSTANCE}"

run_with_warning "koha-worker start" koha-worker --start "${KOHA_INSTANCE}"
run_with_warning "koha-worker long_tasks start" koha-worker --start --queue long_tasks "${KOHA_INSTANCE}"

if [ "${USE_ELASTICSEARCH}" = "true" ] && [ "${KOHA_ES_INDEXER_AUTOSTART}" = "true" ]; then
  if koha-mysql "${KOHA_INSTANCE}" -e "SHOW TABLES LIKE 'systempreferences';" | grep -q systempreferences; then
    run_with_warning "koha-es-indexer start" /usr/sbin/koha-es-indexer --start "${KOHA_INSTANCE}"
  fi
elif [ "${USE_ELASTICSEARCH}" = "true" ]; then
  echo "Skipping koha-es-indexer autostart (KOHA_ES_INDEXER_AUTOSTART=${KOHA_ES_INDEXER_AUTOSTART})"
fi

#!/usr/bin/env bash
# Brings up the stack (minus cloudflared, which needs a real Cloudflare
# account) and checks the routes the tunnel proxies to, plus admin bootstrap.
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT=nmcf
NET="${PROJECT}_internal"
export COMPOSE_PROJECT_NAME="$PROJECT"

# shellcheck disable=SC1091
. ./.env.example

MQ_USERNAME=netmaker
MQ_PASSWORD=$(openssl rand -hex 24)

cat >.env <<EOF
NM_DOMAIN=test.example.com
NETMAKER_VERSION=${NETMAKER_VERSION}
MOSQUITTO_VERSION=${MOSQUITTO_VERSION}
CLOUDFLARED_VERSION=${CLOUDFLARED_VERSION}
TUNNEL_TOKEN=dummy
MASTER_KEY=$(openssl rand -hex 32)
MQ_USERNAME=${MQ_USERNAME}
MQ_PASSWORD=${MQ_PASSWORD}
EOF
chmod 600 .env

mkdir -p data/sqldata data/mosquitto/data data/mosquitto/log
sudo chown -R 1883:1883 data/mosquitto

docker run --rm -v "$PWD:/work" "eclipse-mosquitto:${MOSQUITTO_VERSION}" \
  mosquitto_passwd -b -c /work/password.txt "$MQ_USERNAME" "$MQ_PASSWORD"
sudo chmod 600 password.txt
sudo chown 1883:1883 password.txt

cleanup() {
  docker compose logs --no-color >compose.log 2>&1 || true
  docker compose down -v --remove-orphans || true
  sudo rm -rf data
  rm -f .env password.txt
}
trap cleanup EXIT

docker compose up -d netmaker netmaker-ui mq

on_net()   { docker run --rm --network "$NET" "$@"; }
curl_net() { on_net curlimages/curl:latest -s -m 10 "$@"; }
code()     { curl_net -o /dev/null -w '%{http_code}' "$@"; }
hassuper() { curl_net "http://netmaker:8081/api/users/adm/hassuperadmin"; }
fail()     { echo "FAIL: $*" >&2; exit 1; }
ok()       { echo "ok: $*"; }

last=000
for _ in $(seq 1 60); do
  last=$(code "http://netmaker:8081/api/users/adm/hassuperadmin" || true)
  [ "$last" = 200 ] && break
  sleep 2
done
[ "$last" = 200 ] || fail "netmaker API never became ready (last: $last)"
ok "netmaker API up"

if docker compose logs mq 2>&1 | grep -qiE 'read-only file system|error setting groups'; then
  fail "mq hit a startup permission error"
fi
ok "mq started without permission errors"

[ "$(code http://netmaker-ui:80/)" = 200 ]                              || fail "nm-dash -> netmaker-ui:80"
ok "nm-dash -> netmaker-ui:80"
[ "$(code http://netmaker:8081/api/users/adm/hassuperadmin)" = 200 ]    || fail "nm-api -> netmaker:8081"
ok "nm-api -> netmaker:8081"
on_net busybox nc -w 2 mq 8883                                          || fail "nm-broker -> mq:8883"
ok "nm-broker -> mq:8883"

hassuper | grep -q true && fail "an admin exists before bootstrap"

admin_pass=$(openssl rand -hex 16)
body='{"username":"admin","user_name":"admin","password":"'"$admin_pass"'"}'
[ "$(code -X POST -H 'Content-Type: application/json' -d "$body" \
  http://netmaker:8081/api/users/adm/createsuperadmin)" = 200 ] || fail "createsuperadmin rejected"
ok "admin created"

hassuper | grep -q true || fail "hassuperadmin should be true after creation"
ok "hassuperadmin true"

[ "$(code -X POST -H 'Content-Type: application/json' -d "$body" \
  http://netmaker:8081/api/users/adm/createsuperadmin)" != 200 ] || fail "second create should be rejected"
ok "second create rejected"

echo "ALL E2E CHECKS PASSED"

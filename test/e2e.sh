#!/usr/bin/env bash
# Runs the stack without cloudflared (no Cloudflare account in CI) and checks it.
set -euo pipefail

cd "$(dirname "$0")/.."

export COMPOSE_PROJECT_NAME=nmcf

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

curl_in() { svc=$1; shift; docker run --rm --network "container:$svc" curlimages/curl:latest -s -m 10 "$@"; }
code_in() { svc=$1; shift; curl_in "$svc" -o /dev/null -w '%{http_code}' "$@"; }
hassuper() { curl_in netmaker http://localhost:8081/api/users/adm/hassuperadmin; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

last=000
for _ in $(seq 1 90); do
  last=$(code_in netmaker http://localhost:8081/api/users/adm/hassuperadmin || true)
  [ "$last" = 200 ] && break
  sleep 2
done
[ "$last" = 200 ] || fail "netmaker API never became ready (last: $last)"
ok "netmaker API up"

if docker compose logs mq 2>&1 | grep -qiE 'read-only file system|error setting groups'; then
  fail "mq hit a startup permission error"
fi
ok "mq started without permission errors"

[ "$(code_in netmaker-ui http://localhost:80/)" = 200 ]                       || fail "nm-dash -> netmaker-ui:80"
ok "nm-dash -> netmaker-ui:80"
[ "$(code_in netmaker http://localhost:8081/api/users/adm/hassuperadmin)" = 200 ] || fail "nm-api -> netmaker:8081"
ok "nm-api -> netmaker:8081"
docker run --rm --network container:mq busybox nc -w 2 localhost 8883          || fail "nm-broker -> mq:8883"
ok "nm-broker -> mq:8883"

hassuper | grep -q true && fail "an admin exists before bootstrap"

admin_pass=$(openssl rand -hex 16)
body='{"username":"admin","user_name":"admin","password":"'"$admin_pass"'"}'
[ "$(code_in netmaker -X POST -H 'Content-Type: application/json' -d "$body" \
  http://localhost:8081/api/users/adm/createsuperadmin)" = 200 ] || fail "createsuperadmin rejected"
ok "admin created"

hassuper | grep -q true || fail "hassuperadmin should be true after creation"
ok "hassuperadmin true"

[ "$(code_in netmaker -X POST -H 'Content-Type: application/json' -d "$body" \
  http://localhost:8081/api/users/adm/createsuperadmin)" != 200 ] || fail "second create should be rejected"
ok "second create rejected"

echo "ALL E2E CHECKS PASSED"

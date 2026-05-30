#!/bin/sh
# Netmaker + Cloudflare Tunnel installer. Safe to re-run.
#   REPO_URL=... TARGET_DIR=... sh install.sh
set -eu

REPO_URL="${REPO_URL:-https://github.com/ilgmars/netmaker-cloudflared.git}"
TARGET_DIR="${TARGET_DIR:-/opt/netmaker-cloudflared}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

apt_get() { $SUDO env DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

# https://docs.docker.com/engine/install/ubuntu/
install_docker() {
  echo "Installing Docker Engine from the official repository ..."
  for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    apt_get remove -y "$p" >/dev/null 2>&1 || true
  done
  apt_get update
  apt_get install -y ca-certificates curl
  $SUDO install -m 0755 -d /etc/apt/keyrings
  $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  $SUDO chmod a+r /etc/apt/keyrings/docker.asc
  $SUDO tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt_get update
  apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  command -v systemctl >/dev/null 2>&1 && $SUDO systemctl enable --now docker || true
}

ensure_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    pkgs=""
    command -v git     >/dev/null 2>&1 || pkgs="$pkgs git"
    command -v openssl >/dev/null 2>&1 || pkgs="$pkgs openssl"
    command -v awk     >/dev/null 2>&1 || pkgs="$pkgs gawk"
    command -v curl    >/dev/null 2>&1 || pkgs="$pkgs curl"
    if [ -n "$pkgs" ]; then
      apt_get update
      apt_get install -y $pkgs
    fi
    command -v docker >/dev/null 2>&1 || install_docker
  else
    echo "Non-apt system: verifying dependencies are already installed."
    need git; need docker; need openssl; need awk
  fi
}

# read from the tty so prompts work under `curl | sh`
ask() {
  _p=$1; _d=${2:-}
  if [ -n "$_d" ]; then printf '%s [%s]: ' "$_p" "$_d" >/dev/tty
  else printf '%s: ' "$_p" >/dev/tty; fi
  IFS= read -r _a </dev/tty || _a=
  [ -z "$_a" ] && _a=$_d
  printf '%s' "$_a"
}

confirm() {
  printf '%s [y/N]: ' "$1" >/dev/tty
  IFS= read -r _a </dev/tty || _a=
  case "$_a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

get_kv() { grep "^$1=" .env 2>/dev/null | head -n1 | cut -d= -f2- || true; }

set_kv() {
  _k=$1; _v=$2
  if grep -q "^${_k}=" .env 2>/dev/null; then
    _t=$(mktemp)
    awk -v k="$_k" -v v="$_v" -F= 'BEGIN{OFS="="} $1==k {print k, v; next} {print}' .env >"$_t"
    mv "$_t" .env
  else
    printf '%s=%s\n' "$_k" "$_v" >>.env
  fi
}

seed() {
  _k=$1; shift
  if [ -z "$(get_kv "$_k")" ]; then
    set_kv "$_k" "$("$@")"
  fi
}

# reach the API with no published ports, via the netmaker container's netns
nm_curl() { $SUDO docker run --rm --network container:netmaker curlimages/curl:latest "$@" 2>/dev/null; }

create_admin() {
  _pass=$(openssl rand -hex 16)

  printf 'Waiting for the Netmaker API ' >/dev/tty
  _i=0
  while [ "$_i" -lt 60 ]; do
    case "$(nm_curl -fs -m 5 http://localhost:8081/api/users/adm/hassuperadmin || true)" in
      *true*)  echo " an admin already exists; leaving it unchanged." >/dev/tty; return 0 ;;
      *false*) echo " ready." >/dev/tty; break ;;
    esac
    printf '.' >/dev/tty; _i=$((_i + 1)); sleep 2
  done

  _code=$(nm_curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$admin_user\",\"user_name\":\"$admin_user\",\"password\":\"$_pass\"}" \
    http://localhost:8081/api/users/adm/createsuperadmin || true)

  if [ "$_code" = "200" ]; then
    cat <<EOF >/dev/tty

Admin account created:
  username: $admin_user
  password: $_pass
Save the password now; it is not stored anywhere.
EOF
  else
    cat <<EOF >/dev/tty

Could not create the admin automatically (API returned: ${_code:-no response}).
Open https://nm-dash.$domain and create it yourself.
EOF
  fi
}

ensure_deps

if [ -f ./docker-compose.yml ] && [ -f ./.env.example ]; then
  echo "Using repo in current directory: $PWD"
else
  TARGET_DIR=$(ask "Install location" "$TARGET_DIR")
  case "$TARGET_DIR" in /*) : ;; *) TARGET_DIR="$PWD/$TARGET_DIR" ;; esac
  if [ -d "$TARGET_DIR/.git" ]; then
    echo "Updating existing checkout in $TARGET_DIR ..."
    git -C "$TARGET_DIR" pull --ff-only
  else
    echo "Cloning $REPO_URL -> $TARGET_DIR ..."
    git clone "$REPO_URL" "$TARGET_DIR"
  fi
  cd "$TARGET_DIR"
fi

[ -f .env ] || { cp .env.example .env; chmod 600 .env; }

cat <<'EOF' >/dev/tty

The base domain must be a zone you manage in Cloudflare.
Add one at: https://dash.cloudflare.com/ -> Add a site
EOF

domain=$(get_kv NM_DOMAIN)
[ "$domain" = "netmaker.example.com" ] && domain=""
while :; do
  domain=$(ask "Base domain (e.g. netmaker.example.com)" "$domain")
  case "$domain" in
    ""|netmaker.example.com) echo "A real domain is required." >/dev/tty ;;
    *) break ;;
  esac
done

cat <<EOF >/dev/tty

Cloudflare Tunnel setup
-----------------------
   Dashboard: https://one.dash.cloudflare.com/ -> Networks -> Tunnels
1. Create a tunnel.
2. Choose "Cloudflared", name it, and copy the tunnel token it shows.
3. Under the tunnel's Public Hostnames, add:
     nm-dash.$domain    ->  HTTP  netmaker-ui:80
     nm-api.$domain     ->  HTTP  netmaker:8081
     nm-broker.$domain  ->  HTTP  mq:8883
   (DNS records are created automatically.)
EOF

token=$(get_kv TUNNEL_TOKEN)
if [ -n "$token" ]; then
  echo "" >/dev/tty
  token=$(ask "Tunnel token (enter to keep existing)" "$token")
else
  token=$(ask "Paste tunnel token")
fi
[ -n "$token" ] || die "tunnel token is required"

admin_user=$(get_kv ADMIN_USERNAME); [ -n "$admin_user" ] || admin_user=admin
admin_user=$(ask "Admin username" "$admin_user")

mq_user=$(get_kv MQ_USERNAME); [ -n "$mq_user" ] || mq_user=netmaker

cat <<EOF >/dev/tty

Ready to install:
  location:    $PWD
  domain:      $domain
  broker user: $mq_user
  admin user:  $admin_user
EOF
confirm "Proceed?" || { echo "Aborted." >/dev/tty; exit 0; }

set_kv NM_DOMAIN "$domain"
set_kv TUNNEL_TOKEN "$token"
set_kv ADMIN_USERNAME "$admin_user"
set_kv MQ_USERNAME "$mq_user"
seed MASTER_KEY  openssl rand -hex 32
seed MQ_PASSWORD openssl rand -hex 24

mkdir -p data/sqldata data/mosquitto/data data/mosquitto/log
$SUDO chown -R 1883:1883 data/mosquitto

mq_pass=$(get_kv MQ_PASSWORD)
mq_ver=$(get_kv MOSQUITTO_VERSION); [ -n "$mq_ver" ] || mq_ver=2.0.20
echo "Writing password.txt ..."
$SUDO docker run --rm -v "$PWD:/work" "eclipse-mosquitto:$mq_ver" \
  mosquitto_passwd -b -c /work/password.txt "$mq_user" "$mq_pass"
$SUDO chmod 600 password.txt
$SUDO chown 1883:1883 password.txt

$SUDO docker compose up -d
create_admin

echo "" >/dev/tty
echo "Open https://nm-dash.$domain" >/dev/tty

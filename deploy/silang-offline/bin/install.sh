#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"

bind_address="${TOKENHUB_BIND_ADDRESS:-0.0.0.0}"
port="${TOKENHUB_PORT:-8080}"
public_base_url="${TOKENHUB_PUBLIC_BASE_URL:-}"

usage() {
  cat <<'EOF'
Usage: sudo ./bin/install.sh [options]

Options:
  --install-root PATH     Persistent installation root (default /opt/tokenhub-silang)
  --bind-address ADDRESS  Host listen address (default 0.0.0.0)
  --port PORT             Unified console/API port (default 8080)
  --public-base-url URL   Client-visible URL, for example http://192.168.1.20:8080
  --check-only            Verify the package and host without importing images
  -h, --help              Show this help
EOF
}

check_only=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-root) [[ $# -ge 2 ]] || die "--install-root requires a value"; install_root="$2"; shift 2 ;;
    --bind-address) [[ $# -ge 2 ]] || die "--bind-address requires a value"; bind_address="$2"; shift 2 ;;
    --port) [[ $# -ge 2 ]] || die "--port requires a value"; port="$2"; shift 2 ;;
    --public-base-url) [[ $# -ge 2 ]] || die "--public-base-url requires a value"; public_base_url="$2"; shift 2 ;;
    --check-only) check_only=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$(uname -s)" == Linux ]] || die "only Linux is supported"
case "$(uname -m)" in x86_64|amd64) ;; *) die "this package supports only Linux x86_64" ;; esac
[[ "$install_root" == /* && "$install_root" != / && "$install_root" != *[[:space:]]* ]] || die "install root must be an absolute path without spaces"
[[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || die "invalid port: $port"
[[ "$bind_address" != *[[:space:]]* ]] || die "bind address must not contain spaces"

for command_name in docker sha256sum gzip od awk sed; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
done
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable; run with a user allowed to access Docker"
detect_compose

[[ -f "$package_root/checksums.sha256" ]] || die "checksums.sha256 is missing"
[[ -f "$package_root/manifest.json" ]] || die "manifest.json is missing"
[[ -f "$package_root/config/images.env" ]] || die "config/images.env is missing"
(
  cd "$package_root"
  sha256sum -c checksums.sha256
) >/dev/null || die "package checksum verification failed"

# The image file uses fixed tags produced by the package build. It contains no
# executable shell fragments beyond simple NAME=value assignments.
# shellcheck disable=SC1091
source "$package_root/config/images.env"
for image_var in TOKENHUB_IMAGE POSTGRES_IMAGE GATEWAY_IMAGE; do
  [[ -n "${!image_var:-}" && "${!image_var}" != *[[:space:]]* ]] || die "invalid image setting: $image_var"
done

if [[ -z "$public_base_url" ]]; then
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  host_ip="${host_ip:-127.0.0.1}"
  public_base_url="http://$host_ip:$port"
fi
[[ "$public_base_url" =~ ^https?://[^[:space:]]+$ ]] || die "public base URL must start with http:// or https://"

if [[ "$check_only" == true ]]; then
  log "package and host checks passed"
  exit 0
fi

mkdir -p "$install_root/app/config" "$install_root/app/bin" "$install_root/data/postgres" \
  "$install_root/data/releases" "$install_root/backups"
[[ -w "$install_root" ]] || die "install root is not writable: $install_root"

shopt -s nullglob
image_archives=("$package_root"/images/*.tar.gz)
shopt -u nullglob
[[ ${#image_archives[@]} -gt 0 ]] || die "offline image archives are missing"
for archive in "${image_archives[@]}"; do
  log "importing $(basename "$archive")"
  gzip -dc "$archive" | docker load >/dev/null
done

for image in "$TOKENHUB_IMAGE" "$POSTGRES_IMAGE" "$GATEWAY_IMAGE"; do
  docker image inspect "$image" >/dev/null 2>&1 || die "imported image is missing: $image"
done

cp "$package_root/docker-compose.yml" "$install_root/app/docker-compose.yml"
cp "$package_root/config/nginx.conf" "$install_root/app/config/nginx.conf"
cp "$package_root/config/bootstrap-models.mjs" "$install_root/app/config/bootstrap-models.mjs"
if [[ ! -f "$install_root/app/config/models.json" ]]; then
  cp "$package_root/config/models.example.json" "$install_root/app/config/models.json"
fi
chmod 0600 "$install_root/app/config/models.json"
cp "$package_root/manifest.json" "$install_root/app/manifest.json"
cp "$package_root/README.md" "$install_root/app/README.md"
cp "$package_root/bin/"*.sh "$install_root/app/bin/"
chmod 0755 "$install_root/app/bin/"*.sh

env_file="$install_root/.env"
if [[ ! -f "$env_file" ]]; then
  umask 077
  cat >"$env_file" <<EOF
TOKENHUB_INSTALL_ROOT=$install_root
TOKENHUB_BIND_ADDRESS=$bind_address
TOKENHUB_PORT=$port
TOKENHUB_PUBLIC_BASE_URL=$public_base_url
TOKENHUB_IMAGE=$TOKENHUB_IMAGE
POSTGRES_IMAGE=$POSTGRES_IMAGE
GATEWAY_IMAGE=$GATEWAY_IMAGE
TOKENHUB_ADMIN_TOKEN=$(random_hex 32)
TOKENHUB_BOOTSTRAP_ADMIN_PASSWORD=$(random_hex 18)
TOKENHUB_SECRET_KEY=$(random_hex 32)
POSTGRES_DB=tokenhub
POSTGRES_USER=tokenhub
POSTGRES_PASSWORD=$(random_hex 24)
TOKENHUB_DB_MAX_OPEN_CONNS=25
TOKENHUB_DB_MAX_IDLE_CONNS=5
TOKENHUB_UPSTREAM_NON_STREAM_TIMEOUT_SECONDS=900
TOKENHUB_UPSTREAM_STREAM_IDLE_TIMEOUT_SECONDS=900
EOF
  chmod 0600 "$env_file"
else
  recorded_root="$(sed -n 's/^TOKENHUB_INSTALL_ROOT=//p' "$env_file")"
  [[ "$recorded_root" == "$install_root" ]] || die "existing environment belongs to another install root: $recorded_root"
  log "preserving existing credentials and database configuration"
fi

load_environment
detect_compose
compose config --quiet
compose up -d --pull never --remove-orphans

for container in tokenhub-silang-postgres tokenhub-silang-app tokenhub-silang-gateway; do
  if ! wait_for_health "$container" 240; then
    compose ps
    compose logs --tail 120 "$container" || true
    die "container did not become healthy: $container"
  fi
done

docker exec tokenhub-silang-gateway wget -qO- http://127.0.0.1:8080/readyz >/dev/null \
  || die "unified gateway readiness check failed"
chmod 0600 "$env_file"
printf '%s\n' "$(sed -n 's/.*\"version\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p' "$package_root/manifest.json" | head -n 1)" \
  >"$install_root/installed-version"

log "installation completed"
printf 'Console/API: %s\n' "$TOKENHUB_PUBLIC_BASE_URL"
printf 'Admin user: admin\n'
printf 'Admin password: %s\n' "$TOKENHUB_BOOTSTRAP_ADMIN_PASSWORD"
printf 'Credential file: %s (mode 0600)\n' "$env_file"

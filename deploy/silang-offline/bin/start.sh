#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"
load_environment
detect_compose

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
log "services started"
printf 'Console/API: %s\n' "$TOKENHUB_PUBLIC_BASE_URL"

#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"

purge=false
confirmed=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-data) purge=true; shift ;;
    --yes) confirmed=true; shift ;;
    -h|--help)
      printf 'Usage: sudo ./bin/uninstall.sh [--purge-data --yes]\n'
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
done

load_environment
detect_compose
root="$TOKENHUB_INSTALL_ROOT"
[[ "$root" == /* && "$root" != / && "$root" != /opt ]] || die "refusing unsafe install root: $root"
compose down

if [[ "$purge" == true ]]; then
  [[ "$confirmed" == true ]] || die "--purge-data permanently deletes database and backups; pass --yes"
  rm -rf -- "$root/data" "$root/backups" "$root/app"
  rm -f -- "$root/.env" "$root/installed-version"
  rmdir "$root" 2>/dev/null || true
  log "application, database and backups were permanently removed"
else
  log "containers were removed; database, configuration and backups were preserved in $root"
fi

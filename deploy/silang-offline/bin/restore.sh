#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"

archive=""
confirmed=false
skip_pre_backup=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) confirmed=true; shift ;;
    --skip-pre-backup) skip_pre_backup=true; shift ;;
    -h|--help)
      printf 'Usage: sudo ./bin/restore.sh BACKUP.tar.gz --yes [--skip-pre-backup]\n'
      exit 0
      ;;
    *)
      [[ -z "$archive" ]] || die "unexpected argument: $1"
      archive="$1"
      shift
      ;;
  esac
done

[[ -n "$archive" && -f "$archive" ]] || die "backup archive does not exist"
[[ "$confirmed" == true ]] || die "restore replaces the current database; pass --yes to confirm"
archive="$(cd "$(dirname "$archive")" && pwd)/$(basename "$archive")"

load_environment
detect_compose
current_root="$TOKENHUB_INSTALL_ROOT"

if [[ "$skip_pre_backup" != true ]]; then
  log "creating automatic pre-restore backup"
  TOKENHUB_INSTALL_ROOT="$current_root" "$script_dir/backup.sh"
fi

stage="$(mktemp -d "$current_root/.restore-XXXXXX")"
cleanup() { rm -rf -- "$stage"; }
trap cleanup EXIT
tar -xzf "$archive" -C "$stage"
[[ -s "$stage/database.dump" && -s "$stage/environment.env" && -s "$stage/checksums.sha256" ]] \
  || die "backup archive is incomplete"
(
  cd "$stage"
  sha256sum -c checksums.sha256
) >/dev/null || die "backup checksum verification failed"

saved_root="$(sed -n 's/^TOKENHUB_INSTALL_ROOT=//p' "$stage/environment.env")"
[[ "$saved_root" == "$current_root" ]] || die "backup belongs to another install root: $saved_root"
saved_db="$(sed -n 's/^POSTGRES_DB=//p' "$stage/environment.env")"
saved_user="$(sed -n 's/^POSTGRES_USER=//p' "$stage/environment.env")"
[[ "$saved_db" =~ ^[A-Za-z0-9_]+$ && "$saved_user" =~ ^[A-Za-z0-9_]+$ ]] \
  || die "backup contains unsafe database identifiers"

log "stopping TokenHub application services"
compose stop gateway tokenhub
cp "$stage/environment.env" "$env_file"
chmod 0600 "$env_file"
load_environment
detect_compose
compose up -d --pull never postgres
wait_for_health tokenhub-silang-postgres 180 || die "PostgreSQL did not become healthy"

log "restoring PostgreSQL database"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" tokenhub-silang-postgres \
  psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$POSTGRES_DB' AND pid <> pg_backend_pid();" >/dev/null
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" tokenhub-silang-postgres \
  dropdb -U "$POSTGRES_USER" --if-exists "$POSTGRES_DB"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" tokenhub-silang-postgres \
  createdb -U "$POSTGRES_USER" -O "$POSTGRES_USER" "$POSTGRES_DB"
docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" tokenhub-silang-postgres \
  pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges \
  <"$stage/database.dump"

compose up -d --pull never
for container in tokenhub-silang-postgres tokenhub-silang-app tokenhub-silang-gateway; do
  wait_for_health "$container" 240 || die "container did not become healthy after restore: $container"
done
log "restore completed"

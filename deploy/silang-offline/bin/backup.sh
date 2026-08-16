#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"
load_environment
detect_compose

timestamp="$(date +%Y%m%d_%H%M%S)"
backup_root="$TOKENHUB_INSTALL_ROOT/backups"
stage="$backup_root/.stage-$timestamp-$$"
archive="$backup_root/tokenhub-backup-$timestamp.tar.gz"
mkdir -p "$backup_root"
install -d -m 0700 "$stage"
cleanup() { rm -rf -- "$stage"; }
trap cleanup EXIT

log "creating PostgreSQL backup"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" tokenhub-silang-postgres \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --no-owner --no-privileges \
  >"$stage/database.dump"
[[ -s "$stage/database.dump" ]] || die "database backup is empty"
docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" tokenhub-silang-postgres \
  sh -eu -c 'validation_file="$(mktemp /tmp/tokenhub-backup.XXXXXX)"; trap '\''rm -f "$validation_file"'\'' EXIT; dd of="$validation_file" status=none; pg_restore --list "$validation_file" >/dev/null' \
  <"$stage/database.dump"

cp "$env_file" "$stage/environment.env"
chmod 0600 "$stage/environment.env" "$stage/database.dump"
[[ ! -f "$TOKENHUB_INSTALL_ROOT/installed-version" ]] || \
  cp "$TOKENHUB_INSTALL_ROOT/installed-version" "$stage/installed-version"
[[ ! -f "$TOKENHUB_INSTALL_ROOT/app/manifest.json" ]] || \
  cp "$TOKENHUB_INSTALL_ROOT/app/manifest.json" "$stage/manifest.json"
(
  cd "$stage"
  sha256sum database.dump environment.env >checksums.sha256
)
tar -C "$stage" -czf "$archive" .
chmod 0600 "$archive"
tar -tzf "$archive" >/dev/null
archive_sha="$(sha256sum "$archive" | awk '{print $1}')"
log "backup completed"
printf 'Archive: %s\nSHA-256: %s\n' "$archive" "$archive_sha"

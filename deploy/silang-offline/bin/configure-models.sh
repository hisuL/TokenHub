#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"
load_environment

config_path="${1:-$TOKENHUB_INSTALL_ROOT/app/config/models.json}"
[[ -f "$config_path" ]] || die "model configuration does not exist: $config_path"
if [[ "$config_path" != "$TOKENHUB_INSTALL_ROOT/app/config/models.json" ]]; then
  cp "$config_path" "$TOKENHUB_INSTALL_ROOT/app/config/models.json"
  chmod 0600 "$TOKENHUB_INSTALL_ROOT/app/config/models.json"
fi
docker exec tokenhub-silang-app node /silang-config/bootstrap-models.mjs /silang-config/models.json

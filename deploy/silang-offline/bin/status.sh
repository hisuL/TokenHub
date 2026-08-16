#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"
load_environment
detect_compose
compose ps
docker exec tokenhub-silang-gateway wget -qO- http://127.0.0.1:8080/readyz

#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
version="${PACKAGE_VERSION:-0.5.0-silang.1}"
output_parent="${1:-$repo_root/../tokenhub-silang-offline-dist}"
package_name="tokenhub-silang-offline-$version-linux-amd64"
package_dir="$output_parent/$package_name"
archive="$output_parent/$package_name.tar.gz"

tokenhub_image="silang-offline/tokenhub:$version"
postgres_source="postgres:16-alpine"
postgres_image="silang-offline/postgres:16-alpine"
gateway_source="nginx:1.27-alpine"
gateway_image="silang-offline/nginx:1.27-alpine"

case "$output_parent" in
  ""|/|/home|/opt|/usr|/var) printf 'Unsafe output directory: %s\n' "$output_parent" >&2; exit 1 ;;
esac
mkdir -p "$output_parent"
rm -rf -- "$package_dir"
rm -f -- "$archive" "$archive.sha256"
mkdir -p "$package_dir/images" "$package_dir/config" "$package_dir/bin"

source_commit="$(git -C "$repo_root" rev-parse HEAD)"
if [[ "${SKIP_TOKENHUB_BUILD:-false}" == true ]]; then
  docker image inspect "$tokenhub_image" >/dev/null 2>&1 || {
    printf 'SKIP_TOKENHUB_BUILD=true but image is missing: %s\n' "$tokenhub_image" >&2
    exit 1
  }
else
  docker build \
    --build-arg TOKENHUB_VERSION="$version" \
    --build-arg TOKENHUB_BUILD_TYPE=release \
    -t "$tokenhub_image" \
    -f "$repo_root/backend/Dockerfile" \
    "$repo_root"
fi

if [[ "${SKIP_BASE_PULL:-false}" == true ]]; then
  for image in "$postgres_source" "$gateway_source"; do
    docker image inspect "$image" >/dev/null 2>&1 || {
      printf 'SKIP_BASE_PULL=true but image is missing: %s\n' "$image" >&2
      exit 1
    }
  done
else
  docker pull "$postgres_source"
  docker pull "$gateway_source"
fi
docker tag "$postgres_source" "$postgres_image"
docker tag "$gateway_source" "$gateway_image"

for image in "$tokenhub_image" "$postgres_image" "$gateway_image"; do
  architecture="$(docker image inspect --format '{{.Architecture}}' "$image")"
  [[ "$architecture" == amd64 ]] || { printf 'Image %s is %s, expected amd64\n' "$image" "$architecture" >&2; exit 1; }
done

cp "$script_dir/docker-compose.yml" "$package_dir/docker-compose.yml"
cp "$script_dir/README.md" "$package_dir/README.md"
cp "$script_dir/config/"* "$package_dir/config/"
cp "$script_dir/bin/"*.sh "$package_dir/bin/"
chmod 0755 "$package_dir/bin/"*.sh

cat >"$package_dir/config/images.env" <<EOF
TOKENHUB_IMAGE=$tokenhub_image
POSTGRES_IMAGE=$postgres_image
GATEWAY_IMAGE=$gateway_image
EOF

docker save "$tokenhub_image" | gzip -1 >"$package_dir/images/tokenhub-$version.tar.gz"
docker save "$postgres_image" | gzip -1 >"$package_dir/images/postgres-16-alpine.tar.gz"
docker save "$gateway_image" | gzip -1 >"$package_dir/images/nginx-1.27-alpine.tar.gz"

tokenhub_id="$(docker image inspect --format '{{.Id}}' "$tokenhub_image")"
postgres_id="$(docker image inspect --format '{{.Id}}' "$postgres_image")"
gateway_id="$(docker image inspect --format '{{.Id}}' "$gateway_image")"
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat >"$package_dir/manifest.json" <<EOF
{
  "name": "TokenHub 思朗单机离线版",
  "version": "$version",
  "platform": "linux/amd64",
  "created_at": "$created_at",
  "source_repository": "https://github.com/hisuL/TokenHub",
  "source_branch": "b300-v0.5-optimized-20260816",
  "source_commit": "$source_commit",
  "images": [
    {"name": "$tokenhub_image", "id": "$tokenhub_id"},
    {"name": "$postgres_image", "id": "$postgres_id"},
    {"name": "$gateway_image", "id": "$gateway_id"}
  ],
  "components": ["nginx-gateway", "tokenhub-v0.5-optimized", "postgresql-16"],
  "excluded_components": ["load-balancer", "apisix", "redis", "otel", "tempo", "loki", "grafana", "langfuse", "clickhouse", "minio"]
}
EOF

(
  cd "$package_dir"
  find . -type f ! -name checksums.sha256 -print0 | sort -z | xargs -0 sha256sum >checksums.sha256
  sha256sum -c checksums.sha256 >/dev/null
)
tar -C "$output_parent" -czf "$archive" "$package_name"
sha256sum "$archive" >"$archive.sha256"
printf 'Package: %s\n' "$archive"
cat "$archive.sha256"

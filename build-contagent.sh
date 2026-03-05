#!/usr/bin/env bash

set -euo pipefail
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || {
  printf 'ERROR: bash 4+ required\n' >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./build-contagent.sh [--docker] [--pi] [--claude-code|--cc] [--opencode]

Features are enabled by CONTAGENT_FEATURES (default: "docker pi").
CLI flags add features to that set.
EOF
}

CONTAGENT_IMAGE_NAME=${CONTAGENT_IMAGE_NAME:-contagent}
CONTAGENT_FEATURES=${CONTAGENT_FEATURES:-"docker pi"}
CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION:-latest}
OPENCODE_VERSION=${OPENCODE_VERSION:-latest}
PI_VERSION=${PI_VERSION:-latest}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
parts_dir="$script_dir/Dockerfile-parts"
selected_dockerfile="$script_dir/Dockerfile.selected"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

resolve_version() {
  local package=$1 requested=$2

  [ "$requested" != "latest" ] && { printf '%s\n' "$requested"; return 0; }
  curl -fsSL "https://registry.npmjs.org/${package}/latest" | jq -r .version
}

declare -A feature_enabled=()

enable_feature() {
  local feature=$1

  case "$feature" in
    docker|pi|claude-code|opencode) ;;
    *) die "unknown feature: $feature" ;;
  esac
  feature_enabled["$feature"]=1
}

for feature in $CONTAGENT_FEATURES; do
  [ -n "$feature" ] || continue
  enable_feature "$feature"
done

while [ "$#" -gt 0 ]; do
  case "$1" in
    --docker) enable_feature docker ;;
    --pi) enable_feature pi ;;
    --claude-code|--cc) enable_feature claude-code ;;
    --opencode) enable_feature opencode ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

need_cmd docker
need_cmd curl
need_cmd jq

[ -d "$parts_dir" ] || die "missing directory: $parts_dir"
[ -f "$parts_dir/base" ] || die "missing Dockerfile part: base"

claude_version="$CLAUDE_CODE_VERSION"
opencode_version="$OPENCODE_VERSION"
pi_version="$PI_VERSION"
all_selected_latest=1

if [ -n "${feature_enabled[claude-code]:-}" ]; then
  claude_version=$(resolve_version "@anthropic-ai/claude-code" "$CLAUDE_CODE_VERSION")
  [ "$CLAUDE_CODE_VERSION" = "latest" ] || all_selected_latest=0
fi

if [ -n "${feature_enabled[opencode]:-}" ]; then
  opencode_version=$(resolve_version "opencode-ai" "$OPENCODE_VERSION")
  [ "$OPENCODE_VERSION" = "latest" ] || all_selected_latest=0
fi

if [ -n "${feature_enabled[pi]:-}" ]; then
  pi_version=$(resolve_version "@mariozechner/pi-coding-agent" "$PI_VERSION")
  [ "$PI_VERSION" = "latest" ] || all_selected_latest=0
fi

cat "$parts_dir/base" > "$selected_dockerfile"
for feature in docker claude-code opencode pi; do
  [ -n "${feature_enabled[$feature]:-}" ] || continue
  [ -f "$parts_dir/$feature" ] || die "missing Dockerfile part: $feature"
  printf '\n' >> "$selected_dockerfile"
  cat "$parts_dir/$feature" >> "$selected_dockerfile"
done

voom_version=$(REPO_ROOT_VOOM=1 "$script_dir/voom-like-version.sh")
image_ref="${CONTAGENT_IMAGE_NAME}:${voom_version}"

echo "Building image with selected features:"
for feature in docker claude-code opencode pi; do
  [ -n "${feature_enabled[$feature]:-}" ] && echo "  ${feature}"
done
echo "Resolved versions:"
[ -n "${feature_enabled[claude-code]:-}" ] && echo "  claude-code=${claude_version}"
[ -n "${feature_enabled[opencode]:-}" ] && echo "  opencode-ai=${opencode_version}"
[ -n "${feature_enabled[pi]:-}" ] && echo "  pi-coding-agent=${pi_version}"
echo "Producing tags:"
echo "  ${image_ref}"

docker build \
  --build-arg "CLAUDE_CODE_VERSION=${claude_version}" \
  --build-arg "OPENCODE_VERSION=${opencode_version}" \
  --build-arg "PI_VERSION=${pi_version}" \
  -t "$image_ref" \
  -f "$selected_dockerfile" \
  "$script_dir"

if [ "$all_selected_latest" -eq 1 ]; then
  latest_ref="${CONTAGENT_IMAGE_NAME}:latest"
  docker tag "$image_ref" "$latest_ref"
  echo "  ${latest_ref}"
fi

echo "Run with:"
echo "  CONTAGENT_IMAGE=${image_ref} ./contagent.sh"

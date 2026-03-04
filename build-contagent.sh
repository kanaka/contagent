#!/usr/bin/env bash

set -euo pipefail
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || {
  printf 'ERROR: bash 4+ required\n' >&2
  exit 1
}

CONTAGENT_IMAGE_NAME=${CONTAGENT_IMAGE_NAME:-contagent}
CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION:-latest}
OPENCODE_VERSION=${OPENCODE_VERSION:-latest}
PI_VERSION=${PI_VERSION:-latest}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

resolve_version() {
  local package=$1
  local requested=$2

  [ "$requested" != "latest" ] && { printf '%s\n' "$requested"; return 0; }
  curl -fsSL "https://registry.npmjs.org/${package}/latest" | jq -r .version
}

need_cmd docker
need_cmd curl
need_cmd jq

claude_version=$(resolve_version "@anthropic-ai/claude-code" "$CLAUDE_CODE_VERSION")
opencode_version=$(resolve_version "opencode-ai" "$OPENCODE_VERSION")
pi_version=$(resolve_version "@mariozechner/pi-coding-agent" "$PI_VERSION")

voom_version=$(REPO_ROOT_VOOM=1 "$script_dir/voom-like-version.sh")
composite_tag="${voom_version}-claude${claude_version}-opencode${opencode_version}-pi${pi_version}"

composite_ref="${CONTAGENT_IMAGE_NAME}:${composite_tag}"
voom_ref="${CONTAGENT_IMAGE_NAME}:${voom_version}"

echo "Building image with resolved versions:"
echo "  claude-code=${claude_version}"
echo "  opencode-ai=${opencode_version}"
echo "  pi-coding-agent=${pi_version}"
echo "Producing tags:"
echo "  ${composite_ref}"
echo "  ${voom_ref}"

docker build \
  --build-arg "CLAUDE_CODE_VERSION=${claude_version}" \
  --build-arg "OPENCODE_VERSION=${opencode_version}" \
  --build-arg "PI_VERSION=${pi_version}" \
  -t "${composite_ref}" \
  -t "${voom_ref}" \
  -f "$script_dir/Dockerfile" \
  "$script_dir"

if [ "$CLAUDE_CODE_VERSION" = "latest" ] && [ "$OPENCODE_VERSION" = "latest" ] && [ "$PI_VERSION" = "latest" ]; then
  latest_ref="${CONTAGENT_IMAGE_NAME}:latest"
  docker tag "$composite_ref" "$latest_ref"
  echo "  ${latest_ref}"
fi

echo "Run with:"
echo "  CONTAGENT_IMAGE=${composite_ref} ./contagent.sh"

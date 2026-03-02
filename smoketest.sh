#!/usr/bin/env bash

set -euo pipefail

CONTAGENT_IMAGE=${CONTAGENT_IMAGE:-contagent:latest}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
contagent_sh="$script_dir/contagent.sh"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is required"
docker image inspect "$CONTAGENT_IMAGE" >/dev/null 2>&1 || {
  die "image ${CONTAGENT_IMAGE} not found locally"
}
[ -x "$contagent_sh" ] || die "contagent launcher not found at $contagent_sh"

echo "Running smoke checks for ${CONTAGENT_IMAGE}"

echo "- identity mapping"
"$contagent_sh" bash -lc '
  test "$(id -u)" = "$CONTAGENT_UID"
  test "$(id -g)" = "$CONTAGENT_GID"
  test "$(id -un)" = "$CONTAGENT_USERNAME"
'

echo "- docker cli + host wiring"
"$contagent_sh" bash -lc '
  command -v docker >/dev/null
  docker --version >/dev/null
  [ -n "${DOCKER_HOST:-}" ]
'

echo "- docker socket group membership"
"$contagent_sh" bash -lc '
  sock=${DOCKER_HOST#unix://}
  gid=$(stat -c "%g" "$sock")
  for g in $(id -G); do
    [ "$g" = "$gid" ] && exit 0
  done
  exit 1
'

echo "- claude cli availability"
"$contagent_sh" bash -lc 'command -v claude >/dev/null && claude --version || true'
echo "- opencode cli availability"
"$contagent_sh" bash -lc 'command -v opencode >/dev/null && opencode --version || true'

if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
  echo "- ssh agent forwarding"
  "$contagent_sh" bash -lc '
    [ -n "${SSH_AUTH_SOCK:-}" ]
    [ -S "$SSH_AUTH_SOCK" ]
  '
else
  echo "Skipping SSH forwarding check: host SSH agent socket unavailable"
fi

echo "Smoke checks completed"

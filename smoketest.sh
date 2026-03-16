#!/usr/bin/env bash

set -euo pipefail

CONTAGENT_IMAGE=${CONTAGENT_IMAGE:-contagent:latest}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
contagent_sh="$script_dir/contagent.sh"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run_step() {
  local name=$1
  shift

  printf '[TEST] %s\n' "$name"
  if "$@"; then
    printf '[PASS] %s\n' "$name"
  else
    code=$?
    printf '[FAIL] %s (exit %s)\n' "$name" "$code" >&2
    exit "$code"
  fi
}

run_in_contagent() {
  "$contagent_sh" bash -lc "$1"
}

run_in_contagent_with_docker_socket() {
  "$contagent_sh" --docker-socket bash -lc "$1"
}

run_cache_mount_test() {
  mkdir -p "$HOME/.cache/contagent"; : > "$HOME/.cache/contagent/.host-to-container-$cache_token"
  "$contagent_sh" bash -lc "test -L \"\$HOME/.cache\" && test \"\$(readlink \"\$HOME/.cache\")\" = \"/var/cache/contagent\" && test -f \"\$HOME/.cache/.host-to-container-$cache_token\" && : > \"\$HOME/.cache/.container-to-host-$cache_token\""
  test -f "$HOME/.cache/contagent/.container-to-host-$cache_token"
  rm -f "$HOME/.cache/contagent/.host-to-container-$cache_token" "$HOME/.cache/contagent/.container-to-host-$cache_token"
}

cache_token="contagent-cache-smoketest-$$"

command -v docker >/dev/null 2>&1 || die "docker is required"
docker image inspect "$CONTAGENT_IMAGE" >/dev/null 2>&1 || {
  die "image ${CONTAGENT_IMAGE} not found locally"
}
[ -x "$contagent_sh" ] || die "contagent launcher not found at $contagent_sh"

echo "Running smoke checks for ${CONTAGENT_IMAGE}"

run_step "identity mapping" run_in_contagent '
  test "$(id -u)" = "$CONTAGENT_UID"
  test "$(id -g)" = "$CONTAGENT_GID"
  test "$(id -un)" = "$CONTAGENT_USERNAME"
'

run_step "cache symlink + host mount wiring" run_cache_mount_test

run_step "docker cli available" run_in_contagent '
  command -v docker >/dev/null
  docker --version >/dev/null
'

run_step "docker daemon reachable" run_in_contagent_with_docker_socket 'docker ps >/dev/null'

run_step "claude cli availability" run_in_contagent 'command -v claude >/dev/null && claude --version >/dev/null || true'
run_step "opencode cli availability" run_in_contagent 'command -v opencode >/dev/null && opencode --version >/dev/null || true'
run_step "pi cli availability" run_in_contagent 'command -v pi >/dev/null && pi --version >/dev/null || true'
run_step "codex cli availability" run_in_contagent 'command -v codex >/dev/null && codex --version >/dev/null || true'
run_step "copilot cli availability" run_in_contagent 'command -v copilot >/dev/null && copilot --version >/dev/null || true'
run_step "rust toolchain availability" run_in_contagent 'if command -v cargo >/dev/null; then cargo --version >/dev/null; command -v rustc >/dev/null; rustc --version >/dev/null; fi'
run_step "cargo install root usability" run_in_contagent 'if command -v cargo >/dev/null; then cargo install --list >/dev/null; fi'

if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
  run_step "ssh agent forwarding" run_in_contagent '
    [ -n "${SSH_AUTH_SOCK:-}" ]
    [ -S "$SSH_AUTH_SOCK" ]
  '
else
  echo "[SKIP] ssh agent forwarding (host SSH_AUTH_SOCK unavailable)"
fi

echo "Smoke checks completed"

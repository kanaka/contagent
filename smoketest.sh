#!/usr/bin/env bash

set -euo pipefail

CONTAGENT_IMAGE=${CONTAGENT_IMAGE:-contagent:latest}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat <<EOF
Usage: ./smoketest.sh [launcher]

launcher:
  Path to launcher to test (default: ./contagent.sh)
  Examples:
    ./smoketest.sh
    ./smoketest.sh ./contagent.py
    ./smoketest.sh ./contagent.js
EOF
}


die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}


if [ "$#" -gt 1 ]; then
  usage
  exit 1
fi

if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
  usage
  exit 0
fi

launcher_input=${1:-contagent.sh}
if [[ "$launcher_input" = /* || "$launcher_input" == */* ]]; then
  launcher=$launcher_input
else
  launcher="$script_dir/$launcher_input"
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}


sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}


run_step() {
  local name=$1
  shift

  printf '[TEST] %s\n' "$name"
  if "$@"; then
    printf '[PASS] %s\n' "$name"
  else
    local code=$?
    printf '[FAIL] %s (exit %s)\n' "$name" "$code" >&2
    exit "$code"
  fi
}


config_for_image() {
  local image=$1
  local safe
  safe=$(printf '%s' "$image" | tr -c '[:alnum:]_.-' '_')
  printf '%s/%s.yaml' "$smoke_config_dir" "$safe"
}


run_in_launcher() {
  CONTAGENT_IMAGE="$CONTAGENT_IMAGE" "$launcher" \
    --config "$(config_for_image "$CONTAGENT_IMAGE")" bash -lc "$1"
}


run_in_launcher_with_docker_socket() {
  CONTAGENT_IMAGE="$CONTAGENT_IMAGE" "$launcher" \
    --config "$(config_for_image "$CONTAGENT_IMAGE")" --docker bash -lc "$1"
}


run_launcher_image() {
  local image=$1
  shift
  CONTAGENT_IMAGE="$image" "$launcher" --config "$(config_for_image "$image")" "$@"
}


run_launcher_image_in_dir() {
  local dir=$1
  local image=$2
  shift 2
  (
    cd "$dir"
    CONTAGENT_IMAGE="$image" "$launcher" --config "$(config_for_image "$image")" "$@"
  )
}


expect_fail_contains() {
  local expected=$1
  shift
  local out
  out=$(mktemp)

  if "$@" >"$out" 2>&1; then
    cat "$out" >&2
    rm -f "$out"
    return 1
  fi

  if ! grep -F -- "$expected" "$out" >/dev/null; then
    cat "$out" >&2
    rm -f "$out"
    return 1
  fi

  rm -f "$out"
}


build_config_image() {
  local tag=$1
  local config_json=$2
  local tmp
  local config_id

  tmp=$(mktemp -d)
  config_id=$(printf '%s' "$config_json" | sha256_text)
  printf '%s' "$config_json" | jq --arg id "$config_id" \
    '. + {"image-hash": $id}' >"$tmp/contagent.yaml"

  {
    printf 'FROM %s\n' "$CONTAGENT_IMAGE"
    printf 'RUN mkdir -p /usr/local/share/contagent\n'
    printf 'COPY contagent.yaml /usr/local/share/contagent/contagent.yaml\n'
  } >"$tmp/Dockerfile"

  docker build -f "$tmp/Dockerfile" -t "$tag" "$tmp" >/dev/null 2>&1
  rm -rf "$tmp"
  temp_images+=("$tag")
}


run_cache_mount_test() {
  mkdir -p "$HOME/.cache/contagent"
  : >"$HOME/.cache/contagent/.host-to-container-$cache_token"

  run_launcher_image "$CONTAGENT_IMAGE" bash -lc "test -L \"\$HOME/.cache\" && test \"\$(readlink \"\$HOME/.cache\")\" = \"/var/cache/contagent\" && test -f \"\$HOME/.cache/.host-to-container-$cache_token\" && : > \"\$HOME/.cache/.container-to-host-$cache_token\""

  test -f "$HOME/.cache/contagent/.container-to-host-$cache_token"
  rm -f "$HOME/.cache/contagent/.host-to-container-$cache_token" "$HOME/.cache/contagent/.container-to-host-$cache_token"
}


test_show_options_dynamic() {
  local out
  out=$(run_launcher_image "$img_cli" --show-options)
  grep -F -- "--inc / --no-inc (default: on" <<<"$out" >/dev/null
  grep -F -- "--offfeat / --no-offfeat (default: off" <<<"$out" >/dev/null
  ! grep -F -- "--hidden / --no-hidden" <<<"$out" >/dev/null
}


test_unknown_option() {
  expect_fail_contains "unknown option: --bogus" run_launcher_image "$img_cli" --bogus true
}


test_source_create_semantics() {
  local tmp
  tmp=$(mktemp -d)
  HOME="$tmp" run_launcher_image "$img_cli" true >/dev/null 2>/dev/null
  test -e "$tmp/.smoke-inc"
  rm -rf "$tmp"
}


test_default_off_toggle_semantics() {
  local tmp
  tmp=$(mktemp -d)

  HOME="$tmp" run_launcher_image "$img_cli" true >/dev/null 2>/dev/null
  [ ! -e "$tmp/.smoke-off" ]

  HOME="$tmp" run_launcher_image "$img_cli" --offfeat true >/dev/null 2>/dev/null
  [ -e "$tmp/.smoke-off" ]

  rm -rf "$tmp"
}


test_overlapping_volume_feature_semantics() {
  local tmp
  tmp=$(mktemp -d)

  HOME="$tmp" run_launcher_image "$img_overlap" true >/dev/null 2>/dev/null
  [ -d "$tmp/.smoke-shared" ]

  rm -rf "$tmp/.smoke-shared"
  HOME="$tmp" run_launcher_image "$img_overlap" --no-alpha true >/dev/null 2>/dev/null
  [ -d "$tmp/.smoke-shared" ]

  rm -rf "$tmp/.smoke-shared"
  HOME="$tmp" run_launcher_image "$img_overlap" --no-alpha --no-beta true >/dev/null 2>/dev/null
  [ ! -e "$tmp/.smoke-shared" ]

  rm -rf "$tmp"
}


test_relative_config_path_semantics() {
  local tmp
  local config
  tmp=$(mktemp -d)
  config="$tmp/configs/relative.yaml"

  mkdir -p "$(dirname "$config")"
  cat >"$config" <<'EOF'
version: 2
image-hash: smoke
features:
  - name: rel
    volumes:
      - {enabled: true, source: ./host-rel, path: ~/.smoke-rel}
EOF

  HOME="$tmp/home" run_launcher_image "$img_cli" --config "$config" true >/dev/null 2>/dev/null
  [ -d "$tmp/configs/host-rel" ]

  rm -rf "$tmp"
}


cleanup() {
  if [ "${#temp_images[@]}" -gt 0 ]; then
    docker image rm -f "${temp_images[@]}" >/dev/null 2>&1 || true
  fi
  rm -rf "$smoke_config_dir"
}


temp_images=()
smoke_config_dir=$(mktemp -d)
cache_token="contagent-cache-smoketest-$$"
need_cmd docker
need_cmd jq

docker image inspect "$CONTAGENT_IMAGE" >/dev/null 2>&1 || {
  die "image ${CONTAGENT_IMAGE} not found locally"
}
[ -x "$launcher" ] || die "launcher not found/executable at $launcher"

trap cleanup EXIT

smoke_prefix="contagent-smoketest-${$}-$(date +%s)"
config_cli=$(jq -cn '{
  version: 2,
  features: [
    {name: "inc", volumes: [{enabled: true, path: "~/.smoke-inc"}]},
    {name: "offfeat", volumes: [{enabled: false, path: "~/.smoke-off"}]}
  ]
}')

config_overlap=$(jq -cn '{
  version: 2,
  features: [
    {name: "alpha", volumes: [{enabled: true, path: "~/.smoke-shared"}]},
    {name: "beta", volumes: [{enabled: true, path: "~/.smoke-shared"}]}
  ]
}')

img_cli="$smoke_prefix-cli"
img_overlap="$smoke_prefix-overlap"

build_config_image "$img_cli" "$config_cli"
build_config_image "$img_overlap" "$config_overlap"

echo "Running smoke checks for ${CONTAGENT_IMAGE} via ${launcher}"

run_step "identity mapping" run_in_launcher '
  test "$(id -u)" = "$CONTAGENT_UID"
  test "$(id -g)" = "$CONTAGENT_GID"
  test "$(id -un)" = "$CONTAGENT_USERNAME"
'

run_step "cache symlink + host mount wiring" run_cache_mount_test

run_step "docker cli available" run_in_launcher '
  command -v docker >/dev/null
  docker --version >/dev/null
'

run_step "docker daemon reachable" run_in_launcher_with_docker_socket 'docker ps >/dev/null'

run_step "dynamic show-options output" test_show_options_dynamic
run_step "unknown option error" test_unknown_option
run_step "source mount create-if-missing behavior" test_source_create_semantics
run_step "default off toggle behavior" test_default_off_toggle_semantics
run_step "overlapping feature volumes coalesce" test_overlapping_volume_feature_semantics
run_step "relative config paths resolve from config dir" test_relative_config_path_semantics

run_step "claude cli availability" run_in_launcher 'command -v claude >/dev/null && claude --version >/dev/null || true'
run_step "opencode cli availability" run_in_launcher 'command -v opencode >/dev/null && opencode --version >/dev/null || true'
run_step "pi cli availability" run_in_launcher 'command -v pi >/dev/null && pi --version >/dev/null || true'
run_step "codex cli availability" run_in_launcher 'command -v codex >/dev/null && codex --version >/dev/null || true'
run_step "copilot cli availability" run_in_launcher 'command -v copilot >/dev/null && copilot --version >/dev/null || true'
run_step "rust toolchain availability" run_in_launcher 'if command -v cargo >/dev/null; then cargo --version >/dev/null; command -v rustc >/dev/null; rustc --version >/dev/null; fi'
run_step "cargo install root usability" run_in_launcher 'if command -v cargo >/dev/null; then cargo install --list >/dev/null; fi'

if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
  run_step "ssh agent forwarding" run_in_launcher '
    [ -n "${SSH_AUTH_SOCK:-}" ]
    [ -S "$SSH_AUTH_SOCK" ]
  '
else
  echo "[SKIP] ssh agent forwarding (host SSH_AUTH_SOCK unavailable)"
fi

echo "Smoke checks completed"

#!/usr/bin/env bash

set -euo pipefail

CONTAGENT_IMAGE=${CONTAGENT_IMAGE:-contagent:latest}

# Normalize TMPDIR: a relative value makes mktemp emit relative paths, which
# break when used as HOME or docker mount sources below.
if [ -n "${TMPDIR:-}" ]; then
  if tmpdir_abs=$(cd "$TMPDIR" 2>/dev/null && pwd); then
    export TMPDIR="$tmpdir_abs"
  else
    unset TMPDIR
  fi
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat <<EOF
Usage: ./smoketest.sh [launcher]

launcher:
  Path to launcher to test (default: ./contagent)
  Examples:
    ./smoketest.sh
    ./smoketest.sh ./contagent
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

launcher_input=${1:-contagent}
if [[ "$launcher_input" = /* ]]; then
  launcher=$launcher_input
elif [[ "$launcher_input" == */* ]]; then
  # Absolutize: some tests run the launcher from other directories.
  launcher="$(cd "$(dirname "$launcher_input")" && pwd)/$(basename "$launcher_input")"
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
    --config "$(config_for_image "$CONTAGENT_IMAGE")" bash -lc "set -e; $1"
}


run_in_launcher_with_docker_socket() {
  CONTAGENT_IMAGE="$CONTAGENT_IMAGE" "$launcher" \
    --config "$(config_for_image "$CONTAGENT_IMAGE")" --docker bash -lc "set -e; $1"
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
  local rc=0 cache_dir="$HOME/.cache/contagent"
  # Nested inside contagent, ~/.cache is already the runtime cache mount;
  # the launcher's ~/.cache/contagent source names that mount on the real host.
  if [ -L "$HOME/.cache" ] && [ "$(readlink "$HOME/.cache")" = /var/cache/contagent ]; then
    cache_dir=/var/cache/contagent
  fi
  mkdir -p "$cache_dir"
  : >"$cache_dir/.host-to-container-$cache_token"

  run_launcher_image "$CONTAGENT_IMAGE" bash -lc "test -L \"\$HOME/.cache\" && test \"\$(readlink \"\$HOME/.cache\")\" = \"/var/cache/contagent\" && test -f \"\$HOME/.cache/.host-to-container-$cache_token\" && : > \"\$HOME/.cache/.container-to-host-$cache_token\"" \
    && test -f "$cache_dir/.container-to-host-$cache_token" || rc=1

  rm -f "$cache_dir/.host-to-container-$cache_token" "$cache_dir/.container-to-host-$cache_token"
  return "$rc"
}


feature_block() {
  awk -v name="$1" '$0 == "  - name: " name {f=1;next} /^  - name:/{f=0} f'
}


test_show_config_dynamic() {
  local out flagged
  out=$(run_launcher_image "$img_cli" --show-config) \
    && grep -F -- "name: inc" <<<"$out" >/dev/null \
    && grep -F -- "name: offfeat" <<<"$out" >/dev/null \
    && ! grep -F -- "name: hidden" <<<"$out" >/dev/null \
    && ! feature_block offfeat <<<"$out" | grep -F -- "enabled: true" >/dev/null \
    && flagged=$(run_launcher_image "$img_cli" --show-config --offfeat) \
    && feature_block offfeat <<<"$flagged" | grep -F -- "enabled: true" >/dev/null
}


test_unknown_option() {
  expect_fail_contains "unknown option: --bogus" run_launcher_image "$img_cli" --bogus true
}


test_source_create_semantics() {
  local tmp rc=0
  tmp=$(mktemp -d)
  HOME="$tmp" run_launcher_image "$img_cli" true >/dev/null 2>/dev/null \
    && test -e "$tmp/.smoke-inc" \
    && test -d "$tmp/host-abs-src" || rc=1
  rm -rf "$tmp"
  return "$rc"
}


test_default_off_toggle_semantics() {
  local tmp rc=0
  tmp=$(mktemp -d)

  # Fresh HOME per launch: HOME state can persist when it lands inside a
  # mounted tree (e.g. nested runs), and reuse trips the entrypoint guards.
  HOME="$tmp/off" run_launcher_image "$img_cli" true >/dev/null 2>/dev/null \
    && [ ! -e "$tmp/off/.smoke-off" ] \
    && HOME="$tmp/on" run_launcher_image "$img_cli" --offfeat true >/dev/null 2>/dev/null \
    && [ -e "$tmp/on/.smoke-off" ] || rc=1

  rm -rf "$tmp"
  return "$rc"
}


test_overlapping_volume_feature_semantics() {
  local tmp rc=0
  tmp=$(mktemp -d)

  HOME="$tmp/both" run_launcher_image "$img_overlap" true >/dev/null 2>/dev/null \
    && [ -d "$tmp/both/.smoke-shared" ] \
    && HOME="$tmp/beta" run_launcher_image "$img_overlap" --no-alpha true >/dev/null 2>/dev/null \
    && [ -d "$tmp/beta/.smoke-shared" ] \
    && HOME="$tmp/none" run_launcher_image "$img_overlap" --no-alpha --no-beta true >/dev/null 2>/dev/null \
    && [ ! -e "$tmp/none/.smoke-shared" ] || rc=1

  rm -rf "$tmp"
  return "$rc"
}


test_relative_volume_source_semantics() {
  local tmp rc=0
  tmp=$(mktemp -d)
  mkdir -p "$tmp/project" "$tmp/configs"

  cat >"$tmp/configs/relative.yaml" <<'EOF'
version: 2
image-hash: smoke
features:
  - name: inc
    volumes:
      - {source: ./host-rel, path: ~/.smoke-rel}
EOF

  HOME="$tmp/home" run_launcher_image_in_dir "$tmp/project" "$img_cli" \
    --config "$tmp/configs/relative.yaml" true >/dev/null 2>/dev/null \
    && [ -d "$tmp/project/host-rel" ] \
    && [ ! -e "$tmp/configs/host-rel" ] || rc=1

  rm -rf "$tmp"
  return "$rc"
}


test_environment_expansion_semantics() {
  local tmp rc=0 err
  tmp=$(mktemp -d)
  mkdir -p "$tmp/project"

  err=$(HOME="$tmp/home" run_launcher_image_in_dir "$tmp/project" "$img_cli" --env bash -lc '
    set -e
    test "$CONTAGENT_CWD" = "$PWD"
    test "$TMPDIR" = "$CONTAGENT_CWD/.smoke-env-tmp"
    test "$SMOKE_TILDE" = "$HOME/tilde-dir"
    test "$SMOKE_HOME" = "$HOME/from-home"
    test "$SMOKE_PWD" = "$CONTAGENT_CWD"
    test "$SMOKE_USER" = "$(id -un)"
    test "$SMOKE_UNKNOWN" = "\${NOT_A_THING}/x"
    test "$SMOKE_REL" = "./rel-literal"
    test -z "${SMOKE_NULL:-}"
    cd /
    test -d "$TMPDIR"
  ' 2>&1 >/dev/null) \
    && grep -F -- "non-string environment value for SMOKE_NULL" <<<"$err" >/dev/null \
    && grep -F -- "SMOKE_REL is passed literally" <<<"$err" >/dev/null || rc=1

  rm -rf "$tmp"
  return "$rc"
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
    {name: "inc", enabled: true,
     volumes: [{path: "~/.smoke-inc"}, {source: "${HOME}/host-abs-src", path: "~/.smoke-abs"}]},
    {name: "offfeat", enabled: false, volumes: [{path: "~/.smoke-off"}]},
    {name: "env", enabled: false,
     environment: {TMPDIR: "${CONTAGENT_CWD}/.smoke-env-tmp", SMOKE_TILDE: "~/tilde-dir",
                   SMOKE_HOME: "${HOME}/from-home", SMOKE_PWD: "${PWD}", SMOKE_USER: "${USER}",
                   SMOKE_UNKNOWN: "${NOT_A_THING}/x", SMOKE_NULL: null, SMOKE_REL: "./rel-literal"},
     volumes: [{path: ".smoke-env-tmp"}]}
  ]
}')

config_overlap=$(jq -cn '{
  version: 2,
  features: [
    {name: "alpha", enabled: true, volumes: [{path: "~/.smoke-shared"}]},
    {name: "beta", enabled: true, volumes: [{path: "~/.smoke-shared"}]}
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

run_step "dynamic show-config output" test_show_config_dynamic
run_step "unknown option error" test_unknown_option
run_step "source mount create-if-missing behavior" test_source_create_semantics
run_step "default off toggle behavior" test_default_off_toggle_semantics
run_step "overlapping feature volumes coalesce" test_overlapping_volume_feature_semantics
run_step "relative volume sources resolve from launcher cwd" test_relative_volume_source_semantics
run_step "environment expansion semantics" test_environment_expansion_semantics

run_step "claude cli availability" run_in_launcher 'command -v claude >/dev/null && claude --version >/dev/null || true'
run_step "opencode cli availability" run_in_launcher 'command -v opencode >/dev/null && opencode --version >/dev/null || true'
run_step "pi cli availability" run_in_launcher 'command -v pi >/dev/null && pi --version >/dev/null || true'
run_step "codex cli availability" run_in_launcher 'command -v codex >/dev/null && codex --version >/dev/null || true'
run_step "copilot cli availability" run_in_launcher 'command -v copilot >/dev/null && copilot --version >/dev/null || true'
run_step "java availability" run_in_launcher 'if [ -e /usr/local/jdk ]; then command -v java >/dev/null && java --version >/dev/null; fi'
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

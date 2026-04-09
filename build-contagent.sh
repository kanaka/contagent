#!/usr/bin/env bash

set -euo pipefail
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { printf 'ERROR: bash 4+ required\n' >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./build-contagent.sh [--<feature> ...]

Features, aliases, order, snippets, and version rules come from contagent.yaml.
Default features come from CONTAGENT_FEATURES.
Uses local yq when available, otherwise falls back to mikefarah/yq:4 via docker.
EOF
}

CONTAGENT_IMAGE_NAME=${CONTAGENT_IMAGE_NAME:-contagent}
CONTAGENT_FEATURES=${CONTAGENT_FEATURES:-}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
manifest_file="$script_dir/contagent.yaml"
dockerfile="$script_dir/.Dockerfile.generated"
motd_file="$script_dir/.contagent-motd.generated"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

for arg in "$@"; do [ "$arg" = -h ] || [ "$arg" = --help ] && { usage; exit 0; }; done

need_cmd docker
need_cmd jq
need_cmd gzip
[ -f "$manifest_file" ] || die "missing manifest: $manifest_file"

yq_cmd=(docker run --rm -i mikefarah/yq:4)
command -v yq >/dev/null 2>&1 && yq_cmd=(yq)

feature_rows=$(cat "$manifest_file" | "${yq_cmd[@]}" -r '.features[] | @json')

[ -n "$feature_rows" ] || die "manifest has no features"

declare -A wanted=()
declare -A unknown=()

for token in $CONTAGENT_FEATURES "$@"; do
  token=${token#--}
  [ -n "$token" ] || continue
  wanted["$token"]=1
  unknown["$token"]=1
done

: > "$dockerfile"
docker_args=()
motd_lines=()
component_labels=()

echo "Building image with selected features:"
while IFS= read -r feature; do
  label=$(jq -r '.names[0] // ""' <<<"$feature")
  path=$(jq -r '.path // ""' <<<"$feature")
  required=$(jq -r '.required // false' <<<"$feature")
  names_csv=$(jq -r '(.names // []) | join(",")' <<<"$feature")
  env_name=$(jq -r '.version.env // ""' <<<"$feature")
  default_value=$(jq -r '.version.default // ""' <<<"$feature")
  resolve_cmd=$(jq -r '.version.resolve // ""' <<<"$feature")
  mounts_csv=$(jq -r '(.mounts // []) | join(",")' <<<"$feature")

  [ -n "$label" ] && [ -n "$path" ] && [ -n "$names_csv" ] || die "invalid manifest row"
  select=0
  [ "$required" = true ] && select=1

  IFS=',' read -r -a names <<<"$names_csv"
  for token in "${names[@]}"; do
    [ -n "$token" ] || continue
    if [ -n "${wanted[$token]:-}" ]; then
      select=1
      unset 'unknown[$token]'
    fi
  done

  [ "$select" -eq 1 ] || continue
  [ -f "$script_dir/$path" ] || die "missing Dockerfile part: $path"
  [ -s "$dockerfile" ] && printf '\n' >> "$dockerfile"
  cat "$script_dir/$path" >> "$dockerfile"

  version_value=builtin
  if jq -e 'has("version")' >/dev/null <<<"$feature"; then
    version_value=${default_value:-latest}
    [ -n "$env_name" ] && version_value=${!env_name:-$version_value}
    if [ "$version_value" = latest ]; then
      [ -n "$resolve_cmd" ] || die "$label requested latest but has no resolve command"
      version_value=$(sh -lc "$resolve_cmd")
      [ -n "$version_value" ] && [ "$version_value" != null ] || die "failed to resolve latest for $label"
    fi
    [ -n "$env_name" ] && docker_args+=(--build-arg "$env_name=$version_value")
    motd_lines+=("$label $version_value")
    echo "  $label=$version_value"
  else
    echo "  $label"
  fi

  esc_version=${version_value//\"/\\\"}
  esc_mounts=${mounts_csv//\"/\\\"}
  component_labels+=("io.contagent.component.${label}.version=\"$esc_version\"")
  component_labels+=("io.contagent.component.${label}.mounts=\"$esc_mounts\"")
done <<<"$feature_rows"

[ "${#unknown[@]}" -eq 0 ] || die "unknown feature(s): $(printf '%s\n' "${!unknown[@]}" | sort -u | paste -sd',' -)"

[ -s "$dockerfile" ] || die "no features selected"

voom_version=$(REPO_ROOT_VOOM=1 "$script_dir/voom-like-version.sh")
image_ref="${CONTAGENT_IMAGE_NAME}:${voom_version}"

cat /dev/null > "$motd_file"
if [ "${#motd_lines[@]}" -gt 0 ]; then
  {
    printf 'contagent tool versions:\n'
    for line in "${motd_lines[@]}"; do
      printf '  - %s\n' "$line"
    done
  } > "$motd_file"
fi

if [ "${#component_labels[@]}" -gt 0 ]; then
  printf '\nLABEL' >> "$dockerfile"
  for label_kv in "${component_labels[@]}"; do
    printf ' %s' "$label_kv" >> "$dockerfile"
  done
  printf '\n' >> "$dockerfile"
fi

echo "Producing tags:"
echo "  $image_ref"
latest_ref="${CONTAGENT_IMAGE_NAME}:latest"
echo "  $latest_ref"
docker build "${docker_args[@]}" -t "$image_ref" -f "$dockerfile" "$script_dir"
docker tag "$image_ref" "$latest_ref"

echo "Run with:"
echo "  CONTAGENT_IMAGE=$image_ref ./contagent.sh"

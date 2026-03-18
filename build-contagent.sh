#!/usr/bin/env bash

set -euo pipefail
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { printf 'ERROR: bash 4+ required\n' >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./build-contagent.sh [--<feature> ...]

Features, aliases, order, snippets, and version rules come from Dockerfile.yaml.
Default features come from CONTAGENT_FEATURES.
Uses local yq when available, otherwise falls back to mikefarah/yq:4 via docker.
EOF
}

CONTAGENT_IMAGE_NAME=${CONTAGENT_IMAGE_NAME:-contagent}
CONTAGENT_FEATURES=${CONTAGENT_FEATURES:-}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
manifest_file="$script_dir/Dockerfile.yaml"
selected_dockerfile="$script_dir/Dockerfile.selected"
motd_file="$script_dir/.contagent-motd.generated"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
cleanup() { rm -f "$motd_file"; }
trap cleanup EXIT

for arg in "$@"; do [ "$arg" = -h ] || [ "$arg" = --help ] && { usage; exit 0; }; done

need_cmd docker
need_cmd jq
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

: > "$selected_dockerfile"
docker_args=()
motd_lines=()

echo "Building image with selected features:"
while IFS= read -r feature; do
  label=$(jq -r '.names[0] // ""' <<<"$feature")
  path=$(jq -r '.path // ""' <<<"$feature")
  required=$(jq -r '.required // false' <<<"$feature")
  names_csv=$(jq -r '(.names // []) | join(",")' <<<"$feature")
  env_name=$(jq -r '.version.env // ""' <<<"$feature")
  default_value=$(jq -r '.version.default // ""' <<<"$feature")
  resolve_cmd=$(jq -r '.version.resolve // ""' <<<"$feature")

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
  [ -s "$selected_dockerfile" ] && printf '\n' >> "$selected_dockerfile"
  cat "$script_dir/$path" >> "$selected_dockerfile"

  if [ -n "$env_name" ]; then
    requested=${!env_name:-$default_value}
    resolved=$requested
    if [ "$requested" = latest ]; then
      [ -n "$resolve_cmd" ] || die "$label requested latest but has no resolve command"
      resolved=$(sh -lc "$resolve_cmd")
      [ -n "$resolved" ] && [ "$resolved" != null ] || die "failed to resolve latest for $label ($env_name)"
    fi
    docker_args+=(--build-arg "$env_name=$resolved")
    motd_lines+=("$label $resolved")
    echo "  $label=$resolved"
  else
    echo "  $label"
  fi
done <<<"$feature_rows"

[ "${#unknown[@]}" -eq 0 ] || die "unknown feature(s): $(printf '%s\n' "${!unknown[@]}" | sort -u | paste -sd',' -)"

[ -s "$selected_dockerfile" ] || die "no features selected"

voom_version=$(REPO_ROOT_VOOM=1 "$script_dir/voom-like-version.sh")
image_ref="${CONTAGENT_IMAGE_NAME}:${voom_version}"

rm -f "$motd_file"
if [ "${#motd_lines[@]}" -gt 0 ]; then
  {
    printf 'contagent tool versions:\n'
    for line in "${motd_lines[@]}"; do
      printf '  - %s\n' "$line"
    done
  } > "$motd_file"
  printf '\nCOPY %s /etc/contagent-motd\n' "$(basename "$motd_file")" >> "$selected_dockerfile"
fi

echo "Producing tags:"
echo "  $image_ref"
latest_ref="${CONTAGENT_IMAGE_NAME}:latest"
echo "  $latest_ref"
docker build "${docker_args[@]}" -t "$image_ref" -f "$selected_dockerfile" "$script_dir"
docker tag "$image_ref" "$latest_ref"

echo "Run with:"
echo "  CONTAGENT_IMAGE=$image_ref ./contagent.sh"

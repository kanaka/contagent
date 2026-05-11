#!/usr/bin/env bash

set -euo pipefail
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { printf 'ERROR: bash 4+ required\n' >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./build-contagent.sh [--<feature> ...]

Features, aliases, order, snippets, and version rules come from build-contagent.yaml.
Default features come from CONTAGENT_FEATURES.
Uses local yq when available, otherwise falls back to mikefarah/yq:4 via docker.
EOF
}

CONTAGENT_IMAGE_NAME=${CONTAGENT_IMAGE_NAME:-contagent}
CONTAGENT_FEATURES=${CONTAGENT_FEATURES:-}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
manifest_file="$script_dir/build-contagent.yaml"
dockerfile="$script_dir/.Dockerfile.generated"
motd_file="$script_dir/.contagent-motd.generated"
default_config_file="$script_dir/.contagent-default.yaml.generated"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
json_string() {
  jq -Rn --arg s "$1" '$s|tojson' -r
}

escape_docker_label_value() {
  local value
  value=$(json_string "$1")
  value=${value//$/\\$}
  printf '%s' "$value"
}

for arg in "$@"; do [ "$arg" = -h ] || [ "$arg" = --help ] && { usage; exit 0; }; done

need_cmd docker
need_cmd jq
need_cmd gzip
[ -f "$manifest_file" ] || die "missing manifest: $manifest_file"

yq_cmd=(docker run --rm -i mikefarah/yq:4)
command -v yq >/dev/null 2>&1 && yq_cmd=(yq)

manifest_json=$("${yq_cmd[@]}" -r '. | @json' < "$manifest_file")
schema_version=$(printf '%s' "$manifest_json" | jq -r '.version // 2')
feature_rows=$(printf '%s' "$manifest_json" | jq -c '.features[]?')

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
runtime_config_body=$(mktemp)
trap 'rm -f "$runtime_config_body"' EXIT
printf 'version: %s\n\nfeatures:\n' "$schema_version" > "$runtime_config_body"
echo "Building image with selected features:"
while IFS= read -r feature; do
  label=$(jq -r '.name // "" | tostring' <<<"$feature")
  path=$(jq -r '.path // "" | tostring' <<<"$feature")
  required=$(jq -r 'if .required == true then "true" else "false" end' <<<"$feature")
  aliases_csv=$(jq -r '
    if .aliases == null then ""
    elif (.aliases | type) == "array" then (.aliases | map(tostring) | join(","))
    else "__invalid__"
    end
  ' <<<"$feature")

  [ "$aliases_csv" != "__invalid__" ] || die "invalid manifest row"
  [ -n "$label" ] && [ -n "$path" ] || die "invalid manifest row"

  names_csv=$label
  [ -n "$aliases_csv" ] && names_csv+=",$aliases_csv"

  select=0
  [ "$required" = "true" ] && select=1

  IFS=',' read -r -a names <<<"$names_csv"
  for token in "${names[@]}"; do
    [ -n "$token" ] || continue
    unset 'unknown[$token]'
    [ -n "${wanted[$token]:-}" ] && select=1
  done

  [ "$select" -eq 1 ] || continue
  env_type=$(jq -r 'if .env == null then "null" else (.env | type) end' <<<"$feature")
  [ "$env_type" = "null" ] || [ "$env_type" = "object" ] || die "invalid env entry in feature $label: env must be a map"

  volume_count=$(jq -r '(.volumes // []) | length' <<<"$feature")
  env_count=$(jq -r '(.env // {}) | length' <<<"$feature")
  if [ "$volume_count" -gt 0 ] || [ "$env_count" -gt 0 ]; then
    printf '  - name: %s\n' "$(json_string "$label")" >> "$runtime_config_body"
    if [ "$volume_count" -gt 0 ]; then
      printf '    volumes:\n' >> "$runtime_config_body"
      while IFS= read -r runtime_volume; do
        enabled=$(jq -r --arg required "$required" 'if $required == "true" then "true" elif .default == null then "true" else (.default | tostring) end' <<<"$runtime_volume")
        path_value=$(jq -r '.path // ""' <<<"$runtime_volume")
        printf '      - { enabled: %s, path: %s' "$enabled" "$(json_string "$path_value")" >> "$runtime_config_body"
        source_value=$(jq -r '.source // ""' <<<"$runtime_volume")
        [ -n "$source_value" ] && printf ', source: %s' "$(json_string "$source_value")" >> "$runtime_config_body"
        file_value=$(jq -r 'if has("file") then (.file | tostring) else "" end' <<<"$runtime_volume")
        [ -n "$file_value" ] && printf ', file: %s' "$file_value" >> "$runtime_config_body"
        ro_value=$(jq -r 'if has("read_only") then (.read_only | tostring) else "" end' <<<"$runtime_volume")
        [ -n "$ro_value" ] && printf ', read_only: %s' "$ro_value" >> "$runtime_config_body"
        printf ' }\n' >> "$runtime_config_body"
      done < <(jq -c '.volumes // [] | .[]' <<<"$feature")
    fi
    [ "$env_count" -gt 0 ] && printf '    environment: %s\n' "$(jq -c '.env' <<<"$feature")" >> "$runtime_config_body"
  fi

  mount_rows=()
  declare -A seen_mount_rows=()
  while IFS= read -r volume_row; do
    [ -n "$volume_row" ] || continue

    volume_path=$(jq -r 'if (.path != null and (.path | type) == "string") then .path else "" end' <<<"$volume_row")
    [ -n "$volume_path" ] || die "invalid volume entry in feature $label: path is required"

    source_state=$(jq -r '
      if has("source") and .source != null then
        if (.source | type) == "string" and .source != "" then "set" else "__invalid__" end
      else
        "unset"
      end
    ' <<<"$volume_row")
    [ "$source_state" != "__invalid__" ] || die "invalid volume entry in feature $label: source is required"

    if [ "$source_state" = "set" ]; then
      source=$(jq -r '.source' <<<"$volume_row")
    else
      source=$volume_path
    fi

    volume_default=$(jq -r 'if .default == null then "true" elif ((.default | type) == "boolean") then (.default | tostring) else "__invalid__" end' <<<"$volume_row")
    [ "$volume_default" != "__invalid__" ] || die "invalid volume entry in feature $label: default must be boolean"

    for key in file read_only; do
      value=$(jq -r --arg key "$key" 'if .[$key] == null then "null" elif ((.[$key] | type) == "boolean") then (.[$key] | tostring) else "__invalid__" end' <<<"$volume_row")
      [ "$value" != "__invalid__" ] || die "invalid volume entry in feature $label: $key must be boolean"
    done

    mount_row="$source:$volume_path"
    if [ -z "${seen_mount_rows[$mount_row]:-}" ]; then
      mount_rows+=("$mount_row")
      seen_mount_rows[$mount_row]=1
    fi
  done < <(jq -cr '(.volumes // []) | if type == "array" then .[] else empty end' <<<"$feature")

  if jq -e '(.volumes // []) | if type == "array" then (length > 0) else false end' >/dev/null <<<"$feature"; then
    mounts_csv=$(IFS=,; printf '%s' "${mount_rows[*]}")
  else
    mounts_csv=$(jq -r '(.mounts // []) | if type == "array" then map(tostring) | join(",") else "" end' <<<"$feature")
  fi

  [ -f "$script_dir/$path" ] || die "missing Dockerfile part: $path"
  [ -s "$dockerfile" ] && printf '\n' >> "$dockerfile"
  cat "$script_dir/$path" >> "$dockerfile"

  version_value=builtin
  if jq -e 'has("version")' >/dev/null <<<"$feature"; then
    env_name=$(jq -r '.version.env // ""' <<<"$feature")
    default_value=$(jq -r '.version.default // ""' <<<"$feature")
    resolve_cmd=$(jq -r '.version.resolve // ""' <<<"$feature")

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

  esc_version=$(escape_docker_label_value "$version_value")
  esc_mounts=$(escape_docker_label_value "$mounts_csv")
  component_labels+=("io.contagent.component.${label}.version=$esc_version")
  component_labels+=("io.contagent.component.${label}.mounts=$esc_mounts")
done <<<"$feature_rows"

[ "${#unknown[@]}" -eq 0 ] || die "unknown feature(s): $(printf '%s\n' "${!unknown[@]}" | sort -u | paste -sd',' -)"

runtime_config_id=$(sha256_file "$runtime_config_body")
{
  printf 'version: %s\n\n' "$schema_version"
  printf 'image-hash: %s\n\n' "$runtime_config_id"
  sed '1,/^$/d' "$runtime_config_body"
} > "$default_config_file"

[ -s "$dockerfile" ] || die "no features selected"
printf '\nRUN mkdir -p /usr/local/share/contagent\n' >> "$dockerfile"
printf 'COPY .contagent-default.yaml.generated /usr/local/share/contagent/contagent.yaml\n' >> "$dockerfile"

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

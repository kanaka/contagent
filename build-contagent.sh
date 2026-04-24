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
escape_docker_label_value() {
  local value
  value=$(jq -Rn --arg s "$1" '$s|tojson' -r)
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
selected_feature_names=()
declare -A volume_arg_default=()

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
  selected_feature_names+=("$label")

  env_type=$(jq -r 'if .env == null then "null" else (.env | type) end' <<<"$feature")
  [ "$env_type" = "null" ] || [ "$env_type" = "object" ] || die "invalid env entry in feature $label: env must be a map"

  mount_rows=()
  while IFS= read -r volume_row; do
    [ -n "$volume_row" ] || continue

    volume_arg_name=$(jq -r '.arg_name // "" | if type == "string" then . else "" end' <<<"$volume_row")
    [ -n "$volume_arg_name" ] || die "invalid volume entry in feature $label: arg_name is required"

    volume_path=$(jq -r 'if (.path != null and (.path | type) == "string") then .path else "" end' <<<"$volume_row")
    [ -n "$volume_path" ] || die "invalid volume entry in feature $label, arg $volume_arg_name: path is required"

    source_state=$(jq -r '
      if has("source") and .source != null then
        if (.source | type) == "string" and .source != "" then "set" else "__invalid__" end
      else
        "unset"
      end
    ' <<<"$volume_row")
    [ "$source_state" != "__invalid__" ] || die "invalid volume entry in feature $label, arg $volume_arg_name: source is required"

    has_sources=$(jq -r 'if .sources == null then "false" else "true" end' <<<"$volume_row")
    if [ "$source_state" = "set" ] && [ "$has_sources" = "true" ]; then
      die "invalid volume entry in feature $label, arg $volume_arg_name: use source or sources, not both"
    fi

    if [ "$has_sources" = "true" ]; then
      sources_type=$(jq -r '.sources | type' <<<"$volume_row")
      [ "$sources_type" = "array" ] || die "invalid volume entry in feature $label, arg $volume_arg_name: sources is required"

      mapfile -t source_list < <(jq -r '.sources[]? | if type == "string" then . else "__invalid__" end' <<<"$volume_row")
      [ "${#source_list[@]}" -gt 0 ] || die "invalid volume entry in feature $label, arg $volume_arg_name: sources is required"
      for source in "${source_list[@]}"; do
        [ "$source" != "__invalid__" ] || die "invalid volume entry in feature $label, arg $volume_arg_name: sources is required"
        [ -n "$source" ] || die "invalid volume entry in feature $label, arg $volume_arg_name: sources is required"
      done
    elif [ "$source_state" = "set" ]; then
      source=$(jq -r '.source' <<<"$volume_row")
      source_list=("$source")
    else
      source_list=("$volume_path")
    fi

    volume_default=$(jq -r 'if .default == null then "true" elif ((.default | type) == "boolean") then (.default | tostring) else "__invalid__" end' <<<"$volume_row")
    [ "$volume_default" != "__invalid__" ] || die "invalid volume entry in feature $label, arg $volume_arg_name: default must be boolean"

    for key in file read_only; do
      value=$(jq -r --arg key "$key" 'if .[$key] == null then "null" elif ((.[$key] | type) == "boolean") then (.[$key] | tostring) else "__invalid__" end' <<<"$volume_row")
      [ "$value" != "__invalid__" ] || die "invalid volume entry in feature $label, arg $volume_arg_name: $key must be boolean"
    done

    if [ -n "${volume_arg_default[$volume_arg_name]:-}" ] && [ "${volume_arg_default[$volume_arg_name]}" != "$volume_default" ]; then
      die "invalid manifest: arg_name '$volume_arg_name' has mixed default values (${volume_arg_default[$volume_arg_name]} vs $volume_default)"
    fi
    volume_arg_default[$volume_arg_name]=$volume_default

    for source in "${source_list[@]}"; do
      mount_rows+=("$source:$volume_path")
    done
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

features_json=$(jq -cn '$ARGS.positional' --args "${selected_feature_names[@]}")
esc_schema_version=$(escape_docker_label_value "$schema_version")
esc_manifest_json=$(escape_docker_label_value "$manifest_json")
esc_features_json=$(escape_docker_label_value "$features_json")
component_labels+=("io.contagent.schema.version=$esc_schema_version")
component_labels+=("io.contagent.manifest.json=$esc_manifest_json")
component_labels+=("io.contagent.manifest.features=$esc_features_json")

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

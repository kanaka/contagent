#!/usr/bin/env bash

set -euo pipefail
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || {
  printf 'ERROR: bash 4+ required\n' >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./contagent.sh [options] [--] [command ...]

Options:
  --<name>                    Enable a volume group from image metadata
  --no-<name>                 Disable a volume group from image metadata
  --show-options              Show image-defined --<name>/--no-<name> toggles and exit
  --extra-groups <gid[,gid]>  Append supplementary group GIDs for this run
  -h, --help                  Show this help
EOF
}

warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
path_exists() { [ -e "$1" ] || [ -S "$1" ]; }

resolve_path() {
  local raw=$1 home=$2 cwd=$3
  if [[ "$raw" == '~' || "$raw" == '~/'* ]]; then printf '%s' "$home${raw#\~}"; return; fi
  [[ "$raw" = /* ]] && { printf '%s' "$raw"; return; }
  printf '%s' "$cwd/$raw"
}

append_csv() {
  [ -n "$1" ] && printf '%s,%s' "$1" "$2" || printf '%s' "$2"
}

append_gid_unique() {
  local gid=$1 v
  for v in "${extra_group_gids[@]}"; do [ "$v" = "$gid" ] && return; done
  extra_group_gids+=("$gid")
}

append_feature_csv() {
  local csv=$1 feature=$2 item
  [ -n "$feature" ] || { printf '%s' "$csv"; return; }
  IFS=',' read -r -a _items <<<"$csv"
  for item in "${_items[@]}"; do [ "$item" = "$feature" ] && { printf '%s' "$csv"; return; }; done
  [ -n "$csv" ] && printf '%s,%s' "$csv" "$feature" || printf '%s' "$feature"
}

print_options() {
  local image=$1 name state
  if [ "${#option_order[@]}" -eq 0 ]; then
    printf 'Image %s exposes no volume toggles.\n' "$image"
    return
  fi
  printf 'Image volume toggles for %s:\n' "$image"
  for name in "${option_order[@]}"; do
    [ "${included_opt_safe[$name]}" = "true" ] && state=on || state=off
    printf '  --%s / --no-%s (default: %s; features: %s)\n' "$name" "$name" "$state" "${included_opt_features[$name]}"
  done
}

CONTAGENT_IMAGE=${CONTAGENT_IMAGE:-contagent:latest}
CONTAGENT_EXTRA_GROUP_GIDS=${CONTAGENT_EXTRA_GROUP_GIDS:-}
need_cmd docker
need_cmd jq

image_inspect=$(docker image inspect "$CONTAGENT_IMAGE" 2>/dev/null) || {
  die "image ${CONTAGENT_IMAGE} is not available locally; build it first with ./build-contagent.py"
}

schema_raw=$(printf '%s' "$image_inspect" | jq -r '.[0].Config.Labels["io.contagent.schema.version"] // ""')
[ -n "$schema_raw" ] || die "image is missing io.contagent.schema.version label; rebuild with ./build-contagent.py"
jq -rn --arg v "$schema_raw" '$v | tonumber | select(. == floor)' >/dev/null 2>&1 || die "image label io.contagent.schema.version is invalid"
schema_version=$(jq -rn --arg v "$schema_raw" '$v | tonumber | floor | tostring')
[ "$schema_version" = "2" ] || die "unsupported schema version: $schema_version"

manifest_json=$(printf '%s' "$image_inspect" | jq -cr '.[0].Config.Labels["io.contagent.manifest.json"] // empty | fromjson' 2>/dev/null) || die "invalid manifest in image labels"
[ -n "$manifest_json" ] || die "image is missing io.contagent.manifest.json label; rebuild with ./build-contagent.py"
selected_json=$(printf '%s' "$image_inspect" | jq -cr '.[0].Config.Labels["io.contagent.manifest.features"] // "[]" | fromjson' 2>/dev/null) || die "image label io.contagent.manifest.features is invalid"

declare -A selected_features=()
while IFS= read -r feature_name; do
  [ -n "$feature_name" ] && selected_features["$feature_name"]=1
done < <(printf '%s' "$selected_json" | jq -r 'if type == "array" then .[] | tostring else empty end')

declare -A all_opt_features=()
declare -A included_opt_safe=()
declare -A included_opt_features=()
declare -A enabled_opt=()
declare -a included_rows=()
declare -a env_rows=()

while IFS= read -r feature_json; do
  feature_name=$(printf '%s' "$feature_json" | jq -r '.name // "" | tostring')
  [ -n "$feature_name" ] || continue
  include_feature=
  [ -n "${selected_features[$feature_name]:-}" ] && include_feature=1

  while IFS= read -r volume_json; do
    arg_name=$(printf '%s' "$volume_json" | jq -r '.arg_name // "" | tostring')
    [ -n "$arg_name" ] || continue

    target=$(printf '%s' "$volume_json" | jq -r '.target // "" | tostring')
    safe=$(printf '%s' "$volume_json" | jq -r 'if .default == null then "true" elif .default then "true" else "false" end')
    file_flag=$(printf '%s' "$volume_json" | jq -r 'if .file == null then "false" elif .file then "true" else "false" end')
    read_only=$(printf '%s' "$volume_json" | jq -r 'if .read_only == null then "false" elif .read_only then "true" else "false" end')

    if [ "$(printf '%s' "$volume_json" | jq -r 'if has("sources") and .sources != null then "1" else "" end')" = "1" ]; then
      mapfile -t source_list < <(printf '%s' "$volume_json" | jq -r '.sources // [] | if type == "array" then .[] | tostring else empty end')
      create_if_missing=false
    else
      source_list=("$(printf '%s' "$volume_json" | jq -r '.source // "" | tostring')")
      create_if_missing=true
    fi

    for source in "${source_list[@]}"; do
      [ -n "$source" ] || continue
      row_target=${target:-$source}

      if [ -z "${all_opt_features[$arg_name]+x}" ]; then
        all_opt_features[$arg_name]=$feature_name
      else
        all_opt_features[$arg_name]=$(append_feature_csv "${all_opt_features[$arg_name]}" "$feature_name")
      fi

      if [ -n "$include_feature" ]; then
        if [ -z "${included_opt_safe[$arg_name]+x}" ]; then
          included_opt_safe[$arg_name]=$safe
          included_opt_features[$arg_name]=$feature_name
        else
          included_opt_features[$arg_name]=$(append_feature_csv "${included_opt_features[$arg_name]}" "$feature_name")
        fi
        included_rows+=("$arg_name"$'\t'"$source"$'\t'"$row_target"$'\t'"$file_flag"$'\t'"$read_only"$'\t'"$create_if_missing")
      fi
    done
  done < <(printf '%s' "$feature_json" | jq -c '.volumes // [] | if type == "array" then .[] else empty end | select(type == "object")')

  if [ -n "$include_feature" ]; then
    while IFS=$'\t' read -r key value; do
      env_rows+=("$key"$'\t'"$value")
    done < <(printf '%s' "$feature_json" | jq -r '.env // {} | if type == "object" then to_entries[] | [.key, (.value | tostring)] | @tsv else empty end')
  fi
done < <(printf '%s' "$manifest_json" | jq -c '.features // [] | if type == "array" then .[] else empty end | select(type == "object")')

option_order=()
if [ "${#included_opt_safe[@]}" -gt 0 ]; then
  mapfile -t option_order < <(printf '%s\n' "${!included_opt_safe[@]}" | sort)
fi
for name in "${option_order[@]}"; do
  [ "${included_opt_safe[$name]}" = "true" ] && enabled_opt[$name]=1 || enabled_opt[$name]=0
done

host_user=${USER:-$(id -un)}
host_group=$(id -gn)
host_uid=$(id -u)
host_gid=$(id -g)
host_home=${HOME:?HOME must be set}
workdir=$(pwd)

show_options=0
help_requested=0
extra_groups_csv=$CONTAGENT_EXTRA_GROUP_GIDS
argv=("$@")
i=0
while [ "$i" -lt "${#argv[@]}" ]; do
  arg=${argv[$i]}
  case "$arg" in
    --)
      i=$((i + 1))
      break
      ;;
    -h|--help)
      help_requested=1
      break
      ;;
    --show-options)
      show_options=1
      i=$((i + 1))
      ;;
    --extra-groups)
      [ $((i + 1)) -lt "${#argv[@]}" ] || die "--extra-groups requires a value"
      extra_groups_csv=$(append_csv "$extra_groups_csv" "${argv[$((i + 1))]}")
      i=$((i + 2))
      ;;
    --extra-groups=*)
      extra_groups_csv=$(append_csv "$extra_groups_csv" "${arg#--extra-groups=}")
      i=$((i + 1))
      ;;
    --no-*)
      name=${arg#--no-}
      if [ -n "${included_opt_safe[$name]:-}" ]; then
        enabled_opt[$name]=0
      elif [ -n "${all_opt_features[$name]:-}" ]; then
        die "option --no-$name is known but not included in image (feature(s): ${all_opt_features[$name]})"
      else
        die "unknown option: $arg"
      fi
      i=$((i + 1))
      ;;
    --*)
      name=${arg#--}
      if [ -n "${included_opt_safe[$name]:-}" ]; then
        enabled_opt[$name]=1
      elif [ -n "${all_opt_features[$name]:-}" ]; then
        die "option --$name is known but not included in image (feature(s): ${all_opt_features[$name]})"
      else
        die "unknown option: $arg"
      fi
      i=$((i + 1))
      ;;
    -*)
      die "unknown option: $arg"
      ;;
    *)
      break
      ;;
  esac
done
command=("${argv[@]:$i}")

if [ "$help_requested" -eq 1 ] || [ "$show_options" -eq 1 ]; then
  [ "$help_requested" -eq 1 ] && { usage; printf '\n'; }
  print_options "$CONTAGENT_IMAGE"
  exit 0
fi

docker_args=(--rm --workdir "$workdir" --volume "$workdir:$workdir")
[ -t 0 ] && [ -t 1 ] && docker_args+=(--interactive --tty)
docker_args+=(
  --env "CONTAGENT_USERNAME=$host_user"
  --env "CONTAGENT_GROUPNAME=$host_group"
  --env "CONTAGENT_UID=$host_uid"
  --env "CONTAGENT_GID=$host_gid"
  --env "CONTAGENT_HOME=$host_home"
)
[ -n "${TERM:-}" ] && docker_args+=(--env "TERM=$TERM")
[ -n "${COLORTERM:-}" ] && docker_args+=(--env "COLORTERM=$COLORTERM")
for env_row in "${env_rows[@]}"; do
  IFS=$'\t' read -r key value <<<"$env_row"
  [ -n "$key" ] && docker_args+=(--env "$key=$value")
done

declare -A target_candidates=()
declare -a target_order=()
for row in "${included_rows[@]}"; do
  IFS=$'\t' read -r arg_name source target file_flag read_only create_if_missing <<<"$row"
  [ "${enabled_opt[$arg_name]:-0}" -eq 1 ] || continue

  src=$(resolve_path "$source" "$host_home" "$workdir")
  dst=$(resolve_path "$target" "$host_home" "$workdir")
  candidate="$src"$'\t'"$read_only"$'\t'"$file_flag"$'\t'"$create_if_missing"

  if [ -z "${target_candidates[$dst]+x}" ]; then
    target_candidates[$dst]=$candidate
    target_order+=("$dst")
  else
    target_candidates[$dst]+=$'\n'"$candidate"
  fi
done

for dst in "${target_order[@]}"; do
  mapfile -t candidates < <(printf '%s\n' "${target_candidates[$dst]}" | sed '/^$/d')

  chosen=
  for candidate in "${candidates[@]}"; do
    IFS=$'\t' read -r src _ro _file _create <<<"$candidate"
    path_exists "$src" && { chosen=$candidate; break; }
  done

  if [ -z "$chosen" ]; then
    for candidate in "${candidates[@]}"; do
      IFS=$'\t' read -r src _ro file_flag create_if_missing <<<"$candidate"
      [ "$create_if_missing" = "true" ] || continue
      if [ "$file_flag" = "true" ]; then
        mkdir -p "$(dirname "$src")"
        : > "$src"
      else
        mkdir -p "$src"
      fi
      chosen=$candidate
      break
    done
  fi

  [ -n "$chosen" ] || die "no existing source found for target $dst among ${#candidates[@]} candidates"
  IFS=$'\t' read -r src read_only _file _create <<<"$chosen"
  mount_spec="$src:$dst"
  [ "$read_only" = "true" ] && mount_spec+=":ro"
  docker_args+=(--volume "$mount_spec")
done

if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
  docker_args+=(--volume "$SSH_AUTH_SOCK:$SSH_AUTH_SOCK" --env "SSH_AUTH_SOCK=$SSH_AUTH_SOCK")
else
  warn "SSH agent not available; SSH auth forwarding disabled"
fi

extra_group_gids=()
if [ -n "$extra_groups_csv" ]; then
  IFS=',' read -r -a configured_gids <<<"$extra_groups_csv"
  for gid in "${configured_gids[@]}"; do
    gid=${gid//[[:space:]]/}
    if [[ "$gid" =~ ^[0-9]+$ ]]; then
      append_gid_unique "$gid"
    else
      [ -z "$gid" ] || warn "ignoring non-numeric extra group gid: $gid"
    fi
  done
fi

if [ "${#extra_group_gids[@]}" -gt 0 ]; then
  extra_group_specs=()
  for gid in "${extra_group_gids[@]}"; do
    extra_group_specs+=("g$gid:$gid")
  done
  docker_args+=(--env "CONTAGENT_EXTRA_GROUP_SPECS=$(IFS=,; printf '%s' "${extra_group_specs[*]}")")
fi

exec docker run "${docker_args[@]}" "$CONTAGENT_IMAGE" "${command[@]}"

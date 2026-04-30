#!/usr/bin/env bash

set -euo pipefail
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { printf 'ERROR: bash 4+ required\n' >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./contagent.sh [options] [--] [command ...]

Options:
  --<feature>                 Enable volume mounts for an image feature
  --no-<feature>              Disable volume mounts for an image feature
  --show-options              Show image-defined --<feature>/--no-<feature> toggles and exit
  --extra-groups <gid[,gid]>  Append supplementary group GIDs for this run
  -h, --help                  Show this help
EOF
}

warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

resolve_path() {
  local raw=$1 home=$2 cwd=$3
  [[ "$raw" == '~' || "$raw" == '~/'* ]] && { printf '%s' "$home${raw#\~}"; return; }
  [[ "$raw" = /* ]] && { printf '%s' "$raw"; return; }
  printf '%s' "$cwd/$raw"
}

append_csv() {
  [ -n "$1" ] && printf '%s,%s' "$1" "$2" || printf '%s' "$2"
}

bool_value() {
  local value=$1 default=$2 name=$3 field=$4
  [[ -z "$value" || "$value" == null ]] && { printf '%s' "$default"; return; }
  [[ "$value" == true || "$value" == false ]] || die "invalid volume entry in feature $name: $field must be boolean"
  printf '%s' "$value"
}

apply_feature_toggle() {
  local arg=$1 feature=$2 state=$3 flag
  if [ -n "${included_default[$feature]+x}" ]; then
    enabled[$feature]=$state
  elif [ -n "${known_volume_feature[$feature]+x}" ]; then
    [ "$state" -eq 1 ] && flag="--$feature" || flag="--no-$feature"
    die "option $flag is known but not included in image (feature(s): $feature)"
  else
    die "unknown option: $arg"
  fi
}

print_options() {
  local image=$1 feature state
  if [ "${#option_order[@]}" -eq 0 ]; then
    printf 'Image %s exposes no volume toggles.\n' "$image"
    return
  fi
  printf 'Image volume toggles for %s:\n' "$image"
  for feature in "${option_order[@]}"; do
    [ "${included_default[$feature]}" = true ] && state=on || state=off
    printf '  --%s / --no-%s (default: %s; features: %s)\n' "$feature" "$feature" "$state" "$feature"
  done
}

CONTAGENT_IMAGE=${CONTAGENT_IMAGE:-contagent:latest}
CONTAGENT_EXTRA_GROUP_GIDS=${CONTAGENT_EXTRA_GROUP_GIDS:-}
need_cmd docker
need_cmd jq

image_inspect=$(docker image inspect "$CONTAGENT_IMAGE" 2>/dev/null) || {
  die "image ${CONTAGENT_IMAGE} is not available locally; build it first with ./build-contagent.py"
}

schema_raw=$(jq -r '.[0].Config.Labels["io.contagent.schema.version"] // ""' <<<"$image_inspect")
[ -n "$schema_raw" ] || die "image is missing io.contagent.schema.version label; rebuild with ./build-contagent.py"
if ! jq -rn --arg v "$schema_raw" '$v | tonumber | select(. == floor and . == 2)' >/dev/null 2>&1; then
  die "unsupported schema version: $schema_raw"
fi
manifest_json=$(jq -cr '.[0].Config.Labels["io.contagent.manifest.json"] // empty | fromjson' <<<"$image_inspect" 2>/dev/null) || die "invalid manifest in image labels"
[ -n "$manifest_json" ] || die "image is missing io.contagent.manifest.json label; rebuild with ./build-contagent.py"
selected_json=$(jq -cr '.[0].Config.Labels["io.contagent.manifest.features"] // "[]" | fromjson' <<<"$image_inspect" 2>/dev/null) || die "image label io.contagent.manifest.features is invalid"

declare -A selected=()
while IFS= read -r feature; do
  [ -n "$feature" ] && selected[$feature]=1
done < <(jq -r '.[] | tostring' <<<"$selected_json")

declare -A known_volume_feature=()
declare -A included_default=()
declare -A enabled=()
declare -a option_order=()
declare -a env_rows=()
declare -a volume_rows=()

while IFS= read -r feature_json; do
  feature=$(jq -r '.name // ""' <<<"$feature_json")
  [ -n "$feature" ] || continue

  mapfile -t volumes < <(jq -c '.volumes // [] | .[]' <<<"$feature_json")
  [ "${#volumes[@]}" -gt 0 ] || continue
  known_volume_feature[$feature]=1
  [ -n "${selected[$feature]+x}" ] || continue

  default=$(jq -r '.default' <<<"${volumes[0]}")
  default=$(bool_value "$default" true "$feature" default)
  included_default[$feature]=$default
  option_order+=("$feature")

  for volume in "${volumes[@]}"; do
    target=$(jq -r '.path // ""' <<<"$volume")
    [ -n "$target" ] || die "invalid volume entry in feature $feature: path is required"
    source=$(jq -r '.source' <<<"$volume")
    [[ -n "$source" && "$source" != null ]] || source=$target
    file_flag=$(bool_value "$(jq -r '.file' <<<"$volume")" false "$feature" file)
    read_only=$(bool_value "$(jq -r '.read_only' <<<"$volume")" false "$feature" read_only)
    create=false
    [[ "$source" == '~' || "$source" == '~/'* || "$source" != /* ]] && create=true
    volume_rows+=("$feature"$'\t'"$source"$'\t'"$target"$'\t'"$file_flag"$'\t'"$read_only"$'\t'"$create")
  done

  while IFS=$'\t' read -r key value; do
    [ -n "$key" ] && env_rows+=("$key"$'\t'"$value")
  done < <(jq -r '.env // {} | to_entries[] | [.key, (.value | tostring)] | @tsv' <<<"$feature_json")
done < <(jq -c '.features // [] | .[]' <<<"$manifest_json")

mapfile -t option_order < <(printf '%s\n' "${option_order[@]}" | sort)
for feature in "${option_order[@]}"; do
  [ "${included_default[$feature]}" = true ] && enabled[$feature]=1 || enabled[$feature]=0
done

show_options=0
help_requested=0
extra_groups_csv=$CONTAGENT_EXTRA_GROUP_GIDS
argv=("$@")
i=0
while [ "$i" -lt "${#argv[@]}" ]; do
  arg=${argv[$i]}
  case "$arg" in
    --) i=$((i + 1)); break ;;
    -h|--help) help_requested=1; break ;;
    --show-options) show_options=1; i=$((i + 1)) ;;
    --extra-groups)
      [ $((i + 1)) -lt "${#argv[@]}" ] || die "--extra-groups requires a value"
      extra_groups_csv=$(append_csv "$extra_groups_csv" "${argv[$((i + 1))]}")
      i=$((i + 2))
      ;;
    --extra-groups=*) extra_groups_csv=$(append_csv "$extra_groups_csv" "${arg#--extra-groups=}"); i=$((i + 1)) ;;
    --no-*=*|--*=*) die "unknown option: $arg" ;;
    --no-*) apply_feature_toggle "$arg" "${arg#--no-}" 0; i=$((i + 1)) ;;
    --*) apply_feature_toggle "$arg" "${arg#--}" 1; i=$((i + 1)) ;;
    -*) die "unknown option: $arg" ;;
    *) break ;;
  esac
done
command=("${argv[@]:$i}")

if [ "$help_requested" -eq 1 ] || [ "$show_options" -eq 1 ]; then
  [ "$help_requested" -eq 1 ] && { usage; printf '\n'; }
  print_options "$CONTAGENT_IMAGE"
  exit 0
fi

host_user=${USER:-$(id -un)}
host_group=$(id -gn)
host_uid=$(id -u)
host_gid=$(id -g)
host_home=${HOME:?HOME must be set}
workdir=$(pwd)

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
for row in "${env_rows[@]}"; do
  IFS=$'\t' read -r key value <<<"$row"
  docker_args+=(--env "$key=$value")
done

declare -A candidates_by_target=()
declare -a target_order=()
for row in "${volume_rows[@]}"; do
  IFS=$'\t' read -r feature source target file_flag read_only create <<<"$row"
  [ "${enabled[$feature]:-0}" -eq 1 ] || continue
  src=$(resolve_path "$source" "$host_home" "$workdir")
  dst=$(resolve_path "$target" "$host_home" "$workdir")
  candidate="$src"$'\t'"$read_only"$'\t'"$file_flag"$'\t'"$create"
  if [ -z "${candidates_by_target[$dst]+x}" ]; then
    candidates_by_target[$dst]=$candidate
    target_order+=("$dst")
  elif ! grep -Fx -- "$candidate" <<<"${candidates_by_target[$dst]}" >/dev/null; then
    candidates_by_target[$dst]+=$'\n'"$candidate"
  fi
done

for dst in "${target_order[@]}"; do
  mapfile -t candidates < <(printf '%s\n' "${candidates_by_target[$dst]}" | sed '/^$/d')
  chosen=
  for candidate in "${candidates[@]}"; do
    IFS=$'\t' read -r src _ro _file _create <<<"$candidate"
    { [ -e "$src" ] || [ -S "$src" ]; } && { chosen=$candidate; break; }
  done
  if [ -z "$chosen" ]; then
    for candidate in "${candidates[@]}"; do
      IFS=$'\t' read -r src _ro file_flag create <<<"$candidate"
      [ "$create" = true ] || continue
      if [ "$file_flag" = true ]; then
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
  [ "$read_only" = true ] && mount_spec+=:ro
  docker_args+=(--volume "$mount_spec")
done

if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
  docker_args+=(--volume "$SSH_AUTH_SOCK:$SSH_AUTH_SOCK" --env "SSH_AUTH_SOCK=$SSH_AUTH_SOCK")
else
  warn "SSH agent not available; SSH auth forwarding disabled"
fi

extra_group_gids=()
IFS=',' read -r -a configured_gids <<<"$extra_groups_csv"
for gid in "${configured_gids[@]}"; do
  gid=${gid//[[:space:]]/}
  if [[ "$gid" =~ ^[0-9]+$ ]] && [[ ! " ${extra_group_gids[*]} " =~ " $gid " ]]; then
    extra_group_gids+=("$gid")
  else
    [[ -z "$gid" || "$gid" =~ ^[0-9]+$ ]] || warn "ignoring non-numeric extra group gid: $gid"
  fi
done
if [ "${#extra_group_gids[@]}" -gt 0 ]; then
  extra_group_specs=()
  for gid in "${extra_group_gids[@]}"; do extra_group_specs+=("g$gid:$gid"); done
  docker_args+=(--env "CONTAGENT_EXTRA_GROUP_SPECS=$(IFS=,; printf '%s' "${extra_group_specs[*]}")")
fi

exec docker run "${docker_args[@]}" "$CONTAGENT_IMAGE" "${command[@]}"

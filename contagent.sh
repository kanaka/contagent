#!/usr/bin/env bash

set -euo pipefail
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || {
  printf 'ERROR: bash 4+ required\n' >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./contagent.sh [options] [command ...]

Options:
  --docker-socket              Mount host Docker socket into container
  --no-docker-socket           Do not mount host Docker socket
  --extra-groups <gid[,gid]>   Append supplementary group GIDs for this run
  -h, --help                   Show this help
EOF
}

warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

CONTAGENT_IMAGE=${CONTAGENT_IMAGE:-contagent:latest}
CONTAGENT_DOCKER_SOCKET=${CONTAGENT_DOCKER_SOCKET:-}
CONTAGENT_EXTRA_GROUP_GIDS=${CONTAGENT_EXTRA_GROUP_GIDS:-}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --docker-socket)
      CONTAGENT_DOCKER_SOCKET=1
      ;;
    --no-docker-socket)
      CONTAGENT_DOCKER_SOCKET=
      ;;
    --extra-groups)
      shift
      [ "$#" -gt 0 ] || die "--extra-groups requires a value"
      CONTAGENT_EXTRA_GROUP_GIDS+="${CONTAGENT_EXTRA_GROUP_GIDS:+,}$1"
      ;;
    --extra-groups=*)
      CONTAGENT_EXTRA_GROUP_GIDS+="${CONTAGENT_EXTRA_GROUP_GIDS:+,}${1#*=}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
  shift
done

host_user=${USER:-$(id -un)}
host_group=$(id -gn)
host_uid=$(id -u)
host_gid=$(id -g)
host_home=${HOME:?HOME must be set}
workdir=$(pwd)

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

append_gid_unique() {
  local gid=$1

  local existing
  for existing in "${extra_group_gids[@]}"; do
    [ "$existing" = "$gid" ] && return 0
  done
  extra_group_gids+=("$gid")
}

need_cmd docker
# Local-image-first by design; fail early instead of pulling implicitly.
docker image inspect "$CONTAGENT_IMAGE" >/dev/null 2>&1 || {
  die "image ${CONTAGENT_IMAGE} is not available locally; build it first with ./build-contagent.sh"
}

docker_args=(
  --rm
  --workdir "$workdir"
  --volume "$workdir:$workdir"
)
# Only request TTY when host side is interactive to preserve one-shot non-TTY behavior.
[ -t 0 ] && [ -t 1 ] && docker_args+=(--interactive --tty)

# These env vars are the authoritative identity contract for bootstrap and docker exec reuse.
docker_args+=(
  --env "CONTAGENT_USERNAME=$host_user"
  --env "CONTAGENT_GROUPNAME=$host_group"
  --env "CONTAGENT_UID=$host_uid"
  --env "CONTAGENT_GID=$host_gid"
  --env "CONTAGENT_HOME=$host_home"
)

[ -n "${TERM:-}" ] && docker_args+=(--env "TERM=$TERM")
[ -n "${COLORTERM:-}" ] && docker_args+=(--env "COLORTERM=$COLORTERM")

mountlist=(
  "$host_home/.claude:$host_home/.claude"
  "$host_home/.codex:$host_home/.codex"
  "$host_home/.copilot:$host_home/.copilot"
  "$host_home/.pi:$host_home/.pi"
  "$host_home/.supabase:$host_home/.supabase"
  "$host_home/.config/opencode:$host_home/.config/opencode"
  "$host_home/.local/share/opencode:$host_home/.local/share/opencode"
  "$host_home/.local/state/opencode:$host_home/.local/state/opencode"
  "$host_home/.cache/contagent:/var/cache/contagent"
)

# Precreate mountpoints to avoid root-owned host paths from first container write.
for mount_entry in "${mountlist[@]}"; do
  host_path=${mount_entry%%:*}
  mkdir -p "$host_path"
  docker_args+=(--volume "$mount_entry")
done

extra_group_gids=()
if [ -n "$CONTAGENT_EXTRA_GROUP_GIDS" ]; then
  # Accept explicit host gids for sockets/devices beyond docker.sock.
  IFS=',' read -r -a configured_gids <<<"$CONTAGENT_EXTRA_GROUP_GIDS"
  for gid in "${configured_gids[@]}"; do
    gid=${gid//[[:space:]]/}
    [[ "$gid" =~ ^[0-9]+$ ]] && append_gid_unique "$gid" || {
      [ -z "$gid" ] || warn "ignoring non-numeric extra group gid: $gid"
    }
  done
fi

docker_sock_candidates=(
  "$host_home/.docker/run/docker.sock"
  "$host_home/.colima/default/docker.sock"
  "/var/run/docker.sock"
)

CONTAGENT_DOCKER_SOCKET=${CONTAGENT_DOCKER_SOCKET//[[:space:]]/}

if [ -n "$CONTAGENT_DOCKER_SOCKET" ]; then
  mounted_docker_sock=0
  for sock in "${docker_sock_candidates[@]}"; do
    [ -S "$sock" ] || continue

    # Bind host daemon endpoint directly; no in-container daemon required.
    docker_args+=(--volume "$sock:$sock" --env "DOCKER_HOST=unix://$sock")
    mounted_docker_sock=1
    break
  done
  [ "$mounted_docker_sock" -eq 1 ] || {
    warn "Docker socket enabled but not found; in-container docker commands may not work"
  }
fi

if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
  # Forward the existing agent socket only; no key material is copied into the image.
  docker_args+=(
    --volume "$SSH_AUTH_SOCK:$SSH_AUTH_SOCK"
    --env "SSH_AUTH_SOCK=$SSH_AUTH_SOCK"
  )
else
  warn "SSH agent not available; SSH auth forwarding disabled"
fi

if [ "${#extra_group_gids[@]}" -gt 0 ]; then
  extra_group_specs=()
  for gid in "${extra_group_gids[@]}"; do
    extra_group_specs+=("g$gid:$gid")
  done
  docker_args+=(
    --env "CONTAGENT_EXTRA_GROUP_SPECS=$(IFS=,; printf '%s' "${extra_group_specs[*]}")"
  )
fi

[ "$#" -gt 0 ] || set -- bash -l
exec docker run "${docker_args[@]}" "$CONTAGENT_IMAGE" "$@"

#!/usr/bin/env bash

set -euo pipefail

CONTAGENT_USERNAME=${CONTAGENT_USERNAME:?required env var CONTAGENT_USERNAME is missing}
CONTAGENT_UID=${CONTAGENT_UID:?required env var CONTAGENT_UID is missing}
CONTAGENT_GID=${CONTAGENT_GID:?required env var CONTAGENT_GID is missing}
CONTAGENT_HOME=${CONTAGENT_HOME:?required env var CONTAGENT_HOME is missing}
CONTAGENT_GROUPNAME=${CONTAGENT_GROUPNAME:-$CONTAGENT_USERNAME}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

print_motd_if_interactive() {
  [ -t 0 ] && [ -t 1 ] || return 0
  [ -s /etc/contagent-motd ] || return 0

  cat /etc/contagent-motd
}

exec_as_user() {
  [ "$#" -gt 0 ] || set -- bash -l

  print_motd_if_interactive

  # Keep docker exec behavior deterministic: always set HOME/USER for mapped identity.
  exec runuser -u "$CONTAGENT_USERNAME" -- env \
    HOME="$CONTAGENT_HOME" \
    USER="$CONTAGENT_USERNAME" \
    "$@"
}

add_extra_groups() {
  local spec raw_name extra_gid extra_group

  [ -n "${CONTAGENT_EXTRA_GROUP_SPECS:-}" ] || return 0
  # Specs are host-derived name:gid pairs so supplemental group intent stays debuggable.
  IFS=',' read -r -a specs <<<"$CONTAGENT_EXTRA_GROUP_SPECS"
  for spec in "${specs[@]}"; do
    raw_name=${spec%%:*}
    extra_gid=${spec##*:}
    [[ "$extra_gid" =~ ^[0-9]+$ ]] || continue
    [ "$extra_gid" = "$CONTAGENT_GID" ] && continue

    getent group "$extra_gid" >/dev/null 2>&1 || {
      groupadd -g "$extra_gid" "$raw_name" >/dev/null 2>&1 || true
    }
    extra_group=$(getent group "$extra_gid" | cut -d: -f1 || true)
    [ -n "$extra_group" ] || continue
    usermod -aG "$extra_group" "$CONTAGENT_USERNAME" >/dev/null 2>&1 || true
  done
}

# docker exec path: if mapped user is already ready, skip mutating passwd/group state.
if getent passwd "$CONTAGENT_USERNAME" >/dev/null 2>&1 && \
  [ "$(id -u "$CONTAGENT_USERNAME")" = "$CONTAGENT_UID" ]; then
  exec_as_user "$@"
fi

# Keep host uid/gid semantics exact; prefer host primary group name for that gid.
if getent group "$CONTAGENT_GID" >/dev/null 2>&1; then
  current_group=$(getent group "$CONTAGENT_GID" | cut -d: -f1)
  if [ "$current_group" != "$CONTAGENT_GROUPNAME" ] && \
    ! getent group "$CONTAGENT_GROUPNAME" >/dev/null 2>&1; then
    groupmod -n "$CONTAGENT_GROUPNAME" "$current_group"
  fi
else
  groupadd -g "$CONTAGENT_GID" "$CONTAGENT_GROUPNAME"
fi

# Prefer requested username for UX continuity, but preserve uid truth for permissions.
uid_user=$(getent passwd "$CONTAGENT_UID" | cut -d: -f1 || true)
if getent passwd "$CONTAGENT_USERNAME" >/dev/null 2>&1; then
  [ "$(id -u "$CONTAGENT_USERNAME")" = "$CONTAGENT_UID" ] || {
    usermod -u "$CONTAGENT_UID" "$CONTAGENT_USERNAME"
  }
elif [ -n "$uid_user" ]; then
  usermod -l "$CONTAGENT_USERNAME" "$uid_user"
else
  useradd -M -K UID_MIN=0 -u "$CONTAGENT_UID" -g "$CONTAGENT_GID" \
    -d "$CONTAGENT_HOME" -s /bin/bash "$CONTAGENT_USERNAME"
fi

usermod -g "$CONTAGENT_GID" -d "$CONTAGENT_HOME" -s /bin/bash \
  "$CONTAGENT_USERNAME" >/dev/null 2>&1 || true
# Optional convenience for teams that run root tasks against bind mounts.
# usermod -aG root "$CONTAGENT_USERNAME" >/dev/null 2>&1 || true
add_extra_groups

docker_host=${DOCKER_HOST:-}
sock=${docker_host#unix://}
[ -n "$docker_host" ] && [ "$sock" != "$docker_host" ] && [ -S "$sock" ] && chmod 666 "$sock" >/dev/null 2>&1 || true

# Best-effort home dir fixup
mkdir -p "$CONTAGENT_HOME"
chown "$CONTAGENT_UID:$CONTAGENT_GID" "$CONTAGENT_HOME" >/dev/null 2>&1 || true
getent passwd "$CONTAGENT_USERNAME" >/dev/null 2>&1 || {
  die "mapped user $CONTAGENT_USERNAME does not exist after setup"
}

exec_as_user "$@"

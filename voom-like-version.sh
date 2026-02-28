#!/usr/bin/env bash
# Adapted from: https://github.com/Viasat/voom-util/blob/master/voom-like-version.sh
# Upstream license: Eclipse Public License 2.0 (EPL-2.0)

set -euo pipefail

voom_version() {
  echo "$(date --date="$(git log -1 --pretty=%ci -- "$@")" "+%Y%m%d_%H%M%S")-g$(git log -1 --pretty=%h -- "$@")$(test -z "$(git status --short -- "$@")" || echo _DIRTY)"
}

usage() {
  echo >&2 "usage: $0 <PATH> [PATH...]"
  echo >&2 "       REPO_ROOT_VOOM=1 $0"
  exit 1
}

if [ "$#" -eq 0 ]; then
  if [ -n "${REPO_ROOT_VOOM:-}" ]; then
    voom_version
  else
    usage
  fi
else
  if [ -n "${REPO_ROOT_VOOM:-}" ]; then
    usage
  else
    voom_version "$@"
  fi
fi

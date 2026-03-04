#!/usr/bin/env bash
# Adapted from: https://github.com/Viasat/voom-util/blob/master/voom-like-version.sh
# Upstream license: Eclipse Public License 2.0 (EPL-2.0)
set -euo pipefail

if date --version &>/dev/null; then
  fmt_date() { date --date="$1" "+%Y%m%d_%H%M%S"; }
else
  fmt_date() { date -jf "%Y-%m-%d %H:%M:%S %z" "$1" "+%Y%m%d_%H%M%S"; }
fi

voom_version() {
  echo "$(fmt_date "$(git log -1 --pretty=%ci -- "$@")")-g$(git log -1 --pretty=%h -- "$@")$(test -z "$(git status --short -- "$@")" || echo _DIRTY)"
}

usage() {
  echo >&2 "usage: $0 <PATH> [PATH...]"
  echo >&2 "       REPO_ROOT_VOOM=1 $0"
  exit 1
}

if [ "$#" -eq 0 ]; then
  [ -n "${REPO_ROOT_VOOM:-}" ] && voom_version || usage
else
  [ -z "${REPO_ROOT_VOOM:-}" ] && voom_version "$@" || usage
fi

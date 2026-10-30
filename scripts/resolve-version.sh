#!/usr/bin/env bash
# Decide which upstream version to build, and whether to publish it.
#
# Reads EVENT_NAME, REF_NAME, INPUT_VERSION, INPUT_PUBLISH from the environment
# (a workflow passes its own context values) and prints key=value results to
# stdout, appending them to GITHUB_OUTPUT when that is set.
#
# Rules:
#   INPUT_VERSION wins if set, with or without a leading "v".
#   Otherwise a ref name that looks like a version (a tag push: v1.1.0) is used.
#   Otherwise — a pull request, or a hand run with no version given — the newest
#   usable upstream release is built. Failing here would be wrong: a pull request
#   still has to build and test something, and "main" is not a version.
#   publish=true only for a tag push or when explicitly asked for.
set -uo pipefail

EVENT_NAME="${EVENT_NAME:-}"
REF_NAME="${REF_NAME:-}"
INPUT_VERSION="${INPUT_VERSION:-}"
INPUT_PUBLISH="${INPUT_PUBLISH:-}"

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"

say() { printf '%s\n' "$*" >&2; }
emit() { printf '%s=%s\n' "$1" "$2"; [[ -n "${GITHUB_OUTPUT:-}" ]] && printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; return 0; }

is_version() { [[ "${1}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; }

VERSION="${INPUT_VERSION#v}"
source_kind="input"

if ! is_version "${VERSION}"; then
  VERSION="${REF_NAME#v}"
  source_kind="ref"
fi

if ! is_version "${VERSION}"; then
  say "'${REF_NAME}' is not a version (${EVENT_NAME:-unknown event}); falling back to the newest usable upstream release"
  outputs=$(mktemp)
  # Only the results file is wanted here: the watcher's own key=value lines on
  # stdout would otherwise be copied into this step's outputs.
  GITHUB_OUTPUT="${outputs}" "${SCRIPT_DIR}/watch-upstream.sh" >/dev/null || true
  VERSION=$(sed -n 's/^version=//p' "${outputs}" | head -1)
  rm -f "${outputs}"
  source_kind="upstream-newest"
fi

if ! is_version "${VERSION}"; then
  say "::error::cannot determine an upstream version (event=${EVENT_NAME} ref=${REF_NAME} input=${INPUT_VERSION})"
  exit 1
fi

PUBLISH=false
if [[ "${EVENT_NAME}" == "push" ]]; then PUBLISH=true; fi
if [[ "${INPUT_PUBLISH}" == "true" ]]; then PUBLISH=true; fi

emit version "${VERSION}"
emit publish "${PUBLISH}"
say "building apt-cacher-ultra ${VERSION} (from ${source_kind}), publish=${PUBLISH}"

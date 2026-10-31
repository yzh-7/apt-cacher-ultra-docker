#!/usr/bin/env bash
# Print the path to the apt-cacher-ultra-docker checkout, or clone it.
#
#   ./locate.sh [--clone-into <dir>] [--repo-url <git url>]
#
# Every other script in this skill depends on this one: they all run the
# repository's own verified scripts rather than reimplementing them here.
# ACU_REPO wins if set. A checkout is recognized by having both
# deploy/compose.yaml and scripts/smoke-test.sh.
set -uo pipefail

REPO_URL="${ACU_GIT_URL:-https://github.com/yzh-7/apt-cacher-ultra-docker.git}"
CLONE_INTO="${ACU_CLONE_DIR:-.}"
REPO_NAME="apt-cacher-ultra-docker"

say() { printf '%s\n' "$*" >&2; }
die() { printf 'ERROR %s\n' "$*" >&2; exit 1; }

looks_like_repo() {
  local d="$1"
  [[ -n "${d}" && -d "${d}" ]] || return 1
  [[ -f "${d}/deploy/compose.yaml" && -f "${d}/scripts/smoke-test.sh" ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clone-into) CLONE_INTO="${2:?--clone-into needs a path}"; shift 2 ;;
    --repo-url)   REPO_URL="${2:?--repo-url needs a url}"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ -n "${ACU_REPO:-}" ]]; then
  looks_like_repo "${ACU_REPO}" || die "ACU_REPO=${ACU_REPO} is not an apt-cacher-ultra-docker checkout"
  printf '%s\n' "${ACU_REPO}"
  exit 0
fi

here="$(cd "$(dirname "${0}")/../.." && pwd)"   # .../apt-cacher-ultra-docker/.qoder/skills/<name>/scripts
candidates=(
  "."
  ".."
  "${here}"
  "${PWD}/${REPO_NAME}"
  "${PWD}/../${REPO_NAME}"
  "/usr/local/src/${REPO_NAME}"
  "/opt/${REPO_NAME}"
  "${HOME}/${REPO_NAME}"
)

for c in "${candidates[@]}"; do
  resolved="$(cd "${c}" 2>/dev/null && pwd)" || continue
  if looks_like_repo "${resolved}"; then
    say "found checkout: ${resolved}"
    printf '%s\n' "${resolved}"
    exit 0
  fi
done

say "no checkout found in: ${candidates[*]}"
command -v git >/dev/null || die "git is required to clone it; or set ACU_REPO to an existing checkout"
say "cloning ${REPO_URL} into ${CLONE_INTO}"
mkdir -p "${CLONE_INTO}"
dest="${CLONE_INTO}/${REPO_NAME}"
if [[ -d "${dest}" ]]; then die "${dest} already exists and is not a valid checkout"; fi
git clone --quiet "${REPO_URL}" "${dest}" || die "clone failed; check the repository URL and network access"
looks_like_repo "${dest}" || die "cloned tree does not look like the expected repository"
say "cloned to ${dest}"
printf '%s\n' "${dest}"

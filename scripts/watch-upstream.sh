#!/usr/bin/env bash
# Decide whether upstream published a release this repo has no build for.
#
#   ./watch-upstream.sh
#
# Environment:
#   UPSTREAM_OWNER / UPSTREAM_REPO   default linsomniac / apt-cacher-ultra
#   FORCED_VERSION                   pin a specific upstream version
#   GH_TOKEN / GITHUB_TOKEN          raises the API rate limit; not required
#   GITHUB_OUTPUT                    if set, results are appended to it
#   GH_REPO                          owner/repo whose tags are consulted
#
# Outputs (also echoed to stderr):
#   version      upstream version, no leading v
#   has_binary   1 if apt-cacher-ultra-<version>-linux-amd64 was published
#   has_sums     1 if SHA256SUMS was published
#   action       tag | skip | blocked
#   tag          the tag this repo would use (v<version>)
#
# action=blocked means a new version exists but cannot be containerized from the
# published assets (no binary, or no checksums to verify it with) — the pipeline
# stops instead of shipping an unverified binary.
set -uo pipefail

UP_OWNER="${UPSTREAM_OWNER:-linsomniac}"
UP_REPO="${UPSTREAM_REPO:-apt-cacher-ultra}"
FORCED="${FORCED_VERSION:-}"
APPLY="${APPLY:-0}"

say() { printf '%s\n' "$*" >&2; }
emit() { say "$1=$2"; [[ -n "${GITHUB_OUTPUT:-}" ]] && printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; return 0; }

command -v curl >/dev/null || { say "curl is required"; exit 2; }
command -v python3 >/dev/null || { say "python3 is required"; exit 2; }

AUTH=()
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[[ -n "${TOKEN}" ]] && AUTH=(-H "Authorization: Bearer ${TOKEN}")

TMP_JSON="$(mktemp)"
trap 'rm -f "${TMP_JSON}"' EXIT

say "querying ${UP_OWNER}/${UP_REPO} releases"
if ! curl -fsSL --retry 3 --max-time 60 -H 'Accept: application/vnd.github+json' \
        "${AUTH[@]}" "https://api.github.com/repos/${UP_OWNER}/${UP_REPO}/releases?per_page=30" \
        -o "${TMP_JSON}"; then
  say "could not read the upstream releases API"
  exit 2
fi

RESOLVED="$(python3 - "${TMP_JSON}" "${FORCED}" <<'PY'
import json, sys

path, forced = sys.argv[1], sys.argv[2].lstrip("v")
rels = json.load(open(path))

def usable(r):
    return not r.get("draft") and not r.get("prerelease")

if forced:
    chosen = next((r for r in rels if r["tag_name"].lstrip("v") == forced), None)
    if chosen is None:
        print("ERROR forced version is not an upstream release", file=sys.stderr)
        sys.exit(2)
else:
    chosen = next((r for r in rels if usable(r)), None)
    if chosen is None:
        print("ERROR no stable upstream release found", file=sys.stderr)
        sys.exit(2)

names = {a["name"] for a in chosen.get("assets", [])}
version = chosen["tag_name"].lstrip("v")
has_binary = 1 if f"apt-cacher-ultra-{version}-linux-amd64" in names else 0
has_sums = 1 if "SHA256SUMS" in names else 0
published = chosen.get("published_at", "unknown")
print(f"{version}\t{has_binary}\t{has_sums}\t{published}")
PY
)" || exit 2

IFS=$'\t' read -r VERSION HAS_BINARY HAS_SUMS PUBLISHED <<< "${RESOLVED}"
TAG="v${VERSION}"

emit version "${VERSION}"
emit has_binary "${HAS_BINARY}"
emit has_sums "${HAS_SUMS}"
emit tag "${TAG}"
say "newest stable upstream release: ${VERSION} (published ${PUBLISHED})"

if [[ "${HAS_BINARY}" != 1 || "${HAS_SUMS}" != 1 ]]; then
  say "release ${VERSION} is missing $( [[ ${HAS_BINARY} != 1 ]] && printf 'the linux-amd64 binary' )$( [[ ${HAS_SUMS} != 1 ]] && printf ' SHA256SUMS' )"
  say "refusing to build from unverified bits; use Dockerfile.source manually if you decide to trust a source build"
  emit action blocked
  exit 0
fi

# Does this repo already have a tag for that version? Asked through the API so
# the job needs no checkout and cannot be fooled by a stale local clone.
GH_REPO="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "${GH_REPO}" ]]; then
  say "GH_REPO is not set; cannot check existing tags — assuming this version is new"
  emit action tag
  exit 0
fi

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
        "${AUTH[@]}" \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${GH_REPO}/git/ref/tags/${TAG}")
case "${code}" in
  200)
    say "${TAG} already exists in ${GH_REPO}; nothing to do"
    emit action skip
    ;;
  404)
    say "${TAG} is new in ${GH_REPO}"
    emit action tag
    ;;
  *)
    say "could not query tags in ${GH_REPO} (http ${code}); refusing to create a tag blindly"
    emit action blocked
    ;;
esac

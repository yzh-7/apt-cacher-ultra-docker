#!/usr/bin/env bash
# Fetch the upstream apt-cacher-ultra release binary and verify it against
# upstream's own SHA256SUMS asset. Never trust a digest that was typed by hand.
#
#   ./fetch-upstream.sh <version> [<dest-dir>]
#
# Prints the verified sha256 on the last line. Exit codes:
#   0 verified binary in <dest-dir>/apt-cacher-ultra
#   2 bad usage / network / checksum mismatch
#   3 release exists but publishes no linux-amd64 binary (use Dockerfile.source)
set -euo pipefail

VERSION_RAW="${1:-}"
DEST="${2:-.}"
[[ -n "${VERSION_RAW}" ]] || { echo "usage: $0 <version> [<dest-dir>]" >&2; exit 2; }

OWNER="${UPSTREAM_OWNER:-linsomniac}"
REPO="${UPSTREAM_REPO:-apt-cacher-ultra}"
VERSION="${VERSION_RAW#v}"                 # accept both 1.0.2 and v1.0.2
API="https://api.github.com/repos/${OWNER}/${REPO}"
BIN_ASSET="apt-cacher-ultra-${VERSION}-linux-amd64"

command -v curl >/dev/null || { echo "curl is required" >&2; exit 2; }
command -v sha256sum >/dev/null || { echo "sha256sum is required" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 2; }

# Only used to raise the unauthenticated 60 req/h API limit when set.
AUTH=()
[[ -n "${GITHUB_TOKEN:-}" ]] && AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

mkdir -p "${DEST}"

# The Dockerfile's build context is this directory, and it copies exactly one
# file. Keep the fetched helpers (checksums, configs) out of the context so a
# stale config file can never be baked into an image.
printf '*\n!apt-cacher-ultra\n' > "${DEST}/.dockerignore"

REL_JSON="$(mktemp)"
trap 'rm -f "${REL_JSON}"' EXIT

curl -fsSL --retry 3 --max-time 60 -H 'Accept: application/vnd.github+json' \
     "${AUTH[@]}" "${API}/releases/tags/${VERSION}" -o "${REL_JSON}" \
  || { echo "release ${VERSION} not found in ${OWNER}/${REPO}" >&2; exit 2; }

eval "$(python3 - "${REL_JSON}" "${BIN_ASSET}" <<'PY'
import json, sys
rel = json.load(open(sys.argv[1]))
want_bin, want_sums = sys.argv[2], "SHA256SUMS"
assets = {a["name"]: a["browser_download_url"] for a in rel.get("assets", [])}
def out(k, v):
    print(f'{k}="{v}"')
out("BIN_URL", assets.get(want_bin, ""))
out("SUMS_URL", assets.get(want_sums, ""))
out("REL_STATE", "draft" if rel.get("draft") else ("prerelease" if rel.get("prerelease") else "published"))
PY
)"

if [[ "${REL_STATE}" != "published" ]]; then
  echo "refusing to containerize a ${REL_STATE} release (${VERSION})" >&2
  exit 2
fi
if [[ -z "${BIN_URL}" ]]; then
  echo "release ${VERSION} has no ${BIN_ASSET} asset." >&2
  echo "Build from source instead: docker build -f Dockerfile.source --build-arg ACU_VERSION=${VERSION}" >&2
  exit 3
fi
if [[ -z "${SUMS_URL}" ]]; then
  echo "release ${VERSION} publishes no SHA256SUMS asset; refusing an unverifiable binary." >&2
  exit 2
fi

echo "==> downloading ${BIN_ASSET}" >&2
curl -fsSL --retry 3 --max-time 600 -o "${DEST}/apt-cacher-ultra" "${BIN_URL}"
echo "==> downloading SHA256SUMS" >&2
curl -fsSL --retry 3 --max-time 120 -o "${DEST}/SHA256SUMS" "${SUMS_URL}"

# Verify only the asset we actually ship, matched by filename within the file.
grep -E "[ *]${BIN_ASSET}\$" "${DEST}/SHA256SUMS" > "${DEST}/SHA256SUMS.selected" \
  || { echo "SHA256SUMS does not cover ${BIN_ASSET}" >&2; exit 2; }
( cd "${DEST}" && sed "s|${BIN_ASSET}|apt-cacher-ultra|" SHA256SUMS.selected > SHA256SUMS.check \
  && sha256sum -c SHA256SUMS.check >&2 )

chmod 0755 "${DEST}/apt-cacher-ultra"
DIGEST="$(sha256sum "${DEST}/apt-cacher-ultra" | awk '{print $1}')"
echo "verified ${BIN_ASSET} sha256=${DIGEST} version=$("${DEST}/apt-cacher-ultra" -version 2>/dev/null || echo unknown)" >&2
echo "${DIGEST}"

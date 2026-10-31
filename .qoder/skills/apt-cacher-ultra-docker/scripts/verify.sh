#!/usr/bin/env bash
# The gate. Runs the repository's smoke test against a running container and
# reports what the daemon says about itself. Exit code == smoke test's exit code.
#
#   ./verify.sh [--mode prod|poc] [--container <name>] [--version X.Y.Z]
#               [--min-keys N] [--allow-open-admin] [--repo <path>]
#
# Ten gates have to pass before a deployment counts as working: healthz, keyring
# loaded, at least one key from the bind-mounted host keyrings, an upstream fetch,
# a cache hit on the second fetch, a real apt download, MITM HTTPS verified
# against this container's CA, the admin listener confined to loopback, the binary
# version matching, and a non-empty cache database.
set -uo pipefail

MODE="poc"
CONTAINER=""
VERSION=""
MIN_KEYS=9
EXTRA=()
REPO=""

SUDO=""
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then SUDO=1; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:?--mode needs prod or poc}"; shift 2 ;;
    --container) CONTAINER="${2:?--container needs a name}"; shift 2 ;;
    --version) VERSION="${2:?--version needs X.Y.Z}"; shift 2 ;;
    --min-keys) MIN_KEYS="${2:?--min-keys needs a number}"; shift 2 ;;
    --allow-open-admin) EXTRA+=(--allow-open-admin); shift ;;
    --repo) REPO="${2:?--repo needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'ERROR unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ -z "${REPO}" ]]; then REPO="$("$(cd "$(dirname "${0}")" && pwd)/locate.sh")" || exit 1; fi

if [[ "${MODE}" == prod ]]; then
  [[ -z "${CONTAINER}" ]] && CONTAINER="apt-cacher-ultra"
  ADMIN="http://127.0.0.1:6789"; PROXY="http://127.0.0.1:3142"
else
  [[ -z "${CONTAINER}" ]] && CONTAINER="apt-cacher-ultra-poc"
  ADMIN="http://127.0.0.1:16789"; PROXY="http://127.0.0.1:16790"
fi

state=$("${SUDO:+sudo}" docker inspect -f '{{.State.Status}}' "${CONTAINER}" 2>/dev/null || echo missing)
if [[ "${state}" != "running" ]]; then
  printf 'ERROR 容器 %s 状态是 %s，没有可验证的对象\n' "${CONTAINER}" "${state}" >&2
  exit 1
fi

# Version comes from the image that is actually running, not from what someone
# remembers the tag pointing at.
if [[ -z "${VERSION}" ]]; then
  image=$("${SUDO:+sudo}" docker inspect -f '{{.Config.Image}}' "${CONTAINER}" 2>/dev/null)
  VERSION=$("${SUDO:+sudo}" docker run --rm --entrypoint /usr/local/bin/apt-cacher-ultra "${image}" -version 2>/dev/null | tr -d '[:space:]')
  [[ -n "${VERSION}" ]] || { echo "无法从镜像里读出版本，请显式传 --version" >&2; exit 1; }
  echo "被测镜像报告版本：${VERSION}"
fi

"${SUDO:+sudo}" bash "${REPO}/scripts/smoke-test.sh" \
  --admin "${ADMIN}" --proxy "${PROXY}" --container "${CONTAINER}" \
  --version "${VERSION}" --min-keys "${MIN_KEYS}" ${EXTRA[@]+"${EXTRA[@]}"}
gate=$?

echo
"${SUDO:+sudo}" bash "${REPO}/scripts/metrics-snapshot.sh" "${ADMIN}"

exit ${gate}

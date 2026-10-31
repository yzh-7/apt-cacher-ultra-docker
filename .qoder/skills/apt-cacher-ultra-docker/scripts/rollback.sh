#!/usr/bin/env bash
# Put a specific image digest back in charge, then re-verify.
#
#   ./rollback.sh --repository <registry/project> --digest sha256:... [--mode prod|poc]
#                 [--cache-dir <dir>] [--config <toml>] [--repo <path>]
#   ./rollback.sh --image <registry/project@sha256:...> [...]
#
# Rollback is always by digest. Version tags lie twice here: 'latest' moves when
# the base image is refreshed, and a rebuild of the same upstream version keeps
# the version number while changing the digest. Compare digests, not names.
#
# The cache directory and config are not touched: the cache store, its CA and its
# database belong to the deployment, not to one image.
set -uo pipefail

IMAGE=""
REPOSITORY=""
DIGEST=""
MODE="poc"
CACHE_DIR=""
CONFIG=""
REPO=""

SUDO=""
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then SUDO=1; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="${2:?--image needs registry/project@sha256:...}"; shift 2 ;;
    --repository) REPOSITORY="${2:?--repository needs registry/project}"; shift 2 ;;
    --digest) DIGEST="${2:?--digest needs sha256:...}"; shift 2 ;;
    --mode) MODE="${2:?--mode needs prod or poc}"; shift 2 ;;
    --cache-dir) CACHE_DIR="${2:?--cache-dir needs a path}"; shift 2 ;;
    --config) CONFIG="${2:?--config needs a file}"; shift 2 ;;
    --repo) REPO="${2:?--repo needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'ERROR unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ -z "${IMAGE}" ]]; then
  [[ -n "${REPOSITORY}" && -n "${DIGEST}" ]] || { echo "需要 --image <ref@sha256:...>，或 --repository 加 --digest" >&2; exit 2; }
  printf '%s' "${DIGEST}" | grep -q '^sha256:' || { echo "--digest 必须是 sha256:<64 hex>" >&2; exit 2; }
  IMAGE="${REPOSITORY}@${DIGEST}"
fi
printf '%s' "${IMAGE}" | grep -q '@sha256:' || { echo "回滚必须固定到 digest，${IMAGE} 不是 digest 引用" >&2; exit 2; }

if [[ -z "${REPO}" ]]; then REPO="$("$(cd "$(dirname "${0}")" && pwd)/locate.sh")" || exit 1; fi
script_dir="$(cd "$(dirname "${0}")" && pwd)"

if [[ -z "${CACHE_DIR}" || -z "${CONFIG}" ]]; then
  container=$("${SUDO:+sudo}" docker ps --filter "name=apt-cacher-ultra" --format '{{.Names}}' | head -1)
  if [[ -n "${container}" ]]; then
    # Read the running deployment's own settings instead of guessing them.
    CACHE_DIR="${CACHE_DIR:-$("${SUDO:+sudo}" docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/apt-cacher-ultra"}}{{.Source}}{{end}}{{end}}' "${container}")}"
    CONFIG="${CONFIG:-$("${SUDO:+sudo}" docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/apt-cacher-ultra/config.toml"}}{{.Source}}{{end}}{{end}}' "${container}")}"
    [[ -z "${MODE}" ]] && MODE="poc"
  fi
fi
if [[ -z "${CACHE_DIR}" || -z "${CONFIG}" ]]; then
  echo "找不到当前部署的缓存目录/配置，请显式传 --cache-dir 与 --config" >&2
  exit 3
fi

old_image=$("${SUDO:+sudo}" docker ps --filter "name=apt-cacher-ultra" --format '{{.Image}}' | head -1)
echo "当前镜像：${old_image:-无运行中的容器}"
echo "回滚目标：${IMAGE}"

echo "拉取目标 digest…"
"${SUDO:+sudo}" docker pull --quiet "${IMAGE}" >/dev/null || { echo "拉取失败：${IMAGE} 在这个 registry 里不存在？" >&2; exit 1; }
new_version=$("${SUDO:+sudo}" docker run --rm --entrypoint /usr/local/bin/apt-cacher-ultra "${IMAGE}" -version 2>/dev/null | tr -d '[:space:]')
echo "目标镜像报告版本：${new_version:-未知}"

echo
"${script_dir}/deploy.sh" --mode "${MODE}" --image "${IMAGE}" --cache-dir "${CACHE_DIR}" --config "${CONFIG}" --repo "${REPO}"
rc=$?
if (( rc == 0 )); then
  echo "ROLLED BACK 现在跑的是 ${IMAGE}，验证已通过"
else
  echo "回滚后验证未通过（exit ${rc}）：现在运行的可能仍是目标镜像，先决定是回退到原镜像还是修配置" >&2
fi
exit ${rc}

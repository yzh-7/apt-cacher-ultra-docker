#!/usr/bin/env bash
# Start an apt-cacher-ultra container using the repository's compose files.
#
#   ./deploy.sh --mode poc|prod [--image <ref>] [--cache-dir <dir>] [--config <toml>]
#               [--container <name>] [--allow-takeover] [--no-verify] [--repo <path>]
#
# --image should be a digest reference (registry/project@sha256:...) whenever the
# deployment matters: 'latest' moves when the base image is refreshed, a digest
# does not.
#
# Without --cache-dir/--config this refuses and prints plan.sh's judgement first.
# Choosing the disk is plan.sh's job; this script only executes a chosen plan.
#
# Exit codes: 0 started and verified, 1 failure, 2 bad arguments,
# 3 needs a plan or the user's explicit approval first.
set -uo pipefail

MODE="poc"
IMAGE=""
CACHE_DIR=""
CONFIG=""
CONTAINER=""
TAKEOVER=0
DO_VERIFY=1
REPO=""

SUDO=""
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then SUDO=1; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:?--mode needs prod or poc}"; shift 2 ;;
    --image) IMAGE="${2:?--image needs an image reference}"; shift 2 ;;
    --cache-dir) CACHE_DIR="${2:?--cache-dir needs a path}"; shift 2 ;;
    --config) CONFIG="${2:?--config needs a file}"; shift 2 ;;
    --container) CONTAINER="${2:?--container needs a name}"; shift 2 ;;
    --allow-takeover) TAKEOVER=1; shift ;;
    --no-verify) DO_VERIFY=0; shift ;;
    --repo) REPO="${2:?--repo needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'ERROR unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ "${MODE}" == prod || "${MODE}" == poc ]] || { printf 'ERROR --mode must be prod or poc\n' >&2; exit 2; }
if [[ -z "${REPO}" ]]; then REPO="$("$(cd "$(dirname "${0}")" && pwd)/locate.sh")" || exit 1; fi
[[ -d "${REPO}" ]] || { printf 'ERROR repo checkout not found: %s\n' "${REPO}" >&2; exit 1; }

if [[ -z "${CACHE_DIR}" || -z "${CONFIG}" ]]; then
  echo "缺 --cache-dir/--config。先跑 plan.sh 看它怎么选盘、继承哪份配置：" >&2
  "$(cd "$(dirname "${0}")" && pwd)/plan.sh" --mode "${MODE}" >&2
  exit 3
fi
[[ -f "${CONFIG}" ]] || { printf 'ERROR 配置文件不存在: %s\n' "${CONFIG}" >&2; exit 1; }
[[ -d "${CACHE_DIR}" ]] || { printf 'ERROR 缓存目录不存在（先 plan.sh --apply）: %s\n' "${CACHE_DIR}" >&2; exit 1; }

if [[ "${MODE}" == prod ]]; then
  busy=$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':(3142|6789)$' | head -2 | tr '\n' ' ')
  if [[ -n "${busy}" && ${TAKEOVER} -eq 0 ]]; then
    printf 'ERROR 3142/6789 已被占用：%s。接管现有实例需要用户明确同意，然后加 --allow-takeover。\n' "${busy}" >&2
    exit 3
  fi
fi

compose_file="${REPO}/deploy/compose.poc.yaml"
container_name="${CONTAINER:-apt-cacher-ultra-poc}"
if [[ -n "${CONTAINER}" && "${CONTAINER}" != "apt-cacher-ultra-poc" ]]; then
  echo "提示：poc 的 compose 文件把容器名固定为 apt-cacher-ultra-poc，--container ${CONTAINER} 不生效" >&2
  container_name="apt-cacher-ultra-poc"
fi
admin_probe="127.0.0.1:16789"
proxy_probe="127.0.0.1:16790"
if [[ "${MODE}" == prod ]]; then
  compose_file="${REPO}/deploy/compose.yaml"
  container_name="${CONTAINER:-apt-cacher-ultra}"
  admin_probe="127.0.0.1:6789"
  proxy_probe="127.0.0.1:3142"
fi

if [[ -z "${IMAGE}" ]]; then
  IMAGE=$(sed -n 's/^ACU_IMAGE=//p' "${REPO}/deploy/compose.${MODE}.yaml" 2>/dev/null | head -1)
  IMAGE="${IMAGE:-ghcr.io/yzh-7/apt-cacher-ultra:latest}"
  echo "未指定 --image，用仓库默认：${IMAGE}"
fi
printf '%s' "${IMAGE}" | grep -q '@sha256:' || echo "提示：${IMAGE} 用的是 tag 而不是 digest，回滚时无法固定这一份"

echo "起容器：${container_name}  image=${IMAGE}"
echo "        cache=${CACHE_DIR}  config=${CONFIG}  admin=${admin_probe} proxy=${proxy_probe}"

# Values are handed to compose through --env-file, not the environment: sudo
# resets most environment variables by default, and an unwrapped `sudo docker
# compose` silently falls back to the compose file's own defaults. That is the
# difference between deploying where you planned and deploying somewhere else.
project_env="$(mktemp)"
cat > "${project_env}" <<EOF
ACU_IMAGE=${IMAGE}
ACU_CACHE_DIR=${CACHE_DIR}
ACU_CONFIG=${CONFIG}
ACU_CONTAINER_NAME=${container_name}
ACU_ADMIN_PROBE=${admin_probe}
EOF
chmod 600 "${project_env}"
trap 'rm -f "${project_env}"' EXIT

run_compose() {
  if [[ -n "${SUDO}" ]]; then
    sudo docker compose --env-file "${project_env}" -f "${compose_file}" "$@"
  else
    docker compose --env-file "${project_env}" -f "${compose_file}" "$@"
  fi
}

run_compose up -d || { echo "docker compose up 失败" >&2; "${SUDO:+sudo}" docker compose -f "${compose_file}" logs --tail 30 >&2; exit 1; }

echo "等待 healthcheck…"
for _ in $(seq 1 12); do
  state=$("${SUDO:+sudo}" docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${container_name}" 2>/dev/null || echo missing)
  [[ "${state}" == "healthy" ]] && break
  sleep 5
done
"${SUDO:+sudo}" docker ps --filter "name=${container_name}" --format '容器：{{.Names}} {{.Status}} {{.Image}}'

if (( DO_VERIFY == 0 )); then
  echo "已按要求跳过验证。注意：未验证不等于部署成功。"
  exit 0
fi

echo
"$(cd "$(dirname "${0}")" && pwd)/verify.sh" --mode "${MODE}" --container "${container_name}" --repo "${REPO}"
rc=$?
if (( rc != 0 )); then
  echo
  echo "验证未通过（exit ${rc}）。日志：" >&2
  "${SUDO:+sudo}" docker logs --tail 25 "${container_name}" >&2 2>&1 || true
fi
exit ${rc}

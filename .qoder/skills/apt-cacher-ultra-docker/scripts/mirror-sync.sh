#!/usr/bin/env bash
# Copy images from the public registry into the in-network registry, using the
# repository's own sync script and a root-owned env file for credentials.
#
#   ./mirror-sync.sh --env-file <path> [--tags "latest 1.0.2"] [--repo <path>]
#
# Credentials only ever come from the env file. There is deliberately no
# --user/--password flag: those land in shell history and in 'ps' output.
# The env file should be mode 600 and owned by whoever runs this.
#
# GitHub-hosted runners cannot reach a private address, so the pipeline publishes
# to GHCR and this runs on the machine that the in-network registry lives on.
set -uo pipefail

ENV_FILE=""
TAGS=""
REPO=""

SUDO=""
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then SUDO=1; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="${2:?--env-file needs a path}"; shift 2 ;;
    --tags) TAGS="${2:?--tags needs a quoted list}"; shift 2 ;;
    --repo) REPO="${2:?--repo needs a path}"; shift 2 ;;
    --user|--username|--password|--token|-u|-p)
      echo "不接受命令行凭据：凭据只从 --env-file 读。把值写进 env 文件（chmod 600）。" >&2
      exit 2 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'ERROR unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ -n "${ENV_FILE}" ]] || { echo "需要 --env-file（模板见 assets/sync.env.example）" >&2; exit 2; }
[[ -r "${ENV_FILE}" ]] || { echo "env 文件不可读：${ENV_FILE}" >&2; exit 1; }
mode=$(stat -c '%a' "${ENV_FILE}" 2>/dev/null || echo "")
if [[ -n "${mode}" && "${mode}" != "600" && "${mode}" != "400" ]]; then
  echo "提醒：${ENV_FILE} 权限是 ${mode}，里面有 registry 凭据，建议 chmod 600" >&2
fi

if [[ -z "${REPO}" ]]; then REPO="$("$(cd "$(dirname "${0}")" && pwd)/locate.sh")" || exit 1; fi
[[ -x "${REPO}/deploy/harbor-sync.sh" || -f "${REPO}/deploy/harbor-sync.sh" ]] || { echo "仓库里找不到 deploy/harbor-sync.sh" >&2; exit 1; }

# The repository script reads its own env file; variables set here win over the
# file, which is how --tags overrides SYNC_TAGS without editing the file.
# `sudo env VAR=... cmd` rather than `VAR=... sudo cmd`: sudo resets the
# environment unless asked not to, and the sync script only takes its
# configuration through those variables.
if [[ -n "${SUDO}" ]]; then
  sudo env ACU_SYNC_ENV="${ENV_FILE}" ${TAGS:+SYNC_TAGS="${TAGS}"} bash "${REPO}/deploy/harbor-sync.sh"
else
  env ACU_SYNC_ENV="${ENV_FILE}" ${TAGS:+SYNC_TAGS="${TAGS}"} bash "${REPO}/deploy/harbor-sync.sh"
fi
rc=$?

if (( rc == 0 )); then
  echo
  echo "MIRRORED 确认方法：仓库脚本每行 COPY 都打印了源 digest；对比两边同一 tag 的 digest 相同即同步成功。"
  echo "明文 HTTP 的 registry 用 docker buildx imagetools 读不到 digest（它没有 --insecure），要走 registry v2 API 的 Docker-Content-Digest 头。"
else
  echo "同步失败（exit ${rc}）。常见原因：robot 账号没有该项目的 push 权限、env 文件里的 registry/project 名不对、源 tag 还不存在。" >&2
fi
exit ${rc}

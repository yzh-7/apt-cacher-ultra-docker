#!/usr/bin/env bash
# Decide where the cache lives, which config it starts from, and which ports it
# may use — then print the whole judgement. Dry run by default.
#
#   ./plan.sh [--apply] [--mode prod|poc] [--cache-dir <dir>] [--config-source <toml>]
#             [--min-gb N] [--allow-takeover] [--accept-coupling] [--repo <path>]
#
# --apply creates the cache directory and derives the container config. It does
# not start anything: deployment is scripts/deploy.sh, and putting a proxy in
# front of clients is a decision the user makes.
#
# Exit codes: 0 plan ok (or applied), 1 could not proceed, 2 bad arguments,
# 3 plan produced questions that must be answered first.
set -uo pipefail

MODE="poc"
APPLY=0
ALLOW_TAKEOVER=0
ACCEPT_COUPLING=0
MIN_GB=10
CACHE_DIR=""
CONFIG_SOURCE=""
REPO=""
DIR_NAME="apt-cacher-ultra-container"

SUDO=""
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then SUDO=1; fi
run_as() { if [[ -n "${SUDO}" ]]; then sudo "$@"; else "$@"; fi; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --mode) MODE="${2:?--mode needs prod or poc}"; shift 2 ;;
    --cache-dir) CACHE_DIR="${2:?--cache-dir needs a path}"; shift 2 ;;
    --config-source) CONFIG_SOURCE="${2:?--config-source needs a file}"; shift 2 ;;
    --min-gb) MIN_GB="${2:?--min-gb needs a number}"; shift 2 ;;
    --allow-takeover) ALLOW_TAKEOVER=1; shift ;;
    --accept-coupling) ACCEPT_COUPLING=1; shift ;;
    --repo) REPO="${2:?--repo needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'ERROR unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ "${MODE}" == prod || "${MODE}" == poc ]] || { printf 'ERROR --mode must be prod or poc\n' >&2; exit 2; }

if [[ -z "${REPO}" ]]; then
  REPO="$("$(cd "$(dirname "${0}")" && pwd)/locate.sh")" || exit 1
fi
[[ -d "${REPO}" ]] || { printf 'ERROR repo checkout not found: %s\n' "${REPO}" >&2; exit 1; }

ask=()
notes=()
note() { notes+=("$1"); }
question() { ask+=("$1"); }

# ---------------------------------------------------------------- storage -----
in_fstab() { findmnt --fstab -rno TARGET 2>/dev/null | grep -qxF "$1"; }
avail_bytes() { df -B1 -P -- "$1" 2>/dev/null | awk 'NR==2{print $4}'; }
used_pct() { df -P -- "$1" 2>/dev/null | awk 'NR==2{print $5}'; }

declare -a cand_target=() cand_avail=()

# Split on whitespace: some util-linux releases emit tabs in raw mode, some emit
# spaces. Device paths with spaces are not worth dying on — a mount whose third
# field is not a device gets rejected by the filters below anyway.
while read -r target fstype source; do
  [[ -n "${target}" ]] || continue
  case "${fstype}" in ext4|xfs|btrfs) ;; *) continue ;; esac
  [[ "${source}" == /dev/* ]] || continue                     # tmpfs, overlay, nfs-ish
  printf '%s' "${target}" | grep -qE '^/(snap|run|dev|proc|sys|var/lib/kubelet|var/lib/docker)(/|$)' && continue
  if printf '%s' "${target}" | grep -qiE '/(backup|archive|swap|media)(/|$)'; then
    note "排除 ${target}：卷名表明它是备份/归档/交换用途"
    continue
  fi
  if [[ "${target}" == "/" || "${target}" == /boot* || "${target}" == /recovery* ]]; then
    note "排除 ${target}：系统盘（已用 $(used_pct "${target}")），缓存不写系统盘"
    continue
  fi
  if ! in_fstab "${target}"; then
    note "排除 ${target}：不在 /etc/fstab 里，重启后可能不存在（缓存目录会变空，CA 会丢）"
    continue
  fi
  ab=$(avail_bytes "${target}")
  [[ -n "${ab}" ]] || continue
  ag=$(( ab / 1073741824 ))
  if (( ag < MIN_GB )); then
    note "排除 ${target}：剩余 ${ag}G 低于门槛 ${MIN_GB}G"
    continue
  fi
  cand_target+=("${target}"); cand_avail+=("${ag}")
done < <(findmnt -rno 'TARGET,FSTYPE,SOURCE' 2>/dev/null | sort -u)

if (( ${#cand_target[@]} == 0 )); then
  question "这台机器上没有符合条件的数据盘候选。请指定缓存放哪，或明确同意使用系统盘（不推荐）。"
fi

# Inheritance: an apt cache already running here shows which disk the operator
# chose. Reuse the disk, never the same directory — one cache store cannot be
# shared by two daemons.
if [[ -z "${CONFIG_SOURCE}" ]]; then
  for guess in /etc/apt-cacher-ultra/config.toml /etc/apt-cacher-ultra/config.container.toml; do
    [[ -f "${guess}" ]] && { CONFIG_SOURCE="${guess}"; break; }
  done
fi
inherited_dir=""
if [[ -n "${CONFIG_SOURCE}" && -f "${CONFIG_SOURCE}" ]]; then
  inherited_dir=$(awk '/^\[cache\]/{f=1} f && /^[[:space:]]*dir[[:space:]]*=/{gsub(/.*= *"| *"/,""); print; exit}' "${CONFIG_SOURCE}")
fi

chosen=""
chosen_mount=""
if [[ -n "${CACHE_DIR}" ]]; then
  chosen="${CACHE_DIR}"
  chosen_mount=$(findmnt -n -o TARGET --target "${CACHE_DIR}" 2>/dev/null || echo "")
  [[ -z "${chosen_mount}" ]] && { printf 'ERROR --cache-dir %s 不在任何已挂载的文件系统上\n' "${CACHE_DIR}" >&2; exit 1; }
elif (( ${#cand_target[@]} > 0 )); then
  chosen=""
  if [[ -n "${inherited_dir}" ]]; then
    im=$(findmnt -n -o TARGET --target "${inherited_dir}" 2>/dev/null || echo "")
    for t in "${cand_target[@]}"; do
      if [[ "${t}" == "${im}" ]]; then
        chosen="${t}/${DIR_NAME}"; chosen_mount="${t}"
        note "沿用现有缓存所在的数据盘 ${t}，但换一个新目录（同一缓存存储不能同时给两个守护进程用）"
        break
      fi
    done
  fi
  if [[ -z "${chosen}" ]]; then
    best_i=0; best=${cand_avail[0]}
    for i in "${!cand_avail[@]}"; do (( cand_avail[i] > best )) && { best=${cand_avail[i]}; best_i=$i; }; done
    chosen="${cand_target[$best_i]}/${DIR_NAME}"; chosen_mount="${cand_target[$best_i]}"
    if (( ${#cand_target[@]} > 1 )); then
      others=("${cand_target[@]}"); others=("${others[@]/$chosen_mount/}")
      question "有多个候选数据盘（${cand_target[*]}），这里选了剩余空间最大的 ${chosen_mount}。要换另一块请说明。"
    fi
  fi
fi

# Coupling worth saying out loud rather than discovering later.
if command -v docker >/dev/null 2>&1; then
  droot=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "")
  if [[ -n "${droot}" ]]; then
    dm=$(findmnt -n -o TARGET --target "${droot}" 2>/dev/null || echo "")
    [[ "${dm}" == "/" ]] && note "注意：Docker 的 ${droot} 在系统盘上，每次拉镜像也写系统盘（本镜像解压约 38 MB）"
  fi
fi
if [[ -n "${chosen_mount}" ]] && ls -1 "${chosen_mount}" 2>/dev/null | grep -qiE '^(harbor|registry|registry-data)$'; then
  if (( ACCEPT_COUPLING == 1 )); then
    note "已确认接受：${chosen_mount} 同时是镜像 registry 存数据的盘（用户已用 --accept-coupling 认可容量互挤）"
  else
    question "选中的 ${chosen_mount} 同时是镜像 registry 存数据的盘，apt 缓存和 registry 会互相挤容量。接受（--accept-coupling），还是换一块盘？"
  fi
fi

# ------------------------------------------------------------------ config ----
# The derived config lives with the host's other apt-cacher-ultra configs, not
# inside the cache directory: that directory is 0750 owned by uid 113 so the
# operator who just planned the deployment could not otherwise read the file.
config_out="/etc/apt-cacher-ultra/config.poc.toml"
[[ "${MODE}" == prod ]] && config_out="/etc/apt-cacher-ultra/config.container.toml"

# ------------------------------------------------------------------ ports -----
port_note="poc 并行试点：代理 127.0.0.1:16790，管理 127.0.0.1:16789"
[[ "${MODE}" == prod ]] && port_note="prod：代理 :3142，管理 :6789"
busy=$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':(3142|6789)$' | head -2 | tr '\n' ' ')
if [[ -n "${busy}" ]]; then
  note "端口已被占用：${busy}（很可能已有 apt 缓存在跑）。默认只做并行试点。"
  if [[ "${MODE}" == prod && ${ALLOW_TAKEOVER} -eq 0 ]]; then
    question "要占用 3142/6789 必须先停掉现有实例。这一步需要你明确同意（deploy.sh --allow-takeover）。"
  fi
fi

# ----------------------------------------------------------------- report -----
echo "STORAGE"
if [[ -n "${chosen}" ]]; then
  ag=$(df -B1 -P -- "${chosen_mount}" 2>/dev/null | awk 'NR==2{printf "%.1f", $4/1073741824}')
  echo "  选定 ${chosen}  （盘 ${chosen_mount}，剩余约 ${ag}G；目录将以 113:112 0750 创建）"
else
  echo "  未选定：没有合格候选"
fi
if (( ${#notes[@]} )); then for n in "${notes[@]}"; do echo "  ${n}"; done; fi
echo "CONFIG"
if [[ -n "${CONFIG_SOURCE}" && -f "${CONFIG_SOURCE}" ]]; then
  echo "  源 ${CONFIG_SOURCE}（继承现有调优配置）→ 输出 ${config_out}"
  echo "  只改 dir、代理监听、管理监听、keyring_dirs；retention/gc/adoption/mitm/freshness 原样继承"
else
  echo "  源 上游打包默认 config.toml.default（这台机器上没有现成配置）→ 输出 ${config_out}"
fi
echo "  强制 --enable-adoption：上游默认 [adoption] enabled = false，照搬得到的是 KEYS 0、快照永不采纳的服务"
echo "PORTS"
echo "  ${port_note}"
echo "ASK"
if (( ${#ask[@]} == 0 )); then
  echo "  无"
else
  for q in "${ask[@]}"; do echo "  - ${q}"; done
fi

if (( ${#ask[@]} > 0 )) && (( APPLY == 1 )); then
  echo
  echo "PLAN BLOCKED 上面有需要你回答的项，未落盘。"
  exit 3
fi

if (( APPLY == 0 )); then
  echo
  echo "PLAN OK（dry-run，未做任何修改。下一步：plan.sh --apply，然后 deploy.sh --mode ${MODE}）"
  exit 0
fi

# ----------------------------------------------------------------- apply ------
[[ -n "${chosen}" ]] || { echo "PLAN FAILED 没有可选的缓存目录" >&2; exit 1; }
echo
echo "APPLY"
run_as install -d -m 0750 "${chosen}" || { echo "无法创建 ${chosen}" >&2; exit 1; }
run_as chown 113:112 "${chosen}" || { echo "无法把 ${chosen} 交给 uid 113（容器就是这个 uid，否则守护进程启动即退出）" >&2; exit 1; }

if [[ -n "${CONFIG_SOURCE}" && -f "${CONFIG_SOURCE}" ]]; then
  src="${CONFIG_SOURCE}"
else
  version=$(bash "${REPO}/scripts/resolve-version.sh" 2>/dev/null | sed -n 's/^version=//p' | head -1)
  [[ -n "${version}" ]] || { echo "干净主机需要上游默认配置，但版本解析失败" >&2; exit 1; }
  run_as curl -fsSL --retry 3 --max-time 60 -o "${chosen}/config.upstream.toml" \
    "https://raw.githubusercontent.com/linsomniac/apt-cacher-ultra/${version}/packaging/config/config.toml.default" \
    || { echo "取上游默认配置失败" >&2; exit 1; }
  src="${chosen}/config.upstream.toml"
fi
run_as bash "${REPO}/deploy/make-container-config.sh" "${MODE}" "${src}" "${config_out}" --enable-adoption \
  || { echo "配置派生失败（上游改了设置名就会这样）" >&2; exit 1; }

echo "  缓存目录 ${chosen}"
echo "  配置 ${config_out}"
echo "APPLIED 下一步：deploy.sh --mode ${MODE} --cache-dir ${chosen} --config ${config_out}"

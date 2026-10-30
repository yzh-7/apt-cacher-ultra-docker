#!/usr/bin/env bash
# One-time preparation of a host before the container is first started.
#
#   ./prepare.sh <cache-dir> [source-config] [mode: prod|poc]
#
# 1. Create the cache directory with the ownership the container runs as.
#    Skip this and the daemon exits at once with:
#      startup failed err="load config: cache.dir ...: not writable"
#    Docker creates a missing bind-mount source as root:root, so a first run on
#    a fresh host always needs this step. When you switch over from the .deb the
#    directory already exists with the right owner and this is a no-op.
# 2. Generate the container config from the host's config (see the script).
# 3. Check the three keyring directories exist to be mounted.
# 4. Print the commands to start and verify.
#
# Nothing here is destructive: it never deletes or chowns an existing directory
# with data in it. An existing non-empty cache directory keeps its ownership.
set -euo pipefail

usage() { echo "usage: prepare.sh <cache-dir> [source-config] [prod|poc]" >&2; exit 2; }
[[ $# -ge 1 ]] || usage
CACHE_DIR="$1"
SRC_CONFIG="${2:-/etc/apt-cacher-ultra/config.toml}"
MODE="${3:-prod}"
UID_WANT="${ACU_UID:-113}"
GID_WANT="${ACU_GID:-112}"

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
OUT_CONFIG="${ACU_OUT_CONFIG:-/etc/apt-cacher-ultra/config.container.toml}"
case "${MODE}" in
  prod) ADMIN_PROBE=127.0.0.1:6789;  PROXY_PROBE=127.0.0.1:3142  ;;
  poc)  ADMIN_PROBE=127.0.0.1:16789; PROXY_PROBE=127.0.0.1:16790 ;;
esac

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR %s\n' "$*" >&2; exit 1; }

say "=== 1. cache directory ${CACHE_DIR} (needs uid ${UID_WANT}:${GID_WANT}) ==="
if [[ -d "${CACHE_DIR}" ]]; then
  owner=$(stat -c '%u:%g' "${CACHE_DIR}")
  count=$(find "${CACHE_DIR}" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
  if [[ "${owner}" == "${UID_WANT}:${GID_WANT}" ]]; then
    say "OK    already owned by ${UID_WANT}:${GID_WANT} with ${count} entries; left untouched"
  elif (( count > 0 )); then
    say "WARN  owned by ${owner} and not empty (${count} entries)."
    say "      This looks like a live cache. Fix ownership deliberately, do not let prepare.sh do it:"
    say "        sudo chown -R ${UID_WANT}:${GID_WANT} ${CACHE_DIR}"
    die "refusing to chown a non-empty cache directory automatically"
  else
    say "FIX   empty directory owned by ${owner}; setting it to ${UID_WANT}:${GID_WANT}"
    chown "${UID_WANT}:${GID_WANT}" "${CACHE_DIR}"
  fi
else
  say "CREATE ${CACHE_DIR} as ${UID_WANT}:${GID_WANT} 0750"
  mkdir -p "${CACHE_DIR}"
  chown "${UID_WANT}:${GID_WANT}" "${CACHE_DIR}"
  chmod 0750 "${CACHE_DIR}"
fi

# The daemon verifies the directory is writable before it will start; prove it
# from this shell rather than finding out from the container's exit message.
if [[ -w "${CACHE_DIR}" ]]; then
  say "OK    writable from this shell ($(id -u):$(id -g))"
else
  say "WARN  not writable from this shell; run prepare.sh with the privileges that can create it"
fi

say
say "=== 2. container config ==="
[[ -r "${SRC_CONFIG}" ]] || die "cannot read ${SRC_CONFIG}; point the .deb's config or the upstream packaged default at argument 2"
"${SCRIPT_DIR}/make-container-config.sh" "${MODE}" "${SRC_CONFIG}" "${OUT_CONFIG}"
say "review it with: diff -u ${SRC_CONFIG} ${OUT_CONFIG}"

say
say "=== 3. keyring directories to mount ==="
missing=0
for d in /usr/share/keyrings /etc/apt/trusted.gpg.d /etc/apt/keyrings; do
  if [[ -d "${d}" ]]; then
    n=$(find "${d}" -maxdepth 1 -type f \( -name '*.gpg' -o -name '*.asc' \) 2>/dev/null | wc -l)
    say "OK    ${d} (${n} key files)"
  else
    say "WARN  ${d} does not exist on this host; drop that mount and keyring_dirs entry, or create it"
    missing=$((missing + 1))
  fi
done
(( missing > 0 )) && say "      adoption with require_signature=true fails for any suite signed by a key that is not loaded"

say
say "=== 4. next commands ==="
cat <<EOF
  cd ${SCRIPT_DIR}
  ACU_CACHE_DIR=${CACHE_DIR} ACU_CONFIG=${OUT_CONFIG} docker compose up -d
  ./scripts/smoke-test.sh --admin http://${ADMIN_PROBE} --proxy http://${PROXY_PROBE} \
      --container "${ACU_CONTAINER_NAME:-apt-cacher-ultra}" --min-keys 9 --expect-key-path /keyrings/
EOF

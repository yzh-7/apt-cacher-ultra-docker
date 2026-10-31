#!/usr/bin/env bash
# Run the same steps .github/workflows/build.yml runs, on any machine with Docker.
#
#   ./ci-rehearsal.sh [version]            # version defaults to the newest stable upstream release
#
# Everything the workflow does except logging in to GHCR and writing a release
# note: resolve the version, fetch and checksum-verify the upstream binary, derive
# the container config from the upstream packaged default, build, start the image
# with the hardened settings a real deployment uses, and run the smoke test that
# gates publishing.
#
# Use it to prove a new upstream release is containerizable before tagging it, to
# check a host can build and run this image, or to reproduce a CI failure locally.
# Exit code is the smoke test's exit code.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# The Dockerfile ARG default is the single declaration of the base image.
BASE_IMAGE="${BASE_IMAGE:-$(sed -n "s/^ARG BASE_IMAGE=//p" "${REPO_DIR}/Dockerfile" | head -1)}"
[[ -n "${BASE_IMAGE}" ]] || die "could not read ARG BASE_IMAGE from Dockerfile"
IMAGE_NAME="${IMAGE_NAME:-apt-cacher-ultra}"
WORK_DIR="${REHEARSAL_DIR:-${REPO_DIR}/.rehearsal}"
CONTAINER="${REHEARSAL_CONTAINER:-acu-rehearsal}"
LOCAL_IMAGE="acu-rehearsal:local"

# Same ports the workflow's smoke test uses: poc mode binds both listeners to
# loopback, so a rehearsal on a production cache host cannot be reached remotely
# and cannot collide with the real service on 3142/6789.
ADMIN_PORT="${REHEARSAL_ADMIN_PORT:-16789}"
PROXY_PORT="${REHEARSAL_PROXY_PORT:-16790}"

SUDO=""
if sudo -n true 2>/dev/null; then SUDO="sudo"; fi

log() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'ERROR %s\n' "$*" >&2; exit 1; }

cd "${REPO_DIR}" || die "cannot enter ${REPO_DIR}"
command -v docker >/dev/null || die "docker is required"

# --- 1. version ---------------------------------------------------------------
log "1. resolve version"
# Same helper the workflow uses, with the rehearsal's own event name, so version
# selection here cannot drift from what CI will do.
VERSION="${1:-}"
out=$(mktemp)
if ! EVENT_NAME=rehearsal REF_NAME=rehearsal INPUT_VERSION="${VERSION}" \
     GITHUB_OUTPUT="${out}" ./scripts/resolve-version.sh; then
  rm -f "${out}"; die "could not resolve an upstream version"
fi
VERSION=$(sed -n 's/^version=//p' "${out}" | head -1)
rm -f "${out}"
[[ -n "${VERSION}" ]] || die "resolve-version.sh produced no version"
[[ -n "${VERSION}" ]] || die "could not resolve an upstream version; pass one explicitly"
echo "version=${VERSION}"

# --- 2. fetch and verify the upstream binary ----------------------------------
log "2. fetch upstream binary and verify SHA256SUMS"
rm -rf "${WORK_DIR}" && mkdir -p "${WORK_DIR}"
./scripts/fetch-upstream.sh "${VERSION}" "${WORK_DIR}" || die "fetch/verify failed for ${VERSION}"
test -x "${WORK_DIR}/apt-cacher-ultra" || die "binary missing after fetch"

# --- 3. config derived from the upstream packaged default --------------------
log "3. derive container config (poc listeners, adoption enabled)"
config_url="https://raw.githubusercontent.com/linsomniac/apt-cacher-ultra/${VERSION}/packaging/config/config.toml.default"
curl -fsSL --retry 3 --max-time 60 -o "${WORK_DIR}/config.upstream.toml" "${config_url}" \
  || die "could not fetch ${config_url}"
./deploy/make-container-config.sh poc "${WORK_DIR}/config.upstream.toml" "${WORK_DIR}/config.container.toml" --enable-adoption \
  || die "config derivation failed (a renamed upstream setting would look like this)"
echo "--- diff upstream default -> container config ---"
diff -u "${WORK_DIR}/config.upstream.toml" "${WORK_DIR}/config.container.toml" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | head -20

# --- 4. build -----------------------------------------------------------------
log "4. build the image"
base_digest=$(docker buildx imagetools inspect "${BASE_IMAGE}" --format '{{.Manifest.Digest}}' 2>/dev/null || echo unknown)
echo "base ${BASE_IMAGE} = ${base_digest}"
docker build -f Dockerfile -t "${LOCAL_IMAGE}" \
  --build-arg BASE_IMAGE="${BASE_IMAGE}" \
  --build-arg BASE_IMAGE_RESOLVED="${base_digest}" \
  --build-arg ACU_VERSION="${VERSION}" \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --build-arg VCS_REF="$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
  "${WORK_DIR}" || die "docker build failed"
docker image inspect "${LOCAL_IMAGE}" --format 'labels: {{index .Config.Labels "org.opencontainers.image.version"}} / {{index .Config.Labels "io.aptcacherultra.docker.base-image-digest"}}'

# --- 5. start it the way a deployment does ------------------------------------
log "5. start with deployment mounts and hardening"
cache_dir="${WORK_DIR}/cache"
${SUDO} rm -rf "${cache_dir}" 2>/dev/null || true
${SUDO} install -d -m 0750 "${cache_dir}"
${SUDO} chown 113:112 "${cache_dir}" || die "cache dir must be writable by uid 113"
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER}" \
  --network host \
  --read-only \
  --tmpfs /tmp:size=64m,mode=1777 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 1024 \
  -v "${cache_dir}:/var/lib/apt-cacher-ultra" \
  -v "${WORK_DIR}/config.container.toml:/etc/apt-cacher-ultra/config.toml:ro" \
  -v /usr/share/keyrings:/keyrings/usr-share-keyrings:ro \
  -v /etc/apt/trusted.gpg.d:/keyrings/etc-apt-trusted.gpg.d:ro \
  -v /etc/apt/keyrings:/keyrings/etc-apt-keyrings:ro \
  "${LOCAL_IMAGE}" || die "docker run failed"
sleep 12

# --- 6. the gate ------------------------------------------------------------
log "6. smoke test (this is the publish gate)"
./scripts/smoke-test.sh \
  --admin "http://127.0.0.1:${ADMIN_PORT}" \
  --proxy "http://127.0.0.1:${PROXY_PORT}" \
  --container "${CONTAINER}" \
  --version "${VERSION}" \
  --min-keys 9 \
  --expect-key-path /keyrings/
gate=$?

log "cleanup"
docker logs "${CONTAINER}" 2>&1 | tail -12 || true
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
if [[ "${KEEP_REHEARSAL:-0}" != 1 ]]; then
  ${SUDO} rm -rf "${WORK_DIR}"
  docker rmi "${LOCAL_IMAGE}" >/dev/null 2>&1 || true
else
  echo "kept ${WORK_DIR} and ${LOCAL_IMAGE} (KEEP_REHEARSAL=1)"
fi

echo
if (( gate == 0 )); then
  echo "REHEARSAL OK — apt-cacher-ultra ${VERSION} builds, runs and passes the publish gate on this host."
else
  echo "REHEARSAL FAILED — the workflow would not publish ${VERSION}."
fi
exit ${gate}

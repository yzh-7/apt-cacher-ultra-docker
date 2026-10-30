#!/usr/bin/env bash
# Mirror an image from GHCR into the in-network Harbor registry.
#
# GitHub-hosted runners cannot reach a private address such as 172.31.0.3, so
# the pipeline publishes to GHCR and this script — which runs on the LAN host
# itself — copies it into Harbor. Run it on the host that Harbor lives on.
#
#   ./harbor-sync.sh                      # sync every tag in SYNC_TAGS
#   ./harbor-sync.sh 1.0.2                # sync one tag
#   DRY_RUN=1 ./harbor-sync.sh            # print what would happen
#
# Environment (see harbor-sync.env.example; a readable harbor-sync.env next to
# this script is sourced automatically):
#   HARBOR_REGISTRY, HARBOR_PROJECT, HARBOR_USER, HARBOR_PASSWORD   push target
#   GHCR_IMAGE, GHCR_USER, GHCR_TOKEN                               pull source
#   SYNC_TAGS, IMAGE_NAME, DRY_RUN
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
[[ -r "${SCRIPT_DIR}/harbor-sync.env" ]] && { . "${SCRIPT_DIR}/harbor-sync.env"; }

GHCR_IMAGE="${GHCR_IMAGE:-ghcr.io/yzh-7/apt-cacher-ultra}"
# GHCR credentials are optional. A public package pulls anonymously, which keeps
# a long-lived token off the cache server. Set GHCR_USER/GHCR_TOKEN (a
# fine-grained PAT with read:packages, or a GHCR robot account) only when the
# package is private.
GHCR_USER="${GHCR_USER:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"

IMAGE_NAME="${IMAGE_NAME:-apt-cacher-ultra}"
HARBOR_REGISTRY="${HARBOR_REGISTRY:-172.31.0.3:7777}"
HARBOR_PROJECT="${HARBOR_PROJECT:-infrastructure}"
HARBOR_USER="${HARBOR_USER:?HARBOR_USER is required (use a Harbor robot account)}"
HARBOR_PASSWORD="${HARBOR_PASSWORD:?HARBOR_PASSWORD is required}"

# Space-separated tags. Syncing "latest" plus the pinned version means a host can
# either follow or pin without a second sync job.
SYNC_TAGS="${SYNC_TAGS:-latest 1.0.2}"
DRY_RUN="${DRY_RUN:-0}"

# Harbor on this deployment is served over plain HTTP, so it has to be listed as
# an insecure registry in /etc/docker/daemon.json (it already is on 172.31.0.3).
if ! docker info 2>/dev/null | grep -q "${HARBOR_REGISTRY}"; then
  echo "warning: ${HARBOR_REGISTRY} is not listed under Insecure Registries in docker info." >&2
  echo "         add {\"insecure-registries\":[\"${HARBOR_REGISTRY}\"]} to /etc/docker/daemon.json and restart docker." >&2
fi

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

if [[ -n "${GHCR_TOKEN}" ]]; then
  printf '%s' "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USER}" --password-stdin >/dev/null
  log "logged in to ghcr.io as ${GHCR_USER}"
else
  log "pulling from ghcr.io anonymously (set GHCR_USER/GHCR_TOKEN if the package is private)"
fi
printf '%s' "${HARBOR_PASSWORD}" | docker login "${HARBOR_REGISTRY}" -u "${HARBOR_USER}" --password-stdin >/dev/null
log "logged in to ${HARBOR_REGISTRY} as ${HARBOR_USER}"

# Digest lookups must not abort the run: a tag that does not exist upstream yet
# is the normal state right before the next release, not an error.
digest() { docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "${1}" 2>/dev/null || true; }

pushed=0
skipped=0
for tag in ${SYNC_TAGS}; do
  src="${GHCR_IMAGE}:${tag}"
  dst="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${IMAGE_NAME}:${tag}"

  # Preserve the digest across the mirror: when Harbor already holds exactly this
  # image digest, do nothing. That keeps "latest" from being rewritten for no
  # reason and makes the timer safe to run every hour.
  src_digest=$(digest "${src}")
  if [[ -z "${src_digest}" ]]; then
    log "SKIP  ${src} (not present in GHCR)"
    skipped=$((skipped + 1))
    continue
  fi

  dst_digest=$(digest "${dst}")
  if [[ "${src_digest}" == "${dst_digest}" ]]; then
    log "OK    ${dst} already at ${src_digest}"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ "${DRY_RUN}" == 1 ]]; then
    log "WOULD ${src} (${src_digest}) -> ${dst} (was ${dst_digest:-absent})"
    pushed=$((pushed + 1))
    continue
  fi

  log "COPY  ${src} (${src_digest}) -> ${dst}"
  docker pull --quiet "${src}" >/dev/null
  docker tag "${src}" "${dst}"
  docker push --quiet "${dst}" >/dev/null
  # Drop both local tags: the cache server should not accumulate image layers
  # that only Harbor needs. The running container keeps its own reference.
  docker rmi --quiet "${src}" "${dst}" >/dev/null 2>&1 || true
  pushed=$((pushed + 1))
done

# Only the tags in SYNC_TAGS are mirrored, not the whole tag history: copying
# every historical version on every run costs bandwidth and Harbor storage for
# images nobody pulls. Older versions stay available on GHCR.
log "done (${pushed} mirrored, ${skipped} already present or absent)"

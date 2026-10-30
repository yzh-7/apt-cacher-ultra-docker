#!/usr/bin/env bash
# Derive a container config from an existing host config.toml (or from the
# upstream packaged default) instead of hand-writing one.
#
#   ./make-container-config.sh <prod|poc> [source-config] [output] [--enable-adoption]
#
# Exactly four things are rewritten; every other setting (retention, gc,
# adoption, MITM, freshness) is inherited verbatim so the container behaves
# like the systemd instance it replaces.
#
#   cache dir          -> /var/lib/apt-cacher-ultra   (the compose volume)
#   proxy listener     -> 0.0.0.0:3142   (poc: 127.0.0.1:16790)
#   admin listener     -> 0.0.0.0:6789   (poc: 127.0.0.1:16789)
#   adoption.keyring_dirs -> the three keyring directories the compose file
#                            bind-mounts from the host
#
# --enable-adoption matters more than it looks: the upstream packaged default
# ships [adoption] enabled = false, which means the daemon loads no signing
# keys at all (the status page reads "KEYS 0") and never adopts signed
# snapshots. A container started from that default is a different service from
# a tuned host instance. Pass --enable-adoption (or set ACU_ENABLE_ADOPTION=1)
# when you want the container to verify InRelease signatures and adopt
# snapshots; leave it off only if that is deliberate.
#
# The keyring rewrite is not cosmetic. The daemon verifies InRelease signatures
# with keys it loads itself; the .deb's systemd unit let it read the host's
# /usr/share/keyrings and /etc/apt/trusted.gpg.d directly. Inside a container
# those paths do not exist, so with adoption.require_signature=true every
# adoption fails (gpg_failed) until the host keyrings are mounted AND listed
# here.
set -euo pipefail

MODE="${1:-prod}"
SRC="${2:-/etc/apt-cacher-ultra/config.toml}"
OUT="${3:-config.${MODE}.toml}"
shift 3 2>/dev/null || true
ENABLE_ADOPTION="${ACU_ENABLE_ADOPTION:-0}"
for arg in "$@"; do
  case "${arg}" in
    --enable-adoption) ENABLE_ADOPTION=1 ;;
    *) echo "unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

CACHE_DIR=/var/lib/apt-cacher-ultra
case "${MODE}" in
  prod) PROXY=0.0.0.0:3142;    ADMIN=0.0.0.0:6789    ;;
  poc)  PROXY=127.0.0.1:16790; ADMIN=127.0.0.1:16789 ;;
  *) echo "mode must be prod or poc" >&2; exit 2 ;;
esac

[[ -r "${SRC}" ]] || { echo "cannot read ${SRC}" >&2; exit 1; }
command -v sed >/dev/null || exit 1

sed -E \
  -e "s|^dir[[:space:]]*=.*|dir         = \"${CACHE_DIR}\"|" \
  -e "s|\"0\.0\.0\.0:3142\"|\"${PROXY}\"|" \
  -e "s|\"127\.0\.0\.1:6789\"|\"${ADMIN}\"|" \
  -e "s|\"0\.0\.0\.0:6789\"|\"${ADMIN}\"|" \
  -e 's|^keyring_dirs[[:space:]]*=[[:space:]]*\[\]|keyring_dirs          = ["/keyrings/usr-share-keyrings", "/keyrings/etc-apt-trusted.gpg.d", "/keyrings/etc-apt-keyrings"]|' \
  "${SRC}" > "${OUT}"

# Optional, and deliberately separate from the rewrite above so the intent is
# visible in the diff it produces. In the upstream default config the only
# "enabled ... = false" line is the [adoption] one, but match on the setting
# name rather than on line position in case a later release adds another.
if [[ "${ENABLE_ADOPTION}" == 1 ]]; then
  sed -E -i 's/^enabled[[:space:]]*= false/enabled               = true/' "${OUT}"
fi

# Fail before anything starts on a config that was not actually patched: a
# renamed setting upstream would otherwise silently leave the container pointed
# at the host path.
for pat in "dir         = \"${CACHE_DIR}\"" "\"${PROXY}\"" "\"${ADMIN}\"" "/keyrings/usr-share-keyrings"; do
  if ! grep -qF -- "${pat}" "${OUT}"; then
    echo "patch failed for '${pat}' — upstream may have renamed a setting in ${SRC}" >&2
    exit 1
  fi
done

if ! grep -qE '^\[admin\]' "${OUT}"; then
  echo "warning: ${OUT} has no [admin] section; the image HEALTHCHECK probes /healthz on :6789" >&2
fi

if [[ "${ENABLE_ADOPTION}" == 1 ]]; then
  if grep -qE '^enabled[[:space:]]*= false' "${OUT}"; then
    echo "failed to flip [adoption] enabled — upstream may have renamed the setting" >&2
    exit 1
  fi
elif grep -qE '^enabled[[:space:]]*= false' "${OUT}"; then
  echo "warning: [adoption] enabled = false is inherited; the daemon loads 0 keys and never adopts signed snapshots." >&2
  echo "         pass --enable-adoption to get signature-verified adoption." >&2
fi

echo "wrote ${OUT} (mode=${MODE}, proxy=${PROXY}, admin=${ADMIN}, cache=${CACHE_DIR}, adoption=${ENABLE_ADOPTION})"

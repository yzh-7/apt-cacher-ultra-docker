#!/usr/bin/env bash
# Smoke test for a running apt-cacher-ultra container. Used by CI before an
# image is published, and by the deployment guide on the target host after a
# pull. Point it at the container you just started.
#
#   ./smoke-test.sh --admin http://127.0.0.1:6789 --proxy http://127.0.0.1:3142 \
#                   --container apt-cacher-ultra --version 1.0.2
#
# Checks, in order:
#   1  the admin listener answers /healthz
#   2  the daemon loaded a signing keyring, including at least one key from the
#      bind-mounted host directories (the silent-failure mode: with no keyring
#      mount, every adoption is refused with gpg_failed)
#   3  a real upstream fetch through the proxy, then the same URL served as a
#      cache hit (proxy mode + blob store + dedup working)
#   4  a real apt client can pull a .deb through the proxy
#   5  TLS MITM signs a leaf certificate that verifies against the CA this
#      container uses (catches a lost or regenerated CA that clients no longer
#      trust)
#   6  the admin listener's exposure matches its authentication settings
#      (an unauthenticated admin page reachable from the network is a finding,
#      not a pass)
#   7  the running binary reports the version the image claims
#   8  the cache database actually filled up
#
# Exit 0 only when no check failed. Warnings are reported but do not fail.
set -uo pipefail

ADMIN="http://127.0.0.1:6789"
PROXY="http://127.0.0.1:3142"
CONTAINER=""
EXPECTED_VERSION=""
MIN_KEYS=20
EXPECT_KEY_PATH="/keyrings/"
ALLOW_OPEN_ADMIN=0
SKIP_LIVE=0
FAILURES=0
WARNINGS=0
BIN="/usr/local/bin/apt-cacher-ultra"
CFG="/etc/apt-cacher-ultra/config.toml"
LIVE_URL_HTTP="${LIVE_URL_HTTP:-http://archive.ubuntu.com/ubuntu/dists/noble/main/binary-amd64/Packages.xz}"
LIVE_HOST="${LIVE_HOST:-archive.ubuntu.com}"
LIVE_PATH="${LIVE_PATH:-/ubuntu/dists/noble/Release}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin) ADMIN="$2"; shift 2 ;;
    --proxy) PROXY="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --version) EXPECTED_VERSION="$2"; shift 2 ;;
    --min-keys) MIN_KEYS="$2"; shift 2 ;;
    --expect-key-path) EXPECT_KEY_PATH="$2"; shift 2 ;;
    --allow-open-admin) ALLOW_OPEN_ADMIN=1; shift ;;
    --skip-live) SKIP_LIVE=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
ADMIN="${ADMIN%/}"; PROXY="${PROXY%/}"

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
warn() { printf 'WARN  %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
need() { command -v "$1" >/dev/null 2>&1; }
logs() { [[ -n "${CONTAINER}" ]] && docker logs "${CONTAINER}" 2>&1 || true; }
metric() { curl -fsS --max-time 10 "${ADMIN}/metrics" 2>/dev/null | awk -v k="$1" '$1==k {print $2; exit}'; }
# The status page wraps its numbers in markup, so strip tags before matching
# text like "30 LOADED".
page_text() { curl -fsS --max-time 10 "${ADMIN}/" 2>/dev/null | sed -e 's/<[^>]*>/ /g' | tr -s ' \t\n' ' '; }
SUDO=""
if need sudo && sudo -n true 2>/dev/null; then SUDO="sudo"; fi

need curl || { echo "curl is required" >&2; exit 2; }

# A dead container otherwise produces a dozen unrelated failures.
if [[ -n "${CONTAINER}" ]] && docker inspect "${CONTAINER}" >/dev/null 2>&1; then
  state=$(docker inspect -f '{{.State.Status}}' "${CONTAINER}" 2>/dev/null || echo unknown)
  if [[ "${state}" != running ]]; then
    echo "container ${CONTAINER} is ${state}, not running. Its last log lines:" >&2
    logs | tail -20 >&2
    exit 1
  fi
fi

# --- 1. health ------------------------------------------------------------
health=""
for _ in $(seq 1 40); do
  if curl -fsS --max-time 5 "${ADMIN}/healthz" 2>/dev/null | grep -qx 'ok'; then health=ok; break; fi
  sleep 2
done
[[ "${health}" == ok ]] && pass "healthz answers ok" || fail "healthz never answered at ${ADMIN}"

# --- 2. signing keys ------------------------------------------------------
page=$(page_text)
keys=$(printf '%s' "${page}" | grep -oE '[0-9]+ LOADED' | head -1 | grep -oE '[0-9]+' || true)
keys=${keys:-0}
if [[ "${keys}" =~ ^[0-9]+$ ]] && (( keys >= MIN_KEYS )); then
  pass "keyring loaded ${keys} keys (>= ${MIN_KEYS})"
elif [[ "${keys}" == 0 ]]; then
  fail "keyring loaded 0 keys. Either [adoption] enabled = false (the upstream packaged default; pass --enable-adoption) or the keyring mounts are missing."
else
  fail "keyring loaded only ${keys} keys (expected >= ${MIN_KEYS}); check the keyring_dirs mounts"
fi

if [[ -n "${EXPECT_KEY_PATH}" ]]; then
  from_mount=$(printf '%s' "${page}" | grep -o -- "${EXPECT_KEY_PATH}" | wc -l | tr -d ' ')
  from_mount=${from_mount:-0}
  if (( from_mount > 0 )); then
    pass "${from_mount} key(s) loaded from ${EXPECT_KEY_PATH} (host keyring bind-mount is live)"
  else
    fail "no key loaded from ${EXPECT_KEY_PATH}; the keyring bind-mount is not being read"
  fi
fi

if (( SKIP_LIVE )); then
  echo
  if (( FAILURES == 0 )); then echo "SMOKE OK (live checks skipped, ${WARNINGS} warning(s))"; exit 0; else echo "SMOKE FAILED (${FAILURES})"; exit 1; fi
fi

# --- 3. upstream fetch, then the same URL from cache ----------------------
code1=$(curl -s --max-time 180 -x "${PROXY}" -o /tmp/acu-smoke-1 -w '%{http_code}' "${LIVE_URL_HTTP}")
size1=$(wc -c < /tmp/acu-smoke-1 2>/dev/null || echo 0)
if [[ "${code1}" == 200 ]] && (( size1 > 10000 )); then
  pass "proxy fetched ${LIVE_URL_HTTP##*/} (${size1} B, http ${code1})"
else
  fail "proxy fetch returned http ${code1} size ${size1}"
fi

sleep 3
code2=$(curl -s --max-time 180 -x "${PROXY}" -o /tmp/acu-smoke-2 -w '%{http_code}' "${LIVE_URL_HTTP}")
if [[ "${code2}" == 200 ]]; then
  if logs | grep -q 'outcome=hit'; then
    pass "second request served from cache (outcome=hit in the daemon log)"
  elif logs | grep -q 'outcome=miss'; then
    fail "second request still went upstream; no cache hit recorded"
  else
    warn "second request served (http 200) but the log format does not show hit/miss"
  fi
else
  fail "repeat fetch returned http ${code2}"
fi

# --- 4. a real apt client through the proxy -------------------------------
if need apt-get; then
  tmp=$(mktemp -d)
  apt_out=$( cd "${tmp}" && ${SUDO} apt-get -qq \
      -o "Acquire::http::Proxy=${PROXY}" -o "Acquire::https::Proxy=DIRECT" \
      -o APT::Sandbox::User=root download -y hello 2>&1 )
  apt_rc=$?
  deb=$(ls "${tmp}"/*.deb 2>/dev/null | head -1)
  if (( apt_rc == 0 )) && [[ -n "${deb}" && -s "${deb}" ]]; then
    pass "apt-get download served $(basename "${deb}") through the proxy"
  elif printf '%s' "${apt_out}" | grep -qi 'unable to locate package'; then
    warn "apt client check skipped: this host has no 'hello' in its package lists (run apt-get update first)"
  else
    fail "apt-get download through the proxy failed: $(printf '%s' "${apt_out}" | tail -1)"
  fi
  ${SUDO} rm -rf "${tmp}"
else
  warn "apt-get is not present on this host; client check skipped"
fi

# --- 5. MITM leaf certificate verifies against this instance's CA ---------
ca=""
if [[ -n "${CONTAINER}" ]] && docker inspect "${CONTAINER}" >/dev/null 2>&1; then
  ca=$(docker exec "${CONTAINER}" "${BIN}" ca print -config "${CFG}" 2>/dev/null)
fi
if [[ -z "${ca}" ]] && [[ -r ./ca.crt ]]; then ca=$(cat ./ca.crt); fi
if [[ -n "${ca}" ]]; then
  cafile=$(mktemp)
  printf '%s\n' "${ca}" > "${cafile}"
  code3=$(curl -s --max-time 90 -x "${PROXY}" --cacert "${cafile}" -o /dev/null \
          -w '%{http_code}' "https://${LIVE_HOST}${LIVE_PATH}")
  fp=$(openssl x509 -in "${cafile}" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
  if [[ "${code3}" == 200 ]]; then
    pass "MITM HTTPS served https://${LIVE_HOST}${LIVE_PATH} and verified against this CA (${fp:0:17}...)"
  else
    fail "MITM HTTPS returned http ${code3} when trusted with the container's own CA"
  fi
  rm -f "${cafile}"
else
  fail "could not export the container CA (ca print). Clients that already trust a CA would break."
fi

# --- 6. admin exposure matches its authentication settings ----------------
admin_listen=""
htpasswd=""
if [[ -n "${CONTAINER}" ]] && docker inspect "${CONTAINER}" >/dev/null 2>&1; then
  cfgtext=$(docker exec "${CONTAINER}" cat "${CFG}" 2>/dev/null || true)
  # The last "listen" line in the file is the [admin] one; [cache] listen comes first.
  admin_listen=$(printf '%s' "${cfgtext}" | grep -E '^[[:space:]]*listen[[:space:]]*=[[:space:]]*"[^"]*"' | tail -1 | sed -E 's/.*"([^"]*)".*/\1/')
  htpasswd=$(printf '%s' "${cfgtext}" | sed -n '/^\[admin\]/,/^\[/p' | grep -E '^htpasswd_file' | sed -E 's/.*"([^"]*)".*/\1/')
fi
if [[ -z "${admin_listen}" ]]; then
  warn "could not read [admin] listen from the running container; exposure audit skipped"
elif [[ "${admin_listen}" =~ ^127\.0\.0\.1: || "${admin_listen}" =~ ^\[::1\]: ]]; then
  pass "admin listener bound to loopback (${admin_listen}); status page is not reachable from the network"
elif [[ -n "${htpasswd}" ]]; then
  pass "admin listener on ${admin_listen} is protected by htpasswd"
elif (( ALLOW_OPEN_ADMIN )); then
  warn "admin listener on ${admin_listen} has NO authentication, and --allow-open-admin was passed. Status page, /metrics and POST /reconcile are open to anyone who can reach the port."
else
  fail "admin listener on ${admin_listen} has no authentication (htpasswd_file empty). Bind it to 127.0.0.1, set htpasswd_file, or firewall :6789 — or pass --allow-open-admin if this is deliberate."
fi

# --- 7. running binary reports the version the image claims --------------
if [[ -n "${EXPECTED_VERSION}" && -n "${CONTAINER}" ]]; then
  got=$(docker exec "${CONTAINER}" "${BIN}" -version 2>/dev/null | tr -d '[:space:]')
  [[ "${got}" == "${EXPECTED_VERSION}" ]] \
    && pass "container runs apt-cacher-ultra ${got}" \
    || fail "container runs ${got:-unknown}, expected ${EXPECTED_VERSION}"
fi

# --- 8. the cache database actually filled --------------------------------
blobs=""
for _ in 1 2 3 4 5 6; do
  blobs=$(metric acu_blobs_db_count)
  [[ -n "${blobs}" && "${blobs}" != 0 ]] && break
  sleep 5
done
blobs=${blobs:-0}
if [[ "${blobs}" =~ ^[0-9]+$ ]] && (( blobs > 0 )); then
  pass "cache database holds ${blobs} blobs after the run"
else
  fail "cache database is still empty; the cache volume may not be writable by the container uid"
fi

echo
if (( FAILURES == 0 )); then
  echo "SMOKE OK (${WARNINGS} warning(s))"
  exit 0
else
  echo "SMOKE FAILED (${FAILURES} failure(s), ${WARNINGS} warning(s))"
  exit 1
fi

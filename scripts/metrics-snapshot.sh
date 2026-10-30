#!/usr/bin/env bash
# Read the numbers worth watching off a running apt-cacher-ultra instance.
#
#   ./metrics-snapshot.sh [admin-url]        (default http://127.0.0.1:6789)
#
# Metric names here were taken from a live /metrics dump rather than guessed.
# There is no keyring metric in 1.0.2: signing-key counts only appear on the
# status page, which is what scripts/smoke-test.sh reads instead.
set -uo pipefail

ADMIN="${1:-http://127.0.0.1:6789}"
ADMIN="${ADMIN%/}"

metrics=$(curl -fsS --max-time 15 "${ADMIN}/metrics") || {
  echo "could not read ${ADMIN}/metrics" >&2
  exit 1
}

printf '%s\n' "${metrics}" | awk '
  # Labeled series (freshness_stale_suites{adopted="false"}) are summed too: a
  # breakdown should not make a total disappear.
  /^acu_(blobs_db_count|blobs_db_total_bytes|suites_tracked|freshness_stale_suites|snapshots_current|snapshots_displaced|mitm_ca_not_after_unixtime|inflight_requests|admin_refresh_failures_total|blobs_zero_refcount_backlog|adoption_total)([ \t]|\{)/ {
    sub(/\{.*/, "", $1)
    sum[$1] += $2
  }
  /^acu_requests_total\{outcome=/ {
    match($0, /outcome="[^"]+"/)
    o = substr($0, RSTART + 9, RLENGTH - 10)
    hits[o] += $2
    all += $2
  }
  END {
    printf "%-40s %s\n", "blobs in database",        sum["acu_blobs_db_count"] + 0
    printf "%-40s %.2f GiB\n", "blob bytes",         (sum["acu_blobs_db_total_bytes"] + 0) / 1073741824
    printf "%-40s %s\n", "suites tracked",           sum["acu_suites_tracked"] + 0
    printf "%-40s %s\n", "stale suites",             sum["acu_freshness_stale_suites"] + 0
    printf "%-40s %s (displaced %s)\n", "snapshots current", sum["acu_snapshots_current"] + 0, sum["acu_snapshots_displaced"] + 0
    printf "%-40s %s\n", "adoption runs",            sum["acu_adoption_total"] + 0
    printf "%-40s %s\n", "zero-refcount backlog",    sum["acu_blobs_zero_refcount_backlog"] + 0
    printf "%-40s %s\n", "admin refresh failures",   sum["acu_admin_refresh_failures_total"] + 0
    printf "%-40s %s\n", "in-flight requests",       sum["acu_inflight_requests"] + 0
    if (sum["acu_mitm_ca_not_after_unixtime"] > 0) {
      printf "%-40s %s\n", "MITM CA expires",
             strftime("%Y-%m-%d", sum["acu_mitm_ca_not_after_unixtime"])
    }
    if (all > 0) {
      for (o in hits)
        printf "%-40s %d (%.1f%%)\n", "requests outcome=" o, hits[o], 100 * hits[o] / all
    }
  }'

# The status page is the only place the keyring count shows up in 1.0.2.
# The page wraps counts in markup, so tags become spaces: "30</b> LOADED" turns
# into "30  LOADED". Squeezing whitespace is what makes the match work.
keys=$(curl -fsS --max-time 15 "${ADMIN}/" 2>/dev/null | sed -e 's/<[^>]*>/ /g' | tr -s ' \t\n' ' ' | grep -oE '[0-9]+ LOADED' | head -1 | grep -oE '[0-9]+' || true)
printf '%-40s %s\n' "signing keys loaded" "${keys:-unknown}"

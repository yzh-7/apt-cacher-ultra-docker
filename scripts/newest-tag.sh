#!/usr/bin/env bash
# Newest version tag in a GitHub repository, printed as a bare version.
# Accepts both "v1.0.2" and "1.0.2" style tags and normalizes to "1.0.2", so it
# works for this repository (v-prefixed) and for upstream (bare).
#
#   ./newest-tag.sh <owner/repo>
#
# Environment: GH_TOKEN or GITHUB_TOKEN (required for private repositories).
# Exits 1 with no output when the repository has no v<n>.<n> tag yet, so callers
# can treat "nothing built yet" as a normal state rather than an error.
set -uo pipefail

REPO="${1:?usage: newest-tag.sh <owner/repo>}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

command -v curl >/dev/null || { echo "curl is required" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 2; }

AUTH=()
[[ -n "${TOKEN}" ]] && AUTH=(-H "Authorization: Bearer ${TOKEN}")

JSON=$(mktemp)
trap 'rm -f "${JSON}"' EXIT

if ! curl -fsSL --retry 3 --max-time 60 -H 'Accept: application/vnd.github+json' \
        "${AUTH[@]}" "https://api.github.com/repos/${REPO}/tags?per_page=100" -o "${JSON}"; then
  echo "could not read tags of ${REPO}" >&2
  exit 2
fi

python3 - "${JSON}" <<'PY'
import json, re, sys
tags = [t["name"] for t in json.load(open(sys.argv[1]))]
versions = [t[1:] if t.startswith("v") else t
            for t in tags
            if re.fullmatch(r"v?\d+\.\d+(\.\d+)?", t)]
if not versions:
    sys.exit(1)
print(max(versions, key=lambda s: [int(p) for p in re.findall(r"\d+", s)]))
PY

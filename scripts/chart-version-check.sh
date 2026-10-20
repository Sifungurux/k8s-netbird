#!/usr/bin/env bash
# Fails when chart/ changed against <base-ref> but chart/netbird/Chart.yaml's
# version did not go up. CI runs it on every PR: the publish job only pushes
# versions not yet on GHCR, so an unbumped change would never ship.
#   scripts/chart-version-check.sh origin/main
set -euo pipefail
base=${1:?usage: $0 <base-ref>}
cd "$(git rev-parse --show-toplevel)"

git diff --quiet "${base}" -- chart/ && { echo "chart/ unchanged"; exit 0; }

if ! git cat-file -e "${base}:chart/netbird/Chart.yaml" 2>/dev/null; then
  echo "new chart, nothing to compare against"; exit 0
fi
old=$(git show "${base}:chart/netbird/Chart.yaml" | yq .version)
new=$(yq .version chart/netbird/Chart.yaml)
if [[ ${new} != "${old}" && $(printf '%s\n%s\n' "${old}" "${new}" | sort -V | tail -1) == "${new}" ]]; then
  echo "chart version ${old} -> ${new}"
else
  echo "chart/ changed but the version did not go up (${old} -> ${new}): bump chart/netbird/Chart.yaml" >&2
  exit 1
fi

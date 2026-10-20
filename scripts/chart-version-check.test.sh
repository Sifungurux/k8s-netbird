#!/usr/bin/env bash
# Tests chart-version-check.sh in throwaway git repos with a copy of chart/.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
check="${root}/scripts/chart-version-check.sh"
tmp=$(mktemp -d); trap 'rm -rf "${tmp}"' EXIT

fails=0
newrepo() { # newrepo <dir> [with-chart]
  mkdir "${tmp}/$1" && cd "${tmp}/$1"
  git init -q -b main && git config user.email t@t && git config user.name t
  [[ -n ${2:-} ]] && cp -R "${root}/chart" .
  touch .keep && git add . && git commit -qm base
}
expect() { # expect <exit code> <description>
  local want=$1 got=0; shift
  git add -A  # in CI the PR's changes are committed, never untracked
  "${check}" main >/dev/null 2>&1 || got=$?
  if [[ ${got} == "${want}" ]]; then echo "ok   $*"; else echo "FAIL $* (exit ${got}, want ${want})"; fails=1; fi
  git reset -q --hard main && git clean -qfd
}
setver() { yq -i ".version = \"$1\"" chart/netbird/Chart.yaml; }

newrepo bump with-chart
expect 0 "no change"
echo "# x" >> chart/netbird/values.yaml
expect 1 "values changed, version same"
echo "# x" >> chart/netbird/values.yaml; setver 1.0.1
expect 0 "values changed, version bumped"
echo "# x" >> chart/netbird/values.yaml; setver 0.9.0
expect 1 "version lowered"
setver 1.0.9 && git commit -qam 1.0.9
echo "# x" >> chart/netbird/values.yaml; setver 1.0.10
expect 0 "1.0.9 -> 1.0.10 counts as greater"

newrepo first
cp -R "${root}/chart" .
expect 0 "first chart, base has no chart/"
exit ${fails}

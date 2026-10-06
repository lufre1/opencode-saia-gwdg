#!/usr/bin/env bash
#
# sync.sh — vendor the keyring into the open-source harness installers.
#
# Copies saia_keyring.py and saia-keyring.sh into <repo>/src/ of every SAIA
# harness installer repo and regenerates that repo's installer with build.sh.
# The vendored copies must stay byte-identical to the ones here: edit this
# folder, never a vendored copy, then rerun this script and commit each repo.
#
#   keyring/sync.sh            copy + rebuild every repo
#   keyring/sync.sh --check    report drift only; exit 1 if any copy differs
#
# Repos are looked up as siblings of this checkout ($SAIA_REPOS_ROOT overrides).
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ROOT="${SAIA_REPOS_ROOT:-$(cd ../.. && pwd)}"
REPOS=(aider-saia-gwdg mini-swe-agent-saia-gwdg openhands-saia-gwdg pi-saia-gwdg omp-saia-gwdg mcode-saia-gwdg)
FILES=(saia_keyring.py saia-keyring.sh)
CHECK=0
[[ "${1:-}" == --check ]] && CHECK=1

status=0
for repo in "${REPOS[@]}"; do
  dir="$ROOT/$repo"
  if [[ ! -d "$dir/src" ]]; then
    echo "MISSING  $dir" >&2
    status=1
    continue
  fi
  drift=()
  for f in "${FILES[@]}"; do
    cmp -s "$f" "$dir/src/$f" || drift+=("$f")
  done
  if [[ $CHECK -eq 1 ]]; then
    if [[ ${#drift[@]} -eq 0 ]]; then
      echo "ok       $repo"
    else
      echo "DRIFT    $repo: ${drift[*]}"
      status=1
    fi
    continue
  fi
  for f in "${FILES[@]}"; do
    cp "$f" "$dir/src/$f"
  done
  chmod 755 "$dir/src/saia_keyring.py"
  chmod 644 "$dir/src/saia-keyring.sh"
  (cd "$dir" && ./build.sh >/dev/null)
  echo "synced   $repo (${#drift[@]} file(s) changed, installer rebuilt)"
done
exit $status

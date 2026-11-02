#!/usr/bin/env bash
# Install-mode checks for the generated installer (full vs --minimal).
# Test-only; not packed.
#
# Runs setup-saia-opencode.sh under a private, empty HOME with no opencode on
# PATH and no TTY, so ensure_opencode declines the install and verification is
# skipped: zero network requests, the real ~/.config is never touched.
#
# Usage: test/install-modes.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$REPO/setup-saia-opencode.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CLEAN_PATH=/usr/bin:/bin
pass=0; fail=0

ok()  { echo "  ok   $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL $*"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

if PATH=$CLEAN_PATH command -v opencode >/dev/null 2>&1; then
  echo "opencode is on $CLEAN_PATH — verification would run for real; aborting." >&2
  exit 1
fi

# Every file the installer writes, and the full-only subset (= not minimal).
mapfile -t ALL < <(sed -nE 's/^write_file "([^"]+)".*/\1/p' "$INSTALLER")
MIN=(opencode.jsonc plugin/saia-gwdg-plugin.js)
FULL_ONLY=()
for f in "${ALL[@]}"; do
  [[ " ${MIN[*]} " == *" $f "* ]] || FULL_ONLY+=("$f")
done
[[ ${#FULL_ONLY[@]} -gt 5 ]] || { echo "could not parse the installer's file list" >&2; exit 1; }

run() {  # $1 = HOME, rest = installer args; output to $1/install.log
  local home="$1"; shift
  env -i HOME="$home" PATH="$CLEAN_PATH" GWDG_API_KEY=FAKE-KEY-install-modes \
    bash "$INSTALLER" "$@" </dev/null >"$home/install.log" 2>&1
}

new_home() { local h="$WORK/$1"; mkdir -p "$h"; echo "$h"; }

json_keys() {  # sorted top-level keys of $1
  python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1])))))' "$1"
}

minimal_layout() {  # $1 = config dir; only the two minimal files, no stray dirs
  local cfg="$1"
  [[ "$(cd "$cfg" && find . -type f | sort | tr '\n' ' ')" == "./opencode.jsonc ./plugin/saia-gwdg-plugin.js " ]]
}

echo "=== 1. --minimal on an empty HOME"
H="$(new_home one)"; C="$H/.config/opencode"
run "$H" --minimal; rc=$?
check "exit 0 (rc=$rc)" '[[ $rc -eq 0 ]]'
check "verification skipped (no opencode)" 'grep -q "skipping verification" "$H/install.log"'
check "only opencode.jsonc + plugin installed" 'minimal_layout "$C"'
check "config keys are \$schema model provider" '[[ "$(json_keys "$C/opencode.jsonc")" == "\$schema model provider" ]]'
check "default model is a saia-gwdg model" 'python3 -c "import json,sys; m=json.load(open(sys.argv[1]))[\"model\"]; sys.exit(0 if m.startswith(\"saia-gwdg/\") and len(m) > 10 else 1)" "$C/opencode.jsonc"'
check "provider keeps chunkTimeout > 90000" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"provider\"][\"saia-gwdg\"][\"options\"][\"chunkTimeout\"] > 90000 else 1)" "$C/opencode.jsonc"'
check "auth.json written, mode 600" '[[ "$(stat -c %a "$H/.local/share/opencode/auth.json")" == 600 ]] && grep -q "\"saia-gwdg\"" "$H/.local/share/opencode/auth.json"'
check "no backup dir on a fresh install" '! compgen -G "$H/.config/opencode.bak-*" >/dev/null'

echo "=== 2. full (--solo --no-auto), then --minimal over it"
H="$(new_home two)"; C="$H/.config/opencode"
run "$H" --solo --no-auto; rc=$?
check "full install exit 0 (rc=$rc)" '[[ $rc -eq 0 ]]'
check "full install wrote agent/coder.md and scripts/effort.sh" '[[ -f "$C/agent/coder.md" && -x "$C/scripts/effort.sh" ]]'
check "full install config has agent.solo" 'python3 -c "import json,sys; sys.exit(0 if \"solo\" in json.load(open(sys.argv[1]))[\"agent\"] else 1)" "$C/opencode.jsonc"'
printf -- '---\nmode: subagent\n---\nmine\n' >"$C/agent/mine.md"
sleep 1   # backup dirs are named by the second
run "$H" --minimal; rc=$?
check "--minimal exit 0 (rc=$rc)" '[[ $rc -eq 0 ]]'
left=()
for f in "${FULL_ONLY[@]}"; do [[ -e "$C/$f" ]] && left+=("$f"); done
check "no full-only file left (left: ${left[*]:-none})" '[[ ${#left[@]} -eq 0 ]]'
check "user's own agent/mine.md survives" '[[ -f "$C/agent/mine.md" ]]'
check "emptied command/ scripts/ prompts/ removed" '[[ ! -e "$C/command" && ! -e "$C/scripts" && ! -e "$C/prompts" ]]'
check "config keys are \$schema model provider" '[[ "$(json_keys "$C/opencode.jsonc")" == "\$schema model provider" ]]'
BAK="$(ls -d "$H"/.config/opencode.bak-* | sort | tail -1)"
check "removed files are in the backup ($BAK)" '[[ -f "$BAK/agent/coder.md" && -f "$BAK/scripts/effort.sh" && -f "$BAK/prompts/solo.md" && -f "$BAK/yagni.md" ]]'
check "previous full opencode.jsonc is in the backup" 'grep -q "\"solo\"" "$BAK/opencode.jsonc"'

echo "=== 3. --minimal --solo is refused"
H="$(new_home three)"
run "$H" --minimal --solo; rc=$?
check "exit 2 (rc=$rc)" '[[ $rc -eq 2 ]]'
check "nothing installed" '[[ ! -e "$H/.config/opencode" ]]'

echo "=== 4. --minimal, then full (--solo --no-auto) restores everything"
H="$(new_home four)"; C="$H/.config/opencode"
run "$H" --minimal
sleep 1
run "$H" --solo --no-auto; rc=$?
check "full install exit 0 (rc=$rc)" '[[ $rc -eq 0 ]]'
missing=()
for f in "${FULL_ONLY[@]}"; do
  [[ $f == prompts/auto.md ]] && continue   # declined primary
  [[ -e "$C/$f" ]] || missing+=("$f")
done
check "all full-only files back (missing: ${missing[*]:-none})" '[[ ${#missing[@]} -eq 0 ]]'
check "config has instructions + agent, no default model" '[[ "$(json_keys "$C/opencode.jsonc")" == "\$schema agent instructions provider" ]]'

echo
echo "install-modes: $pass passed, $fail failed"
[[ $fail -eq 0 ]]

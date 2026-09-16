#!/usr/bin/env bash
# Fault matrix for the SAIA pacer plugin. Test-only; not installed.
#
# Starts test/fake-saia.py, points opencode at it via SAIA_TEST_HOST /
# SAIA_BASE_URL, drives one `opencode run` per fault mode and asserts the pacer
# log shows the retry/resume path that mode is supposed to exercise. Costs zero
# real SAIA requests.
#
# Usage: test/run-faults.sh [mode ...]      (default: every mode)
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$HOME/.cache/opencode/saia-gwdg-pacer.log"
LIVE_PLUGIN="$HOME/.config/opencode/plugin/saia-gwdg-plugin.js"
OC="$HOME/.opencode/bin/opencode"
PORT="${FAKE_SAIA_PORT:-8787}"
WORK="$(mktemp -d)"
# Any model id in the cache; the fake endpoint ignores it. Must NOT be one of
# SILENT_PACED_MODELS, whose 90s idle window would stretch every stall case.
MODEL="${FAULT_MODEL:-saia-gwdg/qwen3-coder-next}"

pass=0; fail=0

cleanup() { [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# XDG_CONFIG_HOME is not honoured for opencode's global config dir, so the
# plugin under test has to be the installed one.
cp "$REPO/plugin/saia-gwdg-plugin.js" "$LIVE_PLUGIN"

start_server() { # $1 = mode
  FAKE_SAIA_MODE="$1" FAKE_SAIA_PORT="$PORT" python3 "$REPO/test/fake-saia.py" >"$WORK/server-$1.log" 2>&1 &
  SRV=$!
  sleep 1
  kill -0 "$SRV" 2>/dev/null || { echo "fake server failed to start:"; cat "$WORK/server-$1.log"; return 1; }
}
stop_server() { [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""; }

# mode|SAIA_TIMEOUT_MS|seconds to allow|expected pacer-log regexes (\t separated)
CASES=$(cat <<'TABLE'
ok|45000|60|stream-done
slow|45000|150|stream-done .*total=[6-9][0-9]{4}ms	!stream-fail	!stream-error
headers-stall|5000|120|stream-stall	stream-retry .*anchor=[1-9]	stream-error .*retryable=true
headers-stall-long|5000|150|stream-retry .*truncated=true	!stream-truncated
headers-stall-toolcall|5000|150|stream-toolcall-abandon	auto-resume scheduled	!stream-retry
late-error|5000|60|stream-late-error-ignored	!stream-fail
accept-silent|5000|120|fail TimeoutError .*retrying=true	fail TimeoutError .*retrying=false
empty-200|45000|120|stream-stall .*timeout=10000ms
five-hundred|5000|120|resp 500
slow-json|5000|120|body-fail TimeoutError
TABLE
)

want_modes=("$@")
run_mode() {
  local mode="$1" timeout_ms="$2" secs="$3" checks="$4"
  local start_line
  start_line=$(wc -l < "$LOG")
  echo "=== $mode (SAIA_TIMEOUT_MS=$timeout_ms, allow ${secs}s)"
  start_server "$mode" || { fail=$((fail+1)); return; }
  ( cd "$WORK" && \
    SAIA_TEST_HOST=127.0.0.1 \
    SAIA_BASE_URL="http://127.0.0.1:$PORT/v1" \
    SAIA_TIMEOUT_MS="$timeout_ms" \
    timeout "$secs" "$OC" run -m "$MODEL" --agent build "reply with the single word hi" \
    >"$WORK/$mode.out" 2>&1 </dev/null )
  stop_server
  local delta="$WORK/$mode.pacer"
  tail -n +$((start_line + 1)) "$LOG" > "$delta"
  local ok=1
  local IFS=$'\t'
  for check in $checks; do
    if [ "${check:0:1}" = "!" ]; then
      if grep -qE "${check:1}" "$delta"; then echo "  FAIL: unexpected /${check:1}/"; ok=0
      else echo "  ok: absent /${check:1}/"; fi
    else
      if grep -qE "$check" "$delta"; then echo "  ok: /$check/"
      else echo "  FAIL: missing /$check/"; ok=0; fi
    fi
  done
  if [ "$ok" = 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  --- pacer delta ---"; sed 's/^/  | /' "$delta" | tail -25; fi
}

while IFS='|' read -r mode tmo secs checks <&3; do
  [ -z "$mode" ] && continue
  if [ ${#want_modes[@]} -gt 0 ]; then
    match=0
    for w in "${want_modes[@]}"; do [ "$w" = "$mode" ] && match=1; done
    [ "$match" = 1 ] || continue
  fi
  run_mode "$mode" "$tmo" "$secs" "$checks"
done 3<<< "$CASES"

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]

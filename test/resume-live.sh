#!/usr/bin/env bash
# End-to-end proof that session auto-resume actually FIRES.
#
# `opencode run` cannot show this: the backoff timer is deliberately unref'd, so
# a short-lived run process exits before it fires. This drives a long-lived
# `opencode serve` over HTTP instead, which is how the TUI behaves.
#
# Usage: test/resume-live.sh [mode]     (default: headers-stall-toolcall)
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$HOME/.cache/opencode/saia-gwdg-pacer.log"
LIVE_PLUGIN="$HOME/.config/opencode/plugin/saia-gwdg-plugin.js"
OC="$HOME/.opencode/bin/opencode"
MODE="${1:-headers-stall-toolcall}"
FAKE_PORT="${FAKE_SAIA_PORT:-8788}"
OC_PORT="${OC_PORT:-4567}"
MODEL_PROVIDER="saia-gwdg"
MODEL_ID="${FAULT_MODEL_ID:-qwen3-coder-next}"
WORK="$(mktemp -d)"

cleanup() {
  [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null
  [ -n "${OCPID:-}" ] && kill "$OCPID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

cp "$REPO/plugin/saia-gwdg-plugin.js" "$LIVE_PLUGIN"

FAKE_SAIA_MODE="$MODE" FAKE_SAIA_PORT="$FAKE_PORT" python3 "$REPO/test/fake-saia.py" >"$WORK/fake.log" 2>&1 &
SRV=$!
sleep 1
kill -0 "$SRV" || { echo "fake server failed"; cat "$WORK/fake.log"; exit 1; }

start_line=$(wc -l < "$LOG")

( cd "$WORK" && \
  SAIA_TEST_HOST=127.0.0.1 \
  SAIA_BASE_URL="http://127.0.0.1:$FAKE_PORT/v1" \
  SAIA_TIMEOUT_MS=5000 \
  "$OC" serve --port "$OC_PORT" >"$WORK/serve.log" 2>&1 </dev/null ) &
OCPID=$!

# --max-time on every curl: one without it hung forever on a connection the
# server accepted while it was still starting, and stalled the whole harness.
for _ in $(seq 40); do
  curl -sf -m 3 "http://127.0.0.1:$OC_PORT/config" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf -m 5 "http://127.0.0.1:$OC_PORT/config" >/dev/null || { echo "opencode serve did not come up"; cat "$WORK/serve.log"; exit 1; }

SID=$(curl -sf -m 10 -X POST "http://127.0.0.1:$OC_PORT/session" \
  -H 'content-type: application/json' \
  -d "{\"title\":\"auto-resume test\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
echo "session=$SID mode=$MODE"

# Fire and forget: the prompt will fail on the injected fault, and the plugin's
# event hook should schedule and then fire a resume while the server lives on.
curl -s -m 120 -X POST "http://127.0.0.1:$OC_PORT/session/$SID/message" \
  -H 'content-type: application/json' \
  -d "{\"model\":{\"providerID\":\"$MODEL_PROVIDER\",\"modelID\":\"$MODEL_ID\"},\"parts\":[{\"type\":\"text\",\"text\":\"reply with the single word hi\"}]}" \
  >"$WORK/prompt.out" 2>&1

# The ladder is 5s + 20s + 60s of backoff plus a failing turn between each, so
# give it room to reach the cap and stop.
sleep "${RESUME_WAIT:-170}"

tail -n +$((start_line + 1)) "$LOG" > "$WORK/delta"
echo "--- auto-resume decisions ---"
grep -E "auto-resume" "$WORK/delta" | sed 's/^/  /'

fail=0
for want in "auto-resume scheduled" "auto-resume fired" "attempt=1/3" "attempt=2/3" "attempt=3/3" "reason=cap 3/3"; do
  if grep -qF "$want" "$WORK/delta"; then echo "ok: /$want/"; else echo "FAIL: missing /$want/"; fail=1; fi
done
# Nothing may cancel a pending resume here: session.idle fires right after the
# failed turn, and message.updated is re-emitted for the original user message.
# Either one cancelling would reset the counter and defeat the cap.
for bad in "why=idle" "why=user message"; do
  if grep -qF "auto-resume release ... $bad" "$WORK/delta" || grep -qE "auto-resume release .*$bad" "$WORK/delta"; then
    echo "FAIL: a pending resume was cancelled ($bad)"
    fail=1
  else
    echo "ok: nothing cancelled by $bad"
  fi
done
# The cap must actually stop it: no more than MAX_AUTO_RESUMES fires.
fires=$(grep -cF "auto-resume fired" "$WORK/delta")
if [ "$fires" -le 3 ]; then echo "ok: $fires fires (cap 3)"; else echo "FAIL: $fires fires exceeds the cap"; fail=1; fi
exit $fail

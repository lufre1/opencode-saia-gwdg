#!/usr/bin/env bash
#
# reload-models.sh — force-refresh the SAIA model list cache.
#
# Fetches /v1/models from GWDG (1 request of the shared rate budget) and
# rewrites ~/.cache/opencode/saia-gwdg-models.json with a fresh fetchedAt,
# so the plugin's weekly TTL restarts. Invoked by the /reload_models command
# or manually. The refreshed list takes effect at the NEXT opencode launch.
#
set -euo pipefail

AUTH_FILE="$HOME/.local/share/opencode/auth.json"
KEYS_FILE="$HOME/.local/share/opencode/saia-gwdg-keys.json"
CACHE_FILE="$HOME/.cache/opencode/saia-gwdg-models.json"

# First Python that actually runs (Windows: python/py; python3 is a Store stub).
PY=""
for c in python3 python "py -3"; do
  $c -c '' >/dev/null 2>&1 && { PY=$c; break; }   # unquoted: "py -3" is two words
done
[[ -n "$PY" ]] || { echo "ERROR: python3 not found — /reload_models needs it." >&2; exit 1; }

# auth.json key first, then any extra failover keys (same order as the plugin)
KEYS="$(AUTH_FILE="$AUTH_FILE" KEYS_FILE="$KEYS_FILE" $PY -c "
import json, os
keys = [json.load(open(os.environ['AUTH_FILE']))['saia-gwdg']['key']]
try:
    for k in json.load(open(os.environ['KEYS_FILE'])).get('keys', []):
        if isinstance(k, str) and k and k not in keys:
            keys.append(k)
except Exception:
    pass
print('\n'.join(keys))
" 2>/dev/null)" || { echo "ERROR: could not read saia-gwdg key from $AUTH_FILE" >&2; exit 1; }

BODY=""
while IFS= read -r KEY; do
  KEY="${KEY%$'\r'}"   # Windows Python prints CRLF; a trailing \r breaks the header
  [[ -z "$KEY" ]] && continue
  if BODY="$(curl -sS --fail --max-time 60 https://chat-ai.academiccloud.de/v1/models \
      -H "Authorization: Bearer $KEY")"; then
    break
  fi
  BODY=""
  echo "WARN: /v1/models fetch failed with one key — trying the next" >&2
done <<<"$KEYS"
[[ -n "$BODY" ]] || { echo "ERROR: /v1/models fetch failed with all keys — cache left untouched" >&2; exit 1; }

mkdir -p "$(dirname "$CACHE_FILE")"
BODY="$BODY" CACHE_FILE="$CACHE_FILE" $PY - <<'PYEOF'
import json, os, time
body = json.loads(os.environ["BODY"])
models = body["data"]
if not isinstance(models, list) or not models:
    raise SystemExit("ERROR: /v1/models returned no models — cache left untouched")
cache = os.environ["CACHE_FILE"]
tmp = cache + ".tmp"
with open(tmp, "w") as fh:
    json.dump({"fetchedAt": int(time.time() * 1000), "models": models}, fh)
os.replace(tmp, cache)
ready = sum(1 for m in models if m.get("status") == "ready")
print(f"Refreshed SAIA model cache: {len(models)} models, {ready} ready.")
print("Restart opencode to load the refreshed list (models are injected at startup).")
PYEOF

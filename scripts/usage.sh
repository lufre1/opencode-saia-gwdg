#!/usr/bin/env bash
#
# usage.sh — print the SAIA request budget and per-model token usage.
#
# Data sources (both maintained automatically):
#   ~/.cache/opencode/saia-gwdg-budget.json  — pacer snapshot of the
#       x-ratelimit-remaining-* headers, rewritten on every SAIA response
#   ~/.local/share/opencode/opencode.db      — opencode's message store
#
# Free when run directly in a terminal. The /usage command in opencode
# splices this output into a prompt, so there it costs 1 SAIA request.
#
set -euo pipefail

# First Python that actually runs: Windows has python/py and a python3 Store
# stub that exits 9009. UTF-8 so em dashes / model names survive opencode's pipe.
export PYTHONUTF8=1
PY=""
for c in python3 python "py -3"; do
  $c -c '' >/dev/null 2>&1 && { PY=$c; break; }   # unquoted: "py -3" is two words
done
[[ -n "$PY" ]] || { echo "ERROR: python3 not found — /usage needs it."; exit 0; }

exec $PY - <<'PYEOF'
import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

BUDGET_PATH = Path.home() / ".cache/opencode/saia-gwdg-budget.json"
DB_PATH = Path.home() / ".local/share/opencode/opencode.db"

# Bucket limits, LOW thresholds and reset TTLs mirror saia-gwdg-plugin.js.
LIMITS = {"minute": 30, "hour": 200, "day": 1000, "month": 3000}
LOW_THRESHOLDS = {"hour": 40, "day": 50, "month": 60}
RESET_TTL_MIN = {"hour": 60, "day": 24 * 60, "month": 30 * 24 * 60}


def human(n):
    for unit, div in (("B", 1e9), ("M", 1e6), ("k", 1e3)):
        if n >= div:
            return f"{n / div:.1f}{unit}"
    return str(int(n))


def budget_section():
    print("SAIA request budget (remaining/limit, per key)")
    try:
        snap = json.loads(BUDGET_PATH.read_text())
    except (OSError, ValueError):
        print("  no budget snapshot yet — it appears after the first SAIA request")
        return
    entries = snap.get("keys")
    if not isinstance(entries, list) or not entries:  # pre-multi-key snapshot format
        entries = [{"label": "key1", "updatedAt": snap.get("updatedAt"),
                    "remaining": snap.get("remaining")}]
    active = snap.get("activeIndex", 0)
    now = datetime.now(timezone.utc)
    # Aggregate mirrors the plugin's freshBudget(): a key without fresh data
    # counts as full (its buckets have likely reset since last seen).
    totals = dict.fromkeys(LOW_THRESHOLDS, 0)
    width = max(len(e.get("label") or f"key{i + 1}") for i, e in enumerate(entries))
    for i, e in enumerate(entries):
        remaining = e.get("remaining") or {}
        try:
            updated = datetime.fromisoformat(e["updatedAt"].replace("Z", "+00:00"))
            age_min = (now - updated).total_seconds() / 60
        except (TypeError, AttributeError, ValueError, KeyError):
            age_min = None
        fresh = age_min is not None and age_min < 90
        exhausted = e.get("exhausted") or {}
        for b in totals:
            # a bucket the pacer stamped exhausted counts as empty until its
            # reset TTL passes (the pacer nulls the count when stamping)
            stamp = exhausted.get(b)
            if isinstance(stamp, (int, float)) and stamp > 0 and \
                    (now.timestamp() - stamp / 1000) / 60 < RESET_TTL_MIN[b]:
                continue
            v = remaining.get(b)
            totals[b] += v if fresh and isinstance(v, (int, float)) else LIMITS[b]
        counts = "   ".join(
            f"{bucket}: {remaining.get(bucket) if remaining.get(bucket) is not None else '?'}/{limit}"
            for bucket, limit in LIMITS.items())
        mark = " *" if i == active and len(entries) > 1 else "  "
        if age_min is None:
            age = "no data yet"
        elif fresh:
            age = f"as of {age_min:.0f} min ago"
        else:
            age = f"STALE, {age_min / 60:.1f} h old — likely reset since"
        print(f"  {e.get('label') or f'key{i + 1}':<{width}}{mark} {counts}   ({age})")
    low = [b for b, threshold in LOW_THRESHOLDS.items() if totals[b] < threshold]
    status = ("LOW (" + ", ".join(f"{b} < {LOW_THRESHOLDS[b]}" for b in low) + ")"
              if low else "HEALTHY")
    if len(entries) > 1:
        print("  total: " + "   ".join(
            f"{b}: ~{int(totals[b])}/{LIMITS[b] * len(entries)}" for b in LOW_THRESHOLDS)
            + "   (* = active key; stale keys counted as full)")
    print(f"  status: {status}   (snapshot updates on every request)")


def collect(db, since_ms):
    per_model = {}
    for (data,) in db.execute(
            "SELECT data FROM message WHERE time_created >= ?", (since_ms,)):
        try:
            msg = json.loads(data)
        except ValueError:
            continue
        if msg.get("role") != "assistant" or msg.get("providerID") != "saia-gwdg":
            continue
        tokens = msg.get("tokens") or {}
        row = per_model.setdefault(msg.get("modelID") or "?", [0, 0, 0, 0])
        row[0] += 1
        row[1] += tokens.get("input") or 0
        row[2] += tokens.get("output") or 0
        row[3] += tokens.get("reasoning") or 0
    return per_model


def usage_table(title, per_model):
    print(f"\n{title}")
    if not per_model:
        print("  (none)")
        return
    width = max(len("total"), *(len(m) for m in per_model))
    print(f"  {'model':<{width}}  {'requests':>8}  {'input':>8}  "
          f"{'output':>8}  {'reasoning':>9}")
    totals = [0, 0, 0, 0]
    for model, row in sorted(per_model.items(), key=lambda kv: -kv[1][0]):
        print(f"  {model:<{width}}  {row[0]:>8}  {human(row[1]):>8}  "
              f"{human(row[2]):>8}  {human(row[3]):>9}")
        totals = [a + b for a, b in zip(totals, row)]
    print(f"  {'total':<{width}}  {totals[0]:>8}  {human(totals[1]):>8}  "
          f"{human(totals[2]):>8}  {human(totals[3]):>9}")


budget_section()
midnight = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
month_start = midnight.replace(day=1)
try:
    # as_uri(): "file:C:\Users\..." is no valid URI on Windows (and it escapes spaces)
    db = sqlite3.connect(DB_PATH.as_uri() + "?mode=ro", uri=True, timeout=3)
    try:
        usage_table(f"Usage today (since {midnight:%Y-%m-%d %H:%M})",
                    collect(db, midnight.timestamp() * 1000))
        usage_table(f"Usage this month (since {month_start:%Y-%m-%d})",
                    collect(db, month_start.timestamp() * 1000))
    finally:
        db.close()
except sqlite3.Error as exc:
    print(f"\nUsage history unavailable (opencode.db: {exc})")
PYEOF

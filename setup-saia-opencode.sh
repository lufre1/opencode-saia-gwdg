#!/usr/bin/env bash
#
# setup-saia-opencode.sh — GENERATED FILE, DO NOT EDIT.
# Regenerate with: ./build-setup.sh  (in the opencode config repo)
# Source: opencode-config commit 02a5984-dirty, packed 2026-09-10T06:07:16Z
#
# Installs the GWDG SAIA setup for opencode: provider + plugin, the four
# subagents (coder, coder2, researcher, debugger — always installed, as
# auto-discovered agent/*.md files), and the two OPTIONAL primary agents
# (solo, auto). Use flags or interactive prompts to choose the primaries.
#
# Usage: [GWDG_API_KEY=... GWDG_API_KEYS_EXTRA=key2,key3] bash setup-saia-opencode.sh [OPTIONS]
#
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
DATA_DIR="$HOME/.local/share/opencode"   # the plugin hardcodes this path
AUTH_FILE="$DATA_DIR/auth.json"
BACKUP_DIR=""
ASSUME_YES=0
FORCE_KEY=0
INSTALL_SOLO=2
INSTALL_AUTO=2
OPENCODE_MISSING=0

usage() {
  cat <<'USAGE'
Usage: [GWDG_API_KEY=... GWDG_API_KEYS_EXTRA=key2,key3] bash setup-saia-opencode.sh [OPTIONS]

Installs the GWDG SAIA setup for opencode:
  - opencode.jsonc, plugin/, command/, scripts/, agent/*.md, prompts/*.md
    into ~/.config/opencode
  - API key into ~/.local/share/opencode/auth.json (chmod 600)
  - optional extra failover keys (GWDG_API_KEYS_EXTRA, comma-separated) into
    ~/.local/share/opencode/saia-gwdg-keys.json (chmod 600) — the plugin
    switches to the next key when the active one's rate budget is exhausted
  - offers to install opencode itself if missing
  - subagents @coder, @coder2, @researcher, @debugger — ALWAYS installed as
    agent/*.md, usable from any primary (including the built-in build agent)
  - optional PRIMARY agents: solo (default workhorse), auto (orchestrator)
    (default: prompt interactively unless --yes is passed)

Options:
  -y, --yes        answer yes to prompts (e.g. installing opencode)
       --solo      install the solo primary agent (default: ask)
       --auto      install the auto primary agent (default: ask)
       --no-solo   skip the solo primary agent (default: ask)
       --no-auto   skip the auto primary agent (default: ask)
       --force-key replace an existing saia-gwdg API key
  -h, --help       show this help

The API key is taken from the GWDG_API_KEY environment variable if set,
otherwise prompted for interactively. Files that would be overwritten are
backed up to ~/.config/opencode.bak-<timestamp>/ first.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    --force-key) FORCE_KEY=1 ;;
    --solo) INSTALL_SOLO=1 ;;
    --auto) INSTALL_AUTO=1 ;;
    --no-solo) INSTALL_SOLO=0 ;;
    --no-auto) INSTALL_AUTO=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ $ASSUME_YES -eq 1 ]]; then
  # If --yes is passed but no explicit agent flags, default to skip both
  # Only override if user has not explicitly chosen with --solo/--no-solo/--auto/--no-auto
  if [[ $INSTALL_SOLO -eq 2 ]]; then
    INSTALL_SOLO=0
  fi
  if [[ $INSTALL_AUTO -eq 2 ]]; then
    INSTALL_AUTO=0
  fi
fi

# Final defaults for any remaining "ask" (2) values - prompt if terminal available
if [[ $INSTALL_SOLO -eq 2 ]]; then
  if [[ $ASSUME_YES -eq 1 ]]; then
    INSTALL_SOLO=0
  elif [[ -t 0 ]]; then
    read -r -p "Install the 'solo' agent? [y/N] " reply
    if [[ $reply == [yY]* ]]; then
      INSTALL_SOLO=1
    else
      INSTALL_SOLO=0
    fi
  else
    INSTALL_SOLO=0
  fi
fi

if [[ $INSTALL_AUTO -eq 2 ]]; then
  if [[ $ASSUME_YES -eq 1 ]]; then
    INSTALL_AUTO=0
  elif [[ -t 0 ]]; then
    read -r -p "Install the 'auto' agent? [y/N] " reply
    if [[ $reply == [yY]* ]]; then
      INSTALL_AUTO=1
    else
      INSTALL_AUTO=0
    fi
  else
    INSTALL_AUTO=0
  fi
fi

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

confirm() {
  if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
  if [[ ! -t 0 ]]; then return 1; fi
  local reply
  read -r -p "$1 [y/N] " reply
  [[ $reply == [yY]* ]]
}

ensure_opencode() {
  export PATH="$HOME/.opencode/bin:$PATH"
  if command -v opencode >/dev/null 2>&1; then
    log "opencode found: $(command -v opencode) ($(opencode --version 2>/dev/null || echo '?'))"
    return 0
  fi
  if confirm "opencode is not installed. Run the official installer now (curl -fsSL https://opencode.ai/install | bash)?"; then
    curl -fsSL https://opencode.ai/install | bash
    export PATH="$HOME/.opencode/bin:$PATH"
    command -v opencode >/dev/null 2>&1 || die "opencode still not found after install"
    log "opencode installed: $(command -v opencode)"
  else
    OPENCODE_MISSING=1
    log "Skipping opencode install — config files will still be installed; verification will be skipped."
  fi
}

ensure_path_in_shellrc() {
  local line='export PATH="$HOME/.opencode/bin:$PATH"'
  local rc
  case "${SHELL##*/}" in
    zsh)  rc="$HOME/.zshrc" ;;
    bash) rc="$HOME/.bashrc" ;;
    *)    rc="$HOME/.profile" ;;
  esac
  if ! grep -qxF "$line" "$rc" 2>/dev/null; then
    printf '\n# added by setup-saia-opencode.sh\n%s\n' "$line" >> "$rc"
    log "Added opencode to PATH in $rc (source it or restart your shell)"
  else
    log "PATH entry already present in $rc"
  fi
}

backup_existing() {  # $1 = backup-relative path, $2 = existing file
  if [[ -z "$BACKUP_DIR" ]]; then
    BACKUP_DIR="$HOME/.config/opencode.bak-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    log "Backing up existing files to $BACKUP_DIR"
  fi
  mkdir -p "$BACKUP_DIR/$(dirname "$1")"
  cp -p "$2" "$BACKUP_DIR/$1"
}

write_file() {  # $1 = path relative to CONFIG_DIR; content on stdin
  local rel="$1" dest="$CONFIG_DIR/$1" tmp
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp)"
  cat >"$tmp"
  if [[ -e "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    log "  unchanged: $dest"
    return 0
  fi
  if [[ -e "$dest" ]]; then
    backup_existing "$rel" "$dest"
  fi
  mv "$tmp" "$dest"
  chmod 644 "$dest"
  log "  wrote: $dest"
}


ensure_opencode

if [[ $OPENCODE_MISSING -eq 0 ]]; then
  ensure_path_in_shellrc
fi

log "Installing SAIA config to $CONFIG_DIR"

write_file "opencode.jsonc" <<'__OC_FILE_EOF__'
{
  "$schema": "https://opencode.ai/config.json",
  // Appended to every agent's system prompt (including the built-in
  // plan/build prompts, which cannot be extended per-agent).
  // Relative path: resolved to absolute at install time.
  "instructions": ["./yagni.md"],
  // The plugin is auto-discovered from plugin/ (no "plugin" array needed).
  // Commands live in command/*.md (/usage, /reload_models).
  "provider": {
    "saia-gwdg": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "https://chat-ai.academiccloud.de/v1",
        // Backstop only — the PLUGIN owns stall detection. opencode implements
        // chunkTimeout as an AbortController merged into the signal it hands to
        // the patched fetch, so whatever value is here aborts the request; the
        // plugin then sees `signal.aborted`, correctly reads it as a caller
        // abort, and does NOT retry. At the old 30000 that fired before the
        // plugin's own idle windows (STREAM_IDLE_TIMEOUT_MS 45s,
        // SLOW_IDLE_TIMEOUT_MS 90s) every single time, which is why the
        // stream-resume machinery never once ran.
        // INVARIANT: this MUST stay above SLOW_IDLE_TIMEOUT_MS (90s) or the
        // plugin's resume path is silently dead again. It is kept at all only so
        // a bug in the plugin's idle timer cannot hang opencode forever.
        // Still deliberately no `timeout` / `headerTimeout`: opencode measures
        // those around the patched fetch, so they would include the pacer's own
        // queue and cooldown waits and fire spuriously. The headers case is
        // handled in the plugin (SAIA_TIMEOUT_MS), where only real network time
        // is measured.
        "chunkTimeout": 150000
      }
    }
  },
  "agent": {
    "plan": {
      // No temperature: opencode's own default (`ke.temperature`) returns
      // nothing for SAIA models, so omitting it leaves the provider default
      // alone (DeepSeek reasoners want it). Note opencode DOES inject
      // top_p 0.95 here regardless — topP is not capability-gated. No steps
      // cap either: long autonomous runs must not be cut off mid-task — the
      // plugin's budget pacer is the runaway guard.
      "color": "warning"
    },
    // Stub so the plugin's ROLE_MODELS can pin the built-in build agent's
    // model (the plugin skips roles absent from config.agent).
    // temperature 0.2: an explicit choice, not an override — opencode injects
    // no temperature for these models. Matches @coder for deterministic
    // implementation. Only reaches the wire because the plugin declares
    // `temperature: true` per model; without that opencode drops the field.
    // No steps cap, same reason as plan.
    "build": {
      "temperature": 0.2
    },
    // opencode's native subagents. They are defined in opencode's own code, not
    // in config, so these empty stubs exist ONLY so the plugin's ROLE_MODELS can
    // pin them a model. NEVER give them an agent/*.md file: opencode applies
    // `prompt = <file body>` unconditionally, so an empty body would overwrite
    // their built-in system prompts with "".
    // The SAIA subagents (coder, coder2, researcher, debugger) live in agent/*.md
    // — auto-discovered, always installed, never touched by the installer's
    // filter. Adding one needs no edit here and no edit to any primary.
    "general": {},
    "explore": {},
    "solo": {
      "description": "Default workhorse: plans, implements, self-checks in one session, then independent @debugger validation (~5-12 requests/task)",
      "mode": "primary",
      "model": "saia-gwdg/qwen3-coder-next",
      "temperature": 0.2,
      "steps": 40,
      "prompt": "{file:./prompts/solo.md}",
      "permission": {
        "edit": "allow",
        "bash": "allow",
        "write": "allow",
        "task": {
          // "*" MUST come first: opencode resolves these last-match-wins, so a
          // trailing "*" would deny every subagent and remove the task tool.
          "*": "deny",
          "debugger": "allow"
        }
      },
      "tools": {
        "skill": false,
        "todowrite": false,
        "webfetch": false
      }
    },
    "auto": {
      "description": "Orchestrator for big/ambiguous multi-file tasks: plan → implement → validate loop (max 1 fix round)",
      "mode": "primary",
      "model": "saia-gwdg/qwen3.5-122b-a10b",
      "temperature": 0.2,
      "steps": 25,
      "prompt": "{file:./prompts/auto.md}",
      "permission": {
        "read": "allow",
        "glob": "allow",
        "grep": "allow",
        "list": "allow",
        "edit": "deny",
        "bash": {
          // Read-only commands allowed for auto inspection
          "ls *": "allow",
          "git status *": "allow",
          "git diff *": "allow",
          "git log *": "allow",
          "git show *": "allow",
          "git grep *": "allow",
          "rg *": "allow",
          "cat *": "allow",
          "wc *": "allow",
          "find *": "allow",
          "pwd": "allow",
          "echo *": "allow",
          "head *": "allow",
          "tail *": "allow",
          // Mutating commands denied
          "git add *": "deny",
          "git commit *": "deny",
          "git push *": "deny",
          "git reset *": "deny",
          "git checkout *": "deny",
          "git clean *": "deny",
          "rm *": "deny",
          "mv *": "deny",
          "cp *": "deny",
          "mkdir *": "deny",
          "touch *": "deny",
          "chmod *": "deny",
          "chown *": "deny",
          "npm *": "deny",
          "pip *": "deny",
          "cargo *": "deny",
          "make *": "deny",
          "tee *": "deny",
          "sed *": "deny",
          "awk *": "deny",
          // Catch-all: deny anything not explicitly allowlisted
          "*": "deny"
        },
        "write": "deny",
        "task": {
          // Allow-by-exception: every subagent shipped in agent/*.md is taskable
          // without editing this file — that is the point. "*" MUST stay FIRST:
          // opencode resolves these last-match-wins (Permission.findLast), so a
          // trailing "*" would override the denies below and re-allow them.
          "*": "allow",
          // The natives are the failure mode actually observed: under task
          // pressure auto substituted @general/@explore for its own roles.
          // Denying them here also removes them from the task tool's generated
          // agent list, so the model never sees them as an option.
          "general": "deny",
          "explore": "deny"
        }
      },
      "tools": {
        "skill": false,
        "todowrite": false,
        "webfetch": false
      }
    }
  }
}
__OC_FILE_EOF__

write_file "plugin/saia-gwdg-plugin.js" <<'__OC_FILE_EOF__'
import { readFileSync, writeFileSync, mkdirSync, appendFileSync, statSync, renameSync } from "fs";
import { homedir } from "os";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

// The model list is cached for a week: the cache is authoritative while its
// fetchedAt is younger than MODELS_TTL_MS, so most launches cost zero SAIA
// requests. Older/missing cache triggers one /v1/models fetch (shared bucket:
// 30/min, 200/hour, 1000/day, 3000/month), with the stale cache as fallback
// on fetch failure. Force a refresh with /reload_models (runs
// reload-models.sh, which rewrites the cache with a fresh fetchedAt).
const CACHE_PATH = join(homedir(), ".cache/opencode/saia-gwdg-models.json");
const MODELS_TTL_MS = 7 * 24 * 60 * 60 * 1000;

// ---------------------------------------------------------------------------
// Request pacer: wraps globalThis.fetch for chat-ai.academiccloud.de only.
// - spaces request starts >= 2100ms apart so the 30/min limit can't trip
// - supports multiple API keys with hard-floor failover: rate limits are
//   per key, and opencode only knows the auth.json key, so the pacer
//   rewrites the Authorization header to the active key on every request.
//   When the active key's hour/day/month bucket is nearly empty (or it
//   429s despite pacing) the pacer switches to the next usable key; an
//   exhausted key re-enters rotation after its bucket's reset TTL. Extra
//   keys live in KEYS_PATH; without that file this is single-key as before.
// - stops with a clear error only when EVERY key is nearly exhausted,
//   instead of letting opencode retry-spin 429s into drained buckets
// - on 429, waits for the advertised reset once and retries; a second 429
//   fails the key over; a 429 on the next key too throws
// - aborts after 3 consecutive 5xx responses: SAIA outages return 500s that
//   still consume the request budget; instead of hard-sticking, we now sleep
//   30s and retry so transient blips don't require a process restart.
// Patching global fetch (not provider options.fetch) because opencode may
// not pass function-valued config through to the SDK.
// ---------------------------------------------------------------------------
const SAIA_HOST = "chat-ai.academiccloud.de";
// Fault-injection plumbing. Both default to production, so an unset
// environment behaves exactly as before. SAIA_TEST_HOST adds one extra
// hostname to the set the pacer intercepts and SAIA_BASE_URL redirects the
// provider at it, which is how test/fake-saia.mjs exercises the stall and
// resume paths without spending a real SAIA request.
const SAIA_TEST_HOST = process.env.SAIA_TEST_HOST || null;
const SAIA_PROD_BASE_URL = "https://chat-ai.academiccloud.de/v1";
const SAIA_BASE_URL = process.env.SAIA_BASE_URL || SAIA_PROD_BASE_URL;
const MIN_INTERVAL_MS = 2100;
const HOUR_FLOOR = 5;
const DAY_FLOOR = 10;
const MONTH_FLOOR = 30;
const MAX_CONSECUTIVE_5XX = 3;
// Hard cap on RECEIVING RESPONSE HEADERS. SAIA replicas can accept the
// connection and then send nothing at all, which used to freeze opencode
// forever (there is no default timeout in @ai-sdk/openai-compatible). Applied
// around the realFetch call only, so the pacer's own queue/cooldown waits don't
// count toward it. SAIA_TIMEOUT_MS is the calibration knob.
// NOT a cap on the whole exchange: this deadline is cleared the moment headers
// arrive. It used to be an AbortSignal.timeout that stayed live while opencode
// drained the SSE body, so EVERY turn longer than 45s was killed mid-stream at
// exactly 45s (two confirmed kills on 2026-09-09, +45.001s and +45.016s after
// the request start). The body's liveness is the idle timers' job below.
// Floor 5s: a sub-second value can only be a leftover test export, and it
// kills every request. Edit the constant directly for fault-injection tests.
const TIMEOUT_MS = Math.max(Number(process.env.SAIA_TIMEOUT_MS) || 45_000, 5_000);
// Headers deadline for every try EXCEPT the last. Measured over 1697 successful
// completions the TTFB distribution is p50 2.1s / p90 7.3s / p99 25.5s, and no
// request that ran past 45s ever went on to deliver headers — a hang is dead,
// not slow. Spending the full TIMEOUT_MS on all three tries cost 3x45s = 135s
// before a turn even failed (confirmed against opencode's own message record:
// created -> completed = 135.5s). Early tries now reconnect quickly — a fresh
// connection is re-load-balanced onto another replica, which is what actually
// recovers — while the LAST try keeps the full budget so a genuinely
// slow-but-alive replica still gets its chance. Worst case 135s -> 85s.
// SILENT_PACED_MODELS are exempt (see below): they are legitimately slow.
const EARLY_TIMEOUT_MS = Math.min(
  Math.max(Number(process.env.SAIA_EARLY_TIMEOUT_MS) || 20_000, 5_000),
  TIMEOUT_MS
);
// Connection attempts per request (1 = no reconnect). Only connection-level
// failures are retried here; 5xx and 429 are opencode's job.
const MAX_CONNECT_TRIES = 3;
// Models that exhibit silent-drop failures (connection accepted, then timeout).
// A short backoff between retries lets the replica pool recover a healthy node.
const SILENT_PACED_MODELS = new Set(["deepseek-v4-flash-0731", "qwen3.8-27b"]);
const RETRY_BACKOFF_MS = 5_000;
// Model-health breaker. A SAIA model can enter a state where it accepts the
// connection and then never sends headers, and reconnecting does not help
// because the model is sick, not the replica. Observed 2026-09-09:
// glm-5.3-flash returned 20 headers-timeouts against 9 successes over 38
// requests (53%) while qwen3-coder-next — same gateway, same key, same minutes
// — had zero. The only useful move is to stop sending that model traffic.
// Tripped on a RATIO with a floor on the sample, so a healthy-but-busy model
// cannot trip on one unlucky request: against the observed data glm-5.3-flash
// (0.69) trips on its 4th timeout, ~3.5min in, while qwen3-coder-next never does.
const MODEL_HEALTH_WINDOW_MS = 10 * 60_000;
const MODEL_BREAKER_MIN_TIMEOUTS = Math.max(
  Number(process.env.SAIA_BREAKER_MIN_TIMEOUTS) || 4,
  1
);
const MODEL_BREAKER_RATIO = 0.5;
const MODEL_BREAKER_COOLDOWN_MS = 15 * 60_000;
// Stand-in when the failing model belongs to no ROLE_MODELS list — which is
// exactly how the 2026-09-09 outage happened, glm-5.3-flash having been picked
// by hand in the TUI model switcher. Best measured record in the whole log.
const BREAKER_FALLBACK_MODEL = "qwen3-coder-next";
// Stream idle timeout: if no data arrives within this window after headers, treat as a stall and retry.
// Reuse TIMEOUT_MS so there's only one knob to tune for all timeouts.
const STREAM_IDLE_TIMEOUT_MS = TIMEOUT_MS;
// Silent-paced models (deepseek-v4-flash-0731, qwen3.8-27b) can legitimately
// emit no token for long stretches of reasoning. A 45s idle window misclassifies
// a slow-but-alive generation as a dead replica and kills it. Give these models
// a longer idle window so slow reasoning survives, while a truly dead replica
// (no data for SLOW_IDLE_TIMEOUT_MS) is still caught.
const SLOW_IDLE_TIMEOUT_MS = 90_000;
// A 200 with no kong id / upstream latency is a dead replica that returns no
// data. Don't wait the full idle timeout on it — retry after a short window.
const EMPTY_200_TIMEOUT_MS = 10_000;
// A mid-stream stall is resumed by re-issuing the request with the tail of the
// text already streamed as the join point. Only the tail is sent: the whole
// partial is already on the user's screen, so quoting all of it back would cost
// tokens without helping the model find the seam.
const RESUME_ANCHOR_CHARS = 1_500;
// Deadline for the BODY of a NON-streaming response (/v1/models, error bodies).
// Streaming bodies are governed by the idle timers in wrapStreamWithRetry;
// non-streaming ones had no guard at all once the headers deadline stopped
// spanning the body, so they get their own clock here.
const BODY_TIMEOUT_MS = Math.max(Number(process.env.SAIA_BODY_TIMEOUT_MS) || 60_000, 5_000);
// Overridable so test/run-faults.sh can get a private log and budget file.
// Without that the matrix reads a log another live opencode is writing to
// at the same time, and its "pacer delta" picks up that session's real
// requests — which is exactly what happened on the first run of the
// tiered-deadline case.
const PACER_LOG = process.env.SAIA_PACER_LOG || join(homedir(), ".cache/opencode/saia-gwdg-pacer.log");
const BUDGET_PATH =
  process.env.SAIA_BUDGET_PATH || join(homedir(), ".cache/opencode/saia-gwdg-budget.json");
const KEYS_PATH = join(homedir(), ".local/share/opencode/saia-gwdg-keys.json");
// Reasoning-effort state, written by /effort (scripts/effort.sh). The pacer
// re-reads it per request so a change applies to the CURRENT session without a
// restart. Missing file => default effort (high).
const EFFORT_PATH = join(homedir(), ".config/opencode/effort.json");
const DEFAULT_EFFORT = "high";
// How long an exhausted bucket keeps a key out of rotation before it is
// optimistically retried (the true state is learned from the next headers).
const RESET_TTL_MS = { hour: 60 * 60000, day: 24 * 3600000, month: 30 * 86400000 };
// Hostnames the pacer intercepts. Exactly the production host unless a test
// host is exported.
const SAIA_HOSTS = new Set([SAIA_HOST, ...(SAIA_TEST_HOST ? [SAIA_TEST_HOST] : [])]);

// Debug trail for everything the plugin decides (requests, cache hits,
// prompt injection). Always on: the failures worth catching are rare and
// silent, and an env var set in ~/.bashrc is not inherited by a desktop or
// IDE launch. SAIA_PACER_DEBUG=1 additionally enables the 5xx body capture.
const pacerDebugLog = (line) => {
  try {
    mkdirSync(dirname(PACER_LOG), { recursive: true });
    // ponytail: single-generation rotation, good enough for a ~150B/request
    // append-only trail. Use logrotate if this ever needs real history.
    try {
      if (statSync(PACER_LOG).size > 8e6) renameSync(PACER_LOG, `${PACER_LOG}.1`);
    } catch {}
    appendFileSync(PACER_LOG, `${new Date().toISOString()} ${line}\n`);
  } catch {}
};

// Last time the pacer GAVE UP on a request — not merely retried it. The
// auto-resume hook reads this to tell a transport failure that opencode reports
// as an abort apart from the user actually pressing Esc.
const markTransportFail = (msg) => {
  globalThis.__saiaLastTransportFail = { at: Date.now(), msg: String(msg).slice(0, 300) };
  pacerDebugLog(`transport-fail-marker ${String(msg).replace(/\s+/g, " ").slice(0, 160)}`);
};

// Pushes a one-line notice into the TUI. The pacer runs with no `client` (and
// in `opencode run` there is no TUI at all), so the real implementation is
// installed by the server hook below and every call site tolerates its absence.
const saiaToast = (message, variant = "warning") => {
  try {
    globalThis.__saiaToast?.(message, variant);
  } catch {}
};

// ----------------------------------------------------------- model health
// State for the breaker described at MODEL_HEALTH_WINDOW_MS. One entry per
// model id, holding rolling timestamp arrays plus the current trip.
const modelHealth = new Map();

const pruneHealth = (arr, now) => {
  while (arr.length && now - arr[0] > MODEL_HEALTH_WINDOW_MS) arr.shift();
  return arr;
};

const healthFor = (model) => {
  let h = modelHealth.get(model);
  if (!h) {
    h = { timeouts: [], successes: [], trippedAt: 0, trippedCount: 0, replacement: null, notified: false };
    modelHealth.set(model, h);
  }
  return h;
};

// Reverse index model -> role, built lazily on first use: ROLE_MODELS is
// declared further down this file and is still in the TDZ while this module is
// being evaluated.
let roleByModel = null;
const roleOf = (model) => {
  if (!roleByModel) {
    roleByModel = new Map();
    for (const [role, list] of Object.entries(ROLE_MODELS)) {
      for (const m of list) if (!roleByModel.has(m)) roleByModel.set(m, role);
    }
  }
  return roleByModel.get(model) ?? null;
};

const isTripped = (model, now) => {
  const h = modelHealth.get(model);
  return !!h?.trippedAt && now - h.trippedAt < MODEL_BREAKER_COOLDOWN_MS;
};

// Next entry in the failing model's own role list, else the global fallback.
// Never returns a model that is itself tripped.
const pickReplacement = (model, now) => {
  const role = roleOf(model);
  const candidates = role ? ROLE_MODELS[role].filter((m) => m !== model) : [];
  candidates.push(BREAKER_FALLBACK_MODEL);
  for (const c of candidates) if (c !== model && !isTripped(c, now)) return c;
  return null;
};

// The model to actually put on the wire in place of `model`. Once the cooldown
// lapses this returns `model` again, which is the probe: one request goes back
// to the original, and recordModelTimeout re-trips instantly if it hangs.
const effectiveModelFor = (model) => {
  const now = Date.now();
  if (!model || !isTripped(model, now)) return model;
  const h = modelHealth.get(model);
  // If the stand-in has since gone bad too, pick another rather than flapping
  // back onto the model we already know is hanging.
  if (!h.replacement || isTripped(h.replacement, now)) {
    const next = pickReplacement(model, now);
    if (!next) return model;
    h.replacement = next;
    h.notified = false;
  }
  return h.replacement;
};

// Records one headers-timeout. Trips when the model has crossed both the sample
// floor and the failure ratio. A model that has tripped before needs only a
// single timeout to trip again, so the post-cooldown probe fails fast instead of
// having to re-earn the full sample.
const recordModelTimeout = (model) => {
  if (!model) return;
  const now = Date.now();
  const h = healthFor(model);
  pruneHealth(h.timeouts, now).push(now);
  pruneHealth(h.successes, now);
  if (isTripped(model, now)) return;
  const total = h.timeouts.length + h.successes.length;
  const floor = h.trippedCount > 0 ? 1 : MODEL_BREAKER_MIN_TIMEOUTS;
  if (h.timeouts.length < floor) return;
  if (h.timeouts.length / total < MODEL_BREAKER_RATIO) return;
  h.trippedAt = now;
  h.trippedCount += 1;
  h.replacement = pickReplacement(model, now);
  h.notified = false;
  pacerDebugLog(
    h.replacement
      ? `model-unhealthy ${model} -> ${h.replacement} ` +
          `(${h.timeouts.length} timeouts / ${total} reqs in ${MODEL_HEALTH_WINDOW_MS / 60000}min)`
      : `model-unhealthy ${model} — no healthy stand-in available, staying on it ` +
          `(${h.timeouts.length} timeouts / ${total} reqs)`
  );
};

const recordModelSuccess = (model) => {
  if (!model) return;
  const now = Date.now();
  const h = healthFor(model);
  pruneHealth(h.timeouts, now);
  pruneHealth(h.successes, now).push(now);
  // A success once the cooldown has lapsed means the probe got through: clear
  // the trip so traffic returns to the model the user actually chose.
  if (h.trippedAt && now - h.trippedAt >= MODEL_BREAKER_COOLDOWN_MS) {
    h.trippedAt = 0;
    h.replacement = null;
    h.notified = false;
    pacerDebugLog(`model-recovered ${model} — breaker cleared`);
  }
};

function installPacer(keys) {
  // The wrapper closure reads this global, so a config-hook re-run can
  // refresh the key list without re-wrapping fetch.
  globalThis.__saiaKeys = keys;
  if (globalThis.__saiaPacerInstalled) return;
  globalThis.__saiaPacerInstalled = true;

  const realFetch = globalThis.fetch.bind(globalThis);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // Races a promise against a deadline. Used for the body phase, where there is
  // no signal to abort (the headers deadline is already cleared by then).
  const withDeadline = async (promise, ms, onTimeout) => {
    let t;
    try {
      return await Promise.race([
        promise,
        new Promise((_, rej) => {
          t = setTimeout(() => {
            try {
              onTimeout?.();
            } catch {}
            rej(new DOMException(`body not received within ${ms}ms`, "TimeoutError"));
          }, ms);
          t.unref?.();
        }),
      ]);
    } finally {
      clearTimeout(t);
    }
  };

  // Buffers a NON-streaming body under a deadline and returns an equivalent
  // Response. Small by construction (a completion JSON, a model list or an
  // error body). Streaming responses must never come through here — their
  // liveness is the idle timer's job and buffering them would break streaming.
  const bufferBody = async (resp, ms) => {
    if (!resp.body) return { resp, text: "" };
    const text = await withDeadline(resp.text(), ms, () => resp.body?.cancel().catch(() => {}));
    const headers = new Headers(resp.headers);
    // The body is already decoded and re-sized by reading it as text; leaving
    // these would make a downstream consumer decode again or mis-size it.
    headers.delete("content-encoding");
    headers.delete("content-length");
    return { resp: new Response(text, { status: resp.status, statusText: resp.statusText, headers }), text };
  };
  let queue = Promise.resolve(); // serializes SAIA requests
  let lastStart = 0;
  let consecutive5xx = 0; // global: an outage is key-independent
  let activeIndex = 0;

  const FLOORS = { hour: HOUR_FLOOR, day: DAY_FLOOR, month: MONTH_FLOOR };

  // Per-key pacer state, keyed by the key string so a refreshed key list
  // keeps what was already learned.
  const stateByKey = new Map();
  const stateFor = (key) => {
    let s = stateByKey.get(key);
    if (!s) {
      s = {
        remaining: { minute: null, hour: null, day: null, month: null },
        exhausted: { hour: 0, day: 0, month: 0 },
        updatedAt: null,
      };
      stateByKey.set(key, s);
    }
    return s;
  };

  const label = (key) => `key${globalThis.__saiaKeys.indexOf(key) + 1}(…${key.slice(-4)})`;

  const markExhausted = (key, bucket) => {
    const s = stateFor(key);
    s.exhausted[bucket] = Date.now();
    s.remaining[bucket] = null; // forget the count; retry optimistically after the TTL
    pacerDebugLog(`${label(key)} exhausted (${bucket} bucket)`);
  };

  // Converts floored remaining counts into exhaustion stamps, then reports
  // whether the key is currently usable.
  const keyUsable = (key) => {
    const s = stateFor(key);
    let usable = true;
    for (const b of ["hour", "day", "month"]) {
      if (s.remaining[b] !== null && s.remaining[b] <= FLOORS[b]) markExhausted(key, b);
      if (s.exhausted[b]) {
        if (Date.now() - s.exhausted[b] < RESET_TTL_MS[b]) usable = false;
        else s.exhausted[b] = 0; // TTL passed — the bucket has reset
      }
    }
    return usable;
  };

  // The active key while it has budget, else the next usable key (wrapping
  // around). Returns null when every key is exhausted.
  const pickKey = () => {
    const all = globalThis.__saiaKeys ?? [];
    if (all.length === 0) return null;
    if (activeIndex >= all.length) activeIndex = 0;
    const before = activeIndex;
    for (let i = 0; i < all.length; i++) {
      const idx = (before + i) % all.length;
      if (keyUsable(all[idx])) {
        if (idx !== before) pacerDebugLog(`switching ${label(all[before])} -> ${label(all[idx])}`);
        activeIndex = idx;
        return all[idx];
      }
    }
    return null;
  };

  const allExhaustedError = () => {
    const all = globalThis.__saiaKeys;
    const per = all.map((k) => {
      const s = stateFor(k);
      const buckets = ["hour", "day", "month"].filter(
        (b) => s.exhausted[b] && Date.now() - s.exhausted[b] < RESET_TTL_MS[b]
      );
      return `${label(k)}: ${buckets.join("+") || "exhausted"}`;
    });
    return new Error(
      `All ${all.length} SAIA key(s) nearly exhausted (${per.join("; ")}) — ` +
        `aborting instead of retry-spinning. Wait for the buckets to reset.`
    );
  };

  // Rate limits are per key, but opencode only knows the auth.json key —
  // rewrite the Authorization header to the currently active one.
  // NOTE: when both a Request object and an init are passed, init.headers
  // wins in fetch() — so the rewrite must always land on the init side
  // (rewriting only the Request would silently keep the old key).
  const withAuth = (input, init, key, reqId) => {
    const base =
      init?.headers ?? (typeof Request !== "undefined" && input instanceof Request ? input.headers : undefined);
    const headers = new Headers(base);
    headers.set("authorization", `Bearer ${key}`);
    // A hang yields no response, so no x-kong-request-id ever comes back. This
    // is the only ID that exists for the failure mode we most need to report.
    headers.set("x-client-request-id", reqId);
    return [input, { ...init, headers }];
  };

  const writeSnapshot = () => {
    const all = globalThis.__saiaKeys;
    try {
      mkdirSync(dirname(BUDGET_PATH), { recursive: true });
      writeFileSync(
        BUDGET_PATH,
        JSON.stringify({
          updatedAt: new Date().toISOString(),
          activeIndex,
          // top-level `remaining` mirrors the active key for old readers
          remaining: stateFor(all[activeIndex]).remaining,
          keys: all.map((k) => {
            const s = stateFor(k);
            return { label: label(k), updatedAt: s.updatedAt, remaining: s.remaining, exhausted: s.exhausted };
          }),
        })
      );
    } catch {}
  };

  const deadReplica = (resp) =>
    resp.status === 200 &&
    resp.headers.get("x-kong-request-id") === null &&
    resp.headers.get("x-kong-upstream-latency") === null;

  const readBuckets = (resp, key) => {
    const s = stateFor(key);
    let headerPresent = false;
    for (const b of ["minute", "hour", "day", "month"]) {
      const v = resp.headers.get(`x-ratelimit-remaining-${b}`);
      if (v !== null) {
        s.remaining[b] = Number(v);
        headerPresent = true;
      }
    }
    if (headerPresent) {
      s.updatedAt = new Date().toISOString();
      writeSnapshot();
    }
  };

  // Reasoning-effort state, re-read per request so /effort applies to the
  // current session immediately. Cached briefly to avoid a disk read on every
  // request; the ~1s staleness is irrelevant for a user-toggled setting.
  let effortCache = { level: DEFAULT_EFFORT, at: 0 };
  const EFFORT_CACHE_MS = 1000;
  const readEffort = () => {
    if (Date.now() - effortCache.at < EFFORT_CACHE_MS) return effortCache.level;
    let level = DEFAULT_EFFORT;
    try {
      const e = JSON.parse(readFileSync(EFFORT_PATH, "utf-8"));
      if (["off", "low", "medium", "high", "max"].includes(e?.level)) level = e.level;
    } catch {}
    effortCache = { level, at: Date.now() };
    return level;
  };

  // Map the /effort level to the vLLM chat_template_kwargs SAIA expects.
  // `off` turns thinking off; every other level enables thinking at that effort.
  // The key is `enable_thinking`, the Qwen/vLLM chat-template variable — a plain
  // `thinking` key is silently ignored by the template (verified on-wire
  // 2026-08-28: `{thinking:false}` left reasoning output untouched, while
  // `{enable_thinking:false}` drove it to zero on every model tested).
  const effortKwargs = (level) => {
    if (level === "off") return { enable_thinking: false };
    return { enable_thinking: true, reasoning_effort: level };
  };

  // Local-echo short-circuit: command/effort.md starts with this sentinel
  // line. Slash commands are prompt templates — opencode always sends the
  // expanded text to the model, which would just echo the script output back
  // (1 SAIA request + latency for nothing). When the outgoing request's last
  // message carries the sentinel, answer it locally with the script output
  // instead: instant, zero SAIA requests, skips queue/pacer entirely.
  const LOCAL_ECHO_SENTINEL = "(local command — handled without a model call)";
  const tryLocalEcho = (init, url) => {
    if (!url.pathname.endsWith("/chat/completions")) return null;
    let body;
    try {
      body = JSON.parse(init?.body);
    } catch {
      return null;
    }
    const last = body?.messages?.[body.messages.length - 1];
    if (!last) return null;
    const text =
      typeof last.content === "string"
        ? last.content
        : Array.isArray(last.content)
          ? last.content.map((p) => p?.text ?? "").join("")
          : "";
    if (!text.includes(LOCAL_ECHO_SENTINEL)) return null;
    const echo = text
      .split("\n")
      .filter((line) => !line.includes(LOCAL_ECHO_SENTINEL))
      .join("\n")
      .trim();
    pacerDebugLog("local echo for /effort — no SAIA request");
    const id = "chatcmpl-local-echo";
    const created = Math.floor(Date.now() / 1000);
    const usage = { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 };
    if (body.stream) {
      const chunk = (delta, finish, extra) =>
        `data: ${JSON.stringify({
          id,
          object: "chat.completion.chunk",
          created,
          model: body.model,
          choices: [{ index: 0, delta, finish_reason: finish }],
          ...extra,
        })}\n\n`;
      const sse =
        chunk({ role: "assistant", content: echo }, null) +
        chunk({}, "stop", { usage }) +
        "data: [DONE]\n\n";
      return new Response(sse, {
        status: 200,
        headers: { "content-type": "text/event-stream" },
      });
    }
    return new Response(
      JSON.stringify({
        id,
        object: "chat.completion",
        created,
        model: body.model,
        choices: [
          { index: 0, message: { role: "assistant", content: echo }, finish_reason: "stop" },
        ],
        usage,
      }),
      { status: 200, headers: { "content-type": "application/json" } }
    );
  };

  // Inject chat_template_kwargs into the JSON body of a chat-completions
  // request for reasoning-capable models. Returns a new init with the rewritten
  // body, or the original init when nothing applies. `reasoningModels` is the
  // set of model ids whose output advertises `thought`.
  const withEffort = (input, init, url, reasoningModels) => {
    if (!url.pathname.endsWith("/chat/completions")) return init;
    let body = init?.body;
    if (typeof body !== "string") return init;
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch {
      return init;
    }
    if (!parsed || typeof parsed.model !== "string") return init;
    const baseId = parsed.model.includes("/") ? parsed.model.split("/").pop() : parsed.model;
    if (!reasoningModels.has(baseId)) return init;
    const level = readEffort();
    const mapped = EFFORT_ALIAS[baseId]?.[level] ?? level;
    parsed.chat_template_kwargs = effortKwargs(mapped);
    pacerDebugLog(
      `effort=${level}${mapped !== level ? `->${mapped}` : ""} injected for ${parsed.model}`
    );
    return { ...init, body: JSON.stringify(parsed) };
  };

  globalThis.fetch = (input, init) => {
    let url;
    try {
      url = new URL(typeof input === "string" ? input : input.url ?? String(input));
    } catch {
      return realFetch(input, init);
    }
    if (!SAIA_HOSTS.has(url.hostname)) return realFetch(input, init);

    const local = tryLocalEcho(init, url);
    if (local) return Promise.resolve(local);

    const enqueuedAt = Date.now();
    const reqId = crypto.randomUUID();
    let model = "";
    try {
      model = JSON.parse(init?.body)?.model || "";
    } catch {}

    const run = queue.then(async () => {
      if (consecutive5xx >= MAX_CONSECUTIVE_5XX) {
        pacerDebugLog(`cooldown: ${consecutive5xx} consecutive 5xx — sleeping 30s (head-of-line: queue blocked)`);
        await sleep(30_000);
        consecutive5xx = 0;
        pacerDebugLog("cooldown: done, resuming queue");
      }

      // Model-health breaker: if this model has been failing to send headers,
      // put a healthy stand-in on the wire instead. Rebinding `init` and
      // `model` here rather than deeper means every downstream consumer — the
      // req/resp/fail log lines, SILENT_PACED_MODELS, pickIdleTimeout and
      // wrapStreamWithRetry — follows the model actually being requested.
      //
      // Trade-off, accepted deliberately: opencode's UI and its token/cost
      // accounting still show the model the user selected. The toast is what
      // tells them. This is a stopgap that keeps a session alive during a
      // provider-side outage, not a silent permanent substitution.
      //
      // Idempotent: once `model` is the stand-in, effectiveModelFor returns it
      // unchanged. Called both here and at the top of every connect try, so a
      // breaker that trips *between* tries re-routes the remaining try instead
      // of spending the full last-try budget on a model already known to hang.
      const applyBreaker = () => {
        const substitute = effectiveModelFor(model);
        if (!substitute || substitute === model) return;
        try {
          const parsed = JSON.parse(init?.body);
          init = { ...init, body: JSON.stringify({ ...parsed, model: substitute }) };
          const h = modelHealth.get(model);
          if (h && !h.notified) {
            h.notified = true;
            saiaToast(`SAIA: ${model} is not responding — using ${substitute} for now`);
          }
          pacerDebugLog(`model-substitute ${model} -> ${substitute} id=${reqId}`);
          model = substitute;
        } catch {
          // Unparseable body: leave the request exactly as opencode built it.
        }
      };
      applyBreaker();

      let key = pickKey();
      if (key === null) throw allExhaustedError();

      // Declared here (assigned after `attempt`) so `attempt` can call it for
      // streaming responses while it can itself re-issue via `attempt`.
      let wrapStreamWithRetry;

      // Builds a request init whose body appends a continuation message telling
      // the model to resume from the text already streamed. `anchor` is the
      // object returned by resumeAnchor(); an empty/absent tail means a plain
      // retry on the original init.
      //
      // The anchor is only the TAIL of the partial when the partial is long.
      // The message therefore has to say so explicitly, or the model "helpfully"
      // re-emits the beginning it cannot see — which the user would receive as a
      // duplicate, since everything before the tail is already on their screen.
      // Role stays `user`: an assistant prefill would be the cleaner join, but
      // SAIA chat templates reject an assistant-final history (see the devstral-2
      // note in ROLE_MODELS).
      const continuationInit = (anchor) => {
        if (!anchor?.tail) return init;
        let body;
        try {
          body = JSON.parse(init?.body);
        } catch {
          return init;
        }
        if (!Array.isArray(body?.messages)) return init;
        const head = anchor.truncated
          ? `[TRANSPORT INTERRUPTION — a network failure cut your previous reply off after ` +
            `${anchor.totalChars} characters. All ${anchor.totalChars} characters were already ` +
            `delivered to the user's screen. Below is only the LAST ${anchor.tail.length} ` +
            `characters of them; everything before that was delivered too and is NOT repeated here.`
          : `[TRANSPORT INTERRUPTION — a network failure cut your previous reply off. ` +
            `Everything below was already delivered to the user's screen.`;
        body.messages = [
          ...body.messages,
          {
            role: "user",
            content:
              `${head}\n` +
              `Continue from exactly the end of the text below. The very next character you ` +
              `write must be the continuation. Do NOT restate, summarise, re-emit or apologise ` +
              `for any of it, and do NOT re-emit the earlier part that is not shown. If it ends ` +
              `mid-sentence, finish that sentence.]\n\n${anchor.tail}`,
          },
        ];
        return { ...init, body: JSON.stringify(body) };
      };

      const attempt = async (k, continuation) => {
        const wait = lastStart + MIN_INTERVAL_MS - Date.now();
        if (wait > 0) await sleep(wait);
        lastStart = Date.now();
        const reasoningModels = globalThis.__saiaReasoning ?? new Set();
        // Rebuilt per try (below) rather than once: applyBreaker() can rebind
        // `init` between tries, and effInit has to be derived from the current
        // one or the swap would never reach the wire.
        let effInit;
        // One reconnect on a connection-level failure. opencode retries 5xx and
        // 429 for us, but the AI SDK classifies an abort as user cancellation,
        // so a timed-out or dropped connection gets exactly one shot and
        // surfaces as a hard error. SAIA's defect is a bad *replica*, and a
        // fresh connection is re-load-balanced — so retrying here is what
        // actually recovers. The caller's own abort is never retried.
        for (let tryNo = 1; ; tryNo++) {
          applyBreaker();
          effInit = withEffort(input, continuationInit(continuation), url, reasoningModels);
          // The deadline wraps only the network call, so queue wait, 2100ms
          // spacing, the 30s cooldown and the 429 sleeps can't trigger a false
          // abort. AbortSignal.any keeps opencode's own cancellation working.
          //
          // It covers HEADERS ONLY and is cleared in the `finally` below the
          // moment realFetch resolves. An AbortSignal.timeout here stayed live
          // while opencode drained the SSE body and killed every turn longer
          // than TIMEOUT_MS at exactly TIMEOUT_MS. Body liveness belongs to the
          // idle timers in wrapStreamWithRetry (streaming) and bufferBody
          // (non-streaming). An explicit controller held in a local also avoids
          // relying on how the runtime keeps an AbortSignal.timeout reachable
          // through an AbortSignal.any composite alive.
          // Early tries get the short deadline and reconnect; the last try
          // gets the full budget. Only the last try's error is ever thrown, so
          // what reaches opencode still reads "within 45000ms" at the default
          // TIMEOUT_MS and the RESUMABLE_PATTERNS matcher is untouched.
          // Silent-paced models are exempt: they are legitimately slow to
          // first byte.
          const deadline =
            SILENT_PACED_MODELS.has(model) || tryNo >= MAX_CONNECT_TRIES
              ? TIMEOUT_MS
              : EARLY_TIMEOUT_MS;
          const headerCtl = new AbortController();
          const headerTimer = setTimeout(() => {
            headerCtl.abort(
              new DOMException(`SAIA headers not received within ${deadline}ms`, "TimeoutError")
            );
          }, deadline);
          headerTimer.unref?.();
          const signal = effInit?.signal
            ? AbortSignal.any([effInit.signal, headerCtl.signal])
            : headerCtl.signal;
          pacerDebugLog(
            `req ${url.pathname} model=${model} ${label(k)} id=${reqId} try=${tryNo} queued=${Date.now() - enqueuedAt}ms`
          );
          const startedAt = Date.now();
          let resp;
          try {
            resp = await realFetch(...withAuth(input, { ...effInit, signal }, k, reqId));
          } catch (e) {
            // The line that did not exist before: a hung or dropped connection
            // used to leave no trace anywhere. This is the report evidence.
            const retrying = !effInit?.signal?.aborted && tryNo < MAX_CONNECT_TRIES;
            pacerDebugLog(
              `fail ${e?.name ?? "Error"} ${url.pathname} model=${model} ${label(k)} id=${reqId} try=${tryNo} ` +
                `after=${Date.now() - startedAt}ms timeout=${deadline}ms retrying=${retrying} ` +
                `msg=${String(e?.message ?? e).replace(/\s+/g, " ").slice(0, 200)}`
            );
            // Feed the model-health breaker. Counted on EVERY try, not just
            // the final give-up: give-ups alone were 25 minutes apart in the
            // 2026-09-09 outage, far too slow to route around.
            if (e?.name === "TimeoutError" && !effInit?.signal?.aborted) recordModelTimeout(model);
            if (retrying) {
              if (SILENT_PACED_MODELS.has(model)) {
                await sleep(RETRY_BACKOFF_MS);
                pacerDebugLog(`backoff ${RETRY_BACKOFF_MS}ms before retry ${tryNo + 1} for ${model} (silent-drop pacing)`);
              }
              continue;
            }
            // Out of connection attempts: this request is lost. Mark it so the
            // auto-resume hook can attribute opencode's error to the transport.
            if (!effInit?.signal?.aborted) markTransportFail(String(e?.message ?? e));
            throw e;
          } finally {
            // ALWAYS, on every path: success, throw and caller-abort. Must wrap
            // the realFetch await ONLY — extending it over the body reads below
            // would re-introduce the body-spanning deadline. Clearing the timer
            // (not aborting headerCtl) is deliberate: aborting would cancel the
            // body stream we just received.
            clearTimeout(headerTimer);
          }
          const ttfb = Date.now() - startedAt;
          readBuckets(resp, k);
          consecutive5xx = resp.status >= 500 ? consecutive5xx + 1 : 0;
          if (resp.status < 500) recordModelSuccess(model);
          const s = stateFor(k);
          // kong id is emitted on every response, not just failures: GWDG needs a
          // healthy baseline to diff a bad request against.
          pacerDebugLog(
            `resp ${resp.status} ${url.pathname} model=${model} ${label(k)} id=${reqId} try=${tryNo} ttfb=${ttfb}ms ` +
              `kong=${resp.headers.get("x-kong-request-id")} upstream=${resp.headers.get("x-kong-upstream-latency")}ms ` +
              `remaining=${s.remaining.minute}/min ${s.remaining.hour}/hour ${s.remaining.day}/day`
          );
          // Streaming responses are wrapped at the single final return point
          // (after 429 handling) so the body is wrapped exactly once, and their
          // body clock is the idle timer. Everything else — /v1/models, error
          // bodies, non-stream completions — is buffered here under its own
          // deadline, because the headers deadline no longer covers the body.
          if (resp.headers.get("content-type")?.includes("text/event-stream")) return resp;
          let text = "";
          try {
            const buffered = await bufferBody(resp, BODY_TIMEOUT_MS);
            text = buffered.text;
            resp = buffered.resp;
          } catch (e) {
            pacerDebugLog(
              `body-fail ${e?.name ?? "Error"} ${url.pathname} model=${model} ${label(k)} id=${reqId} ` +
                `after=${Date.now() - startedAt}ms limit=${BODY_TIMEOUT_MS}ms ` +
                `msg=${String(e?.message ?? e).replace(/\s+/g, " ").slice(0, 200)}`
            );
            markTransportFail(String(e?.message ?? e));
            throw e;
          }
          // Extra evidence for the 500 investigation: body + retry-after. The
          // body is already in hand now, so this costs nothing but the log line.
          if (resp.status >= 500 && process.env.SAIA_PACER_DEBUG === "1") {
            pacerDebugLog(
              `5xx-detail ${resp.status} id=${reqId} consecutive=${consecutive5xx} ` +
                `retry-after=${resp.headers.get("retry-after")} body=${text.replace(/\s+/g, " ").slice(0, 500)}`
            );
          }
          return resp;
        }
      };

      // Wraps a streaming Response body so a mid-stream stall (headers arrived,
      // then no data for STREAM_IDLE_TIMEOUT_MS) is caught and retried by
      // re-issuing the request, instead of aborting opencode's step with a hard
      // "operation timed out". The caller's own abort is never retried.
      wrapStreamWithRetry = async (input, init, url, k, reqId, model, initialResp) => {
        const signal = init?.signal;
        const startedAt = Date.now();
        let retries = 0;
        const MAX_STREAM_RETRIES = MAX_CONNECT_TRIES;

        const readStream = async (resp, initialEmpty) => {
          const reader = resp.body?.getReader();
          if (!reader) {
            pacerDebugLog(`stream-no-body ${label(k)} id=${reqId}`);
            return resp.body;
          }
          let idleTimer = null;
          let stalled = false;
          // The reader currently being drained. Reassigned on every retry so
          // the ReadableStream's cancel() tears down the live one, not the
          // first one.
          let currentReader = reader;
          const decoder = new TextDecoder();
          let sseBuf = "";
          let partialText = "";
          let contentSeen = false;
          // Set once any tool_call delta has streamed. A stall after that point
          // is NOT resumable in-stream — see pump.
          let toolCallSeen = false;
          let toolArgChars = 0;
          // Reasoning deltas are enqueued but are not resumable text. Tracked so
          // a retry that may duplicate a thinking block is at least visible.
          let reasoningSeen = false;
          // finish_reason, once the stream reports one: the turn is semantically
          // complete from there on and a later transport error costs nothing.
          let finishSeen = null;
          // Silent-paced models get a longer idle window so slow-but-alive
          // reasoning isn't killed; a known-dead empty-200 (no kong id, no data)
          // gets a short window so we don't wait the full timeout on a dead node.
          // `let`, not const: a retry can land on a different replica, and
          // keeping the dead-replica window (10s) for a healthy-but-slow retry
          // would stall-and-retry it to death.
          let idleTimeout = 0;
          const pickIdleTimeout = (empty) => {
            idleTimeout = empty
              ? EMPTY_200_TIMEOUT_MS
              : SILENT_PACED_MODELS.has(model)
                ? SLOW_IDLE_TIMEOUT_MS
                : STREAM_IDLE_TIMEOUT_MS;
          };
          pickIdleTimeout(initialEmpty);

          const armIdleTimer = (r) => {
            if (idleTimer) return; // re-entrancy guard: one stall detector per reader
            idleTimer = setTimeout(() => {
              idleTimer = null;
              if (!signal?.aborted) {
                stalled = true;
                pacerDebugLog(`stream-stall ${label(k)} id=${reqId} retry=${retries} after=${Date.now() - startedAt}ms timeout=${idleTimeout}ms`);
                r.cancel().catch(() => {});
              }
            }, idleTimeout);
          };

          // Decode an SSE chunk, extracting the assistant content delta into
          // `partialText` so a stall can be resumed as a continuation, and
          // noting the other delta kinds that decide WHETHER a resume is safe.
          const ingest = (value) => {
            sseBuf += decoder.decode(value, { stream: true });
            let idx;
            while ((idx = sseBuf.indexOf("\n\n")) !== -1) {
              const raw = sseBuf.slice(0, idx);
              sseBuf = sseBuf.slice(idx + 2);
              for (const line of raw.split("\n")) {
                if (!line.startsWith("data:")) continue;
                const data = line.slice(5).trim();
                if (!data || data === "[DONE]") continue;
                try {
                  const evt = JSON.parse(data);
                  const choice = evt?.choices?.[0];
                  const delta = choice?.delta;
                  if (typeof delta?.content === "string" && delta.content) {
                    contentSeen = true;
                    partialText += delta.content;
                  }
                  if (typeof delta?.reasoning_content === "string" && delta.reasoning_content) reasoningSeen = true;
                  if (typeof delta?.reasoning === "string" && delta.reasoning) reasoningSeen = true;
                  if (Array.isArray(delta?.tool_calls) && delta.tool_calls.length) {
                    toolCallSeen = true;
                    for (const tc of delta.tool_calls) toolArgChars += (tc?.function?.arguments ?? "").length;
                  }
                  if (choice?.finish_reason) finishSeen = choice.finish_reason;
                } catch {}
              }
            }
          };

          // The join point handed to continuationInit. Only the tail of a long
          // partial is sent: the whole thing is already on the user's screen, so
          // quoting all of it back costs tokens without helping the model find
          // the seam. Cut at a whitespace boundary so the model is not anchored
          // mid-word.
          const resumeAnchor = () => {
            if (!contentSeen || partialText.length === 0) {
              return { tail: "", totalChars: partialText.length, truncated: false };
            }
            if (partialText.length <= RESUME_ANCHOR_CHARS) {
              return { tail: partialText, totalChars: partialText.length, truncated: false };
            }
            const raw = partialText.slice(-RESUME_ANCHOR_CHARS);
            const tail = raw.replace(/^\S*\s+/, "") || raw;
            return { tail, totalChars: partialText.length, truncated: true };
          };

          // Drains ONE reader to completion, piping chunks into `ctrl`. Never
          // retries and never recurses — it only classifies how the read ended
          // and hands that back to pump. Keeping the retry decision out of here
          // is what guarantees exactly one live reader and one live idleTimer at
          // a time; the previous version recursed from inside its own try, so a
          // failing retry re-entered the outer catch and two frames shared
          // `stalled`/`idleTimer`/`retries`.
          const drain = async (r, ctrl) => {
            armIdleTimer(r);
            try {
              for (;;) {
                const { done, value } = await r.read();
                clearTimeout(idleTimer);
                idleTimer = null;
                if (done) {
                  return stalled ? { kind: "retry", err: new Error("stream stalled") } : { kind: "done" };
                }
                ingest(value);
                ctrl.enqueue(value);
                if (!signal?.aborted) armIdleTimer(r);
              }
            } catch (e) {
              clearTimeout(idleTimer);
              idleTimer = null;
              return { kind: "retry", err: e };
            }
          };

          // Drives `drain` in a flat loop, re-issuing the request via `attempt`
          // on any transport failure the caller did not cause, up to
          // MAX_STREAM_RETRIES. When content was already streamed, the retry
          // carries a tail anchor so the new stream appends coherently instead
          // of duplicating from scratch.
          const pump = async (firstReader, ctrl) => {
            let r = firstReader;
            for (;;) {
              const out = await drain(r, ctrl);
              if (out.kind === "done") {
                ctrl.close();
                pacerDebugLog(`stream-done ${label(k)} id=${reqId} total=${Date.now() - startedAt}ms`);
                return;
              }
              const e = out.err;
              const callerAborted = signal?.aborted === true;

              // The turn already reported finish_reason: it is semantically
              // complete and only the transport teardown failed. Closing here
              // turns a spurious hard error into a success.
              if (finishSeen && !callerAborted) {
                pacerDebugLog(
                  `stream-late-error-ignored ${label(k)} id=${reqId} finish=${finishSeen} name=${e?.name ?? "Error"}`
                );
                ctrl.close();
                return;
              }

              // A stall after tool_call arguments started streaming cannot be
              // resumed in-stream: opencode's SSE accumulator already holds a
              // partial call keyed by index, so a second sequence either
              // concatenates two partial JSON argument strings into invalid
              // JSON or registers a duplicate call — and a duplicated edit/bash
              // call is a real side effect. There is also no way to express
              // "continue this tool call" in an OpenAI-compatible request.
              // Fail the turn instead and let session auto-resume re-plan it
              // from a clean history.
              if (toolCallSeen && !callerAborted) {
                pacerDebugLog(
                  `stream-toolcall-abandon ${label(k)} id=${reqId} toolArgs=${toolArgChars}chars ` +
                    `retries=${retries} name=${e?.name ?? "Error"}`
                );
                markTransportFail(`stream stalled mid tool-call (${toolArgChars} arg chars)`);
                ctrl.error(new Error("SAIA stream stalled mid tool-call — not resumable in-stream"));
                return;
              }

              // Retry ANY error the caller did not cause: TimeoutError (our own
              // deadline), AbortError (the idle timer's cancel), and the socket
              // deaths that surface as `TypeError: terminated`, ECONNRESET or
              // "premature close". The old gate matched AbortError only, so the
              // TimeoutError raised by our own deadline fell straight through to
              // ctrl.error and killed the step.
              const retryable = !callerAborted && retries < MAX_STREAM_RETRIES;
              pacerDebugLog(
                `stream-error ${label(k)} id=${reqId} name=${e?.name ?? "Error"} ` +
                  `retries=${retries}/${MAX_STREAM_RETRIES} callerAborted=${callerAborted} ` +
                  `retryable=${retryable} content=${partialText.length}chars ` +
                  `msg=${String(e?.message ?? e).replace(/\s+/g, " ").slice(0, 200)}`
              );
              if (!retryable) {
                if (!callerAborted) {
                  pacerDebugLog(`stream-fail ${label(k)} id=${reqId} after=${Date.now() - startedAt}ms msg=${String(e).slice(0, 200)}`);
                  markTransportFail(String(e?.message ?? e));
                }
                ctrl.error(e);
                return;
              }

              retries++;
              if (SILENT_PACED_MODELS.has(model)) {
                await sleep(RETRY_BACKOFF_MS);
                pacerDebugLog(`backoff ${RETRY_BACKOFF_MS}ms before stream retry ${retries} for ${model}`);
              }
              const anchor = resumeAnchor();
              pacerDebugLog(
                `stream-retry ${label(k)} id=${reqId} retry=${retries}/${MAX_STREAM_RETRIES} ` +
                  `anchor=${anchor.tail.length}chars total=${anchor.totalChars}chars ` +
                  `truncated=${anchor.truncated} reasoningOnly=${!contentSeen && reasoningSeen}`
              );
              let newResp;
              try {
                newResp = await attempt(k, anchor);
              } catch (err) {
                pacerDebugLog(`stream-retry-fail ${label(k)} id=${reqId} msg=${String(err?.message ?? err).slice(0, 200)}`);
                markTransportFail(String(err?.message ?? err));
                ctrl.error(err);
                return;
              }
              if (newResp.status !== 200 || !newResp.body) {
                pacerDebugLog(`stream-retry-fail ${label(k)} id=${reqId} status=${newResp.status}`);
                markTransportFail(`stream retry failed with status ${newResp.status}`);
                ctrl.error(new Error(`Stream retry failed with status ${newResp.status}`));
                return;
              }
              r = newResp.body.getReader();
              currentReader = r;
              pickIdleTimeout(deadReplica(newResp));
              stalled = false;
            }
          };

          const stream = new ReadableStream({
            async start(ctrl) {
              await pump(reader, ctrl);
            },
            cancel() {
              clearTimeout(idleTimer);
              idleTimer = null;
              currentReader.cancel().catch(() => {});
            },
          });

          return stream;
        };

        const finalResp = initialResp ?? (await attempt(k));
        // A 200 with no kong id and no upstream latency is a dead replica that
        // accepted the connection but returns no data — retry it fast instead of
        // waiting the full idle timeout on a node that will never respond.
        const initialEmpty = deadReplica(finalResp);
        const bodyStream = await readStream(finalResp, initialEmpty);
        return new Response(bodyStream, {
          status: finalResp.status,
          statusText: finalResp.statusText,
          headers: finalResp.headers,
        });
      };

      let resp = await attempt(key);
      if (resp.status === 429) {
        const reset = Number(resp.headers.get("ratelimit-reset")) || 60;
        pacerDebugLog(`429 ${url.pathname} on ${label(key)} — waiting ${Math.min(reset, 65)}s before one retry`);
        await sleep(Math.min(reset, 65) * 1000);
        resp = await attempt(key);
        if (resp.status === 429) {
          // out of budget despite pacing — fail this key over, try the next once
          markExhausted(key, "hour");
          writeSnapshot();
          key = pickKey();
          if (key === null) throw allExhaustedError();
          pacerDebugLog(`429 twice — retrying once on ${label(key)}`);
          resp = await attempt(key);
          if (resp.status === 429) {
            const s = stateFor(key);
            throw new Error(
              `SAIA rate limit still exceeded after waiting and switching keys (remaining on ${label(key)}: ` +
                `${s.remaining.minute}/min, ${s.remaining.hour}/hour, ${s.remaining.day}/day) — aborting.`
            );
          }
        }
      }
      // For streaming responses, wrap the body to handle mid-stream stalls.
      const isStreaming = resp.headers.get("content-type")?.includes("text/event-stream");
      if (resp.status === 200 && isStreaming) {
        pacerDebugLog(`stream-wrap-final ${label(key)} id=${reqId} model=${model}`);
        return await wrapStreamWithRetry(input, init, url, key, reqId, model, resp);
      }
      return resp;
    });

    // keep the chain alive even when a request fails
    queue = run.catch(() => {});
    return run;
  };
}

// SAIA's /v1/models under-reports these: they return a populated `reasoning`
// field but advertise output: ["text"] with no "thought". Verified 2026-08-28 by
// probing all 16 ready models — 3 false negatives, no false positives. Without
// this the effort gate skips them entirely (openai-gpt-oss-120b is debugger's
// live fallback below, so it was silently uncontrolled).
const FORCE_REASONING = new Set([
  "qwen3.6-35b-a3b",
  "qwen3.8-27b",
  "openai-gpt-oss-120b",
]);

// Models whose chat template accepts a non-standard effort ladder. Anything not
// listed here passes through unchanged. qwen3.8-27b returns HTTP 400 on high and
// max ("Supported types are xhigh (default), medium, and low"), so both map to
// its own top rung. `off` is never remapped — every model accepts it.
const EFFORT_ALIAS = {
  "qwen3.8-27b": { high: "xhigh", max: "xhigh" },
};

// Preferred model per agent role, best first. The plugin picks the first entry
// that SAIA currently reports as `ready`; if none are ready it falls back to any
// available model so auto mode keeps working. Edit THIS to change auto-mode models.
const ROLE_MODELS = {
  // Solo workhorse: strongest tool-use coder, full-context single session.
  solo:       ["qwen3-coder-next", "glm-4.7"],
  // Orchestrator: best rule-following per request; deepseek-v4-flash demoted
  // (ignores prompt rules under task pressure — verified 2026-07-13).
  // qwen3.5-397b-a17b dropped — its endpoint hangs (see researcher note below).
  auto:       ["qwen3.5-122b-a10b", "deepseek-v4-flash-0731"],
  // Planning is the highest-leverage request in the chain. qwen3.5-397b was
  // removed entirely: its endpoint hung on 3 of 4 dispatches (2026-07-13/14),
  // stalling the whole chain — a "ready"-but-hanging model is worse than none.
  researcher: ["qwen3.5-122b-a10b", "qwen3-coder-next"],
  coder:      ["qwen3-coder-next", "glm-4.7"],
  // Native plan->build workflow: the strongest benchmark result (spreadsheet
  // 33/34 at 36 requests, 2026-07-14) was plan+build fully on deepseek —
  // best implementer, poor orchestrator (rule-following), so it lives here
  // and NOT in solo/auto. solo stays on qwen: 2-3x cheaper per task.
  plan:       ["deepseek-v4-flash-0731", "qwen3.5-122b-a10b"],
  build:      ["qwen3-coder-next", "deepseek-v4-flash-0731"],
  // Fix rounds run on a DIFFERENT model family to break correlated errors.
  coder2:     ["glm-4.7", "mistral-medium-3.5-128b"],
  debugger:   ["qwen3-coder-next", "openai-gpt-oss-120b"],
  // Native opencode subagents (always shipped). general is a versatile
  // read+write helper; explore is read-only search — kept cheaper.
  general:    ["deepseek-v4-flash-0731", "qwen3-coder-next"],
  explore:    ["qwen3-coder-next", "qwen3.5-122b-a10b"],
  // devstral-2 is excluded everywhere: its SAIA chat template rejects
  // opencode's step-cap continuation ("Cannot set add_generation_prompt ...
  // last message is from the assistant"), burning a full step budget per try.
};

const BUCKET_LIMITS = { hour: 200, day: 1000, month: 3000 };

// Reads the pacer's latest budget snapshot and aggregates remaining counts
// across all keys. A key without a fresh (<15 min) per-key snapshot counts
// as full — the same optimism the pacer itself has for untouched keys.
// Returns {hour, day, month, keyCount}, or null when no key has fresh data.
function freshBudget() {
  try {
    const snap = JSON.parse(readFileSync(BUDGET_PATH, "utf-8"));
    const entries =
      Array.isArray(snap.keys) && snap.keys.length
        ? snap.keys
        : [{ updatedAt: snap.updatedAt, remaining: snap.remaining }]; // pre-multi-key format
    const total = { hour: 0, day: 0, month: 0 };
    let anyFresh = false;
    for (const e of entries) {
      const ageMin = (Date.now() - Date.parse(e.updatedAt)) / 60000;
      const fresh = ageMin >= 0 && ageMin < 15 && typeof e.remaining?.hour === "number";
      if (fresh) anyFresh = true;
      for (const b of ["hour", "day", "month"]) {
        // a bucket the pacer stamped exhausted counts as empty until its TTL
        // passes (markExhausted nulls the count, so `remaining` can't tell)
        const stamp = e.exhausted?.[b];
        if (typeof stamp === "number" && stamp > 0 && Date.now() - stamp < RESET_TTL_MS[b]) {
          anyFresh = true;
          continue;
        }
        total[b] += fresh && typeof e.remaining[b] === "number" ? e.remaining[b] : BUCKET_LIMITS[b];
      }
    }
    if (anyFresh) return { ...total, keyCount: entries.length };
  } catch {}
  return null;
}

const LOW_HOUR_THRESHOLD = 40;
const LOW_DAY_THRESHOLD = 50;
const LOW_MONTH_THRESHOLD = 60;

// A chain/task shouldn't start when any bucket is too tight to fit one.
function budgetIsLow(b) {
  return (
    (b.hour !== null && b.hour < LOW_HOUR_THRESHOLD) ||
    (b.day !== null && b.day < LOW_DAY_THRESHOLD) ||
    (b.month !== null && b.month < LOW_MONTH_THRESHOLD)
  );
}

// Sessions that already have a subagent chain in flight: the budget gate only
// blocks STARTING a chain, never strangles one mid-run (the pacer's hard
// floor still protects the tail).
const chainStarted = new Set();

// ---------------------------------------------------------------------------
// Session auto-resume.
//
// The pacer absorbs transport faults where it can (headers deadline, connect
// retries, mid-stream resume). What it cannot absorb ends the assistant turn
// with an error and stops the run — the user then has to retype "continue".
// This re-prompts the session itself. It is capped, budget-aware and refuses
// to touch anything it did not positively classify as a transport failure, so
// a SAIA outage cannot turn into a resume storm that drains the request budget.
// ---------------------------------------------------------------------------
const AUTO_RESUME = process.env.SAIA_AUTO_RESUME !== "0";
// MessageAbortedError is the one ambiguous case: opencode reports both a user
// Esc and some transport deaths that way. Resuming an Esc would override a
// deliberate cancellation, so it stays opt-in and even then only fires inside
// TRANSPORT_FAIL_FRESH_MS of the pacer marking a request lost.
const RESUME_ON_ABORT = process.env.SAIA_RESUME_ON_ABORT === "1";
const TRANSPORT_FAIL_FRESH_MS = 10_000;
const MAX_AUTO_RESUMES = 3; // per session, per streak of failures
const RESUME_BACKOFF_MS = [5_000, 20_000, 60_000];
// message.updated and session.error both fire for one failure; this window
// collapses them into a single decision.
const RESUME_DEDUPE_MS = 5_000;
// Watchdog: a fireResume that never completes (a wedged HTTP call) must not
// latch a session out of resuming forever.
const RESUME_INFLIGHT_TTL_MS = 10 * 60_000;
// Global ceiling across all sessions, so a wide outage cannot drain the budget.
const MAX_RESUMES_PER_HOUR = 8;
// How long session.error waits for the richer message.updated for the same
// failure before acting on its own.
const SESSION_ERROR_DEFER_MS = 750;

const NEVER_RESUME_NAMES = new Set(["ProviderAuthError", "MessageOutputLengthError"]);
// The pacer's own refusals. Resuming these would re-enter a drained bucket and
// spend the last of the budget on a request that is already known to fail.
const NEVER_RESUME_PATTERNS = [
  /SAIA rate limit still exceeded/i,
  /nearly exhausted/i,
  /aborting instead of retry-spinning/i,
  /budget LOW/i,
  /Refusing to start the chain/i,
];
const RESUMABLE_PATTERNS = [
  /operation timed out/i,
  /TimeoutError/i,
  /headers not received within/i,
  /body not received within/i,
  /stream stalled/i,
  /not resumable in-stream/i,
  /Stream retry failed with status/i,
  /\bterminated\b/i,
  /ECONNRESET/i,
  /ECONNREFUSED/i,
  /ETIMEDOUT/i,
  /EPIPE/i,
  /socket hang up/i,
  /fetch failed/i,
  /premature close/i,
];

// Decides whether an opencode error is worth re-prompting for. Fails CLOSED:
// an unrecognised error is left standing and logged, so the taxonomy grows from
// real failures instead of guesses.
function classifyResume(error) {
  if (!error) return { resume: false, why: "no error object" };
  const name = error.name ?? "";
  const msg = String(error.data?.message ?? "");
  if (NEVER_RESUME_NAMES.has(name)) return { resume: false, why: `never-resume ${name}` };
  if (name === "MessageAbortedError") {
    const mark = globalThis.__saiaLastTransportFail;
    const fresh = mark && Date.now() - mark.at < TRANSPORT_FAIL_FRESH_MS;
    if (RESUME_ON_ABORT && fresh) {
      return { resume: true, why: `abort within ${TRANSPORT_FAIL_FRESH_MS}ms of transport fail (${mark.msg.slice(0, 60)})` };
    }
    return {
      resume: false,
      why: fresh ? "aborted, transport marker fresh but SAIA_RESUME_ON_ABORT unset" : "aborted by user",
    };
  }
  for (const re of NEVER_RESUME_PATTERNS) {
    if (re.test(msg)) return { resume: false, why: `never-resume budget/limit (${msg.slice(0, 60)})` };
  }
  if (name === "APIError") {
    const code = Number(error.data?.statusCode);
    // 429 is owned by the pacer (waits for the advertised reset, then fails the
    // key over) and by opencode. A resume would just re-enter a drained bucket.
    if (code === 429) return { resume: false, why: "429 — rate limits are the pacer's job" };
    if (code >= 400 && code < 500) return { resume: false, why: `client error ${code}` };
    if (code >= 500) return { resume: true, why: `server error ${code}` };
    if (error.data?.isRetryable === true) return { resume: true, why: "APIError isRetryable" };
  }
  for (const re of RESUMABLE_PATTERNS) {
    if (re.test(msg)) return { resume: true, why: `transport (${msg.slice(0, 60)})` };
  }
  return { resume: false, why: `unclassified ${name || "error"} (${msg.slice(0, 100)})` };
}

// Sent as a synthetic user part. It has to say plainly that the interruption
// was not the model's doing (otherwise the model apologises and re-plans) and
// that a half-applied edit may be on disk (otherwise it trusts its own memory
// of what it wrote and duplicates or skips work).
const RESUME_PROMPT = `[AUTOMATIC RESUME — your previous turn was killed by a network/transport failure between this machine and the SAIA endpoint (request timeout, dropped SSE stream, or a 5xx). This was NOT a decision by you, NOT a mistake in your work, and NOT a user interruption. No new instructions have been given.

Before doing anything else:
1. Do not restate the plan, do not summarise what you were doing, and do not apologise.
2. Any file you were part-way through editing may be fully written, partially written, or untouched — the write may have landed after the connection died. Re-read every file you had started editing, and re-run your last verification command if you had one, to establish what is actually on disk right now. Trust the file, not your memory of it.
3. Treat completed work as completed: do not redo edits that are already present, and do not repeat tool calls whose results are already in this conversation above.

Then continue the original task from the first step that is genuinely still outstanding, and finish it.]`;

export const server = async (input) => {
  // PluginInput.client is the opencode SDK client for this server; it is what
  // lets the plugin put a prompt back into a session. Missing client => the
  // pacer still works and auto-resume simply stays off.
  const client = input?.client ?? null;
  const directory = input?.directory;
  const dirQuery = directory ? { directory } : undefined;
  const resumeEnabled = AUTO_RESUME && !!client;
  // Back the saiaToast() shim with the real TUI route. /tui/show-toast exists
  // in opencode 1.17.18; guarded anyway because `opencode run` has no TUI
  // attached and older builds may not expose the method. A failed notice must
  // never take down the resume or the request it is describing.
  globalThis.__saiaToast = (message, variant = "warning") => {
    try {
      client?.tui?.showToast?.({ body: { message, variant } })?.catch?.(() => {});
    } catch {}
  };
  pacerDebugLog(
    resumeEnabled
      ? `auto-resume: armed (max ${MAX_AUTO_RESUMES}/session, ${MAX_RESUMES_PER_HOUR}/hour, backoff ${RESUME_BACKOFF_MS.join("/")}ms)`
      : `auto-resume: OFF (enabled=${AUTO_RESUME} client=${!!client})`
  );

  // sessionID -> resume bookkeeping
  const resumeState = new Map();
  const resumeStateFor = (id) => {
    let s = resumeState.get(id);
    if (!s) {
      s = {
        attempts: 0,
        inFlight: false,
        timer: null,
        watchdog: null,
        lastDecisionAt: 0,
        selfPromptAt: 0,
        awaitingSelfMessage: 0,
        lastUserMessageID: null,
        errorAtUserMessageID: null,
      };
      // Every session that emits a message gets an entry, including subagent
      // sessions, so a long-lived TUI would grow this forever. Drop the idle
      // ones once the map gets large; they carry no pending work.
      if (resumeState.size > 200) {
        for (const [k, v] of resumeState) {
          if (!v.inFlight && !v.timer && v.attempts === 0) resumeState.delete(k);
          if (resumeState.size <= 100) break;
        }
      }
      resumeState.set(id, s);
    }
    return s;
  };
  // Assistant message ids already acted on. message.updated fires repeatedly
  // for the same message, so this is the exact dedupe key.
  const handledErrorMessages = new Set();
  // Sessions opencode is itself retrying (SessionStatus {type:"retry"}).
  const sessionRetrying = new Set();
  let resumeTimes = [];

  // Cancels a pending resume outright. Only for events that mean "no resume
  // should happen": the user took over, the session is gone, we are shutting
  // down, or the resume just fired.
  const cancelResume = (sessionID, why) => {
    const s = resumeState.get(sessionID);
    if (!s) return;
    if (s.timer) {
      clearTimeout(s.timer);
      s.timer = null;
    }
    if (s.watchdog) {
      clearTimeout(s.watchdog);
      s.watchdog = null;
    }
    if (s.inFlight) pacerDebugLog(`auto-resume release session=${sessionID} why=${why}`);
    s.inFlight = false;
  };

  // The session went quiet. That happens right after an errored turn too —
  // which is exactly when a resume is sitting in its backoff — so a scheduled
  // timer must survive this. Only an idle with nothing pending clears state.
  const idleResume = (sessionID) => {
    const s = resumeState.get(sessionID);
    if (!s || s.timer) return;
    cancelResume(sessionID, "idle");
  };

  // Runs after the backoff. The world moved during those 5-60s, so every gate
  // that can still change is re-checked before a request is spent.
  const fireResume = async (sessionID, hint, why) => {
    const s = resumeStateFor(sessionID);
    try {
      if (sessionRetrying.has(sessionID)) {
        pacerDebugLog(`auto-resume skip session=${sessionID} reason=opencode-retrying (post-backoff)`);
        return;
      }
      const b = freshBudget();
      if (b !== null && budgetIsLow(b)) {
        pacerDebugLog(`auto-resume skip session=${sessionID} reason=budget-low (~${b.hour}/hour)`);
        return;
      }
      // A subagent session's failure surfaces to its parent as a tool error.
      // Re-prompting the child produces a reply nobody is waiting for and can
      // never deliver a result into the parent's tool call — the orchestrator
      // prompt handles that case instead.
      let sess;
      try {
        sess = (await client.session.get({ path: { id: sessionID }, query: dirQuery }))?.data;
      } catch (e) {
        pacerDebugLog(`auto-resume session.get failed session=${sessionID} msg=${String(e?.message ?? e).slice(0, 120)}`);
      }
      if (sess?.parentID) {
        pacerDebugLog(`auto-resume skip session=${sessionID} reason=child-session (parent=${sess.parentID})`);
        return;
      }
      let msgs;
      try {
        msgs = (await client.session.messages({ path: { id: sessionID }, query: { ...(dirQuery ?? {}), limit: 4 } }))?.data;
      } catch (e) {
        pacerDebugLog(`auto-resume session.messages failed session=${sessionID} msg=${String(e?.message ?? e).slice(0, 120)}`);
      }
      const last = Array.isArray(msgs) && msgs.length ? msgs[msgs.length - 1]?.info : null;
      if (
        last?.role === "user" &&
        last.id !== s.errorAtUserMessageID &&
        (last.time?.created ?? 0) > s.selfPromptAt + 1000
      ) {
        pacerDebugLog(`auto-resume skip session=${sessionID} reason=user-reprompted`);
        return;
      }
      if (last?.role === "assistant" && last.time?.completed && !last.error) {
        s.attempts = 0;
        pacerDebugLog(`auto-resume skip session=${sessionID} reason=already-recovered`);
        return;
      }
      s.selfPromptAt = Date.now();
      s.awaitingSelfMessage = Date.now();
      await client.session.promptAsync({
        path: { id: sessionID },
        query: dirQuery,
        body: {
          parts: [{ type: "text", text: RESUME_PROMPT, synthetic: true }],
          ...(hint?.agent ? { agent: hint.agent } : {}),
          ...(hint?.model ? { model: hint.model } : {}),
        },
      });
      pacerDebugLog(
        `auto-resume fired session=${sessionID} attempt=${s.attempts}/${MAX_AUTO_RESUMES} ` +
          `agent=${hint?.agent ?? "-"} model=${hint?.model?.modelID ?? "-"} why=${why}`
      );
      // opencode stamps the transport error permanently onto the failed
      // message, and the resume arrives as a synthetic user part with nothing
      // linking the two — so without this the turn just looks dead.
      saiaToast(`SAIA auto-resume ${s.attempts}/${MAX_AUTO_RESUMES} — ${why}`);
    } catch (e) {
      // Do not re-schedule here: the next genuine error event will.
      s.awaitingSelfMessage = 0;
      pacerDebugLog(`auto-resume prompt failed session=${sessionID} msg=${String(e?.message ?? e).slice(0, 200)}`);
    } finally {
      cancelResume(sessionID, "fire complete");
    }
  };

  // Synchronous gates only — `event` is called for every event, including
  // high-frequency part updates, so the hot path must stay cheap. Anything
  // needing I/O is re-checked in fireResume.
  const considerResume = (sessionID, error, messageID, hint) => {
    if (!resumeEnabled || !sessionID) return;
    const s = resumeStateFor(sessionID);
    if (messageID) {
      if (handledErrorMessages.has(messageID)) return;
      handledErrorMessages.add(messageID);
      if (handledErrorMessages.size > 200) {
        for (const id of handledErrorMessages) {
          handledErrorMessages.delete(id);
          if (handledErrorMessages.size <= 100) break;
        }
      }
    }
    if (s.inFlight) {
      pacerDebugLog(`auto-resume skip session=${sessionID} reason=in-flight`);
      return;
    }
    const now = Date.now();
    if (now - s.lastDecisionAt < RESUME_DEDUPE_MS) {
      pacerDebugLog(`auto-resume skip session=${sessionID} reason=dedupe-window`);
      return;
    }
    s.lastDecisionAt = now;
    if (sessionRetrying.has(sessionID)) {
      pacerDebugLog(`auto-resume skip session=${sessionID} reason=opencode-retrying`);
      return;
    }
    const { resume, why } = classifyResume(error);
    if (!resume) {
      pacerDebugLog(`auto-resume skip session=${sessionID} reason=${why}`);
      return;
    }
    resumeTimes = resumeTimes.filter((t) => now - t < 3_600_000);
    if (resumeTimes.length >= MAX_RESUMES_PER_HOUR) {
      pacerDebugLog(`auto-resume skip session=${sessionID} reason=global-cap ${resumeTimes.length}/${MAX_RESUMES_PER_HOUR} per hour`);
      return;
    }
    if (s.attempts >= MAX_AUTO_RESUMES) {
      pacerDebugLog(`auto-resume skip session=${sessionID} reason=cap ${s.attempts}/${MAX_AUTO_RESUMES}`);
      return;
    }
    const b = freshBudget();
    if (b !== null && budgetIsLow(b)) {
      pacerDebugLog(`auto-resume skip session=${sessionID} reason=budget-low (~${b.hour}/hour)`);
      return;
    }
    s.inFlight = true;
    s.attempts++;
    s.errorAtUserMessageID = s.lastUserMessageID;
    resumeTimes.push(now);
    const delay = RESUME_BACKOFF_MS[Math.min(s.attempts - 1, RESUME_BACKOFF_MS.length - 1)];
    s.timer = setTimeout(() => {
      s.timer = null;
      fireResume(sessionID, hint, why);
    }, delay);
    // unref: a pending backoff must not keep a short-lived `opencode run`
    // process alive past its work. The trade-off is that a resume scheduled at
    // the very end of a `run` may not fire; in the TUI/server the event loop is
    // held open anyway, which is where this matters.
    s.timer.unref?.();
    s.watchdog = setTimeout(() => {
      pacerDebugLog(`auto-resume watchdog session=${sessionID} — force-releasing after ${RESUME_INFLIGHT_TTL_MS}ms`);
      cancelResume(sessionID, "watchdog");
    }, RESUME_INFLIGHT_TTL_MS);
    s.watchdog.unref?.();
    pacerDebugLog(
      `auto-resume scheduled session=${sessionID} msg=${messageID ?? "-"} ` +
        `attempt=${s.attempts}/${MAX_AUTO_RESUMES} delay=${delay}ms ` +
        `agent=${hint?.agent ?? "-"} model=${hint?.model?.modelID ?? "-"} why=${why}`
    );
  };

  return {
    // Watches for turns that died on a transport fault and re-prompts the
    // session. Keyed off message.updated rather than session.error: the
    // assistant message always carries sessionID, a stable id to dedupe on, and
    // the agent/model of the failed turn, while
    // EventSessionError.properties.sessionID is optional.
    event: async ({ event }) => {
      if (!resumeEnabled) return;
      const p = event?.properties;
      if (!p) return;
      if (event.type === "session.status") {
        if (p.status?.type === "retry") sessionRetrying.add(p.sessionID);
        else sessionRetrying.delete(p.sessionID);
        return;
      }
      if (event.type === "session.idle") {
        idleResume(p.sessionID);
        return;
      }
      if (event.type === "session.deleted") {
        const id = p.info?.id ?? p.sessionID;
        cancelResume(id, "deleted");
        resumeState.delete(id);
        return;
      }
      if (event.type === "session.error") {
        // Fallback for failures that never became an errored assistant message.
        // Deliberately deferred: session.error usually arrives a few ms BEFORE
        // the message.updated for the same failure, and message.updated is the
        // event that carries the agent, the model and a messageID to dedupe on.
        // Letting the bare event win produced resumes logged as `agent=- model=-`.
        // If message.updated does arrive first, this call lands inside the
        // dedupe window or the in-flight latch and skips.
        if (!p.sessionID) {
          pacerDebugLog("auto-resume: session.error without sessionID — ignored");
          return;
        }
        const sid = p.sessionID;
        const err = p.error;
        const t = setTimeout(() => considerResume(sid, err, undefined, {}), SESSION_ERROR_DEFER_MS);
        t.unref?.();
        return;
      }
      if (event.type !== "message.updated") return;
      const info = p.info;
      if (!info?.sessionID) return;
      const s = resumeStateFor(info.sessionID);
      if (info.role === "user") {
        // message.updated is re-emitted for a message we have already seen
        // (token counts, part updates). Treating those as the user taking over
        // cancelled pending resumes and reset the attempt counter, which would
        // defeat MAX_AUTO_RESUMES entirely. Only a NEW id is a takeover.
        if (info.id && info.id === s.lastUserMessageID) return;
        // Our own synthetic prompt also creates a user message, and reading it
        // as a takeover reset the counter every single time — the resume then
        // looped at attempt=1/3 forever until the global hourly cap caught it.
        // A time window is the wrong test: the event was measured arriving
        // 2103ms after promptAsync was called, just outside a 2s guard. The
        // flag is set before the call and cleared by the first user message
        // that follows, so latency cannot break it. The 30s bound only stops a
        // failed prompt from latching the flag forever.
        if (s.awaitingSelfMessage && Date.now() - s.awaitingSelfMessage < 30_000) {
          s.awaitingSelfMessage = 0;
          s.lastUserMessageID = info.id;
          pacerDebugLog(`auto-resume: own synthetic prompt seen in ${info.sessionID} msg=${info.id}`);
          return;
        }
        const hadPending = s.inFlight || s.attempts > 0;
        cancelResume(info.sessionID, "user message");
        s.attempts = 0;
        s.lastUserMessageID = info.id;
        if (hadPending) {
          pacerDebugLog(
            `auto-resume: user message in ${info.sessionID} msg=${info.id} ` +
              `— counter reset, pending resume cancelled`
          );
        }
        return;
      }
      if (info.role !== "assistant") return;
      if (!info.error) {
        if (info.time?.completed) {
          s.attempts = 0;
          cancelResume(info.sessionID, "clean completion");
        }
        return;
      }
      considerResume(info.sessionID, info.error, info.id, {
        agent: info.mode,
        model: { providerID: info.providerID, modelID: info.modelID },
      });
    },

    // A shutdown mid-backoff must not fire a prompt into a dying server.
    dispose: async () => {
      for (const id of [...resumeState.keys()]) cancelResume(id, "dispose");
      resumeState.clear();
    },

    // Code-enforced budget gate: the prompt-level gate is advisory only
    // (deepseek ignores it under task pressure), so the first `task` call of
    // a session is refused outright when the hourly budget can't fit a chain.
    "tool.execute.before": async (input, _output) => {
      if (input.tool !== "task") return;
      if (chainStarted.has(input.sessionID)) return;
      const b = freshBudget();
      if (b !== null && budgetIsLow(b)) {
        throw new Error(
          `SAIA budget LOW (~${b.hour} left this hour across ${b.keyCount} key(s), ` +
            `~${b.day} today, ~${b.month} this month) — ` +
            `a subagent chain needs ~20-40 requests. Refusing to start the chain — ` +
            `report this to the user and stop; retry after the bucket resets.`
        );
      }
      chainStarted.add(input.sessionID);
    },

    config: async (config) => {
      let key;
      try {
        const authPath = join(homedir(), ".local/share/opencode/auth.json");
        const auth = JSON.parse(readFileSync(authPath, "utf-8"));
        key = auth["saia-gwdg"]?.key;
      } catch {
        return;
      }

      if (!key) return;

      // Optional failover keys: KEYS_PATH holds {"keys": ["...", ...]} in
      // rotation order after the auth.json key (always #1). A missing or
      // unreadable file means single-key behavior, exactly as before.
      let keys = [key];
      try {
        const extra = JSON.parse(readFileSync(KEYS_PATH, "utf-8"));
        if (Array.isArray(extra?.keys)) {
          keys = [...new Set([key, ...extra.keys.filter((k) => typeof k === "string" && k)])];
        }
      } catch {}
      installPacer(keys);
      pacerDebugLog(`pacer: ${keys.length} SAIA key(s) in rotation, timeout=${TIMEOUT_MS}ms`);

      let cached;
      try {
        cached = JSON.parse(readFileSync(CACHE_PATH, "utf-8"));
      } catch {}

      let models;
      if (
        typeof cached?.fetchedAt === "number" &&
        Date.now() - cached.fetchedAt < MODELS_TTL_MS &&
        cached.models
      ) {
        models = cached.models; // fresh enough — costs zero SAIA requests
        pacerDebugLog(
          `models: cache hit (age ${((Date.now() - cached.fetchedAt) / 86400000).toFixed(1)}d)`
        );
      } else {
        try {
          const resp = await fetch(`${SAIA_BASE_URL}/models`, {
            headers: { Authorization: `Bearer ${key}` },
          });
          if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
          const json = await resp.json();
          models = json.data;
          pacerDebugLog("models: fetched fresh");
          try {
            mkdirSync(dirname(CACHE_PATH), { recursive: true });
            writeFileSync(CACHE_PATH, JSON.stringify({ fetchedAt: Date.now(), models }));
          } catch {}
        } catch {
          models = cached?.models; // stale cache beats no models
          pacerDebugLog("models: fetch failed, using stale cache");
        }
      }

      if (!models) return;

      if (!config.provider) config.provider = {};
      if (!config.provider["saia-gwdg"]) {
        config.provider["saia-gwdg"] = {
          npm: "@ai-sdk/openai-compatible",
          options: { baseURL: SAIA_BASE_URL },
        };
      }

      // The provider is normally declared in opencode.jsonc, so the branch
      // above does not run and its baseURL stands. A test baseURL has to win
      // anyway, or fault injection quietly spends real SAIA requests.
      if (SAIA_BASE_URL !== SAIA_PROD_BASE_URL) {
        config.provider["saia-gwdg"].options = {
          ...(config.provider["saia-gwdg"].options ?? {}),
          baseURL: SAIA_BASE_URL,
        };
        pacerDebugLog(`baseURL overridden to ${SAIA_BASE_URL} (SAIA_BASE_URL is set)`);
      }

      config.provider["saia-gwdg"].models = {};
      // Reasoning-capable model ids, exposed on the global so the pacer's
      // per-request effort injection knows which models to apply it to.
      const reasoningModels = new Set();
      for (const m of models) {
        if (m.status !== "ready") continue;
        const reasoning = m.output?.includes("thought") || FORCE_REASONING.has(m.id);
        if (reasoning) reasoningModels.add(m.id);
        config.provider["saia-gwdg"].models[m.id] = {
          name: m.name,
          attachment: m.input?.some((t) => ["image", "audio", "video"].includes(t)),
          reasoning,
          // Required for ANY temperature to reach the wire: opencode gates the
          // field on `model.capabilities.temperature`, so without this every
          // agent temperature in opencode.jsonc is silently dropped (verified
          // on-wire, opencode 211.18.23). SAIA models are all OpenAI-compatible
          // completions endpoints, so temperature is always supported.
          temperature: true,
        };
      }
      globalThis.__saiaReasoning = reasoningModels;

      // Resolve each agent's model from ROLE_MODELS against the live list:
      // first preference that is ready wins, otherwise any ready model.
      const ready = new Set(Object.keys(config.provider["saia-gwdg"].models));
      const anyReady = [...ready][0];

      if (config.agent) {
        const providerModels = config.provider["saia-gwdg"].models;
        for (const [role, prefs] of Object.entries(ROLE_MODELS)) {
          const agent = config.agent[role];
          if (!agent) continue;
          let pick = prefs.find((id) => ready.has(id));

          pick = pick ?? anyReady;
          if (pick) agent.model = `saia-gwdg/${pick}`;
        }
      }

      // Budget check for the auto orchestrator. Its read tool can't reach
      // ~/.cache from a project session (external_directory permission is
      // auto-rejected in non-interactive runs), so the check happens here at
      // startup: read the pacer's last snapshot and bake a status line into
      // the auto prompt via the __SAIA_BUDGET_STATUS__ placeholder.
      let status = "UNKNOWN (no recent budget data)";
      const b = freshBudget();
      if (b !== null) {
        status =
          (budgetIsLow(b) ? "LOW" : "HEALTHY") +
          `: ~${b.hour} requests left this hour across ${b.keyCount} key(s), ~${b.day} today, ` +
          `~${b.month} this month (sustainable pace ≈${100 * b.keyCount}/day)`;
      }
      for (const [role, promptFile] of [
        ["auto", "prompts/auto.md"],
        ["solo", "prompts/solo.md"],
      ]) {
        try {
          // This plugin lives in <config>/plugin/; prompts/ is a child of the
          // config root, one level up — hence the "..".
          const dir = dirname(fileURLToPath(import.meta.url));
          const txt = readFileSync(join(dir, "..", promptFile), "utf-8");
          if (config.agent?.[role] && txt.includes("__SAIA_BUDGET_STATUS__")) {
            config.agent[role].prompt = txt.replaceAll("__SAIA_BUDGET_STATUS__", status);
            pacerDebugLog(`budget-status injected into ${role} prompt: ${status}`);
          } else {
            pacerDebugLog(
              `budget-status NOT injected into ${role} (agent=${!!config.agent?.[role]}, placeholder=${txt.includes("__SAIA_BUDGET_STATUS__")})`
            );
          }
        } catch (e) {
          // An install without --solo (or without --auto) simply has no such
          // file. That is a supported configuration, not a failure, and logging
          // it as one on every config-hook run is pure noise.
          if (e?.code === "ENOENT") continue;
          pacerDebugLog(`budget-status injection failed for ${role}: ${e.message}`);
        }
      }

      // @coder2 is @coder on a different model family; they share ONE prompt.
      // opencode expands {file:...} only inside opencode.json{,c}, never in an
      // agent/*.md body (ConfigAgent.parse does frontmatter + body and no
      // substitution), so agent/coder.md is the single source of truth and the
      // copy happens here instead of duplicating the contract into
      // agent/coder2.md. Deliberately LAST in this hook: opencode swallows a
      // config-hook throw, so anything placed above the budget-status loop
      // could silently disable it.
      if (config.agent?.coder2 && config.agent?.coder?.prompt) {
        config.agent.coder2.prompt = config.agent.coder.prompt;
        pacerDebugLog("coder2 prompt cloned from coder");
      }
    },
  };
};
__OC_FILE_EOF__

write_file "yagni.md" <<'__OC_FILE_EOF__'
# YAGNI first

You Aren't Gonna Need It: build the minimal solution that satisfies the stated
requirements, and nothing more.

- No speculative abstractions, config options, plugin points, or
  "future-proofing" the task did not ask for.
- Prefer the standard library and native platform features over new
  dependencies.
- Prefer editing existing code over adding new files, layers, or indirection.
- When planning, plan the smallest set of steps that meets the requirements;
  cut any step whose absence would not fail the task.
- When a requirement is ambiguous, choose the simpler interpretation and state
  the assumption.
- Explicitly required deliverables (tests, NOTES.md, docs) are in scope;
  everything else must justify its existence.
__OC_FILE_EOF__

write_file "command/usage.md" <<'__OC_FILE_EOF__'
---
description: Show SAIA request budget and per-model token usage (costs 1 request)
---
Current SAIA usage report, generated locally at command time:

!`bash "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/scripts/usage.sh"`

Repeat the report above to the user verbatim in one fenced code block. No commentary, no analysis, no tool calls.
__OC_FILE_EOF__

write_file "command/reload_models.md" <<'__OC_FILE_EOF__'
---
description: Force-refresh the SAIA model list cache (1 API request; restart opencode afterwards)
---
Run this exact command with the bash tool and report its output verbatim: bash "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/scripts/reload-models.sh". If it succeeded, remind the user to restart opencode so the refreshed model list takes effect. Requires bash permission — run from the solo or build agent, not auto.
__OC_FILE_EOF__

write_file "command/effort.md" <<'__OC_FILE_EOF__'
---
description: Set reasoning effort for thinking models (off|low|medium|high|max; no arg shows current)
---
(local command — handled without a model call)

!`bash "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/scripts/effort.sh" "$ARGUMENTS"`
__OC_FILE_EOF__

write_file "scripts/usage.sh" <<'__OC_FILE_EOF__'
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

exec python3 - <<'PYEOF'
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
    db = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=3)
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
__OC_FILE_EOF__

write_file "scripts/reload-models.sh" <<'__OC_FILE_EOF__'
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

# auth.json key first, then any extra failover keys (same order as the plugin)
KEYS="$(AUTH_FILE="$AUTH_FILE" KEYS_FILE="$KEYS_FILE" python3 -c "
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
BODY="$BODY" CACHE_FILE="$CACHE_FILE" python3 - <<'PYEOF'
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
__OC_FILE_EOF__

write_file "scripts/effort.sh" <<'__OC_FILE_EOF__'
#!/usr/bin/env bash
#
# effort.sh — set the SAIA reasoning effort for thinking models.
#
# Writes ~/.config/opencode/effort.json, which the plugin's pacer re-reads on
# every request, so the change applies to the CURRENT session immediately
# (no restart). Missing file => default "high".
#
# Usage:
#   effort.sh            print the current level
#   effort.sh off        disable thinking (chat_template_kwargs.enable_thinking=false)
#   effort.sh LEVEL      thinking on, reasoning_effort=LEVEL (low|medium|high|max)
#
# Invoked via !`...` injection from command/effort.md: only stdout reaches the
# prompt there, so errors go to stdout and every path exits 0.
set -uo pipefail

EFFORT_FILE="$HOME/.config/opencode/effort.json"
DEFAULT="high"
LEVELS=(off low medium high max)

mkdir -p "$(dirname "$EFFORT_FILE")"

current() {
  local level=""
  if [[ -f "$EFFORT_FILE" ]]; then
    level=$(sed -n 's/.*"level": *"\([^"]*\)".*/\1/p' "$EFFORT_FILE" 2>/dev/null | head -1)
  fi
  case " ${LEVELS[*]} " in
    *" $level "*) echo "$level" ;;
    *) echo "$DEFAULT" ;;
  esac
}

ladder() {
  local cur out=""
  cur=$(current)
  for l in "${LEVELS[@]}"; do
    if [[ "$l" == "$cur" ]]; then out+="[$l]  "; else out+="$l  "; fi
  done
  echo "Reasoning effort: ${out% } (default: $DEFAULT)"
}

ARG="${1:-}"

if [[ -z "$ARG" || "$ARG" == "?" || "$ARG" == "show" ]]; then
  ladder
  echo "Set with: /effort off|low|medium|high|max"
  exit 0
fi

case " ${LEVELS[*]} " in
  *" $ARG "*) ;;
  *)
    echo "Invalid effort '$ARG' — use off|low|medium|high|max (or no arg to show current)."
    ladder
    exit 0
    ;;
esac

# Atomic write so the pacer never sees a partial file.
TMP="$EFFORT_FILE.tmp"
printf '{"level": "%s", "updatedAt": "%s"}\n' "$ARG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$TMP"
mv "$TMP" "$EFFORT_FILE"

echo "Reasoning effort set to '$ARG' for thinking models."
echo "Applies to the current session immediately (the pacer re-reads the setting per request)."
__OC_FILE_EOF__

write_file "agent/coder2.md" <<'__OC_FILE_EOF__'
---
description: Fix-round implementer on a different model family (breaks correlated errors)
mode: subagent
model: saia-gwdg/glm-4.7
temperature: 0.2
steps: 35
permission:
  edit: allow
  bash: allow
  write: allow
tools:
  skill: false
---

# Coder 2 (fix-round implementer)

Same contract as @coder: implement the audited PLAN exactly, match the
surrounding code's style, self-check by actually running the fastest relevant
command, and end every response with the CHANGES block. You exist so that a
fix round runs on a different model family than the first implementation
attempt, which breaks correlated errors.

The SAIA plugin replaces this body with @coder's full prompt at startup —
opencode expands no `{file:...}` reference inside an agent/*.md body, so
agent/coder.md stays the single source of truth for the shared contract.
__OC_FILE_EOF__

write_file "agent/coder.md" <<'__OC_FILE_EOF__'
---
description: "Implementation agent: executes an audited PLAN, returns CHANGES block"
mode: subagent
model: saia-gwdg/qwen3-coder-next
temperature: 0.2
steps: 35
permission:
  edit: allow
  bash: allow
  write: allow
tools:
  skill: false
---

# Coder (implementation agent)

You implement an audited PLAN handed to you by an orchestrator.

## Rules

- Every response step costs one rate-limited API request — batch independent
  tool calls (multiple reads, several edits, chained bash commands) into a
  single step instead of one call per step.
- Implement exactly what the PLAN specifies. Deviations must be declared in
  your CHANGES block, never made silently.
- Match the surrounding code's style, naming, and idiom.
- Before returning, self-check by actually running the fastest relevant
  command (build, syntax check, targeted test). Report what you ran and the
  result.
- Never claim STATUS: COMPLETE if anything failed or was left undone. If you
  cannot complete the task, return STATUS: BLOCKED with the exact error. A
  false COMPLETE will be caught by the debugger and costs everyone a round.

## Required output

End every response with exactly this block:

```
## CHANGES
STATUS: COMPLETE | PARTIAL | BLOCKED
FILES TOUCHED:
- <path> — <summary of change>
SELF-CHECK: <commands actually run + one-line result each; "none run" if none>
DEVIATIONS FROM PLAN: <or "none">
NOTES FOR VALIDATION: <hints for the debugger>
```
__OC_FILE_EOF__

write_file "agent/debugger.md" <<'__OC_FILE_EOF__'
---
description: "Validator: runs acceptance criteria, returns VERDICT PASS/FAIL with quoted output"
mode: subagent
model: saia-gwdg/qwen3-coder-next
temperature: 0.1
steps: 15
permission:
  edit: allow
  bash: allow
  write: allow
tools:
  skill: false
  todowrite: false
  webfetch: false
---

# Validator

You validate implementations against acceptance criteria for an orchestrator.

Reading code is NOT validation. You MUST execute every acceptance criterion's
command and quote its real output.

## Rules

- Every response step costs one rate-limited API request. Run ALL acceptance
  criteria as a single chained bash invocation in ONE step whenever possible
  (`cmd1; echo ---; cmd2; echo ---; cmd3`), then quote each command's section
  from that one run. Only split commands when one criterion depends on the
  outcome of another. Target: the entire validation in ≤5 steps.
- Run each acceptance criterion exactly as given; quote the actual output
  (trim long output to the relevant lines — never fabricate or paraphrase it).
- If a command cannot run (missing dependency, syntax error, crash), that
  criterion is FAIL and the error output is the evidence.
- PASS requires ALL criteria to pass. Never output PASS without quoted command
  output for every criterion.
- Do not fix code yourself unless explicitly asked; your job is verdicts, not
  repairs.
- For each failure, point to the suspected cause (file:line) and suggest a fix
  direction — the coder will act on your FAILURES section verbatim.

## Required output

End every validation response with exactly this block:

```
## VERDICT: PASS | FAIL
CRITERIA RESULTS:
1. <criterion> — PASS/FAIL — command run: `<cmd>`
   output: <verbatim, trimmed>
FAILURES: (only if FAIL)
- <criterion #>: symptom, suspected cause (file:line), suggested fix
```
__OC_FILE_EOF__

write_file "agent/researcher.md" <<'__OC_FILE_EOF__'
---
description: "Read-only analyst: produces PLAN blocks with runnable acceptance criteria"
mode: subagent
model: saia-gwdg/qwen3.5-122b-a10b
temperature: 0.2
steps: 15
permission:
  edit: deny
  bash: deny
  write: deny
tools:
  skill: false
  webfetch: false
---

# Researcher (read-only analyst)

You analyze codebases and requirements for an orchestrator. You have no
edit/bash/write access — your output is findings and plans, nothing else.

## Rules

- Every response step costs one rate-limited API request — batch independent
  tool calls (multiple reads/globs/greps) into a single step instead of one
  call per step.
- Cite exact file paths and line numbers for every claim about the code.
- Do not speculate: verify claims by actually reading the files. If you could
  not verify something, say so explicitly.
- Prefer reusing existing functions, utilities, and patterns you find over
  proposing new code — name them with their paths.
- Every ACCEPTANCE CRITERION must be a command the debugger can execute
  (build, test, script, curl, grep on output) with an expected observable
  result. "Code is clean" or "works correctly" is not a criterion.
- STEPS must be concrete enough that an implementer needs no further research.

## Required output

End every planning response with exactly this block:

```
## PLAN
GOAL: <one sentence>
CONSTRAINTS: <hard requirements, things that must not break>
FILES TO CHANGE:
- <path> — <what changes and why> (mark NEW if to be created)
STEPS:
1. <ordered, concrete implementation steps>
ACCEPTANCE CRITERIA:
1. <a runnable command> → <expected observable output/exit code>
RISKS: <what could go wrong, edge cases>
```
__OC_FILE_EOF__

write_file "prompts/auto.md" <<'__OC_FILE_EOF__'
# Orchestrator

You coordinate four subagents — @researcher, @coder, @coder2 (fix rounds
only), @debugger — via the task tool.

CRITICAL: delegation happens ONLY through an actual `task` tool call. Writing
"@coder" or "Now tasking the researcher" in your response text invokes NOTHING —
if you end a response announcing a delegation without having made the task tool
call, the work silently never happens. Never end a turn between phases: after
your PLAN is audited, the SAME response must contain the task tool call to
@coder, and so on through the workflow until Phase 5 is reported.
## BUDGET GATE — evaluate BEFORE your first tool call

Session-start budget status: `__SAIA_BUDGET_STATUS__`

## READ-ONLY BASH — use only for inspection

You may use bash **only** for read-only inspection: `ls *`, `git status/diff/log/show/grep *`, `rg *`, `cat *`, `wc *`, `find *`, `pwd`, `echo *`, `head *`, `tail *`.

**Never** mutate files, run installers, or touch paths outside the project (external_directory is blocked). Never use `>`, `>>`, `;`, `&&`, or any mutating command (git add/commit/push/reset, rm/mv/cp/mkdir/touch, npm/pip/cargo, etc.).

If a bash command fails because it's not allowlisted, delegate to the appropriate subagent instead of attempting it.

## WORKING MEMORY — maintain this STATE block each turn

After each subagent response, update and display a STATE block showing:

```
## STATE
DONE: <completed items with brief results>
DOING: <current task>
TODO: <remaining items from plan>
BLOCKERS: <issues blocking progress, or "none">
```

This gives mid-flight visibility without extra requests. Keep it concise.

## REQUEST ECONOMY (every step is one rate-limited API request)

If that status starts with LOW: your ENTIRE response is to report those numbers
to the user and stop — no tool calls, no subagents. A full chain needs ~20-40
requests; starting one on a LOW budget dies mid-chain and loses all work. If it
starts with HEALTHY or UNKNOWN — or still shows the literal placeholder —
proceed normally. The status covers the hour, day, and month buckets; when it
is HEALTHY but the day/month numbers look tight relative to the sustainable
pace (≈100/day), prefer the fast path and mention the budget situation in your
final report. Never try to read budget/cache files yourself: paths outside
the project are permission-blocked and the attempt kills the run.

You never edit files or run commands yourself; those tools are denied. Your
read/glob/grep access exists ONLY to scope tasks and audit subagent claims
(e.g., confirming a file the coder says it changed actually contains the change),
never to do analysis or implementation yourself.

If you feel the temptation to "just quickly check something in depth" or "make a
small edit" — STOP and delegate to the appropriate subagent.

## REQUEST ECONOMY (every step is one rate-limited API request)

The API budget is 200 requests/hour shared across you and all subagents. Each
of your steps — and each subagent step — costs one request. Therefore:

- Batch ALL independent glob/read/grep calls into a single step; never make
  one tool call per step when several are independent.
- Complete intake in ≤2 steps and each plan audit in ≤2 steps.
- Always use paths RELATIVE to the project root in tool calls. Never retype an
  absolute path — one typo lands outside the project, the permission system
  auto-rejects it, and the run dies.

- Parallel delegation: if multiple sub-tasks are independent (no shared files, no ordering dependency), task multiple subagents in a single step. This saves requests.

## SUBAGENT FAILURE RULE (non-negotiable)

If a subagent errors out or returns without its required block (PLAN /
CHANGES / VERDICT), re-task that SAME agent exactly ONCE, stating what was
missing or what error occurred. If it fails again, STOP and report failure
to the user. NEVER substitute a different agent type as a stand-in: @general
and @explore are denied to you and must never be used for one of your roles.
The `task` tool's own list of agent types is authoritative — if an agent is
not in that list, it does not exist for you. @coder2 is reserved for Phase 4
fix rounds.

EXCEPTION — transport errors. If the failure message contains "operation timed
out", "stream stalled", "not resumable in-stream", "Internal Server Error" or
"terminated", the model endpoint dropped the connection. That is not a subagent
failure: re-task the same agent with the same instructions immediately, and do
NOT count it against the single retry above. Tell the subagent nothing about
the error — it never saw it.

## WORKFLOW (mandatory order — never skip a phase)

### Phase 0 — Intake
Restate the user's task in one sentence. Use glob/grep/read minimally to scope
it (which project, which area of the code). Do not analyze deeply — that is the
researcher's job. Initialize the STATE block with empty DONE/DOING/TODO/BLOCKERS.

**Budget gate** — apply the BUDGET GATE at the top of this prompt before
anything else in this phase.

### Phase 1 — Plan (before ANY coding)
FAST PATH: if the task touches at most ONE file AND the change is fully
specified by the user's request (no analysis needed to know what to write),
author the PLAN block yourself instead of tasking @researcher. This is the
only exception to the no-analysis rule, and the audit rules below still apply
to your own plan. When in doubt, use @researcher.

Otherwise, task @researcher to analyze the request and produce a PLAN block
(template below). Then AUDIT the plan yourself:

- Every file listed under FILES TO CHANGE must exist (verify with glob/read)
  unless it is marked NEW.
- Every ACCEPTANCE CRITERION must be a concrete runnable command with an
  expected, observable result. "Code looks clean" is not a criterion.
- The STEPS must be concrete enough that the coder needs no further research.

Course-correction: if a subagent reports a blocker or partial failure, auto may
adjust the plan mid-flight (e.g., tell @coder "skip step 3, do step 4 first")
without aborting. Keep the single fix round and honest-failure protocol intact.

If the plan fails the audit, re-task @researcher ONCE with the specific gaps.
Never send work to @coder without an audited PLAN.

### Phase 2 — Implement
Task @coder with the FULL PLAN block pasted verbatim, plus any user constraints.
Require a CHANGES block back (template below). If STATUS is BLOCKED, do not
proceed — go to Phase 5 and report.

Parallel delegation: if the plan has multiple independent sub-tasks (no shared
files, no ordering dependency), you may task multiple subagents in a single step
to save requests. Only task @coder for implementation; other subagents are used
for their specialized outputs (PLAN, VERDICT).

### Phase 3 — Validate
Task @debugger with the PLAN's acceptance criteria plus the coder's CHANGES
block. Require a VERDICT block back (template below). The debugger must have
RUN every criterion and quoted real output.

### Phase 4 — Fix loop (max 1 round)
If VERDICT is FAIL, you get exactly ONE fix round (API budget is tight):
1. State it explicitly ("Fix round 1 of 1").
2. Task @coder2 (NOT @coder — a different model family avoids repeating the
   same mistake) with: the debugger's FAILURES section quoted verbatim
   ("Fix exactly these failures: ..."), the original PLAN block, and the
   first coder's CHANGES block.
3. Re-task @debugger to re-run ALL acceptance criteria (not just the failed ones).
4. If VERDICT is still FAIL, stop and report failure — never start a second round.

### Phase 5 — Report
Summarize for the user: what was planned, what was changed, and the validation
evidence. Include the final STATE block showing the completed work. Follow the
completion protocol below.

## COMPLETION PROTOCOL (non-negotiable)

You may declare success ONLY IF the most recent @debugger response contains
`VERDICT: PASS` with quoted real command output for EVERY acceptance criterion.

- "The code looks correct" is not evidence.
- A coder self-check is not evidence.
- A paraphrased result is not evidence.

If the loop ends without PASS, you MUST report failure: state what was
attempted, quote the remaining FAILURES verbatim from the debugger, and list
which acceptance criteria are unmet. Never soften, summarize away, or omit a
failure. An honest failure report is a successful outcome; a false success
claim is the worst possible outcome.

## SUBAGENT OUTPUT TEMPLATES (demand these; reject responses missing them)

From @researcher:

```
## PLAN
GOAL: <one sentence>
CONSTRAINTS: <hard requirements, things that must not break>
FILES TO CHANGE:
- <path> — <what changes and why> (mark NEW if to be created)
STEPS:
1. <ordered, concrete implementation steps>
ACCEPTANCE CRITERIA:
1. <a runnable command> → <expected observable output/exit code>
RISKS: <what could go wrong, edge cases>
```

From @coder:

```
## CHANGES
STATUS: COMPLETE | PARTIAL | BLOCKED
FILES TOUCHED:
- <path> — <summary of change>
SELF-CHECK: <commands actually run + one-line result each; "none run" if none>
DEVIATIONS FROM PLAN: <or "none">
NOTES FOR VALIDATION: <hints for the debugger>
```

From @debugger:

```
## VERDICT: PASS | FAIL
CRITERIA RESULTS:
1. <criterion> — PASS/FAIL — command run: `<cmd>`
   output: <verbatim, trimmed>
FAILURES: (only if FAIL)
- <criterion #>: symptom, suspected cause (file:line), suggested fix
```
__OC_FILE_EOF__

write_file "prompts/solo.md" <<'__OC_FILE_EOF__'
# Solo (builder + independent checker)

You are the default workhorse: one strong agent that plans, implements, and
self-checks a task in a single session with full context, then hands the
result to the independent @debugger for validation. You have full tool access.

## BUDGET GATE — evaluate BEFORE your first tool call

Session-start budget status: `__SAIA_BUDGET_STATUS__`

If that status starts with LOW: your ENTIRE response is to report those numbers
to the user and stop — no tool calls. A solo run needs ~5-12 requests; starting
one on a LOW budget risks dying mid-task. If it starts with HEALTHY or UNKNOWN
— or still shows the literal placeholder — proceed normally. Never try to read
budget/cache files yourself: paths outside the project are permission-blocked
and the attempt kills the run.

## REQUEST ECONOMY (every step is one rate-limited API request)

Batch independent tool calls (multiple reads/globs, several edits, chained
bash commands) into a single step instead of one call per step. Keep the whole
task within ~10 of your own steps. Always use paths RELATIVE to the project
root in tool calls — never retype an absolute path; one typo lands outside the
project, the permission system auto-rejects it, and the run dies.

## WORKFLOW

1. **Restate** the user's task in one sentence.
2. **Plan inline** (before any edit): a short plan naming the files to change
   and 1-3 ACCEPTANCE CRITERIA — each a runnable command with an expected,
   observable result. "Code looks clean" is not a criterion.
3. **Implement**, matching the surrounding code's style, naming, and idiom.
4. **Self-check**: actually run the acceptance commands. Fix what fails.
5. **Independent validation (MANDATORY)**: task @debugger with your acceptance
   criteria plus a short CHANGES summary (files touched, what changed). Require
   a VERDICT block back with quoted real output for every criterion.
6. **On FAIL**: exactly ONE fix round — fix the quoted failures, re-task
   @debugger to re-run ALL criteria. If still FAIL, stop and report failure.

If a @debugger call errors out with "operation timed out", "stream stalled",
"not resumable in-stream", "Internal Server Error" or "terminated", the model
endpoint dropped the connection. That is not a validation failure and not a fix
round: re-task @debugger with the same criteria immediately.

## COMPLETION PROTOCOL (non-negotiable)

You may declare success ONLY IF the most recent @debugger response contains
`VERDICT: PASS` with quoted real command output for EVERY acceptance criterion.
Your own self-check is not sufficient evidence.

- If the validation task call is refused by the budget gate, report the work
  as completed-but-UNVALIDATED and say why — never claim PASS.
- If validation ends without PASS, report failure: quote the remaining
  FAILURES verbatim and list the unmet criteria. An honest failure report is a
  successful outcome; a false success claim is the worst possible outcome.

Delegation happens ONLY through an actual `task` tool call — writing
"@debugger" in your response text invokes nothing.

## Expected from @debugger

```
## VERDICT: PASS | FAIL
CRITERIA RESULTS:
1. <criterion> — PASS/FAIL — command run: `<cmd>`
   output: <verbatim, trimmed>
FAILURES: (only if FAIL)
- <criterion #>: symptom, suspected cause (file:line), suggested fix
```
__OC_FILE_EOF__

setup_auth_key() {
  mkdir -p "$DATA_DIR"
  if [[ -f "$AUTH_FILE" ]] && grep -q '"saia-gwdg"' "$AUTH_FILE" && [[ $FORCE_KEY -eq 0 ]]; then
    log "Existing saia-gwdg API key kept (use --force-key to replace)."
    return 0
  fi
  local key="${GWDG_API_KEY:-}"
  if [[ -z "$key" ]]; then
    if [[ -t 0 ]]; then
      read -r -s -p "Enter your GWDG/SAIA API key (Academic Cloud portal): " key
      echo
    else
      die "No GWDG_API_KEY set and no terminal to prompt — export GWDG_API_KEY and rerun."
    fi
  fi
  if [[ -z "$key" ]]; then die "No API key provided."; fi
  if [[ -f "$AUTH_FILE" ]]; then
    backup_existing "auth.json" "$AUTH_FILE"
  fi
  if command -v python3 >/dev/null 2>&1; then
    # merge into any existing auth.json (it may hold other providers' keys)
    ( umask 077; KEY="$key" AUTH_FILE="$AUTH_FILE" python3 - <<'PYEOF'
import json, os
path = os.environ["AUTH_FILE"]
try:
    with open(path) as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
data["saia-gwdg"] = {"type": "api", "key": os.environ["KEY"]}
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
PYEOF
    )
  else
    if [[ -f "$AUTH_FILE" ]]; then
      die "python3 not found and $AUTH_FILE already exists — add this entry manually: {\"saia-gwdg\": {\"type\": \"api\", \"key\": \"...\"}}"
    fi
    if [[ "$key" == *[\"\\]* ]]; then
      die "API key contains a quote or backslash — write $AUTH_FILE manually."
    fi
    ( umask 077; printf '{\n  "saia-gwdg": {\n    "type": "api",\n    "key": "%s"\n  }\n}\n' "$key" >"$AUTH_FILE" )
  fi
  chmod 600 "$AUTH_FILE"
  log "API key written to $AUTH_FILE (chmod 600)."
}

setup_extra_keys() {
  local extra="${GWDG_API_KEYS_EXTRA:-}" keys_file="$DATA_DIR/saia-gwdg-keys.json"
  if [[ -z "$extra" ]]; then
    if [[ -f "$keys_file" ]]; then
      log "Existing extra-keys file kept: $keys_file (set GWDG_API_KEYS_EXTRA to replace)."
    fi
    return 0
  fi
  command -v python3 >/dev/null 2>&1 \
    || die "python3 required to write $keys_file — create it manually: {\"keys\": [\"key2\", ...]}"
  if [[ -f "$keys_file" ]]; then
    backup_existing "saia-gwdg-keys.json" "$keys_file"
  fi
  ( umask 077; EXTRA="$extra" KEYS_FILE="$keys_file" python3 - <<'PYEOF'
import json, os
keys = [k.strip() for k in os.environ["EXTRA"].split(",") if k.strip()]
path = os.environ["KEYS_FILE"]
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump({"keys": keys}, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
print(f"{len(keys)} extra failover key(s) written to {path}")
PYEOF
  )
  chmod 600 "$keys_file"
}

# (fix_plugin_path removed — the plugin is auto-discovered from plugin/, so
#  there is no "plugin" array entry to rewrite to an absolute path.)

# Fix instructions path to absolute (resolves ./yagni.md → CONFIG_DIR/yagni.md)
fix_instructions_path() {
  local input="$CONFIG_DIR/opencode.jsonc"
  
  if [[ ! -f "$input" ]]; then
    return 0
  fi
  
  if ! command -v python3 >/dev/null 2>&1; then
    log "  python3 not found - cannot fix instructions path, skipping"
    return 0
  fi
  
  ( umask 077; python3 - "$input" "$CONFIG_DIR" <<'PYEOF'
import json, os, sys
input_path = sys.argv[1]
config_dir = sys.argv[2]

with open(input_path) as fh:
    data = json.load(fh)

instructions = data.get("instructions", [])
changed = False
for i, path in enumerate(instructions):
    if path == "./yagni.md":
        instructions[i] = os.path.join(config_dir, "yagni.md")
        changed = True

if changed:
    data["instructions"] = instructions
    tmp = input_path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, input_path)
    print("  fixed instructions path: " + instructions[i])

PYEOF
  )
}

# Filter opencode.jsonc based on agent selection
filter_opencode_jsonc() {
  local input="$CONFIG_DIR/opencode.jsonc"
  
  if [[ ! -f "$input" ]]; then
    return 0
  fi
  
  if ! command -v python3 >/dev/null 2>&1; then
    log "  python3 not found - cannot filter opencode.jsonc, skipping agent filtering"
    return 0
  fi
  
  ( umask 077; python3 - "$input" "$INSTALL_SOLO" "$INSTALL_AUTO" <<'PYEOF'
import json, re, sys
input_path = sys.argv[1]
install_solo = int(sys.argv[2])
install_auto = int(sys.argv[3])

# Strip JSONC comments (// line comments) before parsing
with open(input_path) as fh:
    lines = fh.readlines()

# Only strip // comments that appear at the start of a line (after optional whitespace)
# URLs in JSON strings like https:// are not stripped because // is not at line start
cleaned = []
for line in lines:
    stripped = re.sub(r'^(\s*)//.*$', r'\1', line)
    cleaned.append(stripped)
content = '\n'.join(cleaned)

data = json.loads(content)

agent = data.get("agent", {})

# Only the two optional PRIMARIES live in opencode.jsonc and may be filtered.
# The SAIA subagents (coder, coder2, researcher, debugger) ship as agent/*.md,
# are auto-discovered, and are deliberately not represented here — so declining
# both primaries still leaves a full set of working subagents for the built-in
# build/plan agents (opencode's native ruleset allows `task` by default).
# NOTE: never add "general"/"explore" to any deletion list either — they are
# opencode's native subagents and their stubs exist only for model pinning.
if install_solo == 0 and "solo" in agent:
    del agent["solo"]
if install_auto == 0 and "auto" in agent:
    del agent["auto"]

# Clean up empty agent dict
if not agent:
    del data["agent"]
else:
    data["agent"] = agent

# Write filtered config
with open(input_path + ".tmp", "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
import os
os.replace(input_path + ".tmp", input_path)

PYEOF
  )
  chmod 644 "$input"
  log "  filtered: $input (solo=$INSTALL_SOLO, auto=$INSTALL_AUTO)"
}

# Clean up prompt files that are disabled
cleanup_disabled_prompts() {
  # Only the two PRIMARY prompts are optional, and they are independent of each
  # other. Nothing else may be removed: each subagent's prompt is the body of
  # its own agent/*.md and always installs. The old cross-conditions here were
  # the install-time coupling — including the bug where "--auto --no-solo" left
  # auto's mandatory @debugger validator undefined.
  if [[ $INSTALL_SOLO -eq 0 ]]; then
    rm -f "$CONFIG_DIR/prompts/solo.md"
    log "  removed (disabled): prompts/solo.md"
  fi

  if [[ $INSTALL_AUTO -eq 0 ]]; then
    rm -f "$CONFIG_DIR/prompts/auto.md"
    log "  removed (disabled): prompts/auto.md"
  fi

  # Orphans from installs that predate agent/*.md: these three are now the
  # bodies of agent/{coder,researcher,debugger}.md and nothing reads them.
  for stale in coder researcher debugger; do
    if [[ -f "$CONFIG_DIR/prompts/$stale.md" ]]; then
      rm -f "$CONFIG_DIR/prompts/$stale.md"
      log "  removed (superseded by agent/$stale.md): prompts/$stale.md"
    fi
  done
}

verify() {
  if [[ $OPENCODE_MISSING -eq 1 ]]; then
    log ""
    log "opencode is not installed — skipping verification."
    log "After installing opencode, verify with: opencode models | grep '^saia-gwdg/'"
    return 0
  fi
  log ""
  log "Verifying (fetches the GWDG model list — 1 request of the shared rate budget)..."
  local out count
  if out="$(opencode models 2>&1)" && grep -q '^saia-gwdg/' <<<"$out"; then
    count="$(grep -c '^saia-gwdg/' <<<"$out")"
    log "SUCCESS: $count saia-gwdg models available."
    if [[ -n "$BACKUP_DIR" ]]; then
      log "Previous files were backed up to $BACKUP_DIR"
    fi
    log ""
    if [[ $INSTALL_SOLO -eq 1 ]] && [[ $INSTALL_AUTO -eq 1 ]]; then
      log "Next steps: run 'opencode', press Tab until the 'solo' agent (default"
      log "workhorse) or 'auto' (orchestrator for big tasks) is selected, and give"
      log "it a task."
    elif [[ $INSTALL_SOLO -eq 1 ]]; then
      log "Next steps: run 'opencode', select the 'solo' agent (default workhorse),"
      log "and give it a task. It delegates validation to @debugger."
    elif [[ $INSTALL_AUTO -eq 1 ]]; then
      log "Next steps: run 'opencode', select the 'auto' agent (orchestrator for"
      log "big tasks), and give it a task."
    else
      log "Next steps: run 'opencode' with the built-in agents (build, plan)."
      log "Install solo/auto later for their orchestration workflows."
    fi
    log "Subagents @coder, @coder2, @researcher and @debugger are always"
    log "installed (agent/*.md) and taskable from any primary."
    log "Force-refresh the weekly model cache with /reload_models."
  else
    {
      echo "FAILED: no saia-gwdg models listed."
      echo "Troubleshooting:"
      echo "  - Invalid or expired API key (the plugin fails silently)."
      echo "  - GWDG rate limit exhausted (30 req/min, 200/hour per key) — wait and retry."
      echo "  - Stale cache: rm ~/.cache/opencode/saia-gwdg-models.json and retry."
    } >&2
    exit 1
  fi
}

chmod 755 "$CONFIG_DIR/scripts/reload-models.sh" "$CONFIG_DIR/scripts/usage.sh" "$CONFIG_DIR/scripts/effort.sh"
setup_auth_key
setup_extra_keys
filter_opencode_jsonc
fix_instructions_path
cleanup_disabled_prompts
verify

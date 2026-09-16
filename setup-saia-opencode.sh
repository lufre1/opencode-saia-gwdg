#!/usr/bin/env bash
#
# setup-saia-opencode.sh — GENERATED FILE, DO NOT EDIT.
# Regenerate with: ./build-setup.sh  (in the opencode config repo)
# Source: opencode-config commit 668b92e-dirty, packed 2026-09-16T07:41:19Z
#
# Installs the GWDG SAIA setup for opencode: provider + plugin, and optional
# agents (solo, auto, coder, coder2, researcher, debugger) with their prompts.
# Use flags or interactive prompts to choose which agents to install.
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
  - opencode.jsonc, plugin/, command/, scripts/, prompts/*.md into ~/.config/opencode
  - API key into ~/.local/share/opencode/auth.json (chmod 600)
  - optional extra failover keys (GWDG_API_KEYS_EXTRA, comma-separated) into
    ~/.local/share/opencode/saia-gwdg-keys.json (chmod 600) — the plugin
    switches to the next key when the active one's rate budget is exhausted
  - offers to install opencode itself if missing
  - optional agents: solo (default workhorse), auto (orchestrator)
    (default: prompt interactively unless --yes is passed)

Options:
  -y, --yes        answer yes to prompts (e.g. installing opencode)
       --solo      install the solo agent (default: ask)
       --auto      install the auto agent (default: ask)
       --no-solo   skip the solo agent (default: ask)
       --no-auto   skip the auto agent (default: ask)
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
        // SAIA replicas sometimes open a stream and then stop sending. No
        // chunk for 60s means the replica is dead — abort so opencode can
        // retry instead of hanging forever. Deliberately no `timeout` /
        // `headerTimeout`: opencode measures those around the plugin's patched
        // fetch, so they would include the pacer's own queue and cooldown
        // waits and fire spuriously. The headers case is handled in the plugin
        // (SAIA_TIMEOUT_MS), where only real network time is measured.
        "chunkTimeout": 60000
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
    // Native opencode subagents. Declared as stubs so they survive every install
    // path (the filter only deletes named custom agents) AND so the plugin's
    // ROLE_MODELS can pin them a model — otherwise no subagent survives when both
    // custom primaries (solo/auto) are declined.
    "general": {},
    "explore": {},
    "solo": {
      "description": "Default workhorse: plans, implements, self-checks in one session, then independent @debugger validation (~5-12 requests/task)",
      "mode": "primary",
      "model": "saia-gwdg/qwen3-coder-next",
      "temperature": 0.2,
      "steps": 25,
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
      "steps": 10,
      "prompt": "{file:./prompts/auto.md}",
      "permission": {
        "read": "allow",
        "glob": "allow",
        "grep": "allow",
        "list": "allow",
        "edit": "deny",
        "bash": "deny",
        "write": "deny",
        "task": {
          // "*" MUST come first: opencode resolves these last-match-wins, so a
          // trailing "*" would deny every subagent and remove the task tool.
          "*": "deny",
          "researcher": "allow",
          "coder": "allow",
          "coder2": "allow",
          "debugger": "allow"
        }
      },
      "tools": {
        "skill": false,
        "todowrite": false,
        "webfetch": false
      }
    },
    "coder": {
      "description": "Implementation agent: executes an audited PLAN, returns CHANGES block",
      "mode": "subagent",
      "model": "saia-gwdg/qwen3-coder-next",
      "temperature": 0.2,
      "steps": 20,
      "prompt": "{file:./prompts/coder.md}",
      "permission": {
        "edit": "allow",
        "bash": "allow",
        "write": "allow"
      },
      "tools": {
        "skill": false
      }
    },
    "coder2": {
      "description": "Fix-round implementer on a different model family (breaks correlated errors)",
      "mode": "subagent",
      "model": "saia-gwdg/glm-4.7",
      "temperature": 0.2,
      "steps": 20,
      "prompt": "{file:./prompts/coder.md}",
      "permission": {
        "edit": "allow",
        "bash": "allow",
        "write": "allow"
      },
      "tools": {
        "skill": false
      }
    },
    "researcher": {
      "description": "Read-only analyst: produces PLAN blocks with runnable acceptance criteria",
      "mode": "subagent",
      "model": "saia-gwdg/qwen3.5-122b-a10b",
      "temperature": 0.2,
      "steps": 8,
      "prompt": "{file:./prompts/researcher.md}",
      "permission": {
        "edit": "deny",
        "bash": "deny",
        "write": "deny"
      },
      "tools": {
        "skill": false,
        "webfetch": false
      }
    },
    "debugger": {
      "description": "Validator: runs acceptance criteria, returns VERDICT PASS/FAIL with quoted output",
      "mode": "subagent",
      "model": "saia-gwdg/qwen3-coder-next",
      "temperature": 0.1,
      "steps": 8,
      "prompt": "{file:./prompts/debugger.md}",
      "permission": {
        "edit": "allow",
        "bash": "allow",
        "write": "allow"
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
// - on 401/403 the key is revoked/expired: drop it from rotation for the
//   session and retry on the next key, instead of wedging every request
//   behind a dead key while healthy ones sit unused
// - aborts after 3 consecutive 5xx responses: SAIA outages return 500s that
//   still consume the request budget; instead of hard-sticking, we now sleep
//   30s and retry so transient blips don't require a process restart.
// Patching global fetch (not provider options.fetch) because opencode may
// not pass function-valued config through to the SDK.
// ---------------------------------------------------------------------------
const SAIA_HOST = "chat-ai.academiccloud.de";
const MIN_INTERVAL_MS = 2100;
const HOUR_FLOOR = 5;
const DAY_FLOOR = 10;
const MONTH_FLOOR = 30;
const MAX_CONSECUTIVE_5XX = 3;
// Hard cap on a single network call. SAIA replicas can accept the connection
// and then send nothing at all, which used to freeze opencode forever (there
// is no default timeout in @ai-sdk/openai-compatible). Applied around the
// realFetch call only, so the pacer's own queue/cooldown waits don't count
// toward it. SAIA_TIMEOUT_MS is the calibration knob.
// Floor 5s: a sub-second value can only be a leftover test export, and it
// kills every request. Edit the constant directly for fault-injection tests.
const TIMEOUT_MS = Math.max(Number(process.env.SAIA_TIMEOUT_MS) || 60_000, 5_000);
// Connection attempts per request (1 = no reconnect). Only connection-level
// failures are retried here; 5xx and 429 are opencode's job.
const MAX_CONNECT_TRIES = 2;
const PACER_LOG = join(homedir(), ".cache/opencode/saia-gwdg-pacer.log");
const BUDGET_PATH = join(homedir(), ".cache/opencode/saia-gwdg-budget.json");
const KEYS_PATH = join(homedir(), ".local/share/opencode/saia-gwdg-keys.json");
// Reasoning-effort state, written by /effort (scripts/effort.sh). The pacer
// re-reads it per request so a change applies to the CURRENT session without a
// restart. Missing file => default effort (high).
const EFFORT_PATH = join(homedir(), ".config/opencode/effort.json");
const DEFAULT_EFFORT = "high";
// How long an exhausted bucket keeps a key out of rotation before it is
// optimistically retried (the true state is learned from the next headers).
const RESET_TTL_MS = { hour: 60 * 60000, day: 24 * 3600000, month: 30 * 86400000 };

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

function installPacer(keys) {
  // The wrapper closure reads this global, so a config-hook re-run can
  // refresh the key list without re-wrapping fetch.
  globalThis.__saiaKeys = keys;
  if (globalThis.__saiaPacerInstalled) return;
  globalThis.__saiaPacerInstalled = true;

  const realFetch = globalThis.fetch.bind(globalThis);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  let queue = Promise.resolve(); // serializes SAIA requests
  let lastStart = 0;
  let consecutive5xx = 0; // global: an outage is key-independent
  let activeIndex = 0;

  const FLOORS = { hour: HOUR_FLOOR, day: DAY_FLOOR, month: MONTH_FLOOR };

  // Per-key pacer state, keyed by the key string so a refreshed key list
  // keeps what was already learned.
  const stateByKey = new Map();
  // Keys SAIA rejected with 401/403. Revoked/expired is permanent — no reset
  // TTL can revive it — so a dead key leaves rotation for the whole session.
  const deadKeys = new Set();
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
    if (deadKeys.has(key)) return false;
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
      if (deadKeys.has(k)) return `${label(k)}: rejected (401/403)`;
      const s = stateFor(k);
      const buckets = ["hour", "day", "month"].filter(
        (b) => s.exhausted[b] && Date.now() - s.exhausted[b] < RESET_TTL_MS[b]
      );
      return `${label(k)}: ${buckets.join("+") || "exhausted"}`;
    });
    const allDead = all.every((k) => deadKeys.has(k));
    return new Error(
      allDead
        ? `All ${all.length} SAIA key(s) rejected by SAIA (${per.join("; ")}) — the key(s) are ` +
          `revoked or expired. Get a new one from https://saia.gwdg.de/ ` +
          `and update ${join(homedir(), ".local/share/opencode/auth.json")} (extra keys: ${KEYS_PATH}).`
        : `All ${all.length} SAIA key(s) nearly exhausted (${per.join("; ")}) — ` +
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
    if (url.hostname !== SAIA_HOST) return realFetch(input, init);

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
      let key = pickKey();
      if (key === null) throw allExhaustedError();

      const attempt = async (k) => {
        const wait = lastStart + MIN_INTERVAL_MS - Date.now();
        if (wait > 0) await sleep(wait);
        lastStart = Date.now();
        const reasoningModels = globalThis.__saiaReasoning ?? new Set();
        const effInit = withEffort(input, init, url, reasoningModels);
        // One reconnect on a connection-level failure. opencode retries 5xx and
        // 429 for us, but the AI SDK classifies an abort as user cancellation,
        // so a timed-out or dropped connection gets exactly one shot and
        // surfaces as a hard error. SAIA's defect is a bad *replica*, and a
        // fresh connection is re-load-balanced — so retrying here is what
        // actually recovers. The caller's own abort is never retried.
        for (let tryNo = 1; ; tryNo++) {
          // Timeout wraps only the network call, so queue wait, 2100ms spacing,
          // the 30s cooldown and the 429 sleeps can't trigger a false abort.
          // AbortSignal.any keeps opencode's own cancellation working.
          const timeout = AbortSignal.timeout(TIMEOUT_MS);
          const signal = effInit?.signal ? AbortSignal.any([effInit.signal, timeout]) : timeout;
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
                `after=${Date.now() - startedAt}ms timeout=${TIMEOUT_MS}ms retrying=${retrying} ` +
                `msg=${String(e?.message ?? e).replace(/\s+/g, " ").slice(0, 200)}`
            );
            if (retrying) continue;
            throw e;
          }
          const ttfb = Date.now() - startedAt;
          readBuckets(resp, k);
          consecutive5xx = resp.status >= 500 ? consecutive5xx + 1 : 0;
          const s = stateFor(k);
          // kong id is emitted on every response, not just failures: GWDG needs a
          // healthy baseline to diff a bad request against.
          pacerDebugLog(
            `resp ${resp.status} ${url.pathname} model=${model} ${label(k)} id=${reqId} try=${tryNo} ttfb=${ttfb}ms ` +
              `kong=${resp.headers.get("x-kong-request-id")} upstream=${resp.headers.get("x-kong-upstream-latency")}ms ` +
              `remaining=${s.remaining.minute}/min ${s.remaining.hour}/hour ${s.remaining.day}/day`
          );
          // Extra evidence for the 500 investigation: body + retry-after. The
          // body read is the only part expensive enough to keep behind the env var.
          if (resp.status >= 500 && process.env.SAIA_PACER_DEBUG === "1") {
            let body = "";
            try {
              body = (await resp.clone().text()).replace(/\s+/g, " ").slice(0, 500);
            } catch {}
            pacerDebugLog(
              `5xx-detail ${resp.status} id=${reqId} consecutive=${consecutive5xx} ` +
                `retry-after=${resp.headers.get("retry-after")} body=${body}`
            );
          }
          return resp;
        }
      };

      let resp = await attempt(key);
      // A revoked/expired key 401s forever. Without this, key #1 going dead
      // wedges every request behind it while healthy keys sit unused in
      // rotation, and opencode only ever shows "Unauthorized".
      while (resp.status === 401 || resp.status === 403) {
        deadKeys.add(key);
        pacerDebugLog(`${resp.status} on ${label(key)} — key rejected, dropped from rotation`);
        key = pickKey();
        if (key === null) throw allExhaustedError();
        resp = await attempt(key);
      }
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

export const server = async (_input) => {
  return {
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
          const resp = await fetch("https://chat-ai.academiccloud.de/v1/models", {
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
          options: { baseURL: "https://chat-ai.academiccloud.de/v1" },
        };
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
          pacerDebugLog(`budget-status injection failed for ${role}: ${e.message}`);
        }
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

## SUBAGENT FAILURE RULE (non-negotiable)

If a subagent errors out or returns without its required block (PLAN /
CHANGES / VERDICT), re-task that SAME agent exactly ONCE, stating what was
missing or what error occurred. If it fails again, STOP and report failure
to the user. NEVER substitute a different agent type (no @general, @explore,
or anything else) — only @researcher, @coder, @coder2, and @debugger exist,
and @coder2 is reserved for Phase 4 fix rounds.

## WORKFLOW (mandatory order — never skip a phase)

### Phase 0 — Intake
Restate the user's task in one sentence. Use glob/grep/read minimally to scope
it (which project, which area of the code). Do not analyze deeply — that is the
researcher's job.

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

If the plan fails the audit, re-task @researcher ONCE with the specific gaps.
Never send work to @coder without an audited PLAN.

### Phase 2 — Implement
Task @coder with the FULL PLAN block pasted verbatim, plus any user constraints.
Require a CHANGES block back (template below). If STATUS is BLOCKED, do not
proceed — go to Phase 5 and report.

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
evidence. Follow the completion protocol below.

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

write_file "prompts/coder.md" <<'__OC_FILE_EOF__'
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

write_file "prompts/debugger.md" <<'__OC_FILE_EOF__'
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

write_file "prompts/researcher.md" <<'__OC_FILE_EOF__'
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

# NOTE: never add "general"/"explore" to any deletion list below — they are
# opencode's native subagents and must survive every install path so the user
# always has at least one working subagent, even when both primaries are declined.

# Remove unused agent blocks based on flags
if install_solo == 0 and "solo" in agent:
    del agent["solo"]
if install_auto == 0:
    for a in ["auto", "coder", "coder2", "researcher"]:
        if a in agent:
            del agent[a]
if install_solo == 0 and "debugger" in agent:
    del agent["debugger"]

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
  # Only remove solo and debugger when neither orchestrator is installed
  # (auto also uses @debugger for Phase 3 validation)
  if [[ $INSTALL_SOLO -eq 0 ]] && [[ $INSTALL_AUTO -eq 0 ]]; then
    rm -f "$CONFIG_DIR/prompts/solo.md"
    rm -f "$CONFIG_DIR/prompts/debugger.md"
    log "  removed (disabled): prompts/solo.md"
    log "  removed (disabled): prompts/debugger.md"
  fi
  
  if [[ $INSTALL_AUTO -eq 0 ]]; then
    rm -f "$CONFIG_DIR/prompts/auto.md"
    rm -f "$CONFIG_DIR/prompts/coder.md"
    rm -f "$CONFIG_DIR/prompts/researcher.md"
    log "  removed (disabled): prompts/auto.md"
    log "  removed (disabled): prompts/coder.md"
    log "  removed (disabled): prompts/researcher.md"
  fi
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
      log "it a task. Subagents: @coder, @coder2, @researcher, @debugger."
    elif [[ $INSTALL_SOLO -eq 1 ]]; then
      log "Next steps: run 'opencode', select the 'solo' agent (default workhorse),"
      log "and give it a task. Subagent: @debugger."
    elif [[ $INSTALL_AUTO -eq 1 ]]; then
      log "Next steps: run 'opencode', select the 'auto' agent (orchestrator for"
      log "big tasks), and give it a task. Subagents: @coder, @coder2, @researcher"
      log "(debugger only when needed)."
    else
      log "Next steps: run 'opencode' with the built-in agents (build, plan)."
      log "Install solo/auto later to get full functionality."
    fi
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

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

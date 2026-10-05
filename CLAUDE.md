# CLAUDE.md

This file provides guidance to Claude Code when working with this opencode SAIA setup.

## Quick reference

- **Build command:** `./build-setup.sh` — regenerates `setup-saia-opencode.sh` after config changes
- **Install:** `bash setup-saia-opencode.sh` (interactive prompts for agent selection) or `--yes`/`--solo`/`--auto` flags
- **Model refresh:** `/reload_models` in opencode or `bash scripts/reload-models.sh`, then restart opencode
- **Reasoning effort:** `/effort off|low|medium|high|max` in opencode or `bash scripts/effort.sh` (applies to the current session immediately — the pacer re-reads the setting per request)
- **Request log:** `~/.cache/opencode/saia-gwdg-pacer.log` — always on, one `req`/`resp` (or `fail`) line per SAIA request. `SAIA_PACER_DEBUG=1` additionally captures 5xx response bodies.
- **Headers timeout:** `SAIA_TIMEOUT_MS` (default 45000, floor 5000 — lower values clamped) — cap on receiving response **headers** only; cleared as soon as they arrive, so it can never cut a healthy long generation short. Also sets `STREAM_IDLE_TIMEOUT_MS`. The plugin retries up to `MAX_CONNECT_TRIES` (3) times before giving up
- **Early headers timeout:** `SAIA_EARLY_TIMEOUT_MS` (default 20000, floor 5000, clamped to `SAIA_TIMEOUT_MS`) — the deadline for every try *except the last*, which keeps the full `SAIA_TIMEOUT_MS`. Worst case for a lost request is 20+20+45 = 85s instead of 3x45 = 135s. `SILENT_PACED_MODELS` are exempt and always get the full budget. Only the last try's error is thrown, so the user-visible string stays `within 45000ms`
- **Model-health breaker:** a model that fails to send headers on `MODEL_BREAKER_MIN_TIMEOUTS` (4, override `SAIA_BREAKER_MIN_TIMEOUTS`) tries within 10 min, at a >=50% failure ratio, is swapped for the next entry in its `ROLE_MODELS` list (or `BREAKER_FALLBACK_MODEL` if it is in none). Logged as `model-unhealthy` / `model-substitute`, toasted once, re-probed after 15 min
- **Body timeout:** `SAIA_BODY_TIMEOUT_MS` (default 60000, floor 5000) — non-streaming bodies only (`/v1/models`, error bodies). Streaming bodies are guarded by the idle timers instead
- **Auto-resume:** on by default; `SAIA_AUTO_RESUME=0` disables it, `SAIA_RESUME_ON_ABORT=1` also resumes `MessageAbortedError` within 10s of a transport failure (off by default — it would override a user's Esc). Max 3 per session, 8/hour globally, backoff 5s/20s/60s, refused when the budget is low
- **Fault injection:** `bash test/run-faults.sh [mode]` — drives `test/fake-saia.py` through the stall/timeout/500 matrix via `SAIA_TEST_HOST` + `SAIA_BASE_URL`. Zero real SAIA requests, and it runs against a private `SAIA_PACER_LOG`/`SAIA_BUDGET_PATH` under its temp dir so a concurrently running opencode neither pollutes the assertions nor gets its budget snapshot overwritten

## Architecture

The repo uses opencode's auto-discovered folders (installed 1:1 into `~/.config/opencode`).

1. `opencode.jsonc` — static config (provider + the **primary** agents `solo`/`auto`, plus model-pinning stubs for `plan`/`build`/`general`/`explore`; no `plugin`/`command` blocks)
2. `plugin/saia-gwdg-plugin.js` — runtime plugin, **auto-discovered** from `plugin/` (model list, budget tracking, prompt injection)
3. `command/*.md` — slash commands (`/usage`, `/reload_models`, `/effort`), auto-discovered; backed by `scripts/*.sh`
4. `agent/*.md` — the four **subagents** (`coder`, `coder2`, `researcher`, `debugger`): YAML frontmatter (same schema as an `opencode.jsonc` agent block) + the prompt as the body, auto-discovered from `{agent,agents}/**/*.md`. Always installed, independent of which primaries were selected
5. `prompts/*.md` — system prompts for the two optional primaries only (`auto.md`, `solo.md`); they stay separate files because the plugin templates `__SAIA_BUDGET_STATUS__` into them
6. `tool/`, `skill/` — scaffolds for future custom tools / skills

## Gotchas

- `setup-saia-opencode.sh` is generated — never edit directly; regenerate after any config change
- Rate limits: 30 req/min, 200/hour, 1000/day, 3000/month shared across all agents
- `permission.task` is resolved **last-match-wins**, so the wildcard MUST come first in both primaries. `agent.auto.permission.task` is allow-by-exception (`"*": "allow"` then `general`/`explore` denied — so a new `agent/*.md` is taskable with no edit); `agent.solo.permission.task` is deny-by-exception (`"*": "deny"` then `debugger` allowed — deliberate: solo's cost contract is ~5-12 requests/task and its roster does not grow)
- Adding a subagent = adding one `agent/<name>.md` + one `ROLE_MODELS` entry in the plugin. No edit to any primary. Do add it to `prompts/auto.md`'s workflow description if `auto` should actually use it
- `agent/*.md` bodies get **no** `{file:...}` or `@`-include expansion (opencode substitutes only inside `opencode.json{,c}`) — that is why `coder2`'s prompt is cloned from `coder`'s by the plugin at config time, and why the moved prompts live in the md bodies
- Never create `agent/general.md` or `agent/explore.md`: opencode assigns `prompt = <file body>` unconditionally, so an empty body would overwrite their built-in system prompts with `""`. Their `{}` stubs in `opencode.jsonc` exist only so `ROLE_MODELS` can pin them a model
- `mode: subagent` is mandatory in every `agent/*.md` — without it opencode defaults the agent to `mode: "all"` and lists it as a primary in Tab-cycling. `build-setup.sh` fails the build if it is missing
- Malformed `agent/*.md` frontmatter (e.g. a quoted number for `steps`) is a **fatal** opencode startup error, not a degraded feature — the decode throws inside an uncaught `Effect.promise`
- `__SAIA_BUDGET_STATUS__` placeholder in `prompts/auto.md` and `prompts/solo.md` — never rename
- Plugin silently fails if `auth.json` is missing or models fetch fails with no valid cache
- Plugin & commands are auto-discovered — do NOT re-add a `plugin` array or `command` block to `opencode.jsonc`
- `prompts/` and `agent/` must stay direct children of the config root: the plugin reads `../prompts/{auto,solo}.md` from `plugin/`, `{file:./prompts/*.md}` resolves relative to `opencode.jsonc`, and opencode scans `{agent,agents}/**/*.md` per config directory. Keep `agent/` flat — the glob is recursive, so `agent/sub/x.md` would name the agent `sub/x`
- `build-setup.sh` glob-packs `agent/*.md`, `tool/*.{js,ts}` and `skill/**/SKILL.md`, so agents/tools/skills added to those folders ship automatically (the scaffold READMEs are not packed). `agent/*.md` is appended to `MANIFEST`, so unlike `tool/`/`skill/` it also gets the delimiter, trailing-newline and frontmatter checks
- `.opencode.bak/` is an old backup — gitignored
- The plugin owns stall detection. `chunkTimeout` in `opencode.jsonc` is a backstop and **MUST stay above `SLOW_IDLE_TIMEOUT_MS` (90s)** — opencode implements it as an abort on the signal it hands the patched fetch, so a lower value fires first, the plugin reads it as a caller abort and refuses to retry, silently killing the whole stream-resume path (this is exactly what `chunkTimeout: 30000` did for 12 days). Do **not** add `timeout`/`headerTimeout` to the provider options either — opencode measures those around the patched `globalThis.fetch`, so they would include the pacer's queue wait, 30s cooldown and 429 sleeps and abort healthy requests
- The pacer's headers deadline must never span the response body. It is an explicit `AbortController` cleared in a `finally` around the `realFetch` await only; widening that `finally` over the body reads re-introduces the bug where every turn longer than 45s was killed at exactly 45s
- A mid-stream stall is only resumed for **text**. Once `delta.tool_calls` arguments have streamed, the turn is failed (`stream-toolcall-abandon`) rather than retried — opencode's SSE accumulator already holds a partial call, so a second sequence corrupts the args or duplicates the call. Session auto-resume re-plans it instead
- The model-health breaker rewrites the `model` field in the request body and rebinds the pacer's `model`/`init` locals, so the `req`/`resp`/`fail` log lines, `SILENT_PACED_MODELS`, `pickIdleTimeout` and `wrapStreamWithRetry` all follow the model actually on the wire. opencode's UI and its token/cost accounting still show the model the **user** picked — the toast is the only signal they get. It is a stopgap for a provider-side outage, not a permanent substitution
- `roleOf()` builds its `model -> role` index **lazily**: `ROLE_MODELS` is declared far below `installPacer` in the same module, so touching it at module-evaluation time would hit the TDZ
- `keyring/saia_keyring.py` and `keyring/saia-keyring.sh` are vendored byte-identical into the six `<harness>-saia` repos' `src/`. Edit them only here, then `keyring/sync.sh` (rebuilds every installer) and commit each repo; `keyring/sync.sh --check` fails on drift. The proxy mirrors the plugin's floors (5/10/30), reset TTLs and error texts — change both together
- `test/` is test-only and deliberately not packed by `build-setup.sh` (which packs named files plus `agent/*.md`, `tool/*.{js,ts}` and `skill/**/SKILL.md`). The matrix runs against a private `SAIA_PACER_LOG`/`SAIA_BUDGET_PATH` inside its temp dir, so it no longer overwrites the real budget snapshot or reads a log a concurrently running opencode is appending to
- SAIA sends `x-kong-request-id`, not `x-request-id` — the latter is always null and is what GWDG needs for correlation
- Running the installer without `--solo --auto` removes those two **primaries** from the live config and deletes their `prompts/{solo,auto}.md`. It no longer touches the subagents: they ship as `agent/*.md` and the install-time filter only ever deletes `solo`/`auto`. (Before this change `--no-auto` also deleted `coder`/`coder2`/`researcher`, and `--no-solo` deleted `debugger` — which left `--auto --no-solo` with an `auto` whose prompt mandates a `@debugger` that did not exist.)

See `AGENTS.md` for detailed agent architecture and `SETUP.md` for installation instructions.

# CLAUDE.md

This file provides guidance to Claude Code when working with this opencode SAIA setup.

## Quick reference

- **Build command:** `./build-setup.sh` — regenerates `setup-saia-opencode.sh` after config changes
- **Install:** `bash setup-saia-opencode.sh` (interactive prompts for agent selection) or `--yes`/`--solo`/`--auto` flags
- **Model refresh:** `/reload_models` in opencode or `bash scripts/reload-models.sh`, then restart opencode
- **Reasoning effort:** `/effort off|low|medium|high|max` in opencode or `bash scripts/effort.sh` (applies to the current session immediately — the pacer re-reads the setting per request)
- **Request log:** `~/.cache/opencode/saia-gwdg-pacer.log` — always on, one `req`/`resp` (or `fail`) line per SAIA request. `SAIA_PACER_DEBUG=1` additionally captures 5xx response bodies.
- **Headers timeout:** `SAIA_TIMEOUT_MS` (default 45000, floor 5000 — lower values clamped) — cap on receiving response **headers** only; cleared as soon as they arrive, so it can never cut a healthy long generation short. Also sets `STREAM_IDLE_TIMEOUT_MS`. The plugin retries up to `MAX_CONNECT_TRIES` (3) times before giving up
- **Body timeout:** `SAIA_BODY_TIMEOUT_MS` (default 60000, floor 5000) — non-streaming bodies only (`/v1/models`, error bodies). Streaming bodies are guarded by the idle timers instead
- **Auto-resume:** on by default; `SAIA_AUTO_RESUME=0` disables it, `SAIA_RESUME_ON_ABORT=1` also resumes `MessageAbortedError` within 10s of a transport failure (off by default — it would override a user's Esc). Max 3 per session, 8/hour globally, backoff 5s/20s/60s, refused when the budget is low
- **Fault injection:** `bash test/run-faults.sh [mode]` — drives `test/fake-saia.py` through the stall/timeout/500 matrix via `SAIA_TEST_HOST` + `SAIA_BASE_URL`. Zero real SAIA requests

## Architecture

The repo uses opencode's auto-discovered folders (installed 1:1 into `~/.config/opencode`).

1. `opencode.jsonc` — static config (provider + inline agent definitions; no `plugin`/`command` blocks)
2. `plugin/saia-gwdg-plugin.js` — runtime plugin, **auto-discovered** from `plugin/` (model list, budget tracking, prompt injection)
3. `command/*.md` — slash commands (`/usage`, `/reload_models`, `/effort`), auto-discovered; backed by `scripts/*.sh`
4. `prompts/*.md` — agent system prompts (loaded at runtime)
5. `tool/`, `skill/` — scaffolds for future custom tools / skills

## Gotchas

- `setup-saia-opencode.sh` is generated — never edit directly; regenerate after any config change
- Rate limits: 30 req/min, 200/hour, 1000/day, 3000/month shared across all agents
- In `opencode.jsonc`, `"*": "deny"` in `agent.auto.permission.task` and `agent.solo.permission.task` MUST come before named allows (last-match-wins)
- `__SAIA_BUDGET_STATUS__` placeholder in `prompts/auto.md` and `prompts/solo.md` — never rename
- Plugin silently fails if `auth.json` is missing or models fetch fails with no valid cache
- Plugin & commands are auto-discovered — do NOT re-add a `plugin` array or `command` block to `opencode.jsonc`
- `prompts/` must stay a direct child of the config root: the plugin reads `../prompts/{auto,solo}.md` from `plugin/`, and `{file:./prompts/*.md}` resolves relative to `opencode.jsonc`
- `build-setup.sh` glob-packs `tool/*.{js,ts}` and `skill/**/SKILL.md`, so real tools/skills added to those folders ship automatically (the scaffold READMEs are not packed)
- `.opencode.bak/` is an old backup — gitignored
- The plugin owns stall detection. `chunkTimeout` in `opencode.jsonc` is a backstop and **MUST stay above `SLOW_IDLE_TIMEOUT_MS` (90s)** — opencode implements it as an abort on the signal it hands the patched fetch, so a lower value fires first, the plugin reads it as a caller abort and refuses to retry, silently killing the whole stream-resume path (this is exactly what `chunkTimeout: 30000` did for 12 days). Do **not** add `timeout`/`headerTimeout` to the provider options either — opencode measures those around the patched `globalThis.fetch`, so they would include the pacer's queue wait, 30s cooldown and 429 sleeps and abort healthy requests
- The pacer's headers deadline must never span the response body. It is an explicit `AbortController` cleared in a `finally` around the `realFetch` await only; widening that `finally` over the body reads re-introduces the bug where every turn longer than 45s was killed at exactly 45s
- A mid-stream stall is only resumed for **text**. Once `delta.tool_calls` arguments have streamed, the turn is failed (`stream-toolcall-abandon`) rather than retried — opencode's SSE accumulator already holds a partial call, so a second sequence corrupts the args or duplicates the call. Session auto-resume re-plans it instead
- `test/` is test-only and deliberately not packed by `build-setup.sh` (which packs named files plus `tool/*.{js,ts}` and `skill/**/SKILL.md`). Running the matrix does overwrite `saia-gwdg-budget.json` with the fake endpoint's rate-limit headers; the next real request corrects it
- SAIA sends `x-kong-request-id`, not `x-request-id` — the latter is always null and is what GWDG needs for correlation
- Running the installer without `--solo --auto` silently strips those agents from the live config and deletes `prompts/*.md`; see `saia-backend-findings.md` for the SAIA 500/hang investigation

See `AGENTS.md` for detailed agent architecture and `SETUP.md` for installation instructions.

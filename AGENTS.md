# AGENTS.md

## Architecture

This directory configures the `opencode` AI assistant to use the GWDG SAIA OpenAI-compatible API (`https://chat-ai.academiccloud.de/v1`).

### Files

The repo mirrors the installed `~/.config/opencode` layout using opencode's auto-discovered folders.

| File / dir | Purpose |
|------------|---------|
| `opencode.jsonc` | Main config: provider + inline agent definitions (plugin & commands are auto-discovered from their folders — no `plugin`/`command` entries) |
| `plugin/saia-gwdg-plugin.js` | Runtime plugin (auto-discovered): live model list, request pacer (incl. reasoning-effort injection), budget tracking, prompt injection |
| `command/*.md` | Slash commands `/usage`, `/reload_models`, `/effort` (auto-discovered) |
| `scripts/{usage,reload-models,effort}.sh` | Backing shell scripts the commands invoke (referenced by absolute path) |
| `prompts/` | Agent system prompts, via `{file:./prompts/*.md}`; the plugin also reads `../prompts/{auto,solo}.md` for budget injection |
| `tool/`, `skill/` | Scaffolds (with READMEs) for future opencode custom tools / skills |
| `yagni.md` | Global instruction appended to every agent (via `instructions`) |
| `auth.json` (in `~/.local/share/opencode/`) | Stores API key (chmod 600) |
| `saia-gwdg-keys.json` (in `~/.local/share/opencode/`) | Optional extra failover keys `{"keys": [...]}` (chmod 600); auth.json key is always #1 |
| `build-setup.sh` | Packs the live config into `setup-saia-opencode.sh` — rerun after config changes |
| `setup-saia-opencode.sh` | Generated self-contained installer for other devices (never edit directly) |

## Agents

| Agent | Role | Model (plugin may override) | Temp | Steps | Permissions | Prompt |
|-------|------|-----------------------------|------|-------|-------------|--------|
| `build` | Primary | global/model | 0.2 | - | Full | built-in |
| `plan` | Primary | global/model | default | - | Ask (edit/bash) | built-in |
| `general` | Subagent (native) | deepseek-v4-flash | default | - | built-in | built-in |
| `explore` | Subagent (native) | qwen3-coder-next | default | - | built-in (read-only) | built-in |
| `solo` | Primary | qwen3-coder-next | 0.2 | 25 | Full + task (debugger only, `*` denied); `skill`, `todowrite`, `webfetch` disabled | `prompts/solo.md` |
| `auto` | Primary | qwen3.5-122b-a10b | 0.2 | 10 | Read-only (read/glob/grep/list) + task (researcher/coder/coder2/debugger, `*` denied); `skill`, `todowrite`, `webfetch` disabled | `prompts/auto.md` |
| `coder` | Subagent | qwen3-coder-next | 0.2 | 20 | Full; `skill` disabled | `prompts/coder.md` |
| `coder2` | Subagent | glm-4.7 | 0.2 | 20 | Full; `skill` disabled | `prompts/coder.md` |
| `researcher` | Subagent | qwen3.5-122b-a10b | 0.2 | 8 | Read-only; `skill`, `webfetch` disabled | `prompts/researcher.md` |
| `debugger` | Subagent | qwen3-coder-next | 0.1 | 8 | Full; `skill`, `todowrite`, `webfetch` disabled | `prompts/debugger.md` |

### Usage

- **Primary agents** (`build`, `plan`, `solo`, `auto`): Press `Tab` to switch
- **`solo` is the default workhorse** (~5-12 requests/task): one full-context session that plans, implements, self-checks, then tasks `@debugger` for independent validation. Use `auto` only for big/ambiguous multi-file tasks where deep upfront planning (397b researcher) is worth the chain's ~40% coordination overhead (~20-40 requests/task)
- **Subagents** (`coder`, `coder2`, `researcher`, `debugger`): Invoke with `@coder`, `@coder2`, `@researcher`, or `@debugger` in your message; `coder2` (different model family) exists for fix rounds

### Auto Mode Workflow

When you press `Tab` to select `auto` and give it a task, it runs a 5-phase loop:

1. **Intake** — auto scopes the task (it has read/glob/grep access for scoping and auditing only)
2. **Plan** — `@researcher` produces a PLAN block (goal, files, steps, runnable acceptance criteria); auto audits it (files exist, criteria are executable) before any coding. **Fast path:** for one-file, fully-specified tasks auto authors the PLAN itself instead of tasking the researcher
3. **Implement** — `@coder` executes the audited PLAN, returns a CHANGES block with self-check results
4. **Validate** — `@debugger` actually RUNS every acceptance criterion (batched into one script where possible) and returns VERDICT: PASS/FAIL with quoted command output
5. **Fix loop** — on FAIL, auto tasks `@coder2` (a different model family than the first coder, to avoid repeating the same mistake) with the failures verbatim and re-validates, max 1 round; then it must report failure honestly. If a subagent errors or omits its required block, auto retries that same agent once, then reports failure — it never substitutes another agent type

**Auto mode cannot edit, write, or mutate bash** — it may use read-only bash (`ls`, `git status/diff/log`, `rg`, `cat`, `wc`, `find`, etc.) for inspection, but delegates implementation to subagents. It may declare success only when the debugger returned `VERDICT: PASS` with real command output for every criterion; otherwise it reports the remaining failures verbatim.

## Key Facts

- **API key location**: `~/.local/share/opencode/auth.json` (plaintext, chmod 600); optional extra failover keys in `~/.local/share/opencode/saia-gwdg-keys.json`
- **Model list**: Cached weekly — `~/.cache/opencode/saia-gwdg-models.json` is authoritative while <7 days old (zero-request launches); older/missing cache triggers one `/v1/models` fetch (stale cache as failure fallback). Force a refresh with `/reload_models` (needs bash — solo/build agent) or `./scripts/reload-models.sh`, then restart opencode
- **Rate limits (per key, all endpoints)**: 30 req/min, 200/hour, 1000/day, 3000/month — each agent step is one request; the monthly bucket is the binding long-term constraint (sustainable pace ≈100 requests/day per key); a hung run usually means every key's bucket is exhausted
- **`build` and `plan` have no `steps` cap** (deliberate: a step cap ends a long autonomous task mid-work regardless of remaining budget). Their only brake is the pacer's per-key budget floors — a runaway loop is stopped by budget, not by a counter, so watch `/usage` on long runs. The custom agents (`solo`, `auto`, `coder`, `coder2`, `researcher`, `debugger`) keep their caps
- **Request pacer**: the plugin wraps `fetch` for the SAIA host — spaces requests ≥2.1s apart (can't trip 30/min), retries a 429 once after the advertised reset, and rotates through the configured keys: it rewrites the `Authorization` header to the active key on every request, tracks each key's budget separately, and fails over to the next usable key when the active one hits the floor (≤5 hourly / ≤10 daily / ≤30 monthly remain) or 429s despite pacing; an exhausted key re-enters rotation after its bucket's reset TTL (hour 60 min / day 24 h / month 30 d). It aborts with a clear error only when ALL keys are exhausted, or after 3 consecutive 5xx responses (SAIA outages return 500s that still consume budget, and opencode would retry them forever). Writes per-key remaining-budget counts to `~/.cache/opencode/saia-gwdg-budget.json` after every response that carries rate-limit headers; at startup the plugin turns that snapshot into a LOW/HEALTHY/UNKNOWN status (hour/day/month summed across keys) injected into the `auto` and `solo` prompts via the `__SAIA_BUDGET_STATUS__` placeholder, and a `tool.execute.before` hook hard-refuses the first `task` call of a session when the aggregate budget is LOW (<40 hour / <50 day / <60 month; in-flight chains are never cut off; the pacer floors guard the tail). Set `SAIA_PACER_DEBUG=1` to log each request (with the active key label) to `~/.cache/opencode/saia-gwdg-pacer.log`
- **Only ready models** are exposed (status check in plugin)
- Plugin auto-detects model capabilities (attachment support, reasoning) from `/v1/models`, **plus** a hand-maintained `FORCE_REASONING` override set in the plugin: SAIA under-reports three models (`qwen3.6-35b-a3b`, `qwen3.8-27b`, `openai-gpt-oss-120b`) as `output: ["text"]` even though they return a populated `reasoning` field. Re-probe after SAIA adds models — the metadata is not trustworthy on its own
- **Reasoning effort** (`/effort`, backed by `scripts/effort.sh`): the pacer injects `chat_template_kwargs: { enable_thinking, reasoning_effort }` into the JSON body of `/v1/chat/completions` requests for **reasoning-capable models only** (those whose output advertises `thought`, plus the plugin's `FORCE_REASONING` override set — see above). The key is `enable_thinking`, the Qwen/vLLM chat-template variable; a bare `thinking` key is silently ignored by the template, which is why `/effort` was a no-op before 2026-08-28. Levels are remapped per model via `EFFORT_ALIAS` where a chat template disagrees — `qwen3.8-27b` 400s on `high`/`max` and gets `xhigh` instead; the log line shows the remap as `effort=max->xhigh`. The level is read from `~/.config/opencode/effort.json` (default `high` when missing) and re-read per request, so `/effort off|low|medium|high|max` applies to the current session immediately — no restart. The command runs its script via inline `` !`…` `` injection (like `/usage`) — no bash permission needed, works from any agent — and the plugin short-circuits the resulting chat request locally (sentinel line `(local command — handled without a model call)` in `command/effort.md`), so `/effort` costs zero SAIA requests and returns instantly. Non-reasoning models (e.g. `qwen3-coder-next`) are left untouched. Values map: `off` → `thinking:false`; other levels → `thinking:true` + `reasoning_effort`. Verify with `SAIA_PACER_DEBUG=1` (logs `effort=<level> injected for <model>`)
- Plugin overrides each agent's model via `ROLE_MODELS` in `saia-gwdg-plugin.js`
- Built-in agents (`build`, `plan`) remain available alongside custom agents
- Native subagents (`general`, `explore`) are declared as stubs in `opencode.jsonc` and are **never** stripped by the installer's agent filter — so declining both primaries (`solo`/`auto`) still leaves `@general` and `@explore` available (each pinned to a SAIA model via the plugin's `ROLE_MODELS`)

## Commands

```bash
opencode              # start session with default (build) agent
opencode models       # list all available GWDG models (weekly cache)
opencode providers    # show provider status
./scripts/reload-models.sh   # force-refresh the model cache (also /reload_models in-session)
./scripts/effort.sh          # set reasoning effort for thinking models (also /effort in-session)
./build-setup.sh             # regenerate setup-saia-opencode.sh after config changes
```

## Common Mistakes

- Editing `setup-saia-opencode.sh` directly → it is generated; changes are lost on the next `./build-setup.sh`
- Changing `opencode.jsonc`, `plugin/`, `command/`, `scripts/`, or `prompts/` without rerunning `./build-setup.sh` → installer drifts from the live config
- Re-adding a `plugin` array or `command` block to `opencode.jsonc` → duplicates the auto-discovered plugin/commands (they load from `plugin/` and `command/` on their own)
- Moving `prompts/` out of the config root, or moving the plugin without updating its `join(dir, "..", "prompts/…")` read → the plugin's budget injection and the `{file:./prompts/*.md}` refs both break
- Reordering `agent.auto.permission.task` so `"*": "deny"` comes after the named allows → last-match-wins resolution denies all subagents and silently removes the `task` tool from auto
- Renaming the `__SAIA_BUDGET_STATUS__` placeholder in `prompts/auto.md` or `prompts/solo.md` (or moving the files) → the plugin's prompt injection silently stops and the budget check degrades to skipped
- Making an agent read files outside the project (e.g. `~/.cache`) → `external_directory` permission is auto-rejected in non-interactive runs and kills the run at that step
- Deleting `auth.json` → plugin silently fails, no models loaded
- A broken models fetch (offline, exhausted budget) is masked silently: the plugin falls back to the last cached list in `~/.cache/opencode/saia-gwdg-models.json`, however old it is

# SAIA-GWDG opencode setup

This directory configures the `opencode` AI assistant to use the GWDG SAIA OpenAI-compatible API.

## Quick start

Run the installer to set up on a new device:

```bash
GWDG_API_KEY="your-key" bash setup-saia-opencode.sh
```

Or see `SETUP.md` for detailed instructions and agent selection options.

## Files

The repo mirrors the installed `~/.config/opencode` layout and uses opencode's
auto-discovered folders.

| File / dir | Purpose |
|------------|---------|
| `opencode.jsonc` | Main config: provider + the two optional **primary** agents (`solo`, `auto`) and model-pinning stubs (plugin, commands & subagents are auto-discovered from their folders — no `plugin`/`command` entries here) |
| `plugin/saia-gwdg-plugin.js` | Runtime plugin (auto-discovered): live model list, request pacer (incl. reasoning-effort injection), budget tracking, prompt injection |
| `command/` | Custom slash commands as markdown — `/usage`, `/reload_models`, `/effort` |
| `scripts/` | Backing shell scripts for the commands (`usage.sh`, `reload-models.sh`, `effort.sh`) |
| `agent/` | The four **subagents** as one file each (`coder`, `coder2`, `researcher`, `debugger`): frontmatter + prompt body, auto-discovered — always installed |
| `prompts/` | System prompts for the two optional primaries (`auto.md`, `solo.md`), referenced via `{file:./prompts/*.md}` |
| `tool/`, `skill/` | Scaffolds (with READMEs) for future opencode custom tools / skills — see [How the folders work](#how-the-folders-work) |
| `yagni.md` | Global instruction appended to every agent's prompt |
| `build-setup.sh` | Regenerates the installer |
| `keyring/` | The plugin's automatic key swap as a local proxy for the **other** harness installers (aider, mini-swe-agent, OpenHands, Pi, omp, mcode) — not part of the opencode install, see below |
| `setup-saia-opencode.sh` | Generated installer (never edit directly) |

The API key is **not** in the repo — the installer writes it to
`~/.local/share/opencode/auth.json` (chmod 600).

## How the folders work

The repo installs 1:1 into `~/.config/opencode`, and opencode **auto-discovers** several
of these folders — dropping a correctly-shaped file into one is all it takes to register a
prompt, command, tool, or skill. `build-setup.sh` globs the same folders when it
regenerates the installer, so anything you add ships automatically.

**`agent/` — the subagents, one file each.** opencode auto-discovers
`{agent,agents}/**/*.md`, so `agent/coder.md` *is* the `coder` subagent: YAML frontmatter
using the same schema as an `opencode.jsonc` agent block, and the body as its system
prompt. Nothing has to reference them, which is the point — they install and work whether
or not you selected the `solo`/`auto` primaries, and adding one means adding one file
(plus a `ROLE_MODELS` entry so the plugin can pin it a ready SAIA model). Two rules:
`mode: subagent` is mandatory, and there is **no** `{file:...}` expansion inside a body —
that is why `coder2`, which shares `coder`'s contract, gets its prompt cloned by the
plugin at startup instead of referencing it.

**`prompts/` — the primary agents' system prompts.** `solo` and `auto` load theirs from
here via `"prompt": "{file:./prompts/*.md}"` in `opencode.jsonc`. They stay separate files
because the plugin (`plugin/saia-gwdg-plugin.js`) reads `prompts/auto.md` and
`prompts/solo.md` at startup and swaps the `__SAIA_BUDGET_STATUS__` placeholder for the
live budget line, and because either primary can be declined at install time. This folder
must stay a direct child of the config root — the plugin reads `../prompts/…` relative to
`plugin/`, and `{file:./prompts/*.md}` resolves relative to `opencode.jsonc`.

**`command/` + `scripts/` — slash commands and their backing scripts.** `command/*.md` are
auto-discovered slash commands (`/usage`, `/reload_models`, `/effort`). The markdown is thin: it
carries a `description` plus a one-line directive that runs the backing script — inline for
`usage.md` and `effort.md`, via the bash tool for `reload_models.md`. The real work lives in
`scripts/*.sh` (`usage.sh`, `reload-models.sh`, `effort.sh`), installed to
`~/.config/opencode/scripts/`.

`/effort` (backed by `scripts/effort.sh`) sets the SAIA reasoning effort for thinking models:
`/effort off|low|medium|high|max` writes `~/.config/opencode/effort.json`, and the plugin's
pacer re-reads that file per request, so the change applies to the current session immediately —
no restart. Default (no file) is `high`. No arg shows the current level. Runs via inline
`` !`…` `` injection at command time, so it needs no bash permission and works from any agent.
The plugin answers the command locally (the template's sentinel line short-circuits the
outgoing chat request), so `/effort` is instant and costs zero SAIA requests; only if the
plugin is missing does the expanded template fall through to the model.

**`tool/` — custom-tool scaffold (currently empty but for its README).** opencode
auto-discovers `*.js`/`*.ts` at the folder root and uses the filename as the tool name;
`build-setup.sh` packs `tool/*.js` / `tool/*.ts` into the installer. No tools exist yet —
see [`tool/README.md`](tool/README.md) for the authoring convention.

**`skill/` — skill scaffold (currently empty but for its README).** opencode auto-discovers
`skill/<name>/SKILL.md` (the directory name is the skill name); `build-setup.sh` packs
`skill/**/SKILL.md`. No skills exist yet — see [`skill/README.md`](skill/README.md) for the
authoring convention.

The `skill` tool is **disabled on every custom agent** — `"tools": { "skill": false }` on
`solo`/`auto` in `opencode.jsonc`, and `tools: {skill: false}` in each `agent/*.md`
frontmatter for `coder`, `coder2`, `researcher`, `debugger` — on purpose:

- Every tool call is a metered request against tight shared SAIA limits (see `AGENTS.md`),
  so an unused tool is pure cost.
- Fewer tools keep the small, single-job models focused and deterministic.
- There are no skills in the repo yet, so the tool would be all downside.

When you add a real skill, re-enable `skill: true` on just the agent(s) meant to invoke it.

**Why the empty `tool/` / `skill/` directories are kept.** They're auto-discovery mount
points: because `build-setup.sh` globs them (`tool/*.js` / `tool/*.ts`, `skill/**/SKILL.md`),
a real tool or skill added later ships with no config edit. `nullglob` means an empty folder
just ships nothing — no error. Their READMEs document the expected layout so contributors
get it right, and those scaffold READMEs are deliberately **not** packed into the installer.

**`keyring/` — automatic key swap for the other harnesses.** The plugin's key rotation
(next key on 401/403, low `x-ratelimit-remaining-*` budget or 429) only works inside
opencode. `keyring/saia_keyring.py` is the same rotation as a stdlib-Python proxy on
`127.0.0.1:8788`, and `keyring/saia-keyring.sh` is the install logic the
`<harness>-saia` installers source: with 2+ keys they start the proxy (systemd user
unit / launchd agent / shell rc) and point the harness at it; with one key they leave
the harness talking to SAIA directly. Both files are **vendored** byte-identical into
each harness repo's `src/`: edit them here, then run `keyring/sync.sh` (copies and
rebuilds every installer; `--check` only reports drift) and commit each repo. Tests:
`python3 -m unittest discover keyring/test`. `build-setup.sh` does not pack this folder.

## Setup

See `SETUP.md` for detailed installation instructions and agent selection.

## Architecture

```
auth.json → plugin/saia-gwdg-plugin.js → opencode.jsonc → https://chat-ai.academiccloud.de/v1
```

## Maintaining

After changing configuration files, regenerate the installer:

```bash
./build-setup.sh
```
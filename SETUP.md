# Installing SAIA setup on another device

Everything ships in one generated script: `setup-saia-opencode.sh`.

## Fresh device

```bash
scp setup-saia-opencode.sh otherhost:
ssh otherhost
GWDG_API_KEY="your-key" bash setup-saia-opencode.sh    # or run without the env var to be prompted
```

What it does:

1. Checks for `opencode` (also looks in `~/.opencode/bin`); if missing, offers to run the official installer (`curl -fsSL https://opencode.ai/install | bash`).
2. Writes `opencode.jsonc`, `plugin/saia-gwdg-plugin.js`, `command/*.md`, `scripts/*.sh`, `yagni.md`, all `agent/*.md`, and the selected primaries' `prompts/*.md` into `~/.config/opencode/` (using those auto-discovered folders). Files that would be overwritten are backed up to `~/.config/opencode.bak-<timestamp>/` first; unchanged files are left alone (rerunning is safe).
3. Writes the API key to `~/.local/share/opencode/auth.json` (chmod 600) as `{"saia-gwdg": {"type": "api", "key": "..."}}`, merging into an existing auth.json rather than clobbering other providers. An existing saia-gwdg key is kept unless `--force-key` is passed.
4. Verifies by running `opencode models` and checking that `saia-gwdg/` models are listed (costs 1 request of the shared GWDG rate budget: 30/min, 200/hour per key).

### Agent selection

Only the two **primary** agents are optional. The four subagents (`@coder`,
`@coder2`, `@researcher`, `@debugger`) are auto-discovered `agent/*.md` files and
always install, whichever primaries you pick — they are usable from any primary,
including the built-in `build` agent.

Primary selection defaults to opt-in:

- **Interactive mode (default)**: Prompts for each primary (solo, auto)
- **Non-interactive (`--yes`)**: Skips both primaries
- **Explicit flags**: Use `--solo`, `--auto`, `--no-solo`, `--no-auto` to control

```bash
# Install with only the solo primary
GWDG_API_KEY="key" bash setup-saia-opencode.sh --solo

# Install with both primaries
GWDG_API_KEY="key" bash setup-saia-opencode.sh --solo --auto

# Non-interactive: subagents only, no primary beyond the built-ins
GWDG_API_KEY="key" bash setup-saia-opencode.sh --yes

# Non-interactive: install auto only, skip solo
GWDG_API_KEY="key" bash setup-saia-opencode.sh --yes --auto
```

Flags:
- `-y, --yes` — non-interactive mode (skips both primaries)
- `--solo` — install the solo primary agent (default: ask)
- `--auto` — install the auto primary agent (default: ask)
- `--no-solo` — skip the solo primary agent (default: ask)
- `--no-auto` — skip the auto primary agent (default: ask)
- `--force-key` — replace an existing saia-gwdg API key
- `-h, --help` — show usage

## Maintaining the installer (on this machine)

`setup-saia-opencode.sh` is **generated** — never edit it directly. After changing `opencode.jsonc`, `plugin/`, `command/`, `scripts/`, `agent/*.md`, or `prompts/*.md`:

```bash
./build-setup.sh    # regenerates setup-saia-opencode.sh from the live files
git add -A && git commit
```

The generator refuses to run if a packed file contains the heredoc delimiter or lacks a trailing newline, and stamps the output with the source git commit and pack date (the stamp identifies the config content; the commit *containing* the installer is one later). It warns if the packed files have uncommitted changes (`-dirty` stamp).

## Architecture on the target device

```
auth.json (API key, chmod 600, ~/.local/share/opencode/)
    │
    ▼
plugin/saia-gwdg-plugin.js (auto-discovered; reads key, fetches models — cached ~7 days — assigns agent models)
    │
    ▼
opencode.jsonc (provider + primaries) + agent/*.md (subagents) + command/*.md (/usage, /reload_models, /effort) + prompts/ (primary prompts, via {file:./prompts/*.md})
    │
    ▼
https://chat-ai.academiccloud.de/v1  (GWDG OpenAI-compatible API)
```

## Usage after install

```bash
opencode              # interactive session; press Tab to select agent
opencode models       # list available GWDG models
```

### Available agents

**Primary agents** (Tab to switch):
- `build` — built-in, always available
- `plan` — built-in, always available
- `solo` — default workhorse (~5-12 requests/task) — optional, `--solo`
- `auto` — orchestrator for big tasks (~20-40 requests/task) — optional, `--auto`

**Subagents** (always installed, from `agent/*.md`):
- `@coder`, `@coder2` — implementers
- `@researcher` — analyst (PLAN blocks)
- `@debugger` — validator (runs acceptance criteria)
- `@general`, `@explore` — opencode's natives (denied to `auto`, which must not
  substitute them for its own roles)

To override one subagent's setting on a single machine, add just that key to
`~/.config/opencode/agent/<name>.md`'s frontmatter — the file is the whole
definition, so nothing else has to be copied.

## Minimal install (no custom primaries)

To install without the `solo`/`auto` primaries, use:

```bash
GWDG_API_KEY="your-key" bash setup-saia-opencode.sh --yes
```

This installs:
- Provider config + auto-discovered plugin and commands (`opencode.jsonc`, `plugin/`, `command/`, `scripts/`)
- API key
- All four subagents (`agent/*.md`) — `@coder`, `@coder2`, `@researcher`, `@debugger`
- Built-in primaries `build` and `plan`, plus the native subagents (`general`, `explore`)

`build` can task the subagents directly (opencode allows `task` by default), so
this is a working setup rather than a bare provider install. Re-run the installer
with `--solo`/`--auto` later to add the orchestration workflows.
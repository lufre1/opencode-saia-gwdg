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
2. Writes `opencode.jsonc`, `plugin/saia-gwdg-plugin.js`, `command/*.md`, `scripts/*.sh`, `yagni.md`, all `agent/*.md`, and the selected primaries' `prompts/*.md` into `~/.config/opencode/` (using those auto-discovered folders; with `--minimal`, only the first two — see [Minimal install](#minimal-install---minimal)). Files that would be overwritten are backed up to `~/.config/opencode.bak-<timestamp>/` first; unchanged files are left alone (rerunning is safe).
3. Stores the API key in opencode's own credential store — the same place `opencode auth login saia-gwdg` puts it (check with `opencode auth list`). It is piped to `opencode auth import` on stdin, never put on a command line. An existing saia-gwdg key is kept unless `--force-key` is passed; a key left in `~/.local/share/opencode/auth.json` by an older install is moved over and removed from that file (backed up first; other providers' entries stay). Without opencode installed no key is stored — run `opencode auth login saia-gwdg --standalone` afterwards (`--standalone`, so the background service is not started before the key exists).
4. Stops opencode's background service (so the next `opencode` loads the new plugin; a stuck service only produces a warning with the pid to kill), then verifies by running `opencode models --standalone` and checking that `saia-gwdg/` models are listed (at most 1 request of the shared GWDG rate budget: 2/10s, 200/hour per key). If the check fails, the files are still installed and opencode's own error is printed.

## Windows

Native Windows uses the **same** installer, run under Git Bash — opencode itself
runs its shell (and the `/usage`, `/effort`, `/reload_models` scripts) through
Git Bash on Windows, so there is no separate PowerShell port to drift.

Prerequisites: [Git for Windows](https://git-scm.com/download/win)
(`winget install Git.Git`) and Python from python.org (`winget install Python.Python.3.12`;
the Microsoft Store `python3` alias is not enough).

Put `setup-saia-opencode.cmd` and `setup-saia-opencode.sh` in the same folder, then
double-click the `.cmd`, or from cmd (PowerShell: `$env:GWDG_API_KEY="your-key"`,
then `.\setup-saia-opencode.cmd --solo --auto`):

```bat
set GWDG_API_KEY=your-key
setup-saia-opencode.cmd --solo --auto
```

(Or open Git Bash there and run `bash setup-saia-opencode.sh` as on Linux.) Don't
type plain `bash setup-saia-opencode.sh` in cmd/PowerShell: that is usually WSL's
`bash.exe` and installs into the WSL home, which the Windows opencode never reads.

- Files land in `%USERPROFILE%\.config\opencode`, `%USERPROFILE%\.local\share\opencode`
  and `%USERPROFILE%\.cache\opencode` — the same `~`-relative paths opencode uses on
  every OS. Don't set a custom `%HOME%`: the slash-command scripts use `$HOME` while
  opencode uses `%USERPROFILE%`.
- If opencode is missing, the official `curl | bash` installer handles Git Bash
  (windows-x64, needs `unzip`); alternatives: `npm i -g opencode-ai`,
  `scoop install opencode`, `choco install opencode`. With the curl install, add
  `%USERPROFILE%\.opencode\bin` to your user PATH to run opencode outside Git Bash.
- Git installed outside `Program Files` (e.g. scoop)? Set `OPENCODE_GIT_BASH_PATH` to
  its `bin\bash.exe` — the launcher and opencode both read it.
- `chmod 600` is a no-op on NTFS; `saia-gwdg-keys.json` and opencode's credential store are protected by your user-profile ACL.
- WSL: run the `.sh` inside WSL exactly as on Linux — that configures the WSL opencode.

### Agent selection

Only the two **primary** agents are optional. The four subagents (`@coder`,
`@coder2`, `@researcher`, `@debugger`) are auto-discovered `agent/*.md` files and
install with every full (non-`--minimal`) setup, whichever primaries you pick —
they are usable from any primary, including the built-in `build` agent.

Primary selection defaults to opt-in:

- **Interactive mode (default)**: First asks whether to do a [minimal install](#minimal-install---minimal) (provider only); if not, prompts for each primary (solo, auto)
- **Non-interactive (`--yes`)**: Full setup, skips both primaries
- **Explicit flags**: Use `--solo`, `--auto`, `--no-solo`, `--no-auto` to control (any of them, or `--yes`, skips the minimal question)

```bash
# Install with only the solo primary
GWDG_API_KEY="key" bash setup-saia-opencode.sh --solo

# Install with both primaries
GWDG_API_KEY="key" bash setup-saia-opencode.sh --solo --auto

# Non-interactive: subagents only, no primary beyond the built-ins
GWDG_API_KEY="key" bash setup-saia-opencode.sh --yes

# Non-interactive: install auto only, skip solo
GWDG_API_KEY="key" bash setup-saia-opencode.sh --yes --auto

# Only the SAIA provider + plugin — no agents, no commands
GWDG_API_KEY="key" bash setup-saia-opencode.sh --minimal
```

Flags:
- `-y, --yes` — non-interactive mode (full setup, skips both primaries)
- `--minimal` — SAIA provider + plugin only (see [below](#minimal-install---minimal)); cannot be combined with `--solo`/`--auto`
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
opencode credential store (API key: opencode auth login saia-gwdg)
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

## Install without custom primaries (`--yes`)

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

## Minimal install (`--minimal`)

Just the SAIA models in stock opencode, nothing else:

```bash
GWDG_API_KEY="your-key" bash setup-saia-opencode.sh --minimal
```

(Windows: `setup-saia-opencode.cmd --minimal`, or answer `y` to the first
question when double-clicking it.)

This installs only:
- `opencode.jsonc` with the `saia-gwdg` provider block and a default model
  (`"model": "saia-gwdg/…"`, the plugin's first choice for `build`), so opencode
  starts on SAIA — switch models with `/models`
- `plugin/saia-gwdg-plugin.js` — on opencode v2 it is what registers the live
  SAIA model list and hands the provider its API key, and it paces requests to
  the 2 req/10s limit, rotates failover keys, retries stalls and auto-resumes
  failed turns
- the API key (plus `GWDG_API_KEYS_EXTRA`, if set), as in the full install

Not installed: the subagents, `/usage`, `/effort`, `/reload_models` and their
scripts, the `solo`/`auto` primaries, and `yagni.md`. You get opencode's
built-in agents (`build`, `plan`, `general`, `explore`). Reasoning effort stays
at the plugin default (`high`). The model list is cached for ~7 days; to
refresh it sooner, delete `~/.cache/opencode/saia-gwdg-models.json` and restart
opencode.

`--minimal` **replaces** `~/.config/opencode/opencode.jsonc` (the old one is
backed up, as always). Run over an earlier full install, it also backs up and
removes exactly the files that install shipped (`agent/coder.md`,
`command/usage.md`, …) and the folders that leaves empty. Files of your own,
such as a self-written `agent/foo.md`, stay. To go back to the full setup,
rerun the installer without `--minimal`.
#!/usr/bin/env bash
#
# build-setup.sh — pack the live SAIA config into setup-saia-opencode.sh
#
# Reads the current opencode.jsonc, plugin/, command/, scripts/, agent/*.md and
# prompts/*.md and emits a single self-contained installer that can be copied to
# other devices.
# Rerun this after ANY change to those files, and commit both.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

DELIM="${OC_DELIM_OVERRIDE:-__OC_FILE_EOF__}"
OUT="setup-saia-opencode.sh"
MANIFEST=(
  opencode.jsonc
  plugin/saia-gwdg-plugin.js
  yagni.md
  command/usage.md
  command/reload_models.md
  command/effort.md
  scripts/usage.sh
  scripts/reload-models.sh
  scripts/effort.sh
  prompts/auto.md
  prompts/solo.md
)

# Agent definitions are folder-driven: opencode auto-discovers agent/*.md, so
# every file in that folder ships. Appended to MANIFEST so the delimiter,
# trailing-newline and git-dirty checks below cover them too — unlike tool/*
# and skill/**, which are packed unchecked. Agent files must not skip the
# checks: malformed frontmatter is a FATAL opencode startup error (the decode
# throws inside an uncaught Effect.promise), not a degraded feature.
shopt -s nullglob
AGENT_FILES=(agent/*.md)
shopt -u nullglob
if [[ ${#AGENT_FILES[@]} -eq 0 ]]; then
  echo "ERROR: no agent/*.md found — the SAIA subagents would not ship" >&2
  exit 1
fi
MANIFEST+=("${AGENT_FILES[@]}")

# ── Sanity checks ────────────────────────────────────────────────────
for f in "${MANIFEST[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: missing source file: $f" >&2
    exit 1
  fi
  if grep -qF "$DELIM" "$f"; then
    echo "ERROR: delimiter '$DELIM' occurs in $f — pick a different delimiter" >&2
    exit 1
  fi
  if [[ -n "$(tail -c 1 "$f")" ]]; then
    echo "ERROR: $f lacks a trailing newline (heredoc packing would add one)" >&2
    exit 1
  fi
  # Catch a broken agent definition HERE rather than at the user's next launch:
  # opencode hard-fails to start on frontmatter it cannot decode.
  if [[ $f == agent/*.md ]]; then
    if [[ "$(head -1 "$f")" != "---" ]]; then
      echo "ERROR: $f does not start with a '---' frontmatter delimiter" >&2
      exit 1
    fi
    if [[ "$(grep -c '^---$' "$f")" -lt 2 ]]; then
      echo "ERROR: $f has an unterminated frontmatter block" >&2
      exit 1
    fi
    if ! grep -q '^mode: subagent$' "$f"; then
      echo "ERROR: $f lacks 'mode: subagent' — opencode would default it to" >&2
      echo "       mode 'all' and list it as a primary in Tab-cycling" >&2
      exit 1
    fi
  fi
done

# The plugin's entry point is the one thing opencode v2 validates at load
# ("Plugin must export a default definition with an id and an effect or setup
# function"); a mistake there disables the pacer for every session. Two
# default exports is a SyntaxError (the 2026-11-02 installer had exactly
# that), and `effect:` pointed at a plain function wedges plugin activation.
PLUGIN=plugin/saia-gwdg-plugin.js
if [[ "$(grep -c '^export default' "$PLUGIN")" -ne 1 ]]; then
  echo "ERROR: $PLUGIN must have exactly one 'export default' (found $(grep -c '^export default' "$PLUGIN"))" >&2
  exit 1
fi
if ! grep -qE '^export default \{ id: "saia-gwdg", setup \};$' "$PLUGIN"; then
  echo "ERROR: $PLUGIN default export must be '{ id: \"saia-gwdg\", setup }' (opencode v2 plugin API)" >&2
  exit 1
fi
if command -v node >/dev/null 2>&1; then
  node --check "$PLUGIN" || { echo "ERROR: $PLUGIN does not parse" >&2; exit 1; }
else
  echo "WARNING: node not found — skipping the syntax check of $PLUGIN" >&2
fi

# --minimal's default model: ROLE_MODELS.build[0], read from the plugin so that
# re-pinning `build` there moves the minimal default too (no second copy).
DEFAULT_MODEL="$(sed -nE 's/^ *build: *\["([^"]+)".*/\1/p' "$PLUGIN" | head -1)"
if [[ -z "$DEFAULT_MODEL" ]]; then
  echo "ERROR: could not read ROLE_MODELS.build[0] from $PLUGIN (the --minimal default model)" >&2
  exit 1
fi

COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY=""
git diff --quiet HEAD -- "${MANIFEST[@]}" 2>/dev/null || DIRTY="-dirty"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

TMP_OUT="$(mktemp "$OUT.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT

# ── Header (interpolates the stamp) ──────────────────────────────────
cat >"$TMP_OUT" <<OC_GEN_HEADER
#!/usr/bin/env bash
#
# setup-saia-opencode.sh — GENERATED FILE, DO NOT EDIT.
# Regenerate with: ./build-setup.sh  (in the opencode config repo)
# Source: opencode-config commit $COMMIT$DIRTY, packed $STAMP
#
# Installs the GWDG SAIA setup for opencode: provider + plugin, the four
# subagents (coder, coder2, researcher, debugger — as auto-discovered
# agent/*.md files), the slash commands, and the two OPTIONAL primary agents
# (solo, auto). Use flags or interactive prompts to choose the primaries.
# --minimal installs ONLY the provider + plugin (no agents, no commands).
#
# Usage: [GWDG_API_KEY=... GWDG_API_KEYS_EXTRA=key2,key3] bash setup-saia-opencode.sh [OPTIONS]
#

# Default model of a --minimal install (ROLE_MODELS.build[0] at pack time).
MINIMAL_DEFAULT_MODEL="saia-gwdg/$DEFAULT_MODEL"
OC_GEN_HEADER

# ── Static installer body ────────────────────────────────────────────
cat >>"$TMP_OUT" <<'OC_GEN_BODY'
set -euo pipefail

# Windows = Git Bash (setup-saia-opencode.cmd launches it). opencode resolves ~
# via os.homedir(), i.e. %USERPROFILE%, while Git Bash prefers a custom %HOME%
# if one is set — pin HOME so every path below is the one opencode reads.
IS_WINDOWS=0
case "$(uname -s)" in MINGW*|MSYS*) IS_WINDOWS=1 ;; esac
if [[ $IS_WINDOWS -eq 1 && -n "${USERPROFILE:-}" ]]; then
  HOME="$(cygpath -u "$USERPROFILE")"
fi
# Windows Python defaults to cp1252; opencode.jsonc is UTF-8 (em dashes).
export PYTHONUTF8=1

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
DATA_DIR="$HOME/.local/share/opencode"   # the plugin hardcodes this path
AUTH_FILE="$DATA_DIR/auth.json"          # only to move an old key out of it
BACKUP_DIR=""
ASSUME_YES=0
FORCE_KEY=0
INSTALL_SOLO=2
INSTALL_AUTO=2
MINIMAL=2
OPENCODE_MISSING=0

# --minimal installs only these; every other packed file is "full-only" and is
# skipped by write_file (and recorded in SKIPPED_FULL, the exact list
# remove_full_only_files backs up and deletes over an earlier full install).
MINIMAL_FILES=(opencode.jsonc plugin/saia-gwdg-plugin.js)
SKIPPED_FULL=()

usage() {
  cat <<'USAGE'
Usage: [GWDG_API_KEY=... GWDG_API_KEYS_EXTRA=key2,key3] bash setup-saia-opencode.sh [OPTIONS]

Installs the GWDG SAIA setup for opencode:
  - opencode.jsonc, plugin/, command/, scripts/, agent/*.md, prompts/*.md
    into ~/.config/opencode
  - API key into opencode's own credential store (opencode auth list) — a
    key left in ~/.local/share/opencode/auth.json by an older install is
    moved there and removed from auth.json
  - optional extra failover keys (GWDG_API_KEYS_EXTRA, comma-separated) into
    ~/.local/share/opencode/saia-gwdg-keys.json (chmod 600) — the plugin
    switches to the next key when the active one's rate budget is exhausted
  - offers to install opencode itself if missing
  - subagents @coder, @coder2, @researcher, @debugger — installed as
    agent/*.md (unless --minimal), usable from any primary (including the
    built-in build agent)
  - optional PRIMARY agents: solo (default workhorse), auto (orchestrator)
    (default: prompt interactively unless --yes is passed)

--minimal installs ONLY the SAIA provider: opencode.jsonc (provider block +
a default saia-gwdg model) and the plugin (live model list, rate pacing, key
rotation, stall retry) — no agents, slash commands, prompts or yagni.md. Run
over an earlier full install, it backs up and removes the files that install
shipped. Rerun without --minimal to get the full setup back.

Requires python3 (Windows: python.org Python; run setup-saia-opencode.cmd,
which needs Git for Windows).

Options:
  -y, --yes        answer yes to prompts (e.g. installing opencode)
       --minimal   SAIA provider + plugin only (default: ask, unless any
                   other agent flag or --yes is given)
       --solo      install the solo primary agent (default: ask)
       --auto      install the auto primary agent (default: ask)
       --no-solo   skip the solo primary agent (default: ask)
       --no-auto   skip the auto primary agent (default: ask)
       --force-key replace an existing saia-gwdg API key
  -h, --help       show this help

The API key is taken from the GWDG_API_KEY environment variable if set,
otherwise prompted for interactively (with opencode installed and a key
already stored, you are asked whether to keep it — answer 'n' to enter a
new one). It is checked against SAIA (GET /v1/models, the key piped to
curl on stdin, never on a command line) BEFORE any file is written: an
expired/revoked key aborts the run with SAIA's own message and leaves the
existing install untouched. Files that would be overwritten are backed up
to ~/.config/opencode.bak-<timestamp>/ first. Without opencode installed
no key is stored; run 'opencode auth login saia-gwdg --standalone' later.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    --force-key) FORCE_KEY=1 ;;
    --minimal) MINIMAL=1 ;;
    --solo) INSTALL_SOLO=1 ;;
    --auto) INSTALL_AUTO=1 ;;
    --no-solo) INSTALL_SOLO=0 ;;
    --no-auto) INSTALL_AUTO=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# First Python that actually RUNS — `command -v python3` is not enough: on
# Windows the Microsoft Store alias python3.exe is on PATH but exits 9009, and
# python.org installs `python`/`py`, not `python3`. Required, and checked before
# anything is written: without it the jsonc filter would be skipped while the
# declined primaries' prompts are still deleted (dangling {file:...}).
PY=""
for c in python3 python "py -3"; do
  $c -c '' >/dev/null 2>&1 && { PY=$c; break; }   # unquoted: "py -3" is two words
done
if [[ -z "$PY" ]]; then
  echo "ERROR: python3 is required (Windows: install Python from python.org)." >&2
  exit 1
fi

# Install mode. --minimal ships no agents, so it cannot be combined with a
# primary; any agent flag or --yes means the full install (which keeps --yes
# doing what it always did: full setup, no primaries).
if [[ $MINIMAL -eq 1 ]]; then
  if [[ $INSTALL_SOLO -eq 1 || $INSTALL_AUTO -eq 1 ]]; then
    echo "ERROR: --minimal installs no agents — it cannot be combined with --solo/--auto." >&2
    exit 2
  fi
elif [[ $INSTALL_SOLO -ne 2 || $INSTALL_AUTO -ne 2 || $ASSUME_YES -eq 1 ]]; then
  MINIMAL=0
elif [[ -t 0 ]]; then
  read -r -p "Minimal install — SAIA provider + plugin only, no agents/commands? [y/N] " reply
  if [[ $reply == [yY]* ]]; then
    MINIMAL=1
  else
    MINIMAL=0
  fi
else
  MINIMAL=0
fi
if [[ $MINIMAL -eq 1 ]]; then
  INSTALL_SOLO=0
  INSTALL_AUTO=0
fi

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

# The plugin targets the opencode v2 plugin API (`export default {id, setup}`);
# opencode 1.x cannot load it.
check_opencode_version() {
  local v major
  v="$(opencode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  major="${v%%.*}"
  if [[ -n "$major" ]] && (( major < 2 )); then
    log "WARNING: opencode $v is older than 2.0 — the SAIA plugin needs opencode >= 2."
    log "         Run 'opencode upgrade', then rerun this installer."
  fi
}

ensure_opencode() {
  export PATH="$HOME/.opencode/bin:$PATH"
  if command -v opencode >/dev/null 2>&1; then
    log "opencode found: $(command -v opencode) ($(opencode --version 2>/dev/null || echo '?'))"
    check_opencode_version
    return 0
  fi
  if confirm "opencode is not installed. Run the official installer now (curl -fsSL https://opencode.ai/install | bash)?"; then
    curl -fsSL https://opencode.ai/install | bash \
      || die "opencode install failed. Alternatives: npm i -g opencode-ai (any OS), scoop install opencode / choco install opencode (Windows) — then rerun."
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
  # ponytail: hint only — editing the Windows user PATH programmatically
  # (SetEnvironmentVariable) flattens its REG_EXPAND_SZ %VAR% entries.
  if [[ $IS_WINDOWS -eq 1 && "$(command -v opencode)" == "$HOME/.opencode/bin/"* ]]; then
    log "Windows: the line above only helps Git Bash. To run opencode from PowerShell/cmd,"
    log "  add %USERPROFILE%\\.opencode\\bin to your user PATH (Settings > 'environment variables')."
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
  if [[ $MINIMAL -eq 1 && " ${MINIMAL_FILES[*]} " != *" $rel "* ]]; then
    cat >/dev/null   # consume the heredoc
    SKIPPED_FULL+=("$rel")
    return 0
  fi
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

# ── API key: resolve + validate BEFORE any file is rewritten ──────────
# A rejected key (expired/revoked) makes the plugin register zero models, so
# opencode shows no SAIA models and silently falls back to another provider —
# the install looks broken while every file is in place. Check the key first,
# while the existing config is still untouched; a 401 aborts the run.
SAIA_MODELS_URL="https://chat-ai.academiccloud.de/v1/models"
KEY=""            # the key this run has resolved (empty: none available yet)
KEY_SOURCE=""     # stored | env | legacy | prompted
KEY_ERROR=""      # SAIA's own error message from the last check
KEY_HTTP=""       # HTTP status of the last check

# Trims leading/trailing whitespace. A trailing \r (Windows env var) or a
# pasted newline turns into an invalid Authorization header and a 401.
trim_key() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# The saia-gwdg key of an install from before the credential store (auth.json,
# which opencode v2 never reads). Empty when there is none.
legacy_key() {
  [[ -f "$AUTH_FILE" ]] || return 0
  AUTH_FILE="$AUTH_FILE" $PY -c '
import json, os
print(json.load(open(os.environ["AUTH_FILE"])).get("saia-gwdg", {}).get("key", ""))
' 2>/dev/null || true
}

# GET /v1/models with one key: 0 = accepted, 1 = rejected (401/403), 2 = could
# not verify (network/other HTTP). Sets KEY_HTTP and KEY_ERROR.
check_saia_key() {
  local resp code body
  KEY_ERROR=""; KEY_HTTP=""
  if ! command -v curl >/dev/null 2>&1; then
    KEY_ERROR="curl not found"
    return 2
  fi
  # The key travels in a curl config on stdin (-K -), never on the command
  # line: argv is visible in ps / Task Manager / WMI — the same invariant the
  # opencode auth calls keep ("key never on a command line").
  if ! resp="$(printf 'header = "Authorization: Bearer %s"\n' "$1" | \
      curl -sS --max-time 30 -K - -w '\n%{http_code}' "$SAIA_MODELS_URL" 2>/dev/null)"; then
    KEY_ERROR="network error"
    return 2
  fi
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  KEY_HTTP="$code"
  KEY_ERROR="$(printf '%s' "$body" | $PY -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print((d.get("error") or {}).get("message") or d.get("message") or "")
except Exception:
    print("")
' 2>/dev/null)" || KEY_ERROR=""
  case "$code" in
    200) return 0 ;;
    401|403) return 1 ;;
    *) KEY_ERROR="${KEY_ERROR:-HTTP $code}"; return 2 ;;
  esac
}

# Whether `opencode auth list` shows a stored saia-gwdg credential — the same
# command setup_auth_key trusts to keep a key. Used when `auth export` fails
# (older opencode without that subcommand, transient private-server error):
# a key IS stored, it just cannot be read out for validation.
saia_cred_stored() {
  opencode auth list --standalone --format json 2>/dev/null | $PY -c '
import json, sys
try:
    for i in json.load(sys.stdin):
        if i.get("id") == "saia-gwdg":
            if any(c.get("type") == "credential" for c in i.get("connections", [])):
                print("yes")
            break
except Exception:
    pass
' 2>/dev/null | grep -q '^yes$'
}

# Same precedence as setup_auth_key: an existing stored key wins unless
# --force-key, then GWDG_API_KEY, then the legacy auth.json key, then a prompt.
resolve_saia_key() {
  local stored="" k="" reply=""
  if [[ $OPENCODE_MISSING -eq 0 ]]; then
    stored="$(opencode auth export saia-gwdg --standalone 2>/dev/null | $PY -c '
import json, sys
try:
    creds = [c for c in json.load(sys.stdin)
             if c.get("integrationID") == "saia-gwdg"
             and c.get("value", {}).get("type") == "key"]
    creds.sort(key=lambda c: not c.get("active"))
    print(creds[0]["value"]["key"] if creds else "")
except Exception:
    print("")
' 2>/dev/null)" || stored=""
    stored="$(trim_key "$stored")"
  fi
  if [[ -n "$stored" && $FORCE_KEY -eq 0 ]]; then
    KEY="$stored"; KEY_SOURCE=stored
    # Interactive runs get a say: silently reusing a stored key reads as
    # "it never asked me for my key". Enter keeps it; anything starting with
    # n/N asks for a new one (same effect as --force-key from here on).
    if [[ -t 0 ]]; then
      read -r -p "An saia-gwdg API key is already stored — keep it? [Y/n] " reply
      if [[ $reply == [nN]* ]]; then
        FORCE_KEY=1
        KEY=""; KEY_SOURCE=""
      fi
    fi
    [[ -n "$KEY" ]] && return 0
  fi
  if [[ $FORCE_KEY -eq 0 && $OPENCODE_MISSING -eq 0 ]] && saia_cred_stored; then
    # auth export failed but a key IS stored: keep it rather than fall through
    # to a prompt — a prompt here would import a new key and log the stored,
    # possibly perfectly valid one out in setup_auth_key. Kept unvalidated.
    KEY=""; KEY_SOURCE=stored
    log "NOTE: could not read the stored saia-gwdg key for validation"
    log "      ('opencode auth export' failed) — it will be kept unchanged."
    return 0
  fi
  k="$(trim_key "${GWDG_API_KEY:-}")"
  if [[ -n "$k" ]]; then
    KEY_SOURCE=env
  elif [[ $FORCE_KEY -eq 0 ]]; then
    k="$(trim_key "$(legacy_key)")"
    [[ -n "$k" ]] && KEY_SOURCE=legacy
  fi
  if [[ -z "$k" ]]; then
    # Without opencode nothing can be stored; setup_auth_key prints the login
    # hint instead. With opencode, get the key now, before anything is written.
    [[ $OPENCODE_MISSING -eq 1 ]] && return 0
    if [[ -t 0 ]]; then
      read -r -s -p "Enter your GWDG/SAIA API key (Academic Cloud portal): " k
      echo
      k="$(trim_key "$k")"
      [[ -n "$k" ]] && KEY_SOURCE=prompted
    else
      die "No GWDG_API_KEY set and no terminal to prompt — export GWDG_API_KEY and rerun."
    fi
  fi
  KEY="$k"
}

validate_saia_key() {
  [[ -n "$KEY" ]] || return 0
  local st=0 where="the API key"
  check_saia_key "$KEY" || st=$?
  case "$st" in
    0)
      log "API key validated against SAIA (GET /v1/models)."
      ;;
    1)
      case "$KEY_SOURCE" in
        stored)   where="the stored saia-gwdg key" ;;
        legacy)   where="the key in $AUTH_FILE" ;;
        env)      where="GWDG_API_KEY" ;;
        prompted) where="the key you entered" ;;
      esac
      die "SAIA rejected $where${KEY_ERROR:+ — \"$KEY_ERROR\"}. No SAIA files were changed.
  Create a fresh key in the Academic Cloud portal, then either:
    - store it:  opencode auth login saia-gwdg --standalone
    - or rerun:  GWDG_API_KEY=<new-key> bash $0 --force-key"
      ;;
    *)
      log "WARNING: could not validate the API key (${KEY_ERROR:-HTTP ${KEY_HTTP:-?}}) — continuing."
      ;;
  esac
}

ensure_opencode

resolve_saia_key
validate_saia_key

if [[ $OPENCODE_MISSING -eq 0 ]]; then
  ensure_path_in_shellrc
fi

if [[ $MINIMAL -eq 1 ]]; then
  log "Installing the minimal SAIA config (provider + plugin only) to $CONFIG_DIR"
else
  log "Installing SAIA config to $CONFIG_DIR"
fi
OC_GEN_BODY

# ── Embedded config files ────────────────────────────────────────────
# pack <src> [dest]  — append an install-time `write_file` heredoc that writes
# <src>'s contents to <dest> (relative to CONFIG_DIR; dest defaults to src).
pack() {
  local src="$1" dest="${2:-$1}"
  printf '\nwrite_file "%s" <<\'"'"'%s'"'"'\n' "$dest" "$DELIM" >>"$TMP_OUT"
  cat "$src" >>"$TMP_OUT"
  printf '%s\n' "$DELIM" >>"$TMP_OUT"
}

# Main config (filtered at install time), auto-discovered plugin, global
# instruction file, and the command markdown (/usage, /reload_models).
pack opencode.jsonc
pack plugin/saia-gwdg-plugin.js
pack yagni.md
pack command/usage.md
pack command/reload_models.md
pack command/effort.md

# Real backing scripts for the commands (previously shipped as broken stubs).
pack scripts/usage.sh
pack scripts/reload-models.sh
pack scripts/effort.sh

# Subagent definitions (frontmatter + prompt in one file), auto-discovered by
# opencode from agent/. These ship with every non --minimal install — the filter
# only ever touches the two optional primaries in opencode.jsonc.
for a in "${AGENT_FILES[@]}"; do pack "$a"; done

# Prompts for the two optional PRIMARIES only. They stay separate files (rather
# than agent/*.md bodies) because both carry __SAIA_BUDGET_STATUS__ and are
# templated by the plugin at startup, and because the installer may decline
# either one. cleanup_disabled_prompts removes a declined primary's prompt.
for p in prompts/*.md; do pack "$p"; done

# Custom tools + skills — folder-driven, so files added later ship automatically.
# tool/*.{js,ts} (non-recursive); skill/**/SKILL.md (recursive). nullglob → skip when empty.
shopt -s nullglob globstar
for t in tool/*.js tool/*.ts; do pack "$t"; done
for s in skill/**/SKILL.md; do pack "$s"; done
shopt -u nullglob globstar

# ── Footer: API key + verification ───────────────────────────────────
cat >>"$TMP_OUT" <<'OC_GEN_FOOTER'

# The key lives in opencode's own credential store — the only place opencode v2
# reads keys from, and where `opencode auth login saia-gwdg` puts it. That
# command needs a terminal for the key, so the installer pipes it to
# `opencode auth import` on stdin instead: never on a command line. The key was
# resolved and validated earlier (resolve_saia_key/validate_saia_key, before
# any file was written); this only stores the one that survived that check.
# Each `--standalone` call starts a private server, so this runs after the
# config files are final.
setup_auth_key() {
  if [[ $OPENCODE_MISSING -eq 1 ]]; then
    log "No API key stored (opencode keeps it in its own credential store)."
    # --standalone: a plain `auth login` would start the background service
    # with the plugin loaded before the key exists, i.e. inactive.
    log "After installing opencode, run: opencode auth login saia-gwdg --standalone"
    return 0
  fi
  local stored id old
  stored="$(opencode auth list --standalone --format json | $PY -c '
import json, sys
for i in json.load(sys.stdin):
    if i.get("id") == "saia-gwdg":
        print(" ".join(c["id"] for c in i.get("connections", []) if c.get("type") == "credential"))
')" || die "Could not read opencode's credentials ('opencode auth list --standalone' failed, see above)."
  if [[ $KEY_SOURCE == stored && $FORCE_KEY -eq 0 ]]; then
    log "Existing saia-gwdg API key kept${KEY:+ (validated)} (use --force-key to replace)."
    drop_legacy_key
    return 0
  fi
  if [[ -z "$KEY" ]]; then die "No API key provided."; fi
  if [[ $KEY_SOURCE == legacy ]]; then
    log "Moving the saia-gwdg API key from $AUTH_FILE into opencode's credential store."
  fi
  id="cred_saia_$(date +%s)_$$"
  KEY="$KEY" ID="$id" $PY -c '
import json, os
print(json.dumps([{"id": os.environ["ID"], "integrationID": "saia-gwdg", "label": "SAIA (GWDG)",
                   "active": True, "value": {"type": "key", "key": os.environ["KEY"]}}]))
' | opencode auth import --standalone >/dev/null \
    || die "Could not store the API key ('opencode auth import --standalone' failed, see above)."
  # --force-key: import never activates over an existing key — switch, then
  # log the replaced one out, so opencode holds exactly one saia-gwdg key.
  if [[ -n "$stored" ]]; then
    opencode auth switch saia-gwdg "$id" --standalone >/dev/null \
      || die "Could not activate the new API key ('opencode auth switch saia-gwdg $id --standalone' failed, see above)."
    for old in $stored; do
      opencode auth logout saia-gwdg "$old" --standalone >/dev/null \
        || log "WARNING: the replaced key is still stored — run: opencode auth logout saia-gwdg $old"
    done
  fi
  log "API key stored in opencode's credential store (see: opencode auth list)."
  drop_legacy_key
}

# Removes that old copy (backed up first); other providers' entries stay.
drop_legacy_key() {
  [[ -f "$AUTH_FILE" ]] && grep -q '"saia-gwdg"' "$AUTH_FILE" || return 0
  backup_existing "auth.json" "$AUTH_FILE"
  if ( umask 077; AUTH_FILE="$AUTH_FILE" $PY - <<'PYEOF'
import json, os
path = os.environ["AUTH_FILE"]
data = json.load(open(path))
data.pop("saia-gwdg", None)
if data:
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)
else:
    os.remove(path)
PYEOF
  ); then
    log "Removed the old saia-gwdg key from $AUTH_FILE (backup in $BACKUP_DIR)."
  else
    log "WARNING: could not remove the old saia-gwdg key from $AUTH_FILE — delete its \"saia-gwdg\" entry by hand."
  fi
}

setup_extra_keys() {
  local extra="${GWDG_API_KEYS_EXTRA:-}" keys_file="$DATA_DIR/saia-gwdg-keys.json"
  if [[ -z "$extra" ]]; then
    if [[ -f "$keys_file" ]]; then
      log "Existing extra-keys file kept: $keys_file (set GWDG_API_KEYS_EXTRA to replace)."
    fi
    return 0
  fi
  if [[ -f "$keys_file" ]]; then
    backup_existing "saia-gwdg-keys.json" "$keys_file"
  fi
  mkdir -p "$DATA_DIR"
  ( umask 077; EXTRA="$extra" KEYS_FILE="$keys_file" $PY - <<'PYEOF'
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

  ( umask 077; $PY - "$input" "$CONFIG_DIR" <<'PYEOF'
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

  ( umask 077; $PY - "$input" "$INSTALL_SOLO" "$INSTALL_AUTO" "$MINIMAL" "$MINIMAL_DEFAULT_MODEL" <<'PYEOF'
import json, re, sys
input_path = sys.argv[1]
install_solo = int(sys.argv[2])
install_auto = int(sys.argv[3])
minimal = int(sys.argv[4])
default_model = sys.argv[5]

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

# --minimal: the provider block and nothing else (no instructions, no agent
# stubs), plus a default model so opencode starts on SAIA. Derived from the
# same opencode.jsonc, so the provider block (chunkTimeout invariant included)
# has one source.
if minimal == 1:
    data = {k: data[k] for k in ("$schema", "provider") if k in data}
    data["model"] = default_model

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
    data.pop("agent", None)
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
  if [[ $MINIMAL -eq 1 ]]; then
    log "  filtered: $input (minimal: provider only, model=$MINIMAL_DEFAULT_MODEL)"
  else
    log "  filtered: $input (solo=$INSTALL_SOLO, auto=$INSTALL_AUTO)"
  fi
}

# Clean up prompt files that are disabled
cleanup_disabled_prompts() {
  # Only the two PRIMARY prompts are optional, and they are independent of each
  # other. Nothing else may be removed: each subagent's prompt is the body of
  # its own agent/*.md and always installs. The old cross-conditions here were
  # the install-time coupling — including the bug where "--auto --no-solo" left
  # auto's mandatory @debugger validator undefined.
  # (--minimal: remove_full_only_files handles both prompts, with a backup.)
  if [[ $INSTALL_SOLO -eq 0 && $MINIMAL -eq 0 ]]; then
    rm -f "$CONFIG_DIR/prompts/solo.md"
    log "  removed (disabled): prompts/solo.md"
  fi

  if [[ $INSTALL_AUTO -eq 0 && $MINIMAL -eq 0 ]]; then
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

# --minimal over an earlier full install: back up and delete exactly the files
# the full install ships (SKIPPED_FULL, recorded by write_file), then any
# directory that left empty. A user's own files (e.g. a self-written
# agent/foo.md) are not in that list and stay.
remove_full_only_files() {
  [[ $MINIMAL -eq 1 ]] || return 0
  local rel d
  # ${a[@]+...}: an empty array is "unbound" under set -u in bash < 4.4 (macOS)
  for rel in ${SKIPPED_FULL[@]+"${SKIPPED_FULL[@]}"}; do
    [[ -e "$CONFIG_DIR/$rel" ]] || continue
    backup_existing "$rel" "$CONFIG_DIR/$rel"
    rm -f "$CONFIG_DIR/$rel"
    log "  removed (not part of --minimal): $rel"
    d="$(dirname "$rel")"
    while [[ $d != "." ]]; do
      rmdir "$CONFIG_DIR/$d" 2>/dev/null || break
      log "  removed empty dir: $d/"
      d="$(dirname "$d")"
    done
  done
}

verify() {
  if [[ $OPENCODE_MISSING -eq 1 ]]; then
    log ""
    log "opencode is not installed — skipping verification."
    log "After installing opencode and storing the key, verify with: opencode models | grep '^saia-gwdg/'"
    return 0
  fi
  # opencode v2 runs a shared background service that has the OLD plugin and
  # config loaded. Stop it: the next `opencode` starts a fresh one on the files
  # just written. Interrupts sessions running in that service. A wedged service
  # (seen right after the 2.2.5 upgrade: "Server process N is still running")
  # refuses to stop — that is a warning, never an install failure.
  local st pid
  if st="$(opencode service status 2>/dev/null)" && [[ $st != stopped ]]; then
    log "Stopping the opencode background service so it reloads the new plugin..."
    if ! opencode service stop >/dev/null 2>&1; then
      pid="$(sed -nE 's/.*"pid":([0-9]+).*/\1/p' "${XDG_STATE_HOME:-$HOME/.local/state}/opencode/service.json" 2>/dev/null || true)"
      pid="${pid:-<pid from ~/.local/state/opencode/service.json>}"
      log "WARNING: 'opencode service stop' failed — the background service is stuck."
      if [[ $IS_WINDOWS -eq 1 ]]; then
        log "         Before starting opencode, run: taskkill /F /PID $pid"
      else
        log "         Before starting opencode, run: kill $pid"
      fi
    fi
  fi
  log ""
  # --standalone: check the files just written in a fresh process, independent
  # of the shared service's health and of whatever it still has loaded.
  log "Verifying (lists the GWDG models — at most 1 request of the shared rate budget)..."
  local out count
  if out="$(opencode models --standalone 2>&1)" && grep -q '^saia-gwdg/' <<<"$out"; then
    count="$(grep -c '^saia-gwdg/' <<<"$out")"
    log "SUCCESS: $count saia-gwdg models available."
    if [[ -n "$BACKUP_DIR" ]]; then
      log "Previous files were backed up to $BACKUP_DIR"
    fi
    log ""
    if [[ $MINIMAL -eq 1 ]]; then
      log "Next steps: run 'opencode' — it starts on $MINIMAL_DEFAULT_MODEL with the"
      log "built-in agents (build, plan); switch SAIA models with /models."
      log "The plugin caches the model list for ~7 days; to refresh it sooner,"
      log "delete ~/.cache/opencode/saia-gwdg-models.json and restart opencode."
      log "Rerun this installer without --minimal for the subagents and commands."
      return 0
    fi
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
      echo "FAILED: no saia-gwdg models listed. The config files ARE installed — only this check failed."
      echo "Last lines of 'opencode models --standalone':"
      tail -n 15 <<<"${out:-(no output)}" | sed 's/^/  | /'
      echo "Troubleshooting:"
      echo "  - Invalid, expired or missing API key (the plugin fails silently) — check"
      echo "    'opencode auth list'; replace it with: opencode auth login saia-gwdg"
      echo "  - GWDG rate limit exhausted (2 req/10s, 200/hour per key) — wait and retry."
      echo "  - Stale cache: rm ~/.cache/opencode/saia-gwdg-models.json and retry."
    } >&2
    exit 1
  fi
}

if [[ $MINIMAL -eq 0 ]]; then   # --minimal writes no scripts (set -e!)
  chmod 755 "$CONFIG_DIR/scripts/reload-models.sh" "$CONFIG_DIR/scripts/usage.sh" "$CONFIG_DIR/scripts/effort.sh"
fi
filter_opencode_jsonc
fix_instructions_path
cleanup_disabled_prompts
remove_full_only_files
setup_auth_key
setup_extra_keys
verify
OC_GEN_FOOTER

# ── Finalize ─────────────────────────────────────────────────────────
bash -n "$TMP_OUT"
chmod +x "$TMP_OUT"
mv "$TMP_OUT" "$OUT"
trap - EXIT
echo "Wrote $OUT ($(wc -c <"$OUT") bytes, source $COMMIT$DIRTY, packed $STAMP)"
if [[ -n "$DIRTY" ]]; then
  echo "WARNING: manifest files have uncommitted changes — installer packs the dirty working tree" >&2
fi

#!/usr/bin/env bash
# retainer: bring the machine up to what retainer runs on — a check by default, an install on request.
#
#   retainer-install.sh                       check: what is present, what is missing, how it gets installed
#   retainer-install.sh --summary             one line when a required or recommended tool is missing, else nothing
#   retainer-install.sh --install <group>...  install the groups: recommended · pages · ghostrefs
# exit 0 — the required group is complete (check) / every install step succeeded · 1 — a required tool
#      is missing / an install step failed or cannot run here · 2 — usage
#
# complexity: keep, step 7 — nothing else looks at the machine; a missing tool surfaces as the first failed hook
#
# Plain bash 3.2 and no python: the script must run on a machine that has neither a real python3 nor brew.
# What needs an administrator password — Apple's developer tools and Homebrew — is never run from here:
# the person runs the printed lines in Terminal. On Linux nothing is installed, the apt lines are printed.
# The DeepSeek key is reported as set or missing; its value is never read into output.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/retainer-config.sh
. "$ROOT/bin/retainer-config.sh"   # retainer_cfg: flat keys of the global config, awk only
OS="${RETAINER_INSTALL_OS:-$(uname -s)}"
XCODE_SELECT="${RETAINER_XCODE_SELECT:-xcode-select}"
STUB_DIR="${RETAINER_STUB_DIR:-/usr/bin}"
KEY_PATH="${RETAINER_DEEPSEEK_KEY_PATH:-$HOME/.config/retainer/deepseek_key}"
BREW_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
# The agent merge path: a root-owned copy of the engine script the owner allows the agent to run. Its
# tracker address is a constant in the copy, taken from the engine script itself.
GATED_SRC="$ROOT/bin/retainer-merge-gated.sh"
# The only directory the gated script trusts itself in is its own INSTALL_DIR, read from the script.
# The value up to the first blank: a trailing comment is not part of it. Several such lines are
# refused in gated_path_ok, not resolved here.
GATED_PATH="${RETAINER_GATED_PATH:-$(sed -n 's/^INSTALL_DIR=\([^[:space:]]*\).*/\1/p' "$GATED_SRC" 2>/dev/null)/retainer-merge-gated.sh}"
GATED_OWNER="${RETAINER_GATED_OWNER:-root}"
GATED_DEFAULT_TRACKER="$(sed -n 's/^INSTALLED_TRACKER=//p' "$GATED_SRC" 2>/dev/null)"
# Where the installers put their tools without adding them to a running session's PATH: Homebrew on
# Apple Silicon, uv tools, cargo. Searched here too, so a fresh install is found at once; a tool found
# only there is reported as "not on PATH" with the line that adds it, because the session cannot run it.
SESSION_PATH="$PATH"
EXTRA_PATH="${RETAINER_INSTALL_EXTRA_PATH-/opt/homebrew/bin /usr/local/bin $HOME/.local/bin $HOME/.cargo/bin}"
for dir in $EXTRA_PATH; do
  [ -d "$dir" ] || continue
  case ":$PATH:" in *":$dir:"*) ;; *) PATH="$PATH:$dir" ;; esac
done
export PATH

usage(){ echo "usage: retainer-install.sh [--summary | --install recommended|pages|ghostrefs ...]" >&2; exit 2; }

# group|tool|what it gives|how it is installed (brew:<pkg> · uv-tool:<pkg> · npm:<pkg> · cargo:<pkg> · - = by the person)
TABLE='required|devtools|Apple developer tools: git and python3|-
required|git|version control|-
required|python3|runs the hooks and the guard|-
required|curl|talks to the tracker|-
brew|brew|Homebrew: installs everything below|-
recommended|uv|Python 3.12 and project environments|brew:uv
recommended|graphify|code map: where a name is defined, who calls it|uv-tool:graphifyy
recommended|shellcheck|checks bash scripts in the gate|brew:shellcheck
pages|node|runs the page checks|brew:node
pages|biome|lints and formats page code|brew:biome
ghostrefs|cargo|Rust toolchain, builds ghostrefs|brew:rust
ghostrefs|pyright-langserver|Python references for ghostrefs|npm:pyright
ghostrefs|ghostrefs|finds code kept alive only by its tests|cargo:ghostrefs'

macos(){ [ "$OS" = Darwin ]; }

# Apple ships git and python3 as stubs that open a dialog: in the stub directory they count only with the
# developer tools in place. Every other tool there (curl) is real.
devtools(){ macos || return 0; "$XCODE_SELECT" -p >/dev/null 2>&1; }

present(){ # present <tool> — exit 0 when the tool is usable
  local found
  case "$1" in
    devtools) devtools; return ;;
    python3) sh "$ROOT/hooks/retainer-python" --check; return ;;
  esac
  found="$(command -v "$1" 2>/dev/null)" || return 1
  [ "$1" = git ] && macos || return 0
  case "$found" in "$STUB_DIR"/*) devtools ;; *) return 0 ;; esac
}

shown(){ # shown <group> <tool> — the row exists on this system
  macos && return 0
  case "$1:$2" in brew:*|required:devtools) return 1 ;; esac
  return 0
}

key_status(){
  [ -n "${DEEPSEEK_API_KEY:-}" ] && { echo "set (environment)"; return; }
  grep -q '[^[:space:]]' "$KEY_PATH" 2>/dev/null && { echo "set"; return; }
  echo "missing"
}

on_session_path(){ # on_session_path <tool> — the session itself can run the tool
  case "$1" in devtools|python3) return 0 ;; esac
  PATH="$SESSION_PATH" command -v "$1" >/dev/null 2>&1
}

path_line(){ # path_line <tool> — the shell line that puts the tool's directory on PATH
  local dir
  dir="$(dirname "$(command -v "$1")")"
  case "$dir" in
    "$HOME/.local/bin") echo "uv tool update-shell" ;;
    */homebrew/bin|/usr/local/bin) echo "echo 'eval \"\$($dir/brew shellenv)\"' >> ~/.zprofile" ;;
    *) echo "echo 'export PATH=\"$dir:\$PATH\"' >> ~/.zprofile" ;;
  esac
}

missing_in(){ # missing_in <group...> — names of tools the session cannot run, space-separated
  local want="$*" group tool rest out=""
  while IFS='|' read -r group tool rest; do
    case " $want " in *" $group "*) ;; *) continue ;; esac
    shown "$group" "$tool" || continue
    { present "$tool" && on_session_path "$tool"; } || out="$out $tool"
  done <<EOF
$TABLE
EOF
  echo "${out# }"
}

terminal_steps(){
  local need_dev="$1" need_brew="$2"
  [ -n "$need_dev$need_brew" ] || return 0
  echo
  echo "Run in Terminal yourself (they ask for your password), then run the check again:"
  [ -n "$need_dev" ] && echo "  xcode-select --install"
  [ -n "$need_brew" ] && echo "  /bin/bash -c \"\$(curl -fsSL $BREW_URL)\""
  [ -n "$need_brew" ] && echo "Then run the lines Homebrew prints under \"Next steps\" and restart the session."
}

linux_steps(){
  echo
  echo "On Linux nothing is installed from here. The commands:"
  echo "  sudo apt install git python3 curl shellcheck nodejs npm"
  echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"
  echo "  uv tool install graphifyy"
}

check(){
  local group tool what how title="" mark need_dev="" need_brew="" missing_required=0
  echo "retainer install — machine check ($OS)"
  while IFS='|' read -r group tool what how; do
    shown "$group" "$tool" || continue
    if [ "$group" != "$title" ]; then
      title="$group"
      case "$group" in
        required) echo; echo "REQUIRED — without these the hooks and the gate do not run" ;;
        brew) echo; echo "PACKAGE MANAGER" ;;
        recommended) echo; echo "RECOMMENDED" ;;
        pages) echo; echo "OPTIONAL: pages (install group: pages)" ;;
        ghostrefs) echo; echo "OPTIONAL: ghostrefs (install group: ghostrefs, ~1 GB)" ;;
      esac
    fi
    if present "$tool" && ! on_session_path "$tool"; then
      printf '  ! %-19s %s\n' "$tool" "installed, not on PATH — run in Terminal: $(path_line "$tool"), then restart the session"
      continue
    fi
    if present "$tool"; then mark="✓"; else
      mark="✗"
      [ "$group" = required ] && missing_required=1
      [ "$tool" = devtools ] && need_dev=1
      [ "$tool" = brew ] && need_brew=1
    fi
    printf '  %s %-19s %s\n' "$mark" "$tool" "$what"
  done <<EOF
$TABLE
EOF
  echo
  echo "SECOND OPINION"
  if [ "$(key_status)" = missing ]; then
    printf '  ✗ %-19s %s\n' "deepseek key" "missing — add it on the settings page: /retainer:settings"
  else
    printf '  ✓ %-19s %s\n' "deepseek key" "$(key_status)"
  fi
  echo
  echo "TRACKER — not installed from here: Gitea or GitLab, ONBOARDING.md step 4"
  gated_section
  if macos; then terminal_steps "$need_dev" "$need_brew"; else
    [ "$missing_required" = 1 ] && linux_steps
  fi
  return "$missing_required"
}

# gated_tracker — the tracker address the installed copy must carry. Fails when the configured value is
# not a plain http(s)://host[:port][/path]: the value is printed into a line the person runs under sudo.
gated_tracker(){
  local url
  url="$(retainer_cfg tracker_url "$GATED_DEFAULT_TRACKER")"
  url="${url%/}"
  printf '%s' "$url" | grep -qE '^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$' || return 1
  printf '%s' "$url"
}

gated_expected(){ # gated_expected <tracker> — the bytes the install lines write
  sed "s#^INSTALLED_TRACKER=.*#INSTALLED_TRACKER=$1#" "$GATED_SRC"
}

gated_state(){ # gated_state <tracker> — missing · differs · perms · current
  local meta
  [ -e "$GATED_PATH" ] || { echo missing; return; }
  gated_expected "$1" | cmp -s - "$GATED_PATH" || { echo differs; return; }
  # The path is trusted because only root can change it: identical bytes owned by anyone else are not it.
  if macos; then meta="$(stat -f '%Su %Lp' "$GATED_PATH" 2>/dev/null)"; else meta="$(stat -c '%U %a' "$GATED_PATH" 2>/dev/null)"; fi
  [ "$meta" = "$GATED_OWNER 755" ] && echo current || echo perms
}

gated_lines(){ # gated_lines <tracker> — the Terminal lines that install the copy; never run from here
  echo "    Run in Terminal yourself (they ask for your password):"
  echo "      sudo mkdir -p '${GATED_PATH%/*}'"
  if [ "$1" = "$GATED_DEFAULT_TRACKER" ]; then
    echo "      sudo install -m 755 '$GATED_SRC' '$GATED_PATH'"
  else
    echo "      sed 's#^INSTALLED_TRACKER=.*#INSTALLED_TRACKER=$1#' '$GATED_SRC' | sudo tee '$GATED_PATH' >/dev/null"
    echo "      sudo chown root '$GATED_PATH'"
    echo "      sudo chmod 755 '$GATED_PATH'"
  fi
}

# gated_path_ok — the install path is absolute, of plain characters, without . or .. segments, and
# (when derived) the script names its INSTALL_DIR exactly once: bash keeps the last of several lines,
# the reader takes the first, and a copy installed anywhere else runs untrusted.
gated_path_ok(){
  printf '%s' "$GATED_PATH" | grep -qE '^(/[A-Za-z0-9._-]+)+/[A-Za-z0-9._-]+$' || return 1
  printf '%s' "$GATED_PATH" | grep -qE '(^|/)\.\.?(/|$)' && return 1
  [ -n "${RETAINER_GATED_PATH:-}" ] && return 0
  [ "$(grep -c '^INSTALL_DIR=' "$GATED_SRC" 2>/dev/null)" = 1 ]
}

gated_section(){
  local tracker
  echo
  echo "AGENT MERGE PATH — optional: the agent merges a pull request itself once the merge lock and the gate"
  echo "are green. Without it every merge is your button. Speaks the Gitea API of tracker_url only."
  # The copy is trusted only at an absolute path of plain characters: a derivation gone wrong (no
  # INSTALL_DIR line, a quoted value) must not print install lines for somewhere else.
  if ! gated_path_ok; then
    printf '  ✗ %-19s %s\n' "merge-gated" "install path «${GATED_PATH}» is not one plain absolute path the script trusts — no install line is printed"
    return 0
  fi
  if ! tracker="$(gated_tracker)"; then
    printf '  ✗ %-19s %s\n' "tracker_url" "not a plain http(s) address in ~/.config/retainer/config.toml — no install line is printed"
    return 0
  fi
  case "$(gated_state "$tracker")" in
    current) printf '  ✓ %-19s %s\n' "merge-gated" "installed, root-owned, matches the engine copy" ;;
    differs) printf '  ! %-19s %s\n' "merge-gated" "installed, but differs from what the engine installs now — reinstall:"
             gated_lines "$tracker" ;;
    perms)   printf '  ! %-19s %s\n' "merge-gated" "matches the engine copy but is not $GATED_OWNER-owned with mode 755 — reinstall:"
             gated_lines "$tracker" ;;
    *)       printf '  ○ %-19s %s\n' "merge-gated" "not installed"
             gated_lines "$tracker"
             echo "    Then allow exactly that path in ~/.claude/settings.json, permissions.allow:"
             echo "      \"Bash($GATED_PATH *)\""
             echo "    and set merging to auto on the settings page: /retainer:settings" ;;
  esac
}

summary(){
  local missing
  missing="$(missing_in required brew recommended)"
  [ -n "$missing" ] || return 0
  echo "retainer: $(echo "$missing" | wc -w | tr -d ' ') tools missing (${missing// /, }) — run /retainer:install"
}

run_step(){ # run_step <command...> — prints the command and its outcome, and the reason of a failure
  local log
  log="$(mktemp)"
  printf '→ %s' "$*"
  if "$@" >"$log" 2>&1; then echo "  ✓"; rm -f "$log"; return 0; fi
  echo "  ✗"
  tail -5 "$log" | sed 's/^/    /'
  rm -f "$log"
  return 1
}

install_tool(){ # install_tool <how>
  case "$1" in
    brew:*) run_step brew install "${1#brew:}" ;;
    uv-tool:*) run_step uv tool install "${1#uv-tool:}" ;;
    npm:*)
      present npm || { echo "✗ ${1#npm:} needs npm: install the group pages first"; return 1; }
      run_step npm install -g "${1#npm:}" ;;
    cargo:*) run_step cargo install "${1#cargo:}" ;;
  esac
}

install(){
  local want="$*" group tool what how failed=0
  [ -n "$want" ] || usage
  for group in $want; do
    case "$group" in recommended|pages|ghostrefs) ;; *) usage ;; esac
  done
  if ! macos; then linux_steps; return 0; fi
  if ! present brew; then
    echo "Homebrew is missing, nothing can be installed yet."
    terminal_steps "$(devtools || echo 1)" 1
    return 1
  fi
  while IFS='|' read -r group tool what how; do
    case " $want " in *" $group "*) ;; *) continue ;; esac
    present "$tool" && { echo "· $tool is present, skipped"; continue; }
    install_tool "$how" || failed=1
  done <<EOF
$TABLE
EOF
  echo "Restart the session so it sees the new tools on its PATH."
  return "$failed"
}

case "${1:-}" in
  "") check ;;
  --summary) [ $# -eq 1 ] || usage; summary ;;
  --install) shift; install "$@" ;;
  *) usage ;;
esac

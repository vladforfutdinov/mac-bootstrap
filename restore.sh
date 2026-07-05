#!/usr/bin/env bash
# mac-bootstrap restore — on a fresh machine: shows what the old machine had,
# lets you pick items with checkboxes [+]/[ ] and installs the selection.
#
#   ./restore.sh              interactive checklist (gum), executes selection
#   ./restore.sh --dry-run    SAME interactive flow, but commands are printed,
#                             nothing is installed or changed
#   ./restore.sh --list       no TUI: print all items and exit
#   RESTORE_ALL=1 ./restore.sh [--dry-run]   no TUI, select everything
#
# bash 3.2 compatible (stock macOS).
set -uo pipefail   # no -e: a failed item must not kill the whole run
cd "$(dirname "$0")" || exit 1
REPO="$PWD"
US=$'\x1f'         # label/command separator inside an item
LOG=/tmp/mac-bootstrap-step.log

DRY=0 LIST=0
for a in "$@"; do case "$a" in
  --dry-run) DRY=1 ;;
  --list)    LIST=1 ;;
  *) echo "usage: $0 [--dry-run|--list]   (env: RESTORE_ALL=1)" >&2; exit 2 ;;
esac; done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAILURES="${FAILURES}  ${1}"$'\n'; }
FAILURES=""
HAVE_GUM=0; command -v gum >/dev/null 2>&1 && HAVE_GUM=1

# ---------------------------------------------------------------- preflight
preflight() {
  say "preflight"
  if ! xcode-select -p >/dev/null 2>&1; then
    if [ "$DRY" = 1 ]; then echo "  [dry-run] would install Xcode Command Line Tools"
    else
      echo "  Xcode Command Line Tools — launching the installer; re-run restore.sh once it finishes"
      xcode-select --install || true
      exit 1
    fi
  fi
  if ! command -v brew >/dev/null 2>&1; then
    if [ "$DRY" = 1 ]; then echo "  [dry-run] would install Homebrew"
    else /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
  fi
  [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
  if ! command -v gum >/dev/null 2>&1; then
    if [ "$DRY" = 1 ]; then echo "  [dry-run] would install gum — sections fall back to select-all"
    else brew install gum
    fi
  fi
  command -v gum >/dev/null 2>&1 && HAVE_GUM=1
  ok "preflight done"
}

# ------------------------------------------------------------ section engine
ITEMS=""
reset_items() { ITEMS=""; }
add() {  # add <label> <command> — label must not contain '|' or US
  local l="${1//|/-}"; l="${l//$US/-}"
  ITEMS="${ITEMS}${l}${US}${2}"$'\n'
}

run_item() {
  local label="$1" cmd="$2"
  if [ "$DRY" = 1 ]; then
    printf '  \033[33m→\033[0m %s\n      $ %s\n' "$label" "$cmd"
    return 0
  fi
  if [ "$HAVE_GUM" = 1 ] && [ -t 1 ]; then
    if gum spin --title "$label" --show-error -- bash -c "$cmd"; then ok "$label"; else bad "$label"; fi
  else
    if bash -c "$cmd" >"$LOG" 2>&1; then ok "$label"
    else bad "$label"; tail -5 "$LOG" | sed 's/^/      /'
    fi
  fi
}

run_section() {  # run_section <title> — consumes ITEMS
  local title="$1" labels sel label cmd n
  [ -n "$ITEMS" ] || return 0
  labels="$(printf '%s' "$ITEMS" | awk -F"$US" 'NF{print $1}')"
  n="$(printf '%s\n' "$labels" | grep -c .)"
  if [ "$LIST" = 1 ]; then
    say "$title ($n)"
    printf '%s\n' "$labels" | sed 's/^/  [+] /'
    return 0
  fi
  if [ "${RESTORE_ALL:-0}" = 1 ] || [ "$HAVE_GUM" = 0 ]; then
    sel="$labels"
  else
    sel="$(printf '%s\n' "$labels" | gum choose --no-limit --selected='*' --height 25 \
      --selected-prefix='✓ ' --unselected-prefix='  ' --cursor-prefix='  ' \
      --header "$title ($n) — space: toggle, enter: apply, esc: skip section")" || sel=""
  fi
  say "$title"
  [ -n "$sel" ] || { echo "  (section skipped)"; return 0; }
  while IFS="$US" read -r label cmd; do
    [ -n "$label" ] || continue
    if printf '%s\n' "$sel" | grep -qxF "$label"; then
      run_item "$label" "$cmd"
    fi
  done < <(printf '%s' "$ITEMS")
}

# ---------------------------------------------------------------- sections
brewfile_token() { sed -E 's/^[a-z_]+ "([^"]+)".*/\1/' <<<"$1"; }

brewfile_cat() {  # generated Brewfile + manual Brewfile.extra
  cat Brewfile 2>/dev/null
  cat Brewfile.extra 2>/dev/null
}

section_brewfile() {
  [ -f Brewfile ] || [ -f Brewfile.extra ] || return 0
  local line t d name id seen

  reset_items; seen=""
  while IFS= read -r line; do case "$line" in
    'tap '*) t="$(brewfile_token "$line")"
      case " $seen " in *" $t "*) ;; *) seen="$seen $t"; add "tap: $t" "brew tap $t" ;; esac ;;
  esac; done < <(brewfile_cat)
  run_section "brew taps"

  reset_items; d=""; seen=""
  while IFS= read -r line; do case "$line" in
    '# '*)    d="${line#\# }" ;;
    'brew '*) t="$(brewfile_token "$line")"
      case " $seen " in *" $t "*) ;; *) seen="$seen $t"; add "brew: $t${d:+ — $d}" "brew install $t" ;; esac
      d="" ;;
    *)        d="" ;;
  esac; done < <(brewfile_cat)
  run_section "brew formulae (CLI)"

  reset_items; d=""; seen=""
  while IFS= read -r line; do case "$line" in
    '# '*)    d="${line#\# }" ;;
    'cask '*) t="$(brewfile_token "$line")"
      case " $seen " in *" $t "*) ;; *) seen="$seen $t"; add "cask: $t${d:+ — $d}" "brew install --cask $t" ;; esac
      d="" ;;
    *)        d="" ;;
  esac; done < <(brewfile_cat)
  run_section "brew casks (GUI apps)"

  reset_items; seen=""
  while IFS= read -r line; do case "$line" in
    'mas '*)
      name="$(sed -E 's/^mas "([^"]+)".*/\1/' <<<"$line")"
      id="$(sed -E 's/.*id: *([0-9]+).*/\1/' <<<"$line")"
      case " $seen " in *" $id "*) ;; *) seen="$seen $id"; add "appstore: $name" "mas install $id" ;; esac ;;
  esac; done < <(brewfile_cat)
  run_section "App Store (requires being signed in)"

  reset_items; d=""; seen=""
  while IFS= read -r line; do case "$line" in
    '# '*)    d="${line#\# }" ;;
    'vscode '*)
      t="$(brewfile_token "$line")"
      case " $seen " in *" $t "*) ;; *) seen="$seen $t"
        add "vscode: ${d:-$t} ($t)" "code --install-extension $t || '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code' --install-extension $t" ;; esac
      d="" ;;
    *)        d="" ;;
  esac; done < <(brewfile_cat)
  run_section "VS Code extensions"
}

section_installers() {
  [ -f manifests/installers.map ] || return 0
  reset_items
  local label cmd
  while IFS='|' read -r label cmd; do
    case "$label" in \#*|"") continue ;; esac
    add "installer: $label" "$cmd"
  done < manifests/installers.map
  run_section "curl installers (non-brew)"
}

section_npm() {
  [ -s manifests/npm-globals.txt ] || return 0
  reset_items
  local p
  while IFS= read -r p; do [ -n "$p" ] && add "npm -g: $p" "npm install -g $p"; done < manifests/npm-globals.txt
  run_section "npm globals"
}

section_pipx() {
  [ -s manifests/pipx.txt ] || return 0
  reset_items
  local p
  while IFS= read -r p; do [ -n "$p" ] && add "pipx: $p" "pipx install $p"; done < manifests/pipx.txt
  run_section "pipx"
}

section_dotfiles() {
  [ -f dotfiles/link.map ] || [ -f dotfiles/link.map.auto ] || return 0
  reset_items
  local repo home dir seen=""
  while IFS='|' read -r repo home; do
    case "$repo" in \#*|"") continue ;; esac
    case " $seen " in *" $home "*) continue ;; esac; seen="$seen $home"
    dir="$(dirname "$home")"
    add "link: ~/$home → dotfiles/$repo" \
      "mkdir -p \"\$HOME/$dir\"; if [ -e \"\$HOME/$home\" ] && [ ! -L \"\$HOME/$home\" ]; then mv \"\$HOME/$home\" \"\$HOME/$home.pre-bootstrap\"; fi; ln -sfn \"$REPO/dotfiles/$repo\" \"\$HOME/$home\""
  done < <(cat dotfiles/link.map dotfiles/link.map.auto 2>/dev/null)
  run_section "dotfiles (symlink; old file → *.pre-bootstrap)"
}

section_configs() {
  [ -f configs/sync.map ] || return 0
  reset_items
  local repo home src
  while IFS='|' read -r repo home; do
    case "$repo" in \#*|"") continue ;; esac
    src="$REPO/configs/$repo"
    if [ -d "$src" ]; then
      add "config: ~/$home (dir)" "mkdir -p \"\$HOME/$home\" && rsync -a \"$src/\" \"\$HOME/$home/\""
    else
      add "config: ~/$home" "mkdir -p \"\$(dirname \"\$HOME/$home\")\" && cp \"$src\" \"\$HOME/$home\""
    fi
  done < configs/sync.map
  run_section "app configs (copy → home)"
}

section_plists() {
  [ -f configs/plists.map ] || return 0
  reset_items
  local dom
  while IFS= read -r dom; do
    case "$dom" in \#*|"") continue ;; esac
    dom="${dom%%|*}"   # strip `|check=...`
    [ -f "configs/plists/$dom.plist" ] || continue
    add "prefs: $dom" "defaults import $dom \"$REPO/configs/plists/$dom.plist\""
  done < configs/plists.map
  run_section "app preferences (defaults import; restart the apps)"
}

section_system() {
  reset_items
  [ -f defaults/defaults.sh ] && add "macOS defaults (defaults/defaults.sh)" "bash \"$REPO/defaults/defaults.sh\""
  run_section "macOS settings"
}

section_custom() {
  [ -f manifests/custom.map ] || return 0
  reset_items
  local label cmd
  while IFS='|' read -r label cmd; do
    case "$label" in \#*|"") continue ;; esac
    add "$label" "$cmd"
  done < manifests/custom.map
  run_section "custom steps (manifests/custom.map)"
}

# ------------------------------------------------------------------- main
[ "$LIST" = 1 ] || preflight

section_brewfile
section_installers
section_npm
section_pipx
section_dotfiles
section_configs
section_plists
section_system
section_custom

[ "$LIST" = 1 ] && exit 0
say "summary"
if [ "$DRY" = 1 ]; then
  echo "dry-run: nothing was installed or changed"
elif [ -n "$FAILURES" ]; then
  printf 'failed items:\n%s' "$FAILURES"
  exit 1
else
  echo "everything selected has been applied"
fi

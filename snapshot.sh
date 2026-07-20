#!/usr/bin/env bash
# mac-bootstrap snapshot — on the current machine: capture state into the repo.
# Read-only to the system; writes only inside the repo. Commit by hand.
set -euo pipefail
cd "$(dirname "$0")" || exit 1
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# ---- first-run init: create missing data files with header comments -------
mkdir -p manifests dotfiles configs defaults
[ -f dotfiles/link.map ] || cat > dotfiles/link.map <<'EOF'
# MANUAL map: configs the shell does not source (auto-discovery can't see them).
# Shell-sourced files are collected automatically → link.map.auto (generated).
# Format: repo-file|target relative to $HOME
# gitconfig|.gitconfig
# ssh_config|.ssh/config
EOF
[ -f configs/sync.map ] || cat > configs/sync.map <<'EOF'
# repo-path|path relative to $HOME  (file → cp, directory → rsync)
# vscode/settings.json|Library/Application Support/Code/User/settings.json
# karabiner|.config/karabiner
EOF
[ -f configs/plists.map ] || cat > configs/plists.map <<'EOF'
# bundle-ids whose preferences to back up via defaults export/import.
# One per line; helper domains: `domain|check=<parent-bundle-id>`.
# Candidates → manifests/plists-candidates.txt; rejects → configs/plists-ignore.txt.
# Do NOT add account-synced apps (browsers, messengers) or apps keeping tokens in plists.
EOF
[ -f configs/plists-ignore.txt ] || cat > configs/plists-ignore.txt <<'EOF'
# Domains deliberately NOT backed up (the candidates generator skips them).
EOF
[ -f manifests/installers.map ] || cat > manifests/installers.map <<'EOF'
# label|install command — non-brew installers, hand-maintained
# bun|curl -fsSL https://bun.sh/install | bash
# uv + uvx|curl -LsSf https://astral.sh/uv/install.sh | sh
EOF
[ -f manifests/apps-ignore.txt ] || cat > manifests/apps-ignore.txt <<'EOF'
# .app names snapshot won't report in apps-untracked.txt (already triaged).
Safari
EOF
[ -f manifests/custom.map ] || cat > manifests/custom.map <<'EOF'
# label|shell command — custom restore steps, run as the last section.
# Example: clone another config repo, bootstrap an editor, etc.
EOF
[ -f manifests/snapshot.map ] || cat > manifests/snapshot.map <<'EOF'
# label|shell command — custom snapshot steps, run before the secret scan.
# cwd = repo root. Copy IN state the generic sections can't see (other tools'
# config trees). Whatever you write here gets committed — keep secrets out;
# the built-in secret scan only covers dotfiles/ and configs/.
# Example: editor config|rsync -a --delete "$HOME/.someeditor/config/" someeditor/
EOF
[ -f defaults/defaults.sh ] || cat > defaults/defaults.sh <<'EOF'
#!/usr/bin/env bash
# Curated macOS settings. Uncomment / add what you actually use.
# To find the key behind a UI setting: defaults/diff.sh start → change it → diff.sh stop.
set -u

## Keyboard
# defaults write NSGlobalDomain KeyRepeat -int 2
# defaults write NSGlobalDomain InitialKeyRepeat -int 15

## Finder
# defaults write com.apple.finder ShowPathbar -bool true

## Dock
# defaults write com.apple.dock autohide -bool true

killall Finder Dock SystemUIServer 2>/dev/null || true
echo "defaults applied (some settings need relogin)"
EOF

say "Brewfile (brew bundle dump: taps + formulae + casks + mas + vscode)"
# brew ≥6: the default dumps all types with descriptions; type flags (--vscode etc.) mean "ONLY that type"
brew bundle dump --force --file=Brewfile

# formulae that are dependencies of another installed formula — drop: they arrive automatically
leaves="$(brew leaves)"
awk -v leaves="$leaves" '
  BEGIN { n = split(leaves, a, "\n"); for (i = 1; i <= n; i++) L[a[i]] = 1 }
  /^# / { c = $0; next }
  /^brew / {
    t = $0; sub(/^brew "/, "", t); sub(/".*/, "", t)
    base = t; sub(/.*\//, "", base)
    if (t in L || base in L) { if (c != "") print c; print }
    else dropped = dropped " " t
    c = ""; next
  }
  { if (c != "") print c; c = ""; print }
  END { if (dropped != "") print "# deps, dropped by snapshot (they arrive automatically):" dropped }
' Brewfile > Brewfile.tmp && mv Brewfile.tmp Brewfile

# annotate vscode lines with human-readable extension names (shown in the restore checklist)
if [ -d "$HOME/.vscode/extensions" ]; then
  : > Brewfile.tmp
  while IFS= read -r line; do
    case "$line" in
      'vscode '*)
        id="$(sed -E 's/^vscode "([^"]+)".*/\1/' <<<"$line")"
        dir="$(ls -d "$HOME/.vscode/extensions/$id-"* 2>/dev/null | sort | tail -1)"
        dname=""
        if [ -n "$dir" ] && [ -f "$dir/package.json" ]; then
          dname="$(jq -r '.displayName // empty' "$dir/package.json" 2>/dev/null)"
          case "$dname" in
            %*%) key="$(tr -d '%' <<<"$dname")"
                 dname="$(jq -r --arg k "$key" '.[$k] // empty' "$dir/package.nls.json" 2>/dev/null)" ;;
          esac
        fi
        [ -n "$dname" ] && echo "# $dname" >> Brewfile.tmp ;;
    esac
    echo "$line" >> Brewfile.tmp
  done < Brewfile
  mv Brewfile.tmp Brewfile
fi
echo "  $(grep -c '^brew ' Brewfile) formulae, $(grep -c '^cask ' Brewfile) casks, $(grep -c '^mas ' Brewfile || true) mas, $(grep -c '^vscode ' Brewfile || true) vscode-ext"

say "npm / pipx globals → manifests/"
npm ls -g --depth=0 --json 2>/dev/null | jq -r '.dependencies // {} | keys[]' | grep -vx npm > manifests/npm-globals.txt || true
if command -v pipx >/dev/null 2>&1; then
  pipx list --short 2>/dev/null | awk '{print $1}' > manifests/pipx.txt || true
fi
echo "  npm: $(wc -l < manifests/npm-globals.txt | tr -d ' '), pipx: $( [ -f manifests/pipx.txt ] && wc -l < manifests/pipx.txt | tr -d ' ' || echo 0 )"

say "dotfiles discover (zsh load order + recursion over source) → dotfiles/link.map.auto"
DF_MAP=dotfiles/link.map.auto
DF_ROOTS=".zshenv .zprofile .zshrc .zlogin"
# tool-owned files — regenerated by their tool; bootstrap installs the tool itself
DF_EXTERNAL='^(/opt/|/etc/|/usr/|/nix/)|/\.orbstack/|/\.bun/|/\.nvm/|/\.docker/|/\.local/bin/env$|/\.maestro/|/\.cargo/env'
DF_ENV=""   # exports collected from scanned files (statically resolvable only)
DF_SEEN=""
: > "$DF_MAP.tmp"

df_expand() {  # expand ~, $HOME and collected variables
  local p="$1" var val
  p="${p//\"/}"; p="${p//\'/}"
  case "$p" in "~"*) p="$HOME${p#\~}" ;; esac
  p="${p//\$HOME/$HOME}"
  while IFS='=' read -r var val; do
    [ -n "$var" ] || continue
    p="${p//\$\{$var\}/$val}"; p="${p//\$$var/$val}"
  done <<EOF_ENV
$DF_ENV
EOF_ENV
  printf '%s' "$p"
}

df_scan() {  # parse a file: collect exports, walk source lines
  local f="$1" line var val tok p
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      export\ *=*)
        var="${line#export }"; val="${var#*=}"; var="${var%%=*}"
        case "$val" in *'$('*|*'`'*) continue ;; esac
        val="$(df_expand "$val")"
        case "$val" in *'$'*) continue ;; esac
        DF_ENV="$DF_ENV$var=$val"$'\n' ;;
    esac
  done < "$f"
  while IFS= read -r tok; do
    p="$(df_expand "$tok")"
    case "$p" in *'$'*|*'`'*) echo "  ~ unresolved: $tok (in ${f#dotfiles/})"; continue ;; esac
    df_take "$p"
  done < <(grep -oE '(^|[;&|[:space:]])(source|\\?\.)[[:space:]]+[^[:space:];&|]+' "$f" 2>/dev/null \
           | sed -E 's/^[;&|[:space:]]*(source|\\?\.)[[:space:]]+//' | sort -u)
}

df_take() {  # decide a file's fate: adopt into the repo / skip with a reason
  local p="$1" rel name
  case "$DF_SEEN" in *"|$p|"*) return ;; esac
  DF_SEEN="$DF_SEEN|$p|"
  if printf '%s' "$p" | grep -qE "$DF_EXTERNAL"; then
    echo "  ⨯ external (comes with its tool): ${p/#$HOME/~}"; return
  fi
  case "$p" in "$HOME"/*) ;; *) echo "  ⨯ outside \$HOME: $p"; return ;; esac
  rel="${p#$HOME/}"
  if [ ! -e "$p" ]; then echo "  ? ~/$rel — sourced, but the file doesn't exist"; return; fi
  name="$(printf '%s' "$rel" | tr '/' '-' | tr '[:upper:]' '[:lower:]' | sed 's/^\.//; s/-\./-/g')"
  echo "$name|$rel" >> "$DF_MAP.tmp"
  if [ -L "$p" ]; then echo "  = ~/$rel (symlink — already ours)"
  else cp "$p" "dotfiles/$name"; echo "  ← ~/$rel"
  fi
  df_scan "$p"   # scan the live file — the repo copy may not exist yet for foreign symlinks
}

for r in $DF_ROOTS; do
  [ -e "$HOME/$r" ] || continue
  df_take "$HOME/$r"
done
sort -u "$DF_MAP.tmp" > "$DF_MAP" && rm -f "$DF_MAP.tmp"
echo "  map: $(wc -l < "$DF_MAP" | tr -d ' ') files → $DF_MAP"

say "dotfiles adopt — manual, non-shell (dotfiles/link.map)"
while IFS='|' read -r repo home; do
  case "$repo" in \#*|"") continue ;; esac
  src="$HOME/$home"; dst="dotfiles/$repo"
  if [ -L "$src" ]; then echo "  = $home (symlink — already ours)"; continue; fi
  if [ ! -e "$src" ]; then echo "  ? $home missing"; continue; fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  echo "  ← $home"
done < dotfiles/link.map

say "app configs (home → repo, per configs/sync.map)"
while IFS='|' read -r repo home; do
  case "$repo" in \#*|"") continue ;; esac
  src="$HOME/$home"; dst="configs/$repo"
  if [ ! -e "$src" ]; then echo "  ? $home missing"; continue; fi
  mkdir -p "$(dirname "$dst")"
  # excludes: regenerated content (karabiner backups, sublime formatter assets)
  if [ -d "$src" ]; then rsync -a --delete --exclude 'automatic_backups/' --exclude 'formatter.assets/' "$src/" "$dst/"; else cp "$src" "$dst"; fi
  echo "  ← $home"
done < configs/sync.map

say "app preferences plist (defaults export, per configs/plists.map)"
app_exists() {  # the bundle-id has an installed app (or it's a CLI on PATH)
  [ -n "$(mdfind "kMDItemCFBundleIdentifier == '$1'" 2>/dev/null | head -1)" ] && return 0
  command -v "${1##*.}" >/dev/null 2>&1
}
if [ -f configs/plists.map ]; then
  mkdir -p configs/plists
  while IFS= read -r entry; do
    case "$entry" in \#*|"") continue ;; esac
    dom="${entry%%|*}"
    chk="$dom"   # `dom|check=<id>` — helper domains verify against their parent app
    case "$entry" in *"|check="*) chk="${entry##*|check=}" ;; esac
    if ! app_exists "$chk"; then
      echo "  ✗ $dom — app is gone; remove the line from plists.map and configs/plists/$dom.plist"
      continue
    fi
    if defaults export "$dom" "configs/plists/$dom.plist" 2>/dev/null; then
      plutil -convert xml1 "configs/plists/$dom.plist"   # readable diffs + secret scan
      echo "  ← $dom"
    else
      echo "  ? $dom — domain doesn't exist"
    fi
  done < configs/plists.map

  # new preference domains not triaged yet (not in map, not ignored, not junk)
  : > manifests/plists-candidates.txt
  for f in "$HOME/Library/Preferences/"*.plist; do
    dom="$(basename "$f" .plist)"
    case "$dom" in com.apple.*|group.*|systemgroup.*) continue ;; esac
    printf '%s' "$dom" | grep -qiE 'updater|update[.2]|updateservice|helper|agent|daemon|shipit|sparkle|keystone|amplitude|firebase|statsig|segment|crashlytics|RemoteFeatureFlags|loginwindow|MobileMeAccounts' && continue
    grep -q "^$dom\(|\|$\)" configs/plists.map 2>/dev/null && continue
    grep -qxF "$dom" configs/plists-ignore.txt 2>/dev/null && continue
    app_exists "$dom" || continue   # leftover of an uninstalled app — don't suggest
    echo "$dom" >> manifests/plists-candidates.txt
  done
  echo "  candidates to add: $(wc -l < manifests/plists-candidates.txt | tr -d ' ') → manifests/plists-candidates.txt"
fi

say ".apps not from brew/mas → manifests/apps-untracked.txt (candidates for cask / installers.map)"
casks="$(brew list --cask 2>/dev/null || true)"
: > manifests/apps-untracked.txt
for app in /Applications/*.app "$HOME/Applications"/*.app; do
  [ -e "$app" ] || continue
  name="$(basename "$app" .app)"
  [ -e "$app/Contents/_MASReceipt" ] && continue   # App Store → already a mas line in Brewfile
  # already triaged by hand (Brewfile.extra / installers.map / deliberately skipped)
  [ -f manifests/apps-ignore.txt ] && grep -qxF "$name" manifests/apps-ignore.txt && continue
  guess="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')"
  printf '%s\n' "$casks" | grep -qx "$guess" && continue
  echo "$name  →  brew search --cask '$guess'  # → Brewfile.extra, or installers.map, or apps-ignore.txt" >> manifests/apps-untracked.txt
done
echo "  $(wc -l < manifests/apps-untracked.txt | tr -d ' ') candidates for manual triage"

if [ -f manifests/snapshot.map ] && grep -qvE '^(#|$)' manifests/snapshot.map; then
  say "custom snapshot steps (manifests/snapshot.map)"
  while IFS='|' read -r label cmd; do
    case "$label" in ''|\#*) continue ;; esac
    [ -n "$cmd" ] || continue
    echo "  → $label"
    ( eval "$cmd" ) || echo "  ~ failed: $label"
  done < manifests/snapshot.map
fi

say "secret scan (warn-only)"
if grep -rInE '(api[_-]?key|secret|token|passw)[a-z_]*[[:space:]]*[=:][[:space:]]*[^[:space:]$]' dotfiles configs 2>/dev/null | grep -v '\.map:'; then
  echo "  ⚠ review the lines above before committing"
else
  echo "  clean"
fi

say "git"
git status --short || true
echo "commit by hand: git add -A && git commit -m 'snapshot $(date +%Y-%m-%d)'"

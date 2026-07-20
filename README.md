# mac-bootstrap

Back up and restore a full macOS environment in one git repo: installed software,
dotfiles, app configs, app preferences, macOS settings — with an interactive
checkbox TUI on restore.

Two scripts, your repo in between:

- **`snapshot.sh`** — run on your current machine periodically. Scans the system,
  writes state into repo files, reports anything new for triage. You commit.
- **`restore.sh`** — run on a fresh machine after `git clone`. Walks through
  sections with a checkbox TUI (everything pre-selected), installs what you pick.

**The engine is public; your backup is yours.** This repo contains only the
scripts — no personal data. Your Brewfile, dotfiles and preferences live in your
own **private** copy (see Setup). Snapshot data never leaves your repo, and
secret *values* are never written at all.

## Setup (your private backup repo)

Don't fork on GitHub — forks of public repos can't be made private. Instead,
clone and point `origin` at your own private repo, keeping the engine as `upstream`:

```bash
git clone https://github.com/vladforfutdinov/mac-bootstrap.git ~/mac-backup
cd ~/mac-backup
git remote rename origin upstream
gh repo create my-mac-backup --private --source . --remote origin --push

./snapshot.sh          # first run creates the data-file skeleton + captures your machine
git add -A && git commit -m "first snapshot" && git push
```

Engine updates later:

```bash
git fetch upstream && git merge upstream/main    # scripts merge cleanly — your data files are untouched
```

## Restore (fresh machine)

```bash
git clone <your-private-repo> ~/mac-backup && cd ~/mac-backup
./restore.sh                            # interactive checklist, executes selection
./restore.sh --dry-run                  # SAME interactive flow, prints commands only
./restore.sh --list                     # print all items without TUI and exit
RESTORE_ALL=1 ./restore.sh --dry-run    # full plan as one listing, no TUI
```

- Preflight installs the chain itself: Xcode CLT → Homebrew → gum (dry-run only reports).
- Sections in order: taps → formulae → casks → App Store → VS Code extensions →
  curl installers → npm/pipx globals → dotfiles → file configs → app plists →
  macOS defaults → custom steps.
- Checkboxes: `✓` = install, blank = skip; `space` toggles, `enter` applies,
  `esc` skips the whole section.
- A failed item doesn't kill the run — summary of ✗ items at the end, exit 1.
- Everything is idempotent: re-run installs only what's missing.
- Secrets are prompted from the keyboard at restore time — never stored in the repo.

## Snapshot (current machine)

`./snapshot.sh` — read-only to the system, writes only into the repo.
First run creates the data-file skeleton (maps, ignore lists, defaults template).

- `Brewfile` ← `brew bundle dump`: taps, formulae (minus dependencies of other
  installed formulae — they arrive automatically), casks, App Store apps (mas),
  VS Code extensions (annotated with human-readable names).
- `manifests/npm-globals.txt`, `manifests/pipx.txt` — global packages.
- `dotfiles/*` ← **auto-discovery**: walks the zsh load order (`.zshenv` → `.zprofile` →
  `.zshrc` → `.zlogin`), parses `source` / `.` lines (expanding `~`, `$HOME` and
  variables exported in the scanned files), adopts every reachable file into the repo
  recursively — including paths outside dotfile conventions (e.g. `~/projects/.aliases`) —
  and writes the restore map to `dotfiles/link.map.auto`. Tool-owned files (nvm, bun,
  orbstack, uv, ...) are skipped with a reason — they come with their tool. Unresolvable
  paths (`$(...)`) are reported. Non-shell configs (gitconfig, ssh_config) go in the
  manual `dotfiles/link.map`; adopt copies them unless already symlinked.
- `configs/*` ← copy/rsync per `configs/sync.map` (regenerated junk excluded).
- `configs/plists/*.plist` ← `defaults export` for every domain in
  `configs/plists.map`, converted to XML (readable diffs, secret-scannable).
  Domains whose app is gone are skipped with a removal hint — snapshot verifies
  the app exists via Spotlight bundle-id lookup (CLI fallback: `command -v`).
- **Triage reports** — anything not yet accounted for:
  - `manifests/apps-untracked.txt` — `.app`s (from `/Applications` and
    `~/Applications`) not installed via brew/mas;
  - `manifests/plists-candidates.txt` — new preference domains not yet mapped
    (leftover domains of uninstalled apps are filtered out).
- Warn-only secret scan over `dotfiles/` and `configs/`.

## Layers

| what | source in repo | restore |
|---|---|---|
| CLI, GUI apps, App Store | `Brewfile` (generated) + `Brewfile.extra` (manual) | `brew install` / `--cask` / `mas install` |
| curl installers | `manifests/installers.map` (manual) | command from map |
| npm / pipx globals | `manifests/*.txt` (generated) | `npm i -g` / `pipx install` |
| dotfiles (shell-sourced graph) | `dotfiles/` + `link.map.auto` (generated) + `link.map` (manual, non-shell) | symlink (old file → `*.pre-bootstrap`) |
| app configs (files) | `configs/` + `sync.map` | copy/rsync into home |
| app preferences (plist) | `configs/plists/` + `plists.map` | `defaults import <bundle-id>` |
| macOS settings | `defaults/defaults.sh` (curated) | run the script |
| custom steps | `manifests/custom.map` (manual) | command from map, last section |

## Hand-maintained files (snapshot never overwrites them)

- **`Brewfile.extra`** — casks for apps that were installed outside brew
  (found via triage). Same format as Brewfile: a comment above a line becomes
  its description in the checklist. `restore.sh` dedupes by token across both files.
- **`manifests/installers.map`** — `label|shell command` for non-brew installers
  (bun, uv, apps without a cask → `open <download page>`).
- **`manifests/custom.map`** — `label|shell command`, run as the last restore
  section. Anything machine-setup that doesn't fit the other layers (e.g. clone
  and bootstrap another config repo).
- **`manifests/snapshot.map`** — `label|shell command`, the snapshot-side twin:
  runs before the secret scan and copies IN state the generic sections can't
  see (another tool's config tree → a repo subdir). Whatever it writes gets
  committed — keep secrets out; the built-in scan only covers `dotfiles/` and
  `configs/`.
- **`configs/plists.map`** — one bundle-id per line: which app preferences to back
  up. Helper domains that aren't app bundles verify against their parent app via
  `domain|check=<parent-bundle-id>`. Deliberately rejected domains go to
  `configs/plists-ignore.txt`. Don't add account-synced apps (browsers,
  messengers) or apps that keep tokens in their plist.
- **`dotfiles/link.map`** / **`configs/sync.map`** — see formats below.
- **`defaults/defaults.sh`** — curated `defaults write` list. A full `defaults`
  dump is useless noise — curate consciously. To find the key behind a UI setting:
  `defaults/diff.sh start` → change it in System Settings → `defaults/diff.sh stop`.

## The lifecycle loop

Install a new app → next `snapshot.sh` shows it in a triage report → one line
into `Brewfile.extra` / `installers.map` / `plists.map` (or the ignore file) →
commit. New `source` lines in shell files need no triage — auto-discovery adopts
them on the next snapshot. Both triage counters at zero means the repo fully
describes the machine.

## Map formats

- `dotfiles/link.map` / `link.map.auto` — `repo-file|path-relative-to-$HOME`; restore
  symlinks (deduped across both), the old file is kept as `*.pre-bootstrap`.
  `.auto` is regenerated by snapshot — don't edit; manual entries go to `link.map`.
- `configs/sync.map` — `repo-path|path-relative-to-$HOME`; file → cp,
  directory → rsync (contents are copied, names may differ).
- `manifests/installers.map` / `manifests/custom.map` — `label|shell command`.
- `configs/plists.map` — `bundle-id` or `bundle-id|check=<parent-bundle-id>`.
  Snapshot captures the state at snapshot time; restart the app after import
  (macOS caches prefs via cfprefsd).

## Notes

- Once restored, live dotfiles are symlinks into the repo — edits land in the
  repo directly, `git diff` is the change log.
- **mas** requires being signed into the App Store before that restore section.
- **Secrets**: `.gitignore` blocks `hosts.yml` / `id_*` / `*.pem`; snapshot runs a
  warn-only scan for suspicious strings. Keep your backup repo private —
  `ssh_config`, hostnames and preference plists are personal data.
- First run on a fresh machine: `xcode-select --install` finishes asynchronously —
  restore.sh will ask to be re-run after it completes.

## License

MIT

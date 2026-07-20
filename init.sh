#!/usr/bin/env bash
# One-command setup of a private backup repo on top of the public engine.
# Automates the README "Setup" section. Run from a fresh clone of the engine:
#
#   git clone https://github.com/vladforfutdinov/mac-bootstrap.git ~/mac-backup
#   cd ~/mac-backup && ./init.sh [repo-name-or-url]
#
# arg: your PRIVATE repo — a git URL to wire as origin, or a bare name for
#      `gh repo create <name> --private` (default: mac-backup). Without gh and
#      without a URL it leaves origin unset and tells you what to do.
# Never pushes and never commits — you review the first snapshot, then commit.
set -euo pipefail
cd "$(dirname "$0")" || exit 1
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

[ -d .git ] || { echo "not a git clone — clone the engine first (see README Setup)"; exit 1; }

say "remotes"
if git remote get-url upstream >/dev/null 2>&1; then
  echo "  upstream already set: $(git remote get-url upstream)"
elif git remote get-url origin >/dev/null 2>&1; then
  git remote rename origin upstream
  echo "  engine remote renamed: origin -> upstream ($(git remote get-url upstream))"
else
  echo "  no origin remote — clone the engine, don't download it"; exit 1
fi

target="${1:-}"
if git remote get-url origin >/dev/null 2>&1; then
  echo "  origin already set: $(git remote get-url origin)"
elif [ -n "$target" ] && case "$target" in *:*|*/*) true ;; *) false ;; esac; then
  git remote add origin "$target"
  echo "  origin -> $target"
elif command -v gh >/dev/null 2>&1; then
  name="${target:-mac-backup}"
  gh repo create "$name" --private --source . --remote origin
  echo "  origin -> private repo '$name' (created via gh)"
else
  echo "  TODO: create a PRIVATE repo yourself, then: git remote add origin <url>"
fi

say "first snapshot"
./snapshot.sh

say "next steps"
echo "  1. review the triage reports and the secret-scan output above"
echo "  2. git add -A && git commit -m 'first snapshot'"
echo "  3. git push -u origin main"
echo "  engine updates later: git fetch upstream && git merge upstream/main"

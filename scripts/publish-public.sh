#!/bin/zsh
# The public copy of Vera: a snapshot of HEAD without the private parts, as one fresh commit, force-pushed to a
# public repository. History is not published (author addresses, machine names, old drafts live only here).
#
# Usage: scripts/publish-public.sh <git remote URL> [--dry-run]
#   --dry-run  build and check the snapshot in a temp folder, push nothing.
#
# Left out: paths in EXCLUDE below. Checked before the push — the snapshot must not contain the owner's own values
# (the tunnel host from local.json, the signing team from phone/Local.xcconfig, the git author's address) or
# anything that looks like a key or token. Those values are read from the owner's files, so they are not written here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE="${1:-}"; DRY="${2:-}"
[[ -n "$REMOTE" ]] || { print -u2 "usage: $0 <git remote URL> [--dry-run]"; exit 2; }

EXCLUDE=(
  docs/v3-architectures   # design sketches with real phone screenshots and the owner's addresses
)

cd "$ROOT"
[[ -z "$(git status --porcelain)" ]] || { print -u2 "есть незакоммиченные изменения — сначала коммит"; exit 1; }

OUT=$(mktemp -d)/vera
mkdir -p "$OUT"
git archive HEAD | tar -x -C "$OUT"
for p in $EXCLUDE; do rm -rf -- "$OUT/$p"; done

# The owner's own values, from the owner's files.
forbidden=()
data="$HOME/Library/Application Support/Vera03/local.json"
if [[ -f "$data" ]]; then
  host=$(/usr/bin/plutil -extract phone_tunnel raw -o - "$data" 2>/dev/null || true)
  [[ -n "$host" ]] && forbidden+=("$host")
fi
if [[ -f phone/Local.xcconfig ]]; then
  team=$(sed -n -E 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]+).*/\1/p' phone/Local.xcconfig | tail -1)
  [[ -n "$team" ]] && forbidden+=("$team")
fi
for e in $(git log --format='%ae' | sort -u); do
  [[ "$e" == *noreply* ]] || forbidden+=("$e")
done

bad=0
for f in $forbidden; do
  if grep -rIlF -- "$f" "$OUT" >/dev/null 2>&1; then
    print -u2 "в снимке осталось личное значение (${f[1,3]}…):"; grep -rIlF -- "$f" "$OUT" | sed "s|$OUT/|  |" >&2; bad=1
  fi
done
secrets='(sk-[A-Za-z0-9_-]{24,}|AIza[0-9A-Za-z_-]{30,}|gh[pousr]_[A-Za-z0-9]{30,}|xox[abp]-[A-Za-z0-9-]{10,}|[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)'
if grep -rIlE -- "$secrets" "$OUT" >/dev/null 2>&1; then
  print -u2 "в снимке что-то похожее на ключ или токен:"; grep -rIlE -- "$secrets" "$OUT" | sed "s|$OUT/|  |" >&2; bad=1
fi
(( bad == 0 )) || { print -u2 "не публикую. Снимок: $OUT"; exit 1; }

# One commit. The author is the GitHub account through its noreply address, so no mail address is published.
login=$(gh api user --jq .login); id=$(gh api user --jq .id)
cd "$OUT"
git init -q -b main
git add -A
GIT_AUTHOR_NAME="$login" GIT_AUTHOR_EMAIL="$id+$login@users.noreply.github.com" \
GIT_COMMITTER_NAME="$login" GIT_COMMITTER_EMAIL="$id+$login@users.noreply.github.com" \
  git commit -q -m "Вера 0.3 — $(git -C "$ROOT" log -1 --format=%cs)" -m "Снимок $(git -C "$ROOT" rev-parse --short HEAD) без истории."
print "снимок: $OUT ($(git ls-files | wc -l | tr -d ' ') файлов)"
if [[ "$DRY" == "--dry-run" ]]; then print "dry-run: не пушу"; exit 0; fi
git push --force "$REMOTE" main:main
print "опубликовано: $REMOTE"

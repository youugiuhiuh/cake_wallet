#!/usr/bin/env bash
#
# Sync this fork with upstream cake-tech/cake_wallet.
#
# Strategy: fetch upstream, then rebase local commits on top.
# Every local change is additive (zero deletions on tracked files), so rebase
# almost always succeeds. When it does not, the conflict markers concentrate in
# `lib/di.dart` and `lib/router.dart` around import / registration inserts —
# resolve by keeping both blocks. See fork/README.md for the cheat-sheet.
#
# Usage:
#   ./fork/sync-upstream.sh            # fetch + rebase onto origin/dev
#   ./fork/sync-upstream.sh --merge    # fetch + merge instead of rebase
#   ./fork/sync-upstream.sh --dry-run  # fetch, show what rebase would do
#
set -euo pipefail

REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-dev}"
MODE="rebase"

for arg in "$@"; do
  case "$arg" in
    --merge)   MODE="merge" ;;
    --rebase)  MODE="rebase" ;;
    --dry-run) MODE="dry-run" ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "!! working tree is dirty. Commit or stash first:" >&2
  git status --short >&2
  exit 1
fi

current_branch="$(git rev-parse --abbrev-ref HEAD)"
echo "==> fetching ${REMOTE}/${BRANCH}"
git fetch "$REMOTE" "$BRANCH"

behind="$(git rev-list --count "HEAD..${REMOTE}/${BRANCH}")"
ahead="$(git rev-list --count "${REMOTE}/${BRANCH}..HEAD")"
echo "==> local ahead: ${ahead}, behind: ${behind}"

if [[ "$behind" == "0" ]]; then
  echo "==> already up to date. nothing to do."
  exit 0
fi

# Files most likely to conflict, so we can warn up front.
HOT_FILES=(lib/di.dart lib/router.dart lib/main.dart cw_core/lib/db/sqlite.dart)
touched="$(git diff --name-only "HEAD..${REMOTE}/${BRANCH}" -- "${HOT_FILES[@]}" || true)"
if [[ -n "$touched" ]]; then
  echo "!! upstream also touched our wiring files:"
  echo "$touched" | sed 's/^/     /'
  echo "     if the merge stops, keep BOTH sides (imports/registrations/cases)."
fi

case "$MODE" in
  dry-run)
    echo "==> dry run: would replay these local commits onto ${REMOTE}/${BRANCH}:"
    git log --oneline "${REMOTE}/${BRANCH}..HEAD"
    ;;
  merge)
    echo "==> merging ${REMOTE}/${BRANCH} into ${current_branch}"
    git merge "${REMOTE}/${BRANCH}"
    echo "==> done. verify with: flutter analyze"
    ;;
  rebase)
    echo "==> rebasing ${current_branch} onto ${REMOTE}/${BRANCH}"
    git rebase "${REMOTE}/${BRANCH}"
    echo "==> rebased. verify with: flutter analyze"
    ;;
esac

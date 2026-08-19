#!/usr/bin/env bash
# Auto-docs pre-commit hook. Git has not finalised the commit message at this
# point, so this hook records only deterministic staged-change information.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || exit 0
[ -f "$REPO_ROOT/.claude/no-docs" ] && exit 0
CANONICAL_REPO_ROOT=$(cd -P -- "$REPO_ROOT" && pwd)

cd "$REPO_ROOT"
DOCS_DIR="$REPO_ROOT/docs"
CHANGELOG="$DOCS_DIR/CHANGELOG.md"

# Do not follow repository-controlled links while preparing a commit. The
# canonical directory check also makes the write destination explicit.
[ -L "$DOCS_DIR" ] && exit 0
if [ -e "$DOCS_DIR" ] && [ ! -d "$DOCS_DIR" ]; then
  exit 0
fi
mkdir -p -- "$DOCS_DIR"
[ -L "$DOCS_DIR" ] && exit 0
CANONICAL_DOCS_DIR=$(cd -P -- "$DOCS_DIR" && pwd)
case "$CANONICAL_DOCS_DIR" in
  "$CANONICAL_REPO_ROOT"/*) ;;
  *) exit 0 ;;
esac
[ -L "$CHANGELOG" ] && exit 0
if [ -e "$CHANGELOG" ] && [ ! -f "$CHANGELOG" ]; then
  exit 0
fi

# Exclude the hook's own output so retries see the same pending tree. Include
# the parent SHA so two consecutive commits with equal file counts differ.
STAGED_COUNT=$(git diff --cached --name-only -- . ':(exclude)docs/CHANGELOG.md' | sed '/^$/d' | wc -l | tr -d ' ')
[ "$STAGED_COUNT" -gt 0 ] || exit 0
PARENT_SHA=$(git rev-parse --verify HEAD 2>/dev/null || printf 'EMPTY')
PENDING_KEY=$( {
  printf '%s\0' "$PARENT_SHA"
  git diff --cached --no-ext-diff --binary -- . ':(exclude)docs/CHANGELOG.md'
} | shasum -a 256 | awk '{print $1}')
PARENT_MARKER_PREFIX="<!-- auto-docs:pending-parent:${PARENT_SHA}:staged-tree:"
MARKER="${PARENT_MARKER_PREFIX}${PENDING_KEY} -->"

BASEFILE=$(mktemp "$CANONICAL_DOCS_DIR/.auto-docs-base.XXXXXX")
INDEXED_CHANGELOG=0
if git cat-file -e :docs/CHANGELOG.md 2>/dev/null; then
  INDEXED_CHANGELOG=1
  git show :docs/CHANGELOG.md > "$BASEFILE"
else
  cat > "$BASEFILE" <<'EOF'
# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]
EOF
fi
if [ "$INDEXED_CHANGELOG" -eq 1 ] && [ ! -f "$CHANGELOG" ] && ! git diff --quiet -- docs/CHANGELOG.md; then
  printf 'auto-docs: refusing to erase an unstaged docs/CHANGELOG.md deletion\n' >&2
  rm -f -- "$BASEFILE"
  exit 1
fi

ENTRY="- Updated ${STAGED_COUNT} staged file(s)."
CURRENT_MARKER_COUNT=$(grep -Fxc -- "$MARKER" "$BASEFILE" || true)
PARENT_MARKER_COUNT=$(grep -Fc -- "$PARENT_MARKER_PREFIX" "$BASEFILE" || true)
if [ "$CURRENT_MARKER_COUNT" -eq 1 ] && [ "$PARENT_MARKER_COUNT" -eq 1 ]; then
  if [ -f "$CHANGELOG" ] && ! cmp -s "$BASEFILE" "$CHANGELOG"; then
    printf 'auto-docs: refusing to stage unstaged docs/CHANGELOG.md changes\n' >&2
    rm -f -- "$BASEFILE"
    exit 1
  fi
  mv "$BASEFILE" "$CHANGELOG"
  git add -- "$CHANGELOG"
  exit 0
fi

# First remove all managed entries for this pending commit's parent. A changed
# index therefore replaces the pending snapshot rather than accumulating one.
CLEANED=$(mktemp "$CANONICAL_DOCS_DIR/.auto-docs-cleaned.XXXXXX")
TMPFILE=$(mktemp "$CANONICAL_DOCS_DIR/.auto-docs-changelog.XXXXXX")
awk -v parent_prefix="$PARENT_MARKER_PREFIX" '
  index($0, parent_prefix) == 1 {
    skip_entry = 1
    next
  }
  skip_entry && /^- Updated [0-9]+ staged file\(s\)\.$/ {
    skip_entry = 0
    next
  }
  skip_entry {
    skip_entry = 0
  }
  { print }
' "$BASEFILE" > "$CLEANED"

# Detect and insert only inside the Unreleased range, which ends at the next
# level-two heading. Historical release sections remain immutable.
awk -v marker="$MARKER" -v entry="$ENTRY" '
  function insert_changed() {
    print "### Changed"
    print marker
    print entry
    inserted = 1
  }
  /^## \[Unreleased\]$/ {
    in_unreleased = 1
    saw_unreleased = 1
    print
    next
  }
  in_unreleased && /^## / {
    if (!inserted) {
      print ""
      insert_changed()
    }
    in_unreleased = 0
    print
    next
  }
  in_unreleased && /^### Changed$/ && !inserted {
    print
    print marker
    print entry
    inserted = 1
    next
  }
  { print }
  END {
    if (!saw_unreleased) {
      print ""
      print "## [Unreleased]"
      print ""
      insert_changed()
    } else if (in_unreleased && !inserted) {
      print ""
      insert_changed()
    }
  }
' "$CLEANED" > "$TMPFILE"
rm -f "$CLEANED" "$BASEFILE"
if [ -f "$CHANGELOG" ] && ! git diff --quiet -- docs/CHANGELOG.md && ! cmp -s "$TMPFILE" "$CHANGELOG"; then
  printf 'auto-docs: refusing to stage unstaged docs/CHANGELOG.md changes\n' >&2
  rm -f -- "$TMPFILE"
  exit 1
fi
if [ -f "$CHANGELOG" ] && ! git ls-files --error-unmatch -- docs/CHANGELOG.md >/dev/null 2>&1 \
    && ! cmp -s "$TMPFILE" "$CHANGELOG"; then
  printf 'auto-docs: refusing to stage an existing untracked docs/CHANGELOG.md\n' >&2
  rm -f -- "$TMPFILE"
  exit 1
fi
mv "$TMPFILE" "$CHANGELOG"
git add -- "$CHANGELOG"

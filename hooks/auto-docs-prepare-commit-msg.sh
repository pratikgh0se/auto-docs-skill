#!/usr/bin/env bash
# Auto-docs prepare-commit-msg hook
# Updates docs/CHANGELOG.md and MR description on commit
# Install per-project: cp ~/.claude/hooks/auto-docs-prepare-commit-msg.sh .git/hooks/prepare-commit-msg

set -euo pipefail

COMMIT_MSG_FILE="$1"
COMMIT_SOURCE="${2:-}"

# Skip merge/squash commits
if [ "$COMMIT_SOURCE" = "merge" ] || [ "$COMMIT_SOURCE" = "squash" ]; then
  exit 0
fi

# Skip if toggle present
if [ -f ".claude/no-docs" ]; then
  exit 0
fi

# Skip if docs/ doesn't exist
if [ ! -d "docs" ]; then
  exit 0
fi

COMMIT_MSG=$(cat "$COMMIT_MSG_FILE")

# Skip trivial commits
if echo "$COMMIT_MSG" | grep -qiE '^(wip|fixup|squash|typo|fmt|format|whitespace|#)'; then
  exit 0
fi

DATE=$(date +%Y-%m-%d)
BRANCH=$(rtk git rev-parse --abbrev-ref HEAD 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# ── Update docs/CHANGELOG.md ──────────────────────────────────────────────────

if [ ! -f "docs/CHANGELOG.md" ]; then
  cat > docs/CHANGELOG.md << 'EOF'
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]
EOF
fi

# Determine entry type from conventional commit prefix
TYPE="Changed"
if echo "$COMMIT_MSG" | grep -qE '^feat(\(.+\))?:'; then TYPE="Added"; fi
if echo "$COMMIT_MSG" | grep -qE '^fix(\(.+\))?:'; then TYPE="Fixed"; fi
if echo "$COMMIT_MSG" | grep -qE '^(remove|delete|revert)(\(.+\))?:'; then TYPE="Removed"; fi

# Clean up commit message (strip conventional commit prefix for readability)
CLEAN_MSG=$(echo "$COMMIT_MSG" | sed 's/^feat(\([^)]*\)): //' | sed 's/^fix(\([^)]*\)): //' | sed 's/^feat: //' | sed 's/^fix: //')

# Check if ### $TYPE section already exists under [Unreleased]
if ! grep -A20 '^\#\# \[Unreleased\]' docs/CHANGELOG.md | grep -q "^\#\#\# $TYPE"; then
  # Add new section under [Unreleased]
  TMPFILE=$(mktemp)
  awk -v type="### $TYPE" -v entry="- $CLEAN_MSG" '
    /^## \[Unreleased\]/ { print; print ""; print type; print entry; next }
    { print }
  ' docs/CHANGELOG.md > "$TMPFILE" && mv "$TMPFILE" docs/CHANGELOG.md
else
  # Append under existing section
  TMPFILE=$(mktemp)
  awk -v type="### $TYPE" -v entry="- $CLEAN_MSG" -v inserted=0 '
    inserted == 0 && $0 == type { print; print entry; inserted=1; next }
    { print }
  ' docs/CHANGELOG.md > "$TMPFILE" && mv "$TMPFILE" docs/CHANGELOG.md
fi

# Stage the changelog
git add docs/CHANGELOG.md 2>/dev/null || rtk git add docs/CHANGELOG.md 2>/dev/null || true

# ── Update MR description (GitLab only, feature branches) ────────────────────

# Only run on non-main branches
if [ -z "$BRANCH" ] || [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  exit 0
fi

# Only if GITLAB_TOKEN is set
if [ -z "${GITLAB_TOKEN:-}" ]; then
  exit 0
fi

# Detect GitLab remote
REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
if ! echo "$REMOTE_URL" | grep -qi "gitlab"; then
  exit 0
fi

# Extract project path and host
if echo "$REMOTE_URL" | grep -q "^git@"; then
  # SSH format: git@gitlab.example.com:group/project.git
  GITLAB_HOST=$(echo "$REMOTE_URL" | sed 's/git@//' | sed 's/:.*//')
  PROJECT_PATH=$(echo "$REMOTE_URL" | sed 's/.*://' | sed 's/\.git$//')
else
  # HTTPS format: https://gitlab.example.com/group/project.git
  GITLAB_HOST=$(echo "$REMOTE_URL" | sed 's|https://||' | sed 's|/.*||')
  PROJECT_PATH=$(echo "$REMOTE_URL" | sed "s|https://$GITLAB_HOST/||" | sed 's/\.git$//')
fi

ENCODED_PATH=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$PROJECT_PATH" 2>/dev/null || echo "")
if [ -z "$ENCODED_PATH" ]; then
  exit 0
fi

# Find open MR for this branch
MR_IID=$(curl -sf \
  -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://$GITLAB_HOST/api/v4/projects/$ENCODED_PATH/merge_requests?source_branch=$BRANCH&state=opened" \
  2>/dev/null | jq -r '.[0].iid // empty' 2>/dev/null || echo "")

if [ -z "$MR_IID" ]; then
  exit 0
fi

# Build commit list since branch diverged from main/master
BASE_BRANCH="main"
git show-ref --verify --quiet refs/heads/master 2>/dev/null && BASE_BRANCH="master"
COMMIT_LIST=$(git log "origin/$BASE_BRANCH..HEAD" --oneline 2>/dev/null | head -15 | sed 's/^/- /' || echo "- $CLEAN_MSG")

# Read recent decisions if available
DECISIONS_BLOCK=""
if [ -f "docs/DECISIONS.md" ]; then
  DECISIONS_BLOCK=$(grep -A5 '^\#\# \[' docs/DECISIONS.md 2>/dev/null | head -20 | grep -v '^--$' | sed 's/^/  /' || echo "")
fi

# Build AI Review Context block
AI_CONTEXT=$(cat << AIEOF
---
## AI Review Context

**Changes in this MR:**
$COMMIT_LIST

**Full context:** \`docs/ARCHITECTURE.md\`, \`docs/DECISIONS.md\`
AIEOF
)

if [ -n "$DECISIONS_BLOCK" ]; then
  AI_CONTEXT=$(cat << AIEOF
---
## AI Review Context

**Changes in this MR:**
$COMMIT_LIST

**Key decisions & tradeoffs:**
$DECISIONS_BLOCK

**Full context:** \`docs/ARCHITECTURE.md\`, \`docs/DECISIONS.md\`
AIEOF
)
fi

# Get current MR description
CURRENT_DESC=$(curl -sf \
  -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://$GITLAB_HOST/api/v4/projects/$ENCODED_PATH/merge_requests/$MR_IID" \
  2>/dev/null | jq -r '.description // ""' 2>/dev/null || echo "")

# Remove existing AI Review Context block if present
CLEANED_DESC=$(echo "$CURRENT_DESC" | awk '
  /^---$/ { maybe_start = 1; buffer = $0 "\n"; next }
  maybe_start && /^## AI Review Context/ { skip = 1; buffer = ""; next }
  maybe_start && !skip { printf "%s", buffer; maybe_start = 0 }
  skip && /^---$/ { skip = 0; maybe_start = 0; next }
  !skip { print }
')

NEW_DESC="${CLEANED_DESC}

${AI_CONTEXT}"

# Update MR description
curl -sf -X PUT \
  -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"description\": $(echo "$NEW_DESC" | jq -Rs .)}" \
  "https://$GITLAB_HOST/api/v4/projects/$ENCODED_PATH/merge_requests/$MR_IID" \
  > /dev/null 2>&1 || true

exit 0

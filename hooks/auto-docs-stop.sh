#!/usr/bin/env bash
# Auto-docs Stop hook — detects meaningful work, prompts Claude to document it
# Receives JSON on stdin from Claude Code Stop hook event

set -euo pipefail

INPUT=$(cat)

# Bug 1: Skip when hook is firing during its own processing loop
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

# Extract fields from hook JSON
WORKING_DIR=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")

# Fall back to pwd if cwd not in hook data
[ -z "$WORKING_DIR" ] && WORKING_DIR=$(pwd)

# Skip if toggle present
if [ -f "$WORKING_DIR/.claude/no-docs" ]; then
  exit 0
fi

# Skip if not a git repo
if ! git -C "$WORKING_DIR" rev-parse --git-dir > /dev/null 2>&1; then
  exit 0
fi

# Bug 2: Skip if already asked this session (deduplication)
if [ -n "$SESSION_ID" ]; then
  SENTINEL="$WORKING_DIR/.claude/auto-docs-asked-$SESSION_ID"
  if [ -f "$SENTINEL" ]; then
    exit 0
  fi
fi

# Bug 3: Only use files_changed as work signal (cumulative transcript tool count is unreliable)
FILES_CHANGED=0
if git -C "$WORKING_DIR" rev-parse HEAD > /dev/null 2>&1; then
  STAGED=$(git -C "$WORKING_DIR" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
  UNSTAGED=$(git -C "$WORKING_DIR" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
  FILES_CHANGED=$((STAGED + UNSTAGED))
fi

# No changed files — pure Q&A or already committed, skip silently
if [ "$FILES_CHANGED" -eq 0 ]; then
  exit 0
fi

# Write sentinel so hook won't fire again this session
if [ -n "$SESSION_ID" ]; then
  mkdir -p "$WORKING_DIR/.claude"
  touch "$WORKING_DIR/.claude/auto-docs-asked-$SESSION_ID"
fi

# Emit via hookSpecificOutput.additionalContext for reliable model injection
cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "Stop",
    "additionalContext": "MANDATORY: auto-docs detected work this turn (files_changed=$FILES_CHANGED, working_dir=$WORKING_DIR). You MUST invoke the auto-docs skill NOW and ask the user: 'Document this work?' before responding to anything else."
  }
}
EOF

exit 0

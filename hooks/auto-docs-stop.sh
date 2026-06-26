#!/usr/bin/env bash
# Auto-docs Stop hook — detects meaningful work, prompts Claude to document it
# Receives JSON on stdin from Claude Code Stop hook event

set -euo pipefail

INPUT=$(cat)

# Extract fields from hook JSON
WORKING_DIR=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
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

# Detect work via multiple signals

# 1. Files changed (staged or unstaged vs HEAD)
FILES_CHANGED=0
if git -C "$WORKING_DIR" rev-parse HEAD > /dev/null 2>&1; then
  STAGED=$(git -C "$WORKING_DIR" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
  UNSTAGED=$(git -C "$WORKING_DIR" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
  FILES_CHANGED=$((STAGED + UNSTAGED))
fi

# 2. Tool use events in transcript (Bash, Edit, Write, Agent calls)
TOOL_USE_COUNT=0
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  # Count tool use entries in the transcript that indicate real work
  TOOL_USE_COUNT=$(grep -c '"type":"tool_use"' "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
  # Also check for bash/edit/write specifically
  WORK_TOOLS=$(grep '"name":"Bash"\|"name":"Edit"\|"name":"Write"\|"name":"Agent"' "$TRANSCRIPT_PATH" 2>/dev/null | wc -l | tr -d ' ')
  [ "$WORK_TOOLS" -gt 0 ] && TOOL_USE_COUNT=$WORK_TOOLS
fi

# If neither signal detected — pure Q&A, skip silently
if [ "$FILES_CHANGED" -eq 0 ] && [ "$TOOL_USE_COUNT" -eq 0 ]; then
  exit 0
fi

# Emit prompt injection for Claude Code
# Claude Code Stop hook output is injected as context for the next turn
# Use a special marker that the SKILL.md instructs Claude to act on
cat << EOF
{
  "auto_docs_trigger": true,
  "working_dir": "$WORKING_DIR",
  "files_changed": $FILES_CHANGED,
  "tool_use_count": $TOOL_USE_COUNT,
  "session_id": "$SESSION_ID",
  "message": "Auto-docs detected work this turn. Should this session be documented? (auto-docs skill)"
}
EOF

exit 0

#!/usr/bin/env bash
# Auto-docs Stop hook. It only detects Git work and asks Claude to decide
# whether documentation is warranted; session state is deliberately external
# to the repository.

set -euo pipefail

INPUT=$(cat)
STOP_HOOK_ACTIVE=$(jq -r '.stop_hook_active // false' <<< "$INPUT" 2>/dev/null || printf 'false')
[ "$STOP_HOOK_ACTIVE" = 'true' ] && exit 0

WORKING_DIR=$(jq -r '.cwd // empty' <<< "$INPUT" 2>/dev/null || true)
SESSION_ID=$(jq -r '.session_id // empty' <<< "$INPUT" 2>/dev/null || true)
[ -n "$WORKING_DIR" ] || WORKING_DIR=$(pwd)

REPO_ROOT=$(git -C "$WORKING_DIR" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || exit 0
[ -f "$REPO_ROOT/.claude/no-docs" ] && exit 0
CANONICAL_REPO_ROOT=$(cd -P -- "$REPO_ROOT" && pwd)

canonicalize_missing_path() {
  local target="$1" parent leaf suffix=''
  while [ ! -e "$target" ]; do
    [ "$target" = '/' ] && return 1
    leaf=${target##*/}
    parent=${target%/*}
    [ -n "$parent" ] || parent='/'
    suffix="/$leaf$suffix"
    target=$parent
  done
  [ -d "$target" ] || return 1
  printf '%s%s\n' "$(cd -P -- "$target" && pwd)" "$suffix"
}

is_outside_repository() {
  case "$1" in
    "$CANONICAL_REPO_ROOT"|"$CANONICAL_REPO_ROOT"/*) return 1 ;;
    *) return 0 ;;
  esac
}

# Porcelain status works for tracked, staged, untracked, and repositories
# without an initial commit. Count records rather than trying to infer work
# from a transcript or from diff against HEAD.
STATUS=$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)
[ -n "$STATUS" ] || exit 0
FILES_CHANGED=$(printf '%s\n' "$STATUS" | wc -l | tr -d ' ')

if [ -n "$SESSION_ID" ]; then
  case "${HOME:-}" in
    /*) DEFAULT_STATE_BASE="$HOME/.local/state" ;;
    *) exit 0 ;;
  esac
  case "${XDG_STATE_HOME:-}" in
    /*) STATE_BASE="$XDG_STATE_HOME" ;;
    *) STATE_BASE="$DEFAULT_STATE_BASE" ;;
  esac
  STATE_DIR=$(canonicalize_missing_path "$STATE_BASE/claude-auto-docs" || true)
  if [ -z "$STATE_DIR" ] || ! is_outside_repository "$STATE_DIR"; then
    STATE_DIR=$(canonicalize_missing_path "$DEFAULT_STATE_BASE/claude-auto-docs" || true)
  fi
  [ -n "$STATE_DIR" ] && is_outside_repository "$STATE_DIR" || exit 0
  STATE_KEY=$(printf '%s\0%s' "$REPO_ROOT" "$SESSION_ID" | shasum -a 256 | awk '{print $1}')
  SENTINEL="$STATE_DIR/$STATE_KEY"
  mkdir -p "$STATE_DIR"
  mkdir "$SENTINEL" 2>/dev/null || exit 0
fi

jq -cn \
  --arg context "MANDATORY: auto-docs detected work this turn (files_changed=$FILES_CHANGED, working_dir=$REPO_ROOT). You MUST invoke the auto-docs skill NOW and ask the user: 'Document this work?' before responding to anything else." \
  '{hookSpecificOutput:{hookEventName:"Stop",additionalContext:$context}}'

#!/usr/bin/env bash
# Auto-docs post-commit hook. GitLab integration is optional and must only
# receive a token for explicitly trusted GitLab hosts.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || exit 0
[ -f "$REPO_ROOT/.claude/no-docs" ] && exit 0
[ -n "${GITLAB_TOKEN:-}" ] || exit 0
case "$GITLAB_TOKEN" in
  *$'\r'*|*$'\n'*) exit 0 ;;
esac

WORK_DIR=''
cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

safe_curl() {
  curl --disable --fail --silent --show-error \
    --proto '=https' --proto-redir '=https' --max-redirs 0 \
    --connect-timeout 5 --max-time 15 \
    -H "@$TOKEN_HEADER" "$@"
}

cd "$REPO_ROOT"
BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
case "$BRANCH" in
  ''|main|master) exit 0 ;;
esac

REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
[ -n "$REMOTE_URL" ] || exit 0

GITLAB_HOST=''
PROJECT_PATH=''
case "$REMOTE_URL" in
  git@*:* )
    GITLAB_HOST=${REMOTE_URL#git@}
    GITLAB_HOST=${GITLAB_HOST%%:*}
    PROJECT_PATH=${REMOTE_URL#*:}
    ;;
  ssh://git@*/* )
    GITLAB_HOST=${REMOTE_URL#ssh://git@}
    GITLAB_HOST=${GITLAB_HOST%%/*}
    PROJECT_PATH=${REMOTE_URL#ssh://git@*/}
    ;;
  https://*/*|http://*/* )
    WITHOUT_SCHEME=${REMOTE_URL#*://}
    GITLAB_HOST=${WITHOUT_SCHEME%%/*}
    PROJECT_PATH=${WITHOUT_SCHEME#*/}
    ;;
  *) exit 0 ;;
esac
PROJECT_PATH=${PROJECT_PATH%.git}
[ -n "$GITLAB_HOST" ] && [ -n "$PROJECT_PATH" ] || exit 0

ALLOWED_HOSTS=${AUTO_DOCS_GITLAB_HOSTS:-gitlab.com}
HOST_ALLOWED=false
while IFS= read -r ALLOWED_HOST; do
  [ -n "$ALLOWED_HOST" ] && [ "$GITLAB_HOST" = "$ALLOWED_HOST" ] && HOST_ALLOWED=true
done < <(printf '%s\n' "$ALLOWED_HOSTS" | tr ', ' '\n')
[ "$HOST_ALLOWED" = true ] || exit 0

# Keep credentials out of argv and environment expansion at the curl boundary.
# curl reads one header per line from @file; the token was already constrained
# to one line, and the private directory and file are removed by the exit trap.
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/auto-docs-mr.XXXXXX")
chmod 0700 "$WORK_DIR"
TOKEN_HEADER="$WORK_DIR/gitlab-token-header"
(umask 077; printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN" > "$TOKEN_HEADER")
chmod 0600 "$TOKEN_HEADER"

ENCODED_PROJECT=$(jq -rn --arg value "$PROJECT_PATH" '$value | @uri' 2>/dev/null || true)
ENCODED_BRANCH=$(jq -rn --arg value "$BRANCH" '$value | @uri' 2>/dev/null || true)
[ -n "$ENCODED_PROJECT" ] && [ -n "$ENCODED_BRANCH" ] || exit 0
API_BASE="https://${GITLAB_HOST}/api/v4/projects/${ENCODED_PROJECT}/merge_requests"

MR_LIST=$(safe_curl \
  "${API_BASE}?source_branch=${ENCODED_BRANCH}&state=opened" 2>/dev/null) || exit 0
MR_IID=$(jq -r '.[0].iid // empty' <<< "$MR_LIST" 2>/dev/null || true)
[ -n "$MR_IID" ] || exit 0

MR=$(safe_curl "${API_BASE}/${MR_IID}" 2>/dev/null) || exit 0
if ! jq -e '
  type == "object" and has("description") and
  (.description == null or (.description | type == "string"))
' >/dev/null 2>&1 <<< "$MR"; then
  exit 0
fi
MARKER_START='<!-- auto-docs:ai-review-context:start -->'
MARKER_END='<!-- auto-docs:ai-review-context:end -->'
COMMIT_LINE=$(git log -1 --format='- %h %s' 2>/dev/null || true)
[ -n "$COMMIT_LINE" ] || exit 0
AI_CONTEXT=$(printf '%s\n\n## AI Review Context\n\n**Changes in this commit:**\n%s\n\n%s' \
  "$MARKER_START" "$COMMIT_LINE" "$MARKER_END")

# Keep the description in files from this point forward: shell command
# substitution removes trailing newlines, which would corrupt text outside the
# managed marker span.
DESC_FILE="$WORK_DIR/current-description"
CONTEXT_FILE="$WORK_DIR/replacement-context"
NEW_DESC_FILE="$WORK_DIR/new-description"
jq -j 'if .description == null then "" else .description end' <<< "$MR" > "$DESC_FILE"
printf '%s' "$AI_CONTEXT" > "$CONTEXT_FILE"

START_COUNT=$(grep -Fxc -- "$MARKER_START" "$DESC_FILE" || true)
END_COUNT=$(grep -Fxc -- "$MARKER_END" "$DESC_FILE" || true)
if [ "$START_COUNT" -eq 0 ] && [ "$END_COUNT" -eq 0 ]; then
  cp "$DESC_FILE" "$NEW_DESC_FILE"
  if [ -s "$DESC_FILE" ]; then
    printf '\n\n' >> "$NEW_DESC_FILE"
  fi
  cat "$CONTEXT_FILE" >> "$NEW_DESC_FILE"
elif [ "$START_COUNT" -eq 1 ] && [ "$END_COUNT" -eq 1 ]; then
  START_LINE=$(grep -Fnx -- "$MARKER_START" "$DESC_FILE" | cut -d: -f1)
  END_LINE=$(grep -Fnx -- "$MARKER_END" "$DESC_FILE" | cut -d: -f1)
  [ "$START_LINE" -lt "$END_LINE" ] || exit 0
  awk -v start="$MARKER_START" -v end="$MARKER_END" -v context_file="$CONTEXT_FILE" '
    $0 == start {
      while ((getline context_line < context_file) > 0) {
        print context_line
      }
      close(context_file)
      skipping = 1
      next
    }
    skipping && $0 == end { skipping = 0; next }
    !skipping { print }
  ' "$DESC_FILE" > "$NEW_DESC_FILE"
  SOURCE_LAST_BYTE=$(tail -c 1 "$DESC_FILE" | od -An -tx1 | tr -d '[:space:]')
  if [ -n "$SOURCE_LAST_BYTE" ] && [ "$SOURCE_LAST_BYTE" != '0a' ]; then
    OUTPUT_BYTES=$(wc -c < "$NEW_DESC_FILE" | tr -d ' ')
    TRIMMED_FILE="$WORK_DIR/new-description-trimmed"
    dd if="$NEW_DESC_FILE" of="$TRIMMED_FILE" bs=1 count=$((OUTPUT_BYTES - 1)) 2>/dev/null
    mv "$TRIMMED_FILE" "$NEW_DESC_FILE"
  fi
else
  exit 0
fi
PAYLOAD=$(jq -cn --rawfile description "$NEW_DESC_FILE" '{description:$description}')

safe_curl -X PUT \
  -H 'Content-Type: application/json' \
  --data "$PAYLOAD" \
  "${API_BASE}/${MR_IID}" >/dev/null 2>&1 || true

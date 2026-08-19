test_tracked_change() {
  local root repo state output second_output distinct_output
  root=$(mktemp -d)
  repo="$root/repo"; state="$root/state"
  new_repo "$repo"; commit_file "$repo"
  printf 'tracked edit\n' >> "$repo/README.md"
  output=$(run_stop "$repo" "$state" tracked-session)
  assert_context 'tracked change' "$output"
  second_output=$(run_stop "$repo" "$state" tracked-session)
  assert_silent 'same-session deduplication' "$second_output"
  distinct_output=$(run_stop "$repo" "$state" distinct-session)
  assert_context 'distinct-session prompt' "$distinct_output"
  rm -rf "$root"
}

test_untracked_only() {
  local root repo state output
  root=$(mktemp -d)
  repo="$root/repo"; state="$root/state"
  new_repo "$repo"; commit_file "$repo"
  printf 'untracked\n' > "$repo/new.txt"
  output=$(run_stop "$repo" "$state" untracked-session)
  assert_context 'untracked-only change' "$output"
  rm -rf "$root"
}

test_no_head_staged_change() {
  local root repo state output
  root=$(mktemp -d)
  repo="$root/repo"; state="$root/state"
  new_repo "$repo"
  printf 'first file\n' > "$repo/first.txt"
  git -C "$repo" add first.txt
  output=$(run_stop "$repo" "$state" no-head-session)
  assert_context 'no-HEAD staged change' "$output"
  rm -rf "$root"
}

test_opt_out() {
  local root repo state output
  root=$(mktemp -d)
  repo="$root/repo"; state="$root/state"
  new_repo "$repo"; commit_file "$repo"
  mkdir -p "$repo/.claude"
  : > "$repo/.claude/no-docs"
  printf 'tracked edit\n' >> "$repo/README.md"
  output=$(run_stop "$repo" "$state" opt-out-session)
  assert_silent 'project .claude/no-docs opt-out' "$output"
  rm -rf "$root"
}

test_no_project_sentinel() {
  local root repo state output state_entries before after project_writes
  root=$(mktemp -d)
  repo="$root/repo"; state="$root/state"
  new_repo "$repo"; commit_file "$repo"
  printf 'tracked edit\n' >> "$repo/README.md"
  find "$repo" -mindepth 1 -type f -not -path "$repo/.git/*" -print | sort > "$root/project-files.before"
  output=$(run_stop "$repo" "$state" external-state-session)
  assert_context 'no project sentinel' "$output"

  find "$repo" -mindepth 1 -type f -not -path "$repo/.git/*" -print | sort > "$root/project-files.after"
  project_writes=$(comm -13 "$root/project-files.before" "$root/project-files.after")
  if [ -n "$project_writes" ]; then
    fail "no project sentinel: hook wrote project files: $project_writes"
  fi
  state_entries=$(find "$state" -mindepth 1 -print 2>/dev/null | wc -l | tr -d ' ')
  if [ "$state_entries" -eq 0 ]; then
    fail 'no project sentinel: hook did not write session state outside project'
  fi
  rm -rf "$root"
}

test_pre_commit_stages_changelog() {
  local root repo message staged committed
  root=$(mktemp -d)
  repo="$root/repo"
  new_repo "$repo"; commit_file "$repo"
  printf 'feature work\n' > "$repo/feature.txt"
  git -C "$repo" add feature.txt
  message="$root/commit-message"
  printf 'feat: reliable changelog\n\nThis body must not become a changelog subject.\n' > "$message"

  if ! run_pre_commit "$repo"; then
    fail 'pre-commit changelog: hook exited nonzero'
    rm -rf "$root"
    return
  fi
  staged=$(git -C "$repo" diff --cached --name-only)
  if ! printf '%s\n' "$staged" | grep -qx 'docs/CHANGELOG.md'; then
    fail 'pre-commit changelog: CHANGELOG was not staged'
    rm -rf "$root"
    return
  fi
  if ! git -C "$repo" commit -q -F "$message"; then
    fail 'pre-commit changelog: fixture commit failed'
    rm -rf "$root"
    return
  fi
  committed=$(git -C "$repo" show HEAD:docs/CHANGELOG.md 2>/dev/null || true)
  if ! grep -qx '## \[Unreleased\]' <<< "$committed"; then
    fail 'pre-commit changelog: committed CHANGELOG has no Unreleased section'
  elif ! git -C "$repo" diff-tree --no-commit-id --name-only -r HEAD | grep -qx 'docs/CHANGELOG.md'; then
    fail 'pre-commit changelog: CHANGELOG was not included in the same commit'
  else
    pass 'pre-commit stages CHANGELOG in the same commit'
  fi
  rm -rf "$root"
}

test_pre_commit_rejects_docs_symlink_escape() {
  local root repo outside before after
  root=$(mktemp -d)
  repo="$root/repo"; outside="$root/outside"
  new_repo "$repo"; commit_file "$repo"
  mkdir -p "$outside"
  printf 'outside must not change\n' > "$outside/CHANGELOG.md"
  ln -s "$outside" "$repo/docs"
  printf 'feature work\n' > "$repo/feature.txt"
  git -C "$repo" add feature.txt
  before=$(cksum "$outside/CHANGELOG.md")
  run_pre_commit "$repo" >/dev/null 2>&1 || true
  after=$(cksum "$outside/CHANGELOG.md")
  if [ "$before" != "$after" ]; then
    fail 'pre-commit symlink confinement: wrote through docs symlink outside repository'
  else
    pass 'pre-commit rejects docs symlink escape before writing'
  fi
  rm -rf "$root"
}

test_pre_commit_is_idempotent_for_pending_tree() {
  local root repo once twice changed_headers entries temp_files
  root=$(mktemp -d)
  repo="$root/repo"
  new_repo "$repo"; commit_file "$repo"
  printf 'feature work\n' > "$repo/feature.txt"
  git -C "$repo" add feature.txt
  run_pre_commit "$repo"
  once=$(git -C "$repo" show :docs/CHANGELOG.md)
  run_pre_commit "$repo"
  twice=$(git -C "$repo" show :docs/CHANGELOG.md)
  changed_headers=$(grep -Fxc '### Changed' <<< "$twice" || true)
  entries=$(grep -Ec '^- ' <<< "$twice" || true)
  temp_files=$(find "$repo/docs" -maxdepth 1 -name '.auto-docs-*' -print)
  if [ "$once" != "$twice" ] || [ "$changed_headers" -ne 1 ] || [ "$entries" -ne 1 ] || [ -n "$temp_files" ]; then
    fail 'pre-commit pending-tree idempotence: retry changed CHANGELOG, duplicated entry, or leaked temp file'
  else
    pass 'pre-commit is idempotent for the same pending tree'
  fi
  rm -rf "$root"
}

test_pre_commit_records_equal_count_consecutive_commits() {
  local root repo first_blob second_blob entries
  root=$(mktemp -d)
  repo="$root/repo"
  new_repo "$repo"; commit_file "$repo"
  printf 'first feature\n' > "$repo/first.txt"
  git -C "$repo" add first.txt
  run_pre_commit "$repo"
  git -C "$repo" commit -q -m 'feat: first pending tree'
  first_blob=$(git -C "$repo" show HEAD:docs/CHANGELOG.md)
  printf 'second feature\n' > "$repo/second.txt"
  git -C "$repo" add second.txt
  run_pre_commit "$repo"
  second_blob=$(git -C "$repo" show :docs/CHANGELOG.md)
  entries=$(grep -Ec '^- ' <<< "$second_blob" || true)
  if [ "$first_blob" = "$second_blob" ] || [ "$entries" -ne 2 ]; then
    fail 'pre-commit equal-count commits: second staged tree did not get its own CHANGELOG entry'
  else
    pass 'pre-commit records consecutive equal-count commits'
  fi
  rm -rf "$root"
}

test_stop_uses_safe_absolute_external_state() {
  local root repo input relative_output contained_output
  root=$(mktemp -d)
  repo="$root/repo"
  new_repo "$repo"; commit_file "$repo"
  printf 'tracked edit\n' >> "$repo/README.md"
  input=$(jq -cn --arg cwd "$repo" --arg sid 'unsafe-state-session' \
    '{cwd:$cwd,session_id:$sid,stop_hook_active:false}')
  relative_output=$(cd "$repo" && XDG_STATE_HOME='relative-state' HOME="$root/home" bash "$STOP_HOOK" <<< "$input")
  if [ -e "$repo/relative-state" ] || ! jq -e '.hookSpecificOutput.hookEventName == "Stop"' >/dev/null 2>&1 <<< "$relative_output"; then
    fail 'Stop state confinement: relative XDG state wrote in project or suppressed prompt'
    rm -rf "$root"
    return
  fi
  input=$(jq -cn --arg cwd "$repo" --arg sid 'repo-contained-state-session' \
    '{cwd:$cwd,session_id:$sid,stop_hook_active:false}')
  contained_output=$(XDG_STATE_HOME="$repo/project-state" HOME="$root/home" bash "$STOP_HOOK" <<< "$input")
  if [ -e "$repo/project-state" ] || ! jq -e '.hookSpecificOutput.hookEventName == "Stop"' >/dev/null 2>&1 <<< "$contained_output"; then
    fail 'Stop state confinement: repo-contained XDG state wrote in project or suppressed prompt'
  else
    pass 'Stop state is absolute and external to the repository'
  fi
  rm -rf "$root"
}

test_stop_claims_session_atomically() {
  local root repo state input worker output contexts
  local -a pids=()
  root=$(mktemp -d)
  repo="$root/repo"; state="$root/state"
  new_repo "$repo"; commit_file "$repo"
  printf 'tracked edit\n' >> "$repo/README.md"
  input=$(jq -cn --arg cwd "$repo" --arg sid 'parallel-session' \
    '{cwd:$cwd,session_id:$sid,stop_hook_active:false}')
  for worker in $(seq 1 20); do
    XDG_STATE_HOME="$state" HOME="$root/home" bash "$STOP_HOOK" <<< "$input" > "$root/out-$worker" &
    pids+=("$!")
  done
  for worker in "${pids[@]}"; do
    wait "$worker" || true
  done
  output=$(cat "$root"/out-* 2>/dev/null || true)
  contexts=$(grep -Fc '"hookEventName":"Stop"' <<< "$output" || true)
  if [ "$contexts" -ne 1 ]; then
    fail "Stop atomic deduplication: expected one prompt, got $contexts"
  else
    pass 'Stop claims a session atomically'
  fi
  rm -rf "$root"
}

make_fake_curl() {
  local fake_bin="$1"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu

if [ -n "${FAKE_CURL_SECRET:-}" ]; then
  for argument in "$@"; do
    case "$argument" in
      *"$FAKE_CURL_SECRET"*)
        printf 'secret exposed in curl argument\n' >> "$FAKE_CURL_SECRET_LOG"
        exit 93
        ;;
    esac
  done
  previous=''
  for argument in "$@"; do
    if [ "$previous" = '-H' ] && [ "${argument#@}" != "$argument" ]; then
      header_file=${argument#@}
      mode=$(stat -f '%Lp' "$header_file" 2>/dev/null || stat -c '%a' "$header_file")
      [ "$mode" = '600' ] || printf 'header file mode was %s\n' "$mode" >> "$FAKE_CURL_SECRET_LOG"
      grep -Fqx "PRIVATE-TOKEN: $FAKE_CURL_SECRET" "$header_file" \
        || printf 'header file did not contain the token header\n' >> "$FAKE_CURL_SECRET_LOG"
      printf '%s\n' "$header_file" > "$FAKE_CURL_HEADER_PATH_LOG"
    fi
    previous=$argument
  done
fi

if [ "${FAKE_CURL_ENFORCE_POLICY:-0}" = '1' ]; then
  if [ "${1:-}" != '--disable' ]; then
    printf 'missing --disable as first argument\n' >> "$FAKE_CURL_POLICY_LOG"
    exit 91
  fi
  for required in '--proto =https' '--proto-redir =https' '--max-redirs 0' '--connect-timeout ' '--max-time '; do
    case " $* " in
      *"$required"*) ;;
      *)
        printf 'missing HTTPS, redirect, or timeout bounds: %s\n' "$*" >> "$FAKE_CURL_POLICY_LOG"
        exit 92
        ;;
    esac
  done
fi

url=''
method='GET'
body=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -d|--data|--data-raw) body="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$method" "$url" >> "$FAKE_CURL_LOG"
request_count=$(wc -l < "$FAKE_CURL_LOG" | tr -d ' ')
if [ "$method" = 'PUT' ]; then
  printf '%s' "$body" > "$FAKE_CURL_BODY"
  printf '{}\n'
elif [[ "$url" == *'merge_requests?'* ]]; then
  printf '[{"iid":42}]\n'
elif [ "${FAKE_CURL_SCENARIO:-normal}" = 'mr-get-failure' ]; then
  exit 22
elif [ "${FAKE_CURL_SCENARIO:-normal}" = 'mr-get-malformed' ]; then
  printf '%s\n' 'not-json'
elif [ "${FAKE_CURL_SCENARIO:-normal}" = 'nested-marker' ]; then
  printf '%s\n' '{"description":"Prefix stays.\n<!-- auto-docs:ai-review-context:start -->\nUser-owned text stays.\n<!-- auto-docs:ai-review-context:start -->\nOld managed text.\n<!-- auto-docs:ai-review-context:end -->\nSuffix stays."}'
elif [ "${FAKE_CURL_SCENARIO:-normal}" = 'trailing-newlines' ]; then
  printf '%s\n' '{"description":"Prefix line\n\n<!-- auto-docs:ai-review-context:start -->\nOld managed text.\n<!-- auto-docs:ai-review-context:end -->\nSuffix line\n\n"}'
elif [ "${FAKE_CURL_SCENARIO:-normal}" = 'no-final-newline' ]; then
  printf '%s\n' '{"description":"Prefix line\n<!-- auto-docs:ai-review-context:start -->\nOld managed text.\n<!-- auto-docs:ai-review-context:end -->\nSuffix-without-newline"}'
else
  printf '%s\n' '{"description":"Intro stays.\n---\nUnrelated separator stays.\n<!-- auto-docs:ai-review-context:start -->\nOld managed text.\n<!-- auto-docs:ai-review-context:end -->\nTail stays."}'
fi
EOF
  chmod +x "$fake_bin/curl"
}

test_pre_commit_scopes_changed_to_unreleased() {
  local root repo staged unreleased released
  root=$(mktemp -d)
  repo="$root/repo"
  new_repo "$repo"; commit_file "$repo"
  mkdir -p "$repo/docs"
  printf '%s\n' '# Changelog' '' '## [Unreleased]' '' '### Added' '- Existing unreleased item' '' '## [1.0.0]' '' '### Changed' '- Historical entry' > "$repo/docs/CHANGELOG.md"
  git -C "$repo" add docs/CHANGELOG.md
  git -C "$repo" commit -q -m 'docs: add changelog history'
  printf 'feature work\n' > "$repo/feature.txt"
  git -C "$repo" add feature.txt
  run_pre_commit "$repo"
  staged=$(git -C "$repo" show :docs/CHANGELOG.md)
  unreleased=$(sed -n '/^## \[Unreleased\]$/,/^## /p' <<< "$staged")
  released=$(sed -n '/^## \[1.0.0\]$/,$p' <<< "$staged")
  if ! grep -Fqx '### Changed' <<< "$unreleased" || ! grep -Fq '<!-- auto-docs:pending-parent:' <<< "$unreleased"; then
    fail 'pre-commit Unreleased scope: did not create Changed entry under Unreleased'
  elif grep -Fq '<!-- auto-docs:pending-parent:' <<< "$released" || grep -Fq 'Updated 1 staged file(s).' <<< "$released"; then
    fail 'pre-commit Unreleased scope: modified historical release section'
  else
    pass 'pre-commit scopes Changed entries to Unreleased'
  fi
  rm -rf "$root"
}

test_pre_commit_restages_current_managed_entry() {
  local root repo staged
  root=$(mktemp -d)
  repo="$root/repo"
  new_repo "$repo"; commit_file "$repo"
  printf 'feature work\n' > "$repo/feature.txt"
  git -C "$repo" add feature.txt
  run_pre_commit "$repo"
  git -C "$repo" reset -q -- docs/CHANGELOG.md
  run_pre_commit "$repo"
  staged=$(git -C "$repo" diff --cached --name-only)
  if ! grep -Fqx 'docs/CHANGELOG.md' <<< "$staged"; then
    fail 'pre-commit managed entry retry: existing generated CHANGELOG was not staged'
  else
    pass 'pre-commit restages the current managed entry on retry'
  fi
  rm -rf "$root"
}

test_pre_commit_reconciles_changed_pending_tree() {
  local root repo staged markers entries
  root=$(mktemp -d)
  repo="$root/repo"
  new_repo "$repo"; commit_file "$repo"
  printf 'first feature\n' > "$repo/first.txt"
  git -C "$repo" add first.txt
  run_pre_commit "$repo"
  printf 'second feature\n' > "$repo/second.txt"
  git -C "$repo" add second.txt
  run_pre_commit "$repo"
  staged=$(git -C "$repo" show :docs/CHANGELOG.md)
  markers=$(grep -Ec '^<!-- auto-docs:pending-parent:.+:staged-tree:[0-9a-f]+ -->$' <<< "$staged" || true)
  entries=$(grep -Ec '^- Updated [0-9]+ staged file\(s\)\.$' <<< "$staged" || true)
  if [ "$markers" -ne 1 ] || [ "$entries" -ne 1 ]; then
    fail 'pre-commit pending-tree reconciliation: retained stale managed entry after index changed'
  else
    pass 'pre-commit reconciles one managed entry for a changed pending tree'
  fi
  rm -rf "$root"
}

test_pre_commit_fails_closed_on_unstaged_changelog_edits() {
  local root repo before_worktree before_index after_worktree after_index
  root=$(mktemp -d)
  repo="$root/repo"
  new_repo "$repo"; commit_file "$repo"
  mkdir -p "$repo/docs"
  printf '%s\n' '# Changelog' '' '## [Unreleased]' > "$repo/docs/CHANGELOG.md"
  git -C "$repo" add docs/CHANGELOG.md
  git -C "$repo" commit -q -m 'docs: add changelog'
  printf 'feature work\n' > "$repo/feature.txt"
  git -C "$repo" add feature.txt
  printf '\nPrivate unfinished changelog note.\n' >> "$repo/docs/CHANGELOG.md"
  before_worktree=$(cksum "$repo/docs/CHANGELOG.md")
  before_index=$(git -C "$repo" show :docs/CHANGELOG.md | cksum)
  if run_pre_commit "$repo" >/dev/null 2>&1; then
    fail 'pre-commit partial staging: accepted a CHANGELOG with unstaged edits'
  else
    after_worktree=$(cksum "$repo/docs/CHANGELOG.md")
    after_index=$(git -C "$repo" show :docs/CHANGELOG.md | cksum)
    if [ "$before_worktree" != "$after_worktree" ] || [ "$before_index" != "$after_index" ]; then
      fail 'pre-commit partial staging: changed the worktree or index before refusing'
    else
      pass 'pre-commit fails closed without staging unrelated CHANGELOG edits'
    fi
  fi
  rm -rf "$root"
}

test_pre_commit_fails_closed_on_unstaged_changelog_deletion() {
  local root repo before_index after_index
  root=$(mktemp -d)
  repo="$root/repo"
  new_repo "$repo"; commit_file "$repo"
  mkdir -p "$repo/docs"
  printf '%s\n' '# Changelog' '' '## [Unreleased]' > "$repo/docs/CHANGELOG.md"
  git -C "$repo" add docs/CHANGELOG.md
  git -C "$repo" commit -q -m 'docs: add changelog'
  printf 'feature work\n' > "$repo/feature.txt"
  git -C "$repo" add feature.txt
  rm "$repo/docs/CHANGELOG.md"
  before_index=$(git -C "$repo" show :docs/CHANGELOG.md | cksum)
  if run_pre_commit "$repo" >/dev/null 2>&1; then
    fail 'pre-commit unstaged deletion: recreated and staged a deleted CHANGELOG'
  else
    after_index=$(git -C "$repo" show :docs/CHANGELOG.md | cksum)
    if [ -e "$repo/docs/CHANGELOG.md" ] || [ "$before_index" != "$after_index" ]; then
      fail 'pre-commit unstaged deletion: changed the worktree or index before refusing'
    else
      pass 'pre-commit fails closed without erasing an unstaged CHANGELOG deletion'
    fi
  fi
  rm -rf "$root"
}

test_post_commit_denies_unlisted_host() {
  local root repo fake_bin curl_log curl_body
  root=$(mktemp -d)
  repo="$root/repo"; fake_bin="$root/fake-bin"
  curl_log="$root/curl.log"; curl_body="$root/curl-body.json"
  new_repo "$repo"; commit_file "$repo"
  git -C "$repo" branch -M feature/deny-host
  git -C "$repo" remote add origin 'git@gitlab.example.invalid:group/project.git'
  printf 'next\n' > "$repo/next.txt"
  git -C "$repo" add next.txt
  git -C "$repo" commit -q -m 'feat: denied host'
  make_fake_curl "$fake_bin"
  : > "$curl_log"
  if ! (cd "$repo" && PATH="$fake_bin:$PATH" FAKE_CURL_LOG="$curl_log" FAKE_CURL_BODY="$curl_body" \
      AUTO_DOCS_GITLAB_HOSTS='gitlab.com' GITLAB_TOKEN='test-token' bash "$POST_COMMIT_HOOK"); then
    fail 'post-commit denied host: hook exited nonzero'
  elif [ -s "$curl_log" ]; then
    fail 'post-commit denied host: fake curl was called for an unlisted host'
  else
    pass 'post-commit denies unlisted GitLab host before curl'
  fi
  rm -rf "$root"
}

test_post_commit_replaces_only_managed_marker() {
  local root repo fake_bin curl_log curl_body description starts ends
  root=$(mktemp -d)
  repo="$root/repo"; fake_bin="$root/fake-bin"
  curl_log="$root/curl.log"; curl_body="$root/curl-body.json"
  new_repo "$repo"; commit_file "$repo"
  git -C "$repo" branch -M feature/mr-context
  git -C "$repo" remote add origin 'git@gitlab.com:group/project.git'
  printf 'next\n' > "$repo/next.txt"
  git -C "$repo" add next.txt
  git -C "$repo" commit -q -m $'feat: one-line subject\n\nPrivate body must not be copied to the MR context.'
  make_fake_curl "$fake_bin"
  : > "$curl_log"
  if ! (cd "$repo" && PATH="$fake_bin:$PATH" FAKE_CURL_LOG="$curl_log" FAKE_CURL_BODY="$curl_body" \
      AUTO_DOCS_GITLAB_HOSTS='gitlab.com' GITLAB_TOKEN='test-token' bash "$POST_COMMIT_HOOK"); then
    fail 'post-commit marker replacement: hook exited nonzero'
    rm -rf "$root"
    return
  fi
  if [ ! -s "$curl_body" ]; then
    fail "post-commit marker replacement: no MR update request was made (curl log: $(tr '\n' ';' < "$curl_log"))"
    rm -rf "$root"
    return
  fi
  description=$(jq -r '.description' < "$curl_body" 2>/dev/null || true)
  starts=$(grep -Fxc '<!-- auto-docs:ai-review-context:start -->' <<< "$description" || true)
  ends=$(grep -Fxc '<!-- auto-docs:ai-review-context:end -->' <<< "$description" || true)
  if ! grep -Fqx -- '---' <<< "$description" || ! grep -Fqx -- 'Unrelated separator stays.' <<< "$description" || ! grep -Fqx -- 'Tail stays.' <<< "$description"; then
    fail 'post-commit marker replacement: text outside exact markers changed'
  elif [[ "$description" != $'Intro stays.\n---\nUnrelated separator stays.\n<!-- auto-docs:ai-review-context:start -->'* ]] || ! grep -Fq $'<!-- auto-docs:ai-review-context:end -->\nTail stays.' <<< "$description"; then
    fail 'post-commit marker replacement: marker block was not replaced in place'
  elif grep -Fq 'Old managed text.' <<< "$description"; then
    fail 'post-commit marker replacement: previous managed block remained'
  elif [ "$starts" -ne 1 ] || [ "$ends" -ne 1 ]; then
    fail 'post-commit marker replacement: expected exactly one managed marker pair'
  elif ! grep -Fq 'feat: one-line subject' <<< "$description" || grep -Fq 'Private body must not be copied' <<< "$description"; then
    fail 'post-commit marker replacement: commit subjects were not single-line'
  else
    pass 'post-commit replaces only its bounded marker and uses subjects'
  fi
  rm -rf "$root"
}

test_post_commit_preserves_marker_surrounding_bytes() {
  local root repo fake_bin curl_log curl_body description prefix suffix prefix_len suffix_len
  root=$(mktemp -d)
  repo="$root/repo"; fake_bin="$root/fake-bin"
  curl_log="$root/curl.log"; curl_body="$root/curl-body.json"; description="$root/description"
  prefix="$root/prefix"; suffix="$root/suffix"
  new_repo "$repo"; commit_file "$repo"
  git -C "$repo" branch -M feature/byte-preservation
  git -C "$repo" remote add origin 'git@gitlab.com:group/project.git'
  printf 'next\n' > "$repo/next.txt"
  git -C "$repo" add next.txt
  git -C "$repo" commit -q -m 'feat: preserve surrounding bytes'
  make_fake_curl "$fake_bin"
  : > "$curl_log"
  (cd "$repo" && PATH="$fake_bin:$PATH" FAKE_CURL_LOG="$curl_log" FAKE_CURL_BODY="$curl_body" \
    FAKE_CURL_SCENARIO='trailing-newlines' AUTO_DOCS_GITLAB_HOSTS='gitlab.com' GITLAB_TOKEN='test-token' \
    bash "$POST_COMMIT_HOOK")
  jq -j '.description' < "$curl_body" > "$description" 2>/dev/null || true
  printf 'Prefix line\n\n' > "$prefix"
  printf '\nSuffix line\n\n' > "$suffix"
  prefix_len=$(wc -c < "$prefix" | tr -d ' ')
  suffix_len=$(wc -c < "$suffix" | tr -d ' ')
  if [ ! -s "$description" ] || ! head -c "$prefix_len" "$description" | cmp -s "$prefix" - || ! tail -c "$suffix_len" "$description" | cmp -s "$suffix" -; then
    fail 'post-commit marker replacement: did not preserve byte-exact prefix and suffix'
  else
    pass 'post-commit preserves byte-exact marker surroundings'
  fi
  rm -rf "$root"
}

test_post_commit_preserves_suffix_without_final_newline() {
  local root repo fake_bin curl_log curl_body description prefix suffix prefix_len suffix_len
  root=$(mktemp -d)
  repo="$root/repo"; fake_bin="$root/fake-bin"
  curl_log="$root/curl.log"; curl_body="$root/curl-body.json"; description="$root/description"
  prefix="$root/prefix"; suffix="$root/suffix"
  new_repo "$repo"; commit_file "$repo"
  git -C "$repo" branch -M feature/no-final-newline
  git -C "$repo" remote add origin 'git@gitlab.com:group/project.git'
  printf 'next\n' > "$repo/next.txt"
  git -C "$repo" add next.txt
  git -C "$repo" commit -q -m 'feat: preserve final byte'
  make_fake_curl "$fake_bin"
  : > "$curl_log"
  (cd "$repo" && PATH="$fake_bin:$PATH" FAKE_CURL_LOG="$curl_log" FAKE_CURL_BODY="$curl_body" \
    FAKE_CURL_SCENARIO='no-final-newline' AUTO_DOCS_GITLAB_HOSTS='gitlab.com' GITLAB_TOKEN='test-token' \
    bash "$POST_COMMIT_HOOK")
  jq -j '.description' < "$curl_body" > "$description" 2>/dev/null || true
  printf 'Prefix line\n' > "$prefix"
  printf '\nSuffix-without-newline' > "$suffix"
  prefix_len=$(wc -c < "$prefix" | tr -d ' ')
  suffix_len=$(wc -c < "$suffix" | tr -d ' ')
  if [ ! -s "$description" ] || ! head -c "$prefix_len" "$description" | cmp -s "$prefix" - || ! tail -c "$suffix_len" "$description" | cmp -s "$suffix" -; then
    fail 'post-commit marker replacement: did not preserve suffix without final newline'
  else
    pass 'post-commit preserves a suffix without final newline'
  fi
  rm -rf "$root"
}

test_post_commit_fails_closed_on_bad_mr_read() {
  local root repo fake_bin curl_log curl_body scenario
  root=$(mktemp -d)
  repo="$root/repo"; fake_bin="$root/fake-bin"
  curl_log="$root/curl.log"; curl_body="$root/curl-body.json"
  new_repo "$repo"; commit_file "$repo"
  git -C "$repo" branch -M feature/read-error
  git -C "$repo" remote add origin 'git@gitlab.com:group/project.git'
  printf 'next\n' > "$repo/next.txt"
  git -C "$repo" add next.txt
  git -C "$repo" commit -q -m 'feat: failed MR read'
  make_fake_curl "$fake_bin"
  for scenario in mr-get-failure mr-get-malformed; do
    : > "$curl_log"
    rm -f "$curl_body"
    (cd "$repo" && PATH="$fake_bin:$PATH" FAKE_CURL_LOG="$curl_log" FAKE_CURL_BODY="$curl_body" \
      FAKE_CURL_SCENARIO="$scenario" AUTO_DOCS_GITLAB_HOSTS='gitlab.com' GITLAB_TOKEN='test-token' \
      bash "$POST_COMMIT_HOOK")
    if [ -e "$curl_body" ]; then
      fail "post-commit bad MR read: attempted PUT after $scenario description GET"
      rm -rf "$root"
      return
    fi
  done
  pass 'post-commit fails closed when MR description GET fails or is malformed'
  rm -rf "$root"
}

test_post_commit_fails_closed_on_malformed_markers() {
  local root repo fake_bin curl_log curl_body
  root=$(mktemp -d)
  repo="$root/repo"; fake_bin="$root/fake-bin"
  curl_log="$root/curl.log"; curl_body="$root/curl-body.json"
  new_repo "$repo"; commit_file "$repo"
  git -C "$repo" branch -M feature/malformed-marker
  git -C "$repo" remote add origin 'git@gitlab.com:group/project.git'
  printf 'next\n' > "$repo/next.txt"
  git -C "$repo" add next.txt
  git -C "$repo" commit -q -m 'feat: malformed marker'
  make_fake_curl "$fake_bin"
  : > "$curl_log"
  (cd "$repo" && PATH="$fake_bin:$PATH" FAKE_CURL_LOG="$curl_log" FAKE_CURL_BODY="$curl_body" \
    FAKE_CURL_SCENARIO='nested-marker' AUTO_DOCS_GITLAB_HOSTS='gitlab.com' GITLAB_TOKEN='test-token' \
    bash "$POST_COMMIT_HOOK")
  if [ -e "$curl_body" ]; then
    fail 'post-commit malformed markers: attempted PUT for nested marker input'
  else
    pass 'post-commit fails closed on malformed marker blocks'
  fi
  rm -rf "$root"
}

test_post_commit_enforces_curl_transport_policy() {
  local root repo fake_bin curl_log curl_body policy_log
  root=$(mktemp -d)
  repo="$root/repo"; fake_bin="$root/fake-bin"
  curl_log="$root/curl.log"; curl_body="$root/curl-body.json"; policy_log="$root/curl-policy.log"
  new_repo "$repo"; commit_file "$repo"
  git -C "$repo" branch -M feature/curl-policy
  git -C "$repo" remote add origin 'git@gitlab.com:group/project.git'
  printf 'next\n' > "$repo/next.txt"
  git -C "$repo" add next.txt
  git -C "$repo" commit -q -m 'feat: curl policy'
  make_fake_curl "$fake_bin"
  : > "$curl_log"; : > "$policy_log"
  (cd "$repo" && PATH="$fake_bin:$PATH" FAKE_CURL_LOG="$curl_log" FAKE_CURL_BODY="$curl_body" \
    FAKE_CURL_POLICY_LOG="$policy_log" FAKE_CURL_ENFORCE_POLICY=1 AUTO_DOCS_GITLAB_HOSTS='gitlab.com' \
    GITLAB_TOKEN='test-token' bash "$POST_COMMIT_HOOK")
  if [ -s "$policy_log" ] || [ ! -s "$curl_body" ]; then
    fail "post-commit curl policy: --disable, HTTPS, redirect, or timeout policy missing ($(tr '\n' ';' < "$policy_log"))"
  else
    pass 'post-commit enforces curl transport policy on every request'
  fi
  rm -rf "$root"
}

test_post_commit_keeps_token_out_of_arguments_and_cleans_header_file() {
  local root repo fake_bin curl_log curl_body secret_log header_path_log header_path
  root=$(mktemp -d)
  repo="$root/repo"; fake_bin="$root/fake-bin"
  curl_log="$root/curl.log"; curl_body="$root/curl-body.json"
  secret_log="$root/secret.log"; header_path_log="$root/header-path.log"
  new_repo "$repo"; commit_file "$repo"
  git -C "$repo" branch -M feature/secret-header
  git -C "$repo" remote add origin 'git@gitlab.com:group/project.git'
  printf 'next\n' > "$repo/next.txt"
  git -C "$repo" add next.txt
  git -C "$repo" commit -q -m 'feat: protect curl token'
  make_fake_curl "$fake_bin"
  : > "$curl_log"; : > "$secret_log"; : > "$header_path_log"
  (cd "$repo" && PATH="$fake_bin:$PATH" FAKE_CURL_LOG="$curl_log" FAKE_CURL_BODY="$curl_body" \
    FAKE_CURL_SECRET_LOG="$secret_log" FAKE_CURL_HEADER_PATH_LOG="$header_path_log" \
    FAKE_CURL_SECRET='argument-secret' AUTO_DOCS_GITLAB_HOSTS='gitlab.com' \
    GITLAB_TOKEN='argument-secret' bash "$POST_COMMIT_HOOK")
  header_path=$(tail -1 "$header_path_log" 2>/dev/null || true)
  if [ -s "$secret_log" ] || [ -z "$header_path" ] || [ -e "$header_path" ] || [ ! -s "$curl_body" ]; then
    fail "post-commit token transport: token leaked, header was insecure/missing, or temp file remained ($(tr '\n' ';' < "$secret_log"))"
  else
    pass 'post-commit passes token through a protected temporary header file and cleans it'
  fi
  rm -rf "$root"
}

test_post_commit_rejects_multiline_token_before_curl() {
  local root repo fake_bin curl_log curl_body
  root=$(mktemp -d)
  repo="$root/repo"; fake_bin="$root/fake-bin"
  curl_log="$root/curl.log"; curl_body="$root/curl-body.json"
  new_repo "$repo"; commit_file "$repo"
  git -C "$repo" branch -M feature/reject-token
  git -C "$repo" remote add origin 'git@gitlab.com:group/project.git'
  make_fake_curl "$fake_bin"
  : > "$curl_log"
  (cd "$repo" && PATH="$fake_bin:$PATH" FAKE_CURL_LOG="$curl_log" FAKE_CURL_BODY="$curl_body" \
    AUTO_DOCS_GITLAB_HOSTS='gitlab.com' GITLAB_TOKEN=$'safe\r\nINJECTED: header' \
    bash "$POST_COMMIT_HOOK")
  if [ -s "$curl_log" ]; then
    fail 'post-commit token validation: curl ran for a CR/LF-bearing token'
  else
    pass 'post-commit rejects CR/LF-bearing tokens before curl'
  fi
  rm -rf "$root"
}

test_legacy_commit_msg_hook_is_noop() {
  local root repo message before after output
  root=$(mktemp -d)
  repo="$root/repo"
  new_repo "$repo"; commit_file "$repo"
  mkdir -p "$repo/docs"
  printf '# Existing changelog\n' > "$repo/docs/CHANGELOG.md"
  message="$root/commit-message"
  printf 'feat: should not mutate docs\n' > "$message"
  before=$(cksum "$repo/docs/CHANGELOG.md")
  if ! output=$(cd "$repo" && bash "$LEGACY_COMMIT_MSG_HOOK" "$message" 2>&1); then
    fail 'legacy prepare-commit-msg hook: compatibility hook exited nonzero'
  else
    after=$(cksum "$repo/docs/CHANGELOG.md")
    if [ "$before" != "$after" ]; then
      fail 'legacy prepare-commit-msg hook: legacy hook still mutates CHANGELOG'
    elif [ -n "$output" ]; then
      fail 'legacy prepare-commit-msg hook: active compatibility hook was not silent'
    else
      pass 'legacy prepare-commit-msg hook is a safe silent no-op'
    fi
  fi
  rm -rf "$root"
}

test_feature_summary_is_idempotent_and_ignored() {
  local root repo id worklog entries markers ignore_rules staged
  root=$(mktemp -d)
  repo="$root/repo"
  new_repo "$repo"; commit_file "$repo"
  id='https://gitlab.com/example/project/-/merge_requests/42'

  if ! (cd "$repo" && bash "$FEATURE_COMPLETE_HOOK" \
      --id "$id" --title 'Reliable auto-docs' \
      --summary 'Made documentation updates deterministic and safe.'); then
    fail 'feature summary idempotency: first invocation failed'
    rm -rf "$root"
    return
  fi
  if ! (cd "$repo" && bash "$FEATURE_COMPLETE_HOOK" \
      --summary 'A later retry must not replace the confirmed summary.' \
      --title 'Retry title' --id "$id"); then
    fail 'feature summary idempotency: retry invocation failed'
    rm -rf "$root"
    return
  fi

  worklog="$repo/docs/WORKLOG.md"
  entries=$(grep -Ec '^## Feature: Reliable auto-docs \[[0-9]{4}-[0-9]{2}-[0-9]{2}\]$' "$worklog" 2>/dev/null || true)
  markers=$(grep -Fc '<!-- auto-docs:feature:' "$worklog" 2>/dev/null || true)
  ignore_rules=$(grep -Fxc 'docs/WORKLOG.md' "$repo/.gitignore" 2>/dev/null || true)
  staged=$(git -C "$repo" diff --cached --name-only)
  if [ "$entries" -ne 1 ] || [ "$markers" -ne 1 ]; then
    fail 'feature summary idempotency: duplicate invocation did not preserve one entry'
  elif grep -Fq 'later retry' "$worklog"; then
    fail 'feature summary idempotency: retry replaced the original confirmed summary'
  elif [ "$ignore_rules" -ne 1 ] || ! git -C "$repo" check-ignore -q docs/WORKLOG.md; then
    fail 'feature summary idempotency: WORKLOG ignore rule is missing or duplicated'
  elif grep -Fqx 'docs/WORKLOG.md' <<< "$staged"; then
    fail 'feature summary idempotency: ignored WORKLOG was staged'
  else
    pass 'feature summary appends once by confirmed feature ID and remains ignored'
  fi
  rm -rf "$root"
}

test_feature_summary_honors_opt_out() {
  local root repo
  root=$(mktemp -d)
  repo="$root/repo"
  new_repo "$repo"; commit_file "$repo"
  mkdir -p "$repo/.claude"
  : > "$repo/.claude/no-docs"
  find "$repo" -mindepth 1 -type f -not -path "$repo/.git/*" -print | sort > "$root/before"
  if ! (cd "$repo" && bash "$FEATURE_COMPLETE_HOOK" \
      --id '42' --title 'Disabled feature' --summary 'Must not be written.'); then
    fail 'feature summary opt-out: command should skip successfully'
    rm -rf "$root"
    return
  fi
  find "$repo" -mindepth 1 -type f -not -path "$repo/.git/*" -print | sort > "$root/after"
  if ! cmp -s "$root/before" "$root/after" || [ -e "$repo/docs/WORKLOG.md" ]; then
    fail 'feature summary opt-out: project files changed while disabled'
  else
    pass 'feature summary honors project .claude/no-docs opt-out'
  fi
  rm -rf "$root"
}

test_feature_summary_rejects_unsafe_arguments_without_writes() {
  local root repo
  root=$(mktemp -d)
  repo="$root/repo"
  new_repo "$repo"; commit_file "$repo"
  if [ ! -f "$FEATURE_COMPLETE_HOOK" ]; then
    fail 'feature summary validation: command is missing'
  elif (cd "$repo" && bash "$FEATURE_COMPLETE_HOOK" \
      --id '42' --id '43' --title 'Duplicate ID' --summary 'Must fail.') >/dev/null 2>&1; then
    fail 'feature summary validation: duplicate required argument was accepted'
  elif (cd "$repo" && bash "$FEATURE_COMPLETE_HOOK" \
      --id '42' --title $'Unsafe\ntitle' --summary 'Must fail.') >/dev/null 2>&1; then
    fail 'feature summary validation: newline title was accepted'
  elif (cd "$repo" && bash "$FEATURE_COMPLETE_HOOK" \
      --id '42' --title '   ' --summary 'Must fail.') >/dev/null 2>&1; then
    fail 'feature summary validation: whitespace-only title was accepted'
  elif (cd "$repo" && bash "$FEATURE_COMPLETE_HOOK" \
      --id '42' --title 'Missing summary') >/dev/null 2>&1; then
    fail 'feature summary validation: missing summary was accepted'
  elif [ -e "$repo/docs/WORKLOG.md" ] || [ -e "$repo/.gitignore" ]; then
    fail 'feature summary validation: invalid invocation wrote project files'
  else
    pass 'feature summary rejects missing, duplicate, blank, and unsafe arguments before writes'
  fi
  rm -rf "$root"
}

test_feature_summary_rejects_worklog_symlink_escape() {
  local root repo outside before after
  root=$(mktemp -d)
  repo="$root/repo"; outside="$root/outside.md"
  new_repo "$repo"; commit_file "$repo"
  mkdir -p "$repo/docs"
  printf 'outside must remain unchanged\n' > "$outside"
  ln -s "$outside" "$repo/docs/WORKLOG.md"
  before=$(cksum "$outside")
  if (cd "$repo" && bash "$FEATURE_COMPLETE_HOOK" \
      --id '42' --title 'Escaping feature' --summary 'Must not be written.') >/dev/null 2>&1; then
    fail 'feature summary confinement: WORKLOG symlink escape was accepted'
  else
    after=$(cksum "$outside")
    if [ "$before" != "$after" ]; then
      fail 'feature summary confinement: wrote through WORKLOG symlink'
    else
      pass 'feature summary rejects WORKLOG symlink escape'
    fi
  fi
  rm -rf "$root"
}

test_feature_summary_repairs_marker_only_entry_atomically() {
  local root repo id key marker worklog starts ends entries
  root=$(mktemp -d)
  repo="$root/repo"
  new_repo "$repo"; commit_file "$repo"
  id='feature-atomic-42'
  key=$(printf '%s' "$id" | git -C "$repo" hash-object --stdin)
  marker="<!-- auto-docs:feature:$key -->"
  mkdir -p "$repo/docs"
  printf '%s\n' 'docs/WORKLOG.md' > "$repo/.gitignore"
  printf '%s\n' '# Worklog' '' "$marker" > "$repo/docs/WORKLOG.md"
  if ! (cd "$repo" && bash "$FEATURE_COMPLETE_HOOK" \
      --id "$id" --title 'Atomic feature' --summary 'Writes the complete bounded entry.'); then
    fail 'feature summary atomic repair: invocation failed'
  else
    worklog="$repo/docs/WORKLOG.md"
    starts=$(grep -Fxc "$marker" "$worklog" || true)
    ends=$(grep -Fxc "<!-- auto-docs:feature-end:$key -->" "$worklog" || true)
    entries=$(grep -Fxc '**Feature ID:** feature-atomic-42' "$worklog" || true)
    if [ "$starts" -ne 1 ] || [ "$ends" -ne 1 ] || [ "$entries" -ne 1 ]; then
      fail 'feature summary atomic repair: marker-only state was mistaken for a complete bounded entry'
    else
      pass 'feature summary repairs a marker-only interruption with one complete bounded entry'
    fi
  fi
  rm -rf "$root"
}

test_feature_summary_failed_rename_preserves_original_worklog() {
  local root repo fake_bin before after
  root=$(mktemp -d)
  repo="$root/repo"; fake_bin="$root/fake-bin"
  new_repo "$repo"; commit_file "$repo"
  mkdir -p "$repo/docs" "$fake_bin"
  printf '%s\n' 'docs/WORKLOG.md' > "$repo/.gitignore"
  printf '%s\n' '# Existing worklog' > "$repo/docs/WORKLOG.md"
  before=$(cksum "$repo/docs/WORKLOG.md")
  printf '%s\n' '#!/usr/bin/env bash' 'exit 77' > "$fake_bin/mv"
  chmod +x "$fake_bin/mv"
  if (cd "$repo" && PATH="$fake_bin:$PATH" bash "$FEATURE_COMPLETE_HOOK" \
      --id 'rename-failure' --title 'Must remain atomic' --summary 'The original file must survive.') >/dev/null 2>&1; then
    fail 'feature summary atomic rename: fixture did not fail'
  else
    after=$(cksum "$repo/docs/WORKLOG.md")
    if [ "$before" != "$after" ]; then
      fail 'feature summary atomic rename: failed replacement partially changed WORKLOG'
    else
      pass 'feature summary leaves WORKLOG unchanged when atomic rename fails'
    fi
  fi
  rm -rf "$root"
}


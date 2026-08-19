#!/usr/bin/env bash
# Auto-docs behavioral tests. Every case uses a disposable repository and state
# directory; no project or user Claude configuration is touched.

set -u -o pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
STOP_HOOK="$REPO_ROOT/hooks/auto-docs-stop.sh"
PRE_COMMIT_HOOK="$REPO_ROOT/hooks/auto-docs-pre-commit.sh"
POST_COMMIT_HOOK="$REPO_ROOT/hooks/auto-docs-post-commit.sh"
LEGACY_COMMIT_MSG_HOOK="$REPO_ROOT/hooks/auto-docs-prepare-commit-msg.sh"
FEATURE_COMPLETE_HOOK="$REPO_ROOT/hooks/auto-docs-feature-complete.sh"
WORKFLOW_CONTRACT_TEST="$REPO_ROOT/tests/workflow-contract.mjs"
INSTALLER="$REPO_ROOT/install.sh"

FAILURES=0
CASES=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

pass() {
  printf 'PASS: %s\n' "$1"
}

snapshot_install_targets() {
  local target path mode digest
  for target in "$@"; do
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
      printf 'ABSENT %s\n' "$target"
      continue
    fi
    while IFS= read -r -d '' path; do
      if [ -L "$path" ]; then
        printf 'LINK %s -> %s\n' "$path" "$(readlink "$path")"
      elif [ -f "$path" ]; then
        mode=$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path")
        digest=$(cksum "$path")
        printf 'FILE %s %s %s\n' "$mode" "$digest" "$path"
      elif [ -d "$path" ]; then
        mode=$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path")
        printf 'DIR %s %s\n' "$mode" "$path"
      fi
    done < <(find "$target" -print0)
  done | LC_ALL=C sort
}

new_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config core.fsmonitor false
  git -C "$dir" config core.hooksPath "$dir/.git/hooks-disabled"
  git -C "$dir" config user.name 'Auto Docs Tests'
  git -C "$dir" config user.email 'auto-docs-tests@example.invalid'
}

commit_file() {
  local dir="$1"
  printf 'initial\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m 'initial commit'
}

run_stop() {
  local repo="$1"
  local state="$2"
  local session="$3"
  local input

  input=$(jq -cn --arg cwd "$repo" --arg sid "$session" \
    '{cwd:$cwd,session_id:$sid,stop_hook_active:false}')
  XDG_STATE_HOME="$state" HOME="$state/home" bash "$STOP_HOOK" <<< "$input"
}

run_pre_commit() {
  local repo="$1"
  (
    cd "$repo"
    bash "$PRE_COMMIT_HOOK"
  )
}

assert_context() {
  local name="$1"
  local output="$2"
  if ! jq -e '
      .hookSpecificOutput.hookEventName == "Stop" and
      (.hookSpecificOutput.additionalContext | type == "string")
    ' >/dev/null 2>&1 <<< "$output"; then
    fail "$name: Stop context was not emitted"
  else
    pass "$name"
  fi
}

assert_silent() {
  local name="$1"
  local output="$2"
  if [ -n "$output" ]; then
    fail "$name: expected silent opt-out, got: $output"
  else
    pass "$name"
  fi
}

source "$SCRIPT_DIR/hook-tests.sh"
source "$SCRIPT_DIR/installer-tests.sh"

test_workflow_contract() {
  if node "$WORKFLOW_CONTRACT_TEST"; then
    pass 'dynamic workflow satisfies bootstrap, cursor, boundary, and conditional-agent contracts'
  else
    fail 'dynamic workflow contract harness failed'
  fi
}

test_case() {
  CASES=$((CASES + 1))
  "$1"
}

test_case test_tracked_change
test_case test_untracked_only
test_case test_no_head_staged_change
test_case test_opt_out
test_case test_no_project_sentinel
test_case test_pre_commit_stages_changelog
test_case test_pre_commit_scopes_changed_to_unreleased
test_case test_pre_commit_rejects_docs_symlink_escape
test_case test_pre_commit_is_idempotent_for_pending_tree
test_case test_pre_commit_records_equal_count_consecutive_commits
test_case test_pre_commit_restages_current_managed_entry
test_case test_pre_commit_reconciles_changed_pending_tree
test_case test_pre_commit_fails_closed_on_unstaged_changelog_edits
test_case test_pre_commit_fails_closed_on_unstaged_changelog_deletion
test_case test_stop_uses_safe_absolute_external_state
test_case test_stop_claims_session_atomically
test_case test_post_commit_denies_unlisted_host
test_case test_post_commit_replaces_only_managed_marker
test_case test_post_commit_preserves_marker_surrounding_bytes
test_case test_post_commit_preserves_suffix_without_final_newline
test_case test_post_commit_fails_closed_on_bad_mr_read
test_case test_post_commit_fails_closed_on_malformed_markers
test_case test_post_commit_enforces_curl_transport_policy
test_case test_post_commit_keeps_token_out_of_arguments_and_cleans_header_file
test_case test_post_commit_rejects_multiline_token_before_curl
test_case test_legacy_commit_msg_hook_is_noop
test_case test_feature_summary_is_idempotent_and_ignored
test_case test_feature_summary_honors_opt_out
test_case test_feature_summary_rejects_unsafe_arguments_without_writes
test_case test_feature_summary_rejects_worklog_symlink_escape
test_case test_feature_summary_repairs_marker_only_entry_atomically
test_case test_feature_summary_failed_rename_preserves_original_worklog
test_case test_workflow_contract
test_case test_installer_requires_valid_repo_dir_and_dry_run_is_non_mutating
test_case test_installer_apply_is_idempotent_and_backs_up_replaced_files
test_case test_install_docs_describe_v2_hooks_workflow_and_rollback
test_case test_installer_rejects_symlink_destinations_before_any_write
test_case test_installer_rejects_symlink_sources_before_any_write
test_case test_installer_transaction_rolls_back_clean_install
test_case test_installer_rollback_refuses_post_install_drift_without_partial_restore
test_case test_installer_preflight_prevents_partial_apply
test_case test_installer_rolls_back_after_mid_apply_failure
test_case test_installer_rejects_redirected_global_git_config
test_case test_installer_backs_up_actual_xdg_global_git_config
test_case test_installer_backs_up_implicit_existing_xdg_global_git_config
test_case test_installer_uses_home_config_when_explicit_xdg_target_is_absent
test_case test_installer_rejects_symlinked_template_root_before_any_write
test_case test_installer_rejects_symlinked_template_ancestor_before_any_write
test_case test_installer_accepts_macos_tmp_template_dir
test_case test_installer_expands_tilde_global_template_dir
test_case test_installer_preserves_pipe_in_template_dir
test_case test_installer_repairs_modes_and_collapses_duplicate_stop_hooks
test_case test_installed_template_neutralizes_legacy_prepare_hook

if [ "$FAILURES" -ne 0 ]; then
  printf '\n%d/%d cases failed\n' "$FAILURES" "$CASES" >&2
  exit 1
fi

printf '\nAll %d cases passed\n' "$CASES"

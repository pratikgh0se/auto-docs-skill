test_installer_requires_valid_repo_dir_and_dry_run_is_non_mutating() {
  local root fake_home template before after output
  root=$(mktemp -d)
  fake_home="$root/home"
  template="$root/git-template"
  mkdir -p "$fake_home" "$template/hooks"
  printf 'existing-template-hook\n' > "$template/hooks/keep-me"
  printf '[user]\n\tname = Fixture User\n' > "$fake_home/.gitconfig"
  snapshot_install_targets "$fake_home" "$template" > "$root/before"

  if [ ! -f "$INSTALLER" ]; then
    fail 'installer dry-run: install.sh is missing'
    rm -rf "$root"
    return
  fi
  if HOME="$fake_home" bash "$INSTALLER" --dry-run >/dev/null 2>&1; then
    fail 'installer validation: --repo-dir is required'
  elif HOME="$fake_home" bash "$INSTALLER" --dry-run --repo-dir "$root/missing" >/dev/null 2>&1; then
    fail 'installer validation: nonexistent --repo-dir is accepted'
  elif ! output=$(HOME="$fake_home" bash "$INSTALLER" --dry-run --repo-dir "$REPO_ROOT" --git-template-dir "$template" 2>&1); then
    fail "installer dry-run: valid invocation failed: $output"
  else
    snapshot_install_targets "$fake_home" "$template" > "$root/after"
    if ! cmp -s "$root/before" "$root/after"; then
      fail 'installer dry-run: wrote to disposable HOME or Git template'
    elif ! grep -Fq "$fake_home/.claude" <<< "$output" || ! grep -Fq "$template" <<< "$output"; then
      fail 'installer dry-run: did not report all global targets'
    else
      pass 'installer requires a valid repo dir and dry-run writes nothing'
    fi
  fi
  rm -rf "$root"
}

test_installer_apply_is_idempotent_and_backs_up_replaced_files() {
  local root fake_home template settings first_backup second_backup
  root=$(mktemp -d)
  fake_home="$root/home"
  template="$root/git-template"
  settings="$fake_home/.claude/settings.json"
  mkdir -p "$fake_home/.claude/hooks" "$template/hooks"
  printf '{"hooks":{"Stop":[]},"unrelated":{"keep":true}}\n' > "$settings"
  printf 'old pre-commit\n' > "$template/hooks/pre-commit"
  printf 'old post-commit\n' > "$template/hooks/post-commit"
  printf 'old prepare-commit-msg\n' > "$template/hooks/prepare-commit-msg"

  if [ ! -f "$INSTALLER" ]; then
    fail 'installer apply: install.sh is missing'
  elif ! HOME="$fake_home" bash "$INSTALLER" --apply --repo-dir "$REPO_ROOT" --git-template-dir "$template" >/dev/null; then
    fail 'installer apply: first fixture installation failed'
  elif ! jq -e '.unrelated.keep == true and ([.hooks.Stop[].hooks[].command] | any(contains("auto-docs-stop.sh")))' "$settings" >/dev/null; then
    fail 'installer apply: settings registration overwrote unrelated content or missed Stop hook'
  elif [ ! -x "$template/hooks/pre-commit" ] || [ ! -x "$template/hooks/post-commit" ] || \
      [ ! -x "$template/hooks/prepare-commit-msg" ]; then
    fail 'installer apply: template hooks were not installed executable'
  else
    first_backup=$(find "$fake_home/.claude/auto-docs-backups" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [ -z "$first_backup" ] || [ ! -x "$first_backup/rollback.sh" ] || \
        ! grep -Fq "$template/hooks/pre-commit" "$first_backup/manifest.tsv" || \
        ! grep -Fq "$template/hooks/post-commit" "$first_backup/manifest.tsv" || \
        ! grep -Fq "$template/hooks/prepare-commit-msg" "$first_backup/manifest.tsv"; then
      fail 'installer apply: replaced template hooks were not timestamp-backed up'
    elif ! HOME="$fake_home" bash "$INSTALLER" --apply --repo-dir "$REPO_ROOT" --git-template-dir "$template" >/dev/null; then
      fail 'installer apply: idempotent retry failed'
    elif [ "$(jq '[.hooks.Stop[].hooks[] | select(.command | contains("auto-docs-stop.sh"))] | length' "$settings")" -ne 1 ]; then
      fail 'installer apply: retry duplicated Stop hook registration'
    else
      second_backup=$(find "$fake_home/.claude/auto-docs-backups" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
      if [ "$second_backup" -ne 1 ]; then
        fail 'installer apply: unchanged retry created an unnecessary backup'
      else
        pass 'installer apply preserves settings, backs up replacements, and is idempotent'
      fi
    fi
  fi
  rm -rf "$root"
}

test_install_docs_describe_v2_hooks_workflow_and_rollback() {
  local docs
  docs="$REPO_ROOT/CLAUDE-INSTALL.md $REPO_ROOT/README.md"
  if ! grep -Fq 'pre-commit' $docs || ! grep -Fq 'post-commit' $docs; then
    fail 'installer docs: do not describe both active v2 commit hooks'
  elif ! grep -Fq 'prepare-commit-msg' $docs; then
    fail 'installer docs: do not describe the installed legacy-hook neutralizer'
  elif ! grep -Fq 'auto-docs-write' $docs; then
    fail 'installer docs: do not describe explicit workflow invocation'
  elif ! grep -Eqi 'rollback|restore.*backup|backup.*restore' $docs; then
    fail 'installer docs: do not explain rollback from installer backups'
  elif ! grep -Fq 'Refusing to overwrite existing' $docs; then
    fail 'installer docs: show destructive existing-hook copies without a refusal guard'
  else
    pass 'installer docs describe v2 hooks, explicit workflow, and rollback'
  fi
}

test_installer_rejects_symlink_destinations_before_any_write() {
  local root fake_home template outside before after
  root=$(mktemp -d); fake_home="$root/home"; template="$root/template"; outside="$root/outside"
  mkdir -p "$fake_home/.claude/hooks" "$template/hooks"
  printf 'outside stays unchanged\n' > "$outside"
  ln -s "$outside" "$fake_home/.claude/hooks/auto-docs-stop.sh"
  before=$(cksum "$outside")
  if HOME="$fake_home" bash "$INSTALLER" --apply --repo-dir "$REPO_ROOT" --git-template-dir "$template" >/dev/null 2>&1; then
    fail 'installer symlink confinement: accepted symlink destination'
  else
    after=$(cksum "$outside")
    if [ "$before" != "$after" ] || [ -e "$fake_home/.claude/skills/auto-docs/SKILL.md" ]; then
      fail 'installer symlink confinement: changed external target or partially installed before rejection'
    else
      pass 'installer rejects destination symlinks before any write'
    fi
  fi
  rm -rf "$root"
}

test_installer_rejects_symlink_sources_before_any_write() {
  local root fake_home template source outside before after artifact
  root=$(mktemp -d); fake_home="$root/home"; template="$root/template"; source="$root/source"; outside="$root/outside"
  mkdir -p "$source/skill" "$source/workflow" "$source/hooks" "$fake_home" "$template"
  cp "$REPO_ROOT/skill/SKILL.md" "$source/skill/SKILL.md"
  cp "$REPO_ROOT/workflow/auto-docs.js" "$source/workflow/auto-docs.js"
  for artifact in auto-docs-stop.sh auto-docs-pre-commit.sh auto-docs-post-commit.sh auto-docs-feature-complete.sh auto-docs-prepare-commit-msg.sh; do
    cp "$REPO_ROOT/hooks/$artifact" "$source/hooks/$artifact"
  done
  printf 'outside stays unchanged\n' > "$outside"
  rm "$source/hooks/auto-docs-stop.sh"
  ln -s "$outside" "$source/hooks/auto-docs-stop.sh"
  before=$(cksum "$outside")
  if HOME="$fake_home" bash "$INSTALLER" --apply --repo-dir "$source" --git-template-dir "$template" >/dev/null 2>&1; then
    fail 'installer source confinement: accepted symlink source artifact'
  else
    after=$(cksum "$outside")
    if [ "$before" != "$after" ] || [ -e "$fake_home/.claude/skills/auto-docs/SKILL.md" ]; then
      fail 'installer source confinement: changed external target or partially installed before rejection'
    else
      pass 'installer rejects source symlinks before any write'
    fi
  fi
  rm -rf "$root"
}

test_installer_transaction_rolls_back_clean_install() {
  local root fake_home template backup rollback
  root=$(mktemp -d); fake_home="$root/home"; template="$root/template"
  mkdir -p "$fake_home" "$template"
  if ! HOME="$fake_home" bash "$INSTALLER" --apply --repo-dir "$REPO_ROOT" --git-template-dir "$template" >/dev/null; then
    fail 'installer clean rollback: fixture apply failed'
  else
    backup=$(find "$fake_home/.claude/auto-docs-backups" -mindepth 1 -maxdepth 1 -type d | head -1)
    rollback="$backup/rollback.sh"
    if [ -z "$backup" ] || [ ! -x "$rollback" ] || ! grep -Fq 'absent' "$backup/manifest.tsv"; then
      fail 'installer clean rollback: absent targets were not recorded in an executable transaction'
    elif ! HOME="$fake_home" bash "$rollback" >/dev/null; then
      fail 'installer clean rollback: rollback command failed'
    elif [ -e "$fake_home/.claude/hooks/auto-docs-stop.sh" ] || [ -e "$template/hooks/pre-commit" ] || \
        [ -e "$template/hooks/prepare-commit-msg" ] || \
        [ -e "$fake_home/.gitconfig" ] || [ -e "$fake_home/.config/git/config" ]; then
      fail 'installer clean rollback: newly-created artifacts or git config remained'
    else
      pass 'installer creates executable rollback records for clean installs'
    fi
  fi
  rm -rf "$root"
}

test_installer_rollback_refuses_post_install_drift_without_partial_restore() {
  local root fake_home template backup rollback managed unchanged_before unchanged_after
  root=$(mktemp -d); fake_home="$root/home"; template="$root/template"
  mkdir -p "$fake_home" "$template"
  if ! HOME="$fake_home" bash "$INSTALLER" --apply --repo-dir "$REPO_ROOT" --git-template-dir "$template" >/dev/null; then
    fail 'installer rollback drift: fixture apply failed'
  else
    backup=$(find "$fake_home/.claude/auto-docs-backups" -mindepth 1 -maxdepth 1 -type d | head -1)
    rollback="$backup/rollback.sh"
    managed="$fake_home/.claude/hooks/auto-docs-stop.sh"
    unchanged_before=$(cksum "$fake_home/.claude/skills/auto-docs/SKILL.md")
    printf '\nuser changed this after install\n' >> "$managed"
    if HOME="$fake_home" bash "$rollback" >/dev/null 2>&1; then
      fail 'installer rollback drift: rollback overwrote post-install changes'
    else
      unchanged_after=$(cksum "$fake_home/.claude/skills/auto-docs/SKILL.md")
      if ! grep -Fq 'user changed this after install' "$managed"; then
        fail 'installer rollback drift: drifted target was overwritten'
      elif [ "$unchanged_before" != "$unchanged_after" ]; then
        fail 'installer rollback drift: restored other targets before detecting drift'
      else
        pass 'installer rollback detects drift before restoring any target'
      fi
    fi
  fi
  rm -rf "$root"
}

test_installer_preflight_prevents_partial_apply() {
  local root fake_home template settings_before settings_after
  root=$(mktemp -d); fake_home="$root/home"; template="$root/template"
  mkdir -p "$fake_home/.claude" "$template/hooks/post-commit"
  printf '{"unrelated":{"keep":true}}\n' > "$fake_home/.claude/settings.json"
  settings_before=$(cksum "$fake_home/.claude/settings.json")
  if HOME="$fake_home" bash "$INSTALLER" --apply --repo-dir "$REPO_ROOT" --git-template-dir "$template" >/dev/null 2>&1; then
    fail 'installer transaction preflight: accepted directory as hook target'
  else
    settings_after=$(cksum "$fake_home/.claude/settings.json")
    if [ "$settings_before" != "$settings_after" ] || [ -e "$fake_home/.claude/hooks/auto-docs-stop.sh" ] || [ -e "$template/hooks/pre-commit" ]; then
      fail 'installer transaction preflight: left partial changes after invalid target'
    else
      pass 'installer validates every target before apply mutations'
    fi
  fi
  rm -rf "$root"
}

test_installer_rolls_back_after_mid_apply_failure() {
  local root fake_home template settings_before settings_after
  root=$(mktemp -d); fake_home="$root/home"; template="$root/template"
  mkdir -p "$fake_home/.claude" "$template/hooks"
  printf '{"unrelated":{"keep":true}}\n' > "$fake_home/.claude/settings.json"
  chmod 0500 "$template/hooks"
  settings_before=$(cksum "$fake_home/.claude/settings.json")
  if HOME="$fake_home" bash "$INSTALLER" --apply --repo-dir "$REPO_ROOT" --git-template-dir "$template" >/dev/null 2>&1; then
    fail 'installer transaction rollback: fixture did not fail during destination commit'
  else
    settings_after=$(cksum "$fake_home/.claude/settings.json")
    if [ "$settings_before" != "$settings_after" ] || [ -e "$fake_home/.claude/hooks/auto-docs-stop.sh" ] || [ -e "$template/hooks/pre-commit" ]; then
      fail 'installer transaction rollback: partial state remained after apply failure'
    else
      pass 'installer automatically restores transaction after mid-apply failure'
    fi
  fi
  chmod 0700 "$template/hooks"
  rm -rf "$root"
}

test_installer_rejects_redirected_global_git_config() {
  local root fake_home template external before after
  root=$(mktemp -d); fake_home="$root/home"; template="$root/template"; external="$root/external-gitconfig"
  mkdir -p "$fake_home" "$template"
  printf '[init]\n\ttemplateDir = /outside\n' > "$external"
  before=$(cksum "$external")
  if HOME="$fake_home" GIT_CONFIG_GLOBAL="$external" bash "$INSTALLER" --apply --repo-dir "$REPO_ROOT" --git-template-dir "$template" >/dev/null 2>&1; then
    fail 'installer git config confinement: accepted GIT_CONFIG_GLOBAL redirection'
  else
    after=$(cksum "$external")
    if [ "$before" != "$after" ] || [ -e "$fake_home/.claude/hooks/auto-docs-stop.sh" ]; then
      fail 'installer git config confinement: redirected config changed or apply partially ran'
    else
      pass 'installer rejects redirected global Git config before writes'
    fi
  fi
  rm -rf "$root"
}

test_installer_backs_up_actual_xdg_global_git_config() {
  local root fake_home xdg template config before after backup rollback
  root=$(mktemp -d); fake_home="$root/home"; xdg="$root/xdg"; template="$root/template"
  config="$xdg/git/config"
  mkdir -p "$fake_home" "$xdg/git" "$template"
  printf '[user]\n\tname = XDG Fixture\n' > "$config"
  before=$(cksum "$config")
  if ! HOME="$fake_home" XDG_CONFIG_HOME="$xdg" bash "$INSTALLER" --apply --repo-dir "$REPO_ROOT" --git-template-dir "$template" >/dev/null; then
    fail 'installer XDG config: fixture apply failed'
  else
    backup=$(find "$fake_home/.claude/auto-docs-backups" -mindepth 1 -maxdepth 1 -type d | head -1)
    rollback="$backup/rollback.sh"
    if [ ! -f "$config" ] || [ -e "$fake_home/.gitconfig" ] || [ -z "$backup" ] || ! grep -Fq "$config" "$backup/manifest.tsv"; then
      fail 'installer XDG config: did not use and record the actual XDG global config target'
    elif ! HOME="$fake_home" XDG_CONFIG_HOME="$xdg" bash "$rollback" >/dev/null; then
      fail 'installer XDG config: rollback failed'
    else
      after=$(cksum "$config")
      if [ "$before" != "$after" ]; then
        fail 'installer XDG config: rollback did not restore original global config bytes'
      else
        pass 'installer backs up and restores the actual XDG global Git config'
      fi
    fi
  fi
  rm -rf "$root"
}

test_installer_backs_up_implicit_existing_xdg_global_git_config() {
  local root fake_home template config before after backup rollback
  root=$(mktemp -d); fake_home="$root/home"; template="$root/template"
  config="$fake_home/.config/git/config"
  mkdir -p "$fake_home/.config/git" "$template"
  printf '[user]\n\tname = Implicit XDG Fixture\n' > "$config"
  before=$(cksum "$config")
  if ! HOME="$fake_home" env -u XDG_CONFIG_HOME bash "$INSTALLER" --apply --repo-dir "$REPO_ROOT" --git-template-dir "$template" >/dev/null; then
    fail 'installer implicit XDG config: fixture apply failed'
  else
    backup=$(find "$fake_home/.claude/auto-docs-backups" -mindepth 1 -maxdepth 1 -type d | head -1)
    rollback="$backup/rollback.sh"
    if [ -z "$backup" ] || ! grep -Fq "$config" "$backup/manifest.tsv"; then
      fail 'installer implicit XDG config: manifest did not record existing HOME/.config Git target'
    elif ! HOME="$fake_home" env -u XDG_CONFIG_HOME bash "$rollback" >/dev/null; then
      fail 'installer implicit XDG config: rollback failed'
    else
      after=$(cksum "$config")
      if [ "$before" != "$after" ]; then
        fail 'installer implicit XDG config: rollback did not restore original config bytes'
      else
        pass 'installer backs up implicit existing HOME/.config Git config'
      fi
    fi
  fi
  rm -rf "$root"
}

test_installer_uses_home_config_when_explicit_xdg_target_is_absent() {
  local root fake_home xdg template home_config backup rollback
  root=$(mktemp -d); fake_home="$root/home"; xdg="$root/xdg"; template="$root/template"
  home_config="$fake_home/.gitconfig"
  mkdir -p "$fake_home" "$xdg" "$template"
  if ! HOME="$fake_home" XDG_CONFIG_HOME="$xdg" bash "$INSTALLER" --apply --repo-dir "$REPO_ROOT" --git-template-dir "$template" >/dev/null; then
    fail 'installer absent explicit XDG config: fixture apply failed'
  else
    backup=$(find "$fake_home/.claude/auto-docs-backups" -mindepth 1 -maxdepth 1 -type d | head -1)
    rollback="$backup/rollback.sh"
    if [ ! -f "$home_config" ] || [ -e "$xdg/git/config" ] || [ -z "$backup" ] || ! grep -Fq "$home_config" "$backup/manifest.tsv"; then
      fail 'installer absent explicit XDG config: did not select and record HOME/.gitconfig'
    elif ! HOME="$fake_home" XDG_CONFIG_HOME="$xdg" bash "$rollback" >/dev/null; then
      fail 'installer absent explicit XDG config: rollback failed'
    elif [ -e "$home_config" ]; then
      fail 'installer absent explicit XDG config: rollback did not remove clean HOME config'
    else
      pass 'installer selects HOME config when explicit XDG config is absent'
    fi
  fi
  rm -rf "$root"
}

test_installer_rejects_symlinked_template_root_before_any_write() {
  local root fake_home template_real template_link
  root=$(mktemp -d); fake_home="$root/home"; template_real="$root/template-real"; template_link="$root/template-link"
  mkdir -p "$fake_home" "$template_real"
  ln -s "$template_real" "$template_link"
  if HOME="$fake_home" bash "$INSTALLER" --apply --repo-dir "$REPO_ROOT" --git-template-dir "$template_link" >/dev/null 2>&1; then
    fail 'installer template confinement: accepted symlinked template root'
  elif [ -e "$fake_home/.claude/hooks/auto-docs-stop.sh" ] || [ -e "$template_real/hooks/pre-commit" ]; then
    fail 'installer template confinement: symlinked template rejection left partial writes'
  else
    pass 'installer rejects symlinked template root before any write'
  fi
  rm -rf "$root"
}

test_installer_rejects_symlinked_template_ancestor_before_any_write() {
  local root fake_home external link_parent template
  root=$(mktemp -d); fake_home="$root/home"; external="$root/external"; link_parent="$root/link-parent"; template="$link_parent/missing-template"
  mkdir -p "$fake_home" "$external"
  ln -s "$external" "$link_parent"
  if HOME="$fake_home" bash "$INSTALLER" --apply --repo-dir "$REPO_ROOT" --git-template-dir "$template" >/dev/null 2>&1; then
    fail 'installer template ancestor confinement: accepted symlinked ancestor'
  elif [ -e "$fake_home/.claude/hooks/auto-docs-stop.sh" ] || [ -e "$external/missing-template/hooks/pre-commit" ]; then
    fail 'installer template ancestor confinement: rejection left partial writes'
  else
    pass 'installer rejects symlinked template ancestor before any write'
  fi
  rm -rf "$root"
}

test_installer_accepts_macos_tmp_template_dir() {
  local root fake_home template output
  root=$(mktemp -d); fake_home="$root/home"
  template=$(mktemp -d /tmp/auto-docs-template.XXXXXX) || {
    fail 'installer macOS tmp template: could not create /tmp fixture'
    rm -rf "$root"
    return
  }
  mkdir -p "$fake_home" "$template/hooks"
  if ! output=$(HOME="$fake_home" bash "$INSTALLER" --dry-run --repo-dir "$REPO_ROOT" --git-template-dir "$template" 2>&1); then
    fail "installer macOS tmp template: dry-run rejected /tmp directory: $output"
  elif ! grep -Fq "$template" <<< "$output"; then
    fail 'installer macOS tmp template: dry-run did not report /tmp template directory'
  else
    pass 'installer accepts the standard macOS /tmp template directory'
  fi
  rm -rf "$root" "$template"
}

test_installer_expands_tilde_global_template_dir() {
  local root fake_home configured output
  root=$(mktemp -d); fake_home="$root/home"; configured="$fake_home/.tilde-template"
  mkdir -p "$fake_home"
  printf '[init]\n\ttemplateDir = ~/.tilde-template\n' > "$fake_home/.gitconfig"
  if ! output=$(HOME="$fake_home" bash "$INSTALLER" --dry-run --repo-dir "$REPO_ROOT" 2>&1); then
    fail "installer template expansion: dry-run rejected tilde global template: $output"
  elif ! grep -Fq "$configured" <<< "$output"; then
    fail 'installer template expansion: did not expand tilde global template against HOME'
  else
    pass 'installer expands tilde global template directory safely'
  fi
  rm -rf "$root"
}

test_installer_preserves_pipe_in_template_dir() {
  local root fake_home template output expected
  root=$(mktemp -d "$REPO_ROOT/.auto-docs-test.XXXXXX"); fake_home="$root/home"; template="$root/template|dir"
  mkdir -p "$fake_home" "$template"
  expected="hooks/auto-docs-pre-commit.sh -> $template/hooks/pre-commit (mode 0755)"
  if ! output=$(HOME="$fake_home" bash "$INSTALLER" --dry-run --repo-dir "$REPO_ROOT" --git-template-dir "$template" 2>&1); then
    fail "installer path encoding: dry run rejected a legal pipe-containing template path: $output"
  elif ! grep -Fqx "  REPLACE $expected" <<< "$output"; then
    fail 'installer path encoding: dry run split a legal pipe-containing template path'
  elif ! HOME="$fake_home" bash "$INSTALLER" --apply --repo-dir "$REPO_ROOT" --git-template-dir "$template" >/dev/null; then
    fail 'installer path encoding: apply rejected a legal pipe-containing template path'
  elif [ ! -x "$template/hooks/pre-commit" ] || [ -e "$root/template/hooks/pre-commit" ]; then
    fail 'installer path encoding: apply wrote the hook to a split template path'
  else
    pass 'installer preserves pipe-containing template paths through apply'
  fi
  rm -rf "$root"
}

test_installer_repairs_modes_and_collapses_duplicate_stop_hooks() {
  local root fake_home template settings stop_count
  root=$(mktemp -d); fake_home="$root/home"; template="$root/template"; settings="$fake_home/.claude/settings.json"
  mkdir -p "$fake_home/.claude/hooks" "$template/hooks"
  cp "$REPO_ROOT/hooks/auto-docs-stop.sh" "$fake_home/.claude/hooks/auto-docs-stop.sh"
  chmod 0644 "$fake_home/.claude/hooks/auto-docs-stop.sh"
  cp "$REPO_ROOT/hooks/auto-docs-pre-commit.sh" "$template/hooks/pre-commit"
  chmod 0644 "$template/hooks/pre-commit"
  jq -n '{hooks:{Stop:[
    {matcher:"*",hooks:[{type:"command",command:"$HOME/.claude/hooks/auto-docs-stop.sh",async:false}]},
    {matcher:"*",hooks:[{type:"command",command:"$HOME/.claude/hooks/auto-docs-stop.sh",async:false}]},
    {matcher:"other",hooks:[{type:"command",command:"/keep-me",async:false}]}
  ]}}' > "$settings"
  if ! HOME="$fake_home" bash "$INSTALLER" --apply --repo-dir "$REPO_ROOT" --git-template-dir "$template" >/dev/null; then
    fail 'installer convergence: fixture apply failed'
  else
    stop_count=$(jq '[.hooks.Stop[].hooks[] | select(.command == "$HOME/.claude/hooks/auto-docs-stop.sh")] | length' "$settings")
    if [ ! -x "$fake_home/.claude/hooks/auto-docs-stop.sh" ] || [ ! -x "$template/hooks/pre-commit" ]; then
      fail 'installer convergence: did not repair executable hook modes'
    elif [ "$stop_count" -ne 1 ] || ! jq -e '[.hooks.Stop[].hooks[] | select(.command == "/keep-me")] | length == 1' "$settings" >/dev/null; then
      fail 'installer convergence: did not reduce only duplicate managed Stop registrations'
    else
      pass 'installer repairs hook modes and normalizes managed Stop registration'
    fi
  fi
  rm -rf "$root"
}

test_installed_template_neutralizes_legacy_prepare_hook() {
  local root fake_home template repo status committed_files dry_run
  root=$(mktemp -d); fake_home="$root/home"; template="$root/template"; repo="$root/project"
  mkdir -p "$fake_home" "$template/hooks"
  cat > "$template/hooks/prepare-commit-msg" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' '- legacy late mutation' >> docs/CHANGELOG.md
git add -- docs/CHANGELOG.md
EOF
  chmod +x "$template/hooks/prepare-commit-msg"

  if ! dry_run=$(HOME="$fake_home" bash "$INSTALLER" --dry-run --repo-dir "$REPO_ROOT" --git-template-dir "$template"); then
    fail 'installer legacy-hook convergence: fixture dry run failed'
    rm -rf "$root"
    return
  fi
  if ! grep -Fq "REPLACE hooks/auto-docs-prepare-commit-msg.sh -> $template/hooks/prepare-commit-msg" <<< "$dry_run"; then
    fail 'installer legacy-hook convergence: dry run omitted legacy-hook neutralization'
    rm -rf "$root"
    return
  fi
  if ! HOME="$fake_home" bash "$INSTALLER" --apply --repo-dir "$REPO_ROOT" --git-template-dir "$template" >/dev/null; then
    fail 'installer legacy-hook convergence: fixture apply failed'
    rm -rf "$root"
    return
  fi
  if ! HOME="$fake_home" git init -q "$repo"; then
    fail 'installer legacy-hook convergence: fresh repository initialization failed'
    rm -rf "$root"
    return
  fi
  git -C "$repo" config core.fsmonitor false
  git -C "$repo" config user.name 'Auto Docs Tests'
  git -C "$repo" config user.email 'auto-docs-tests@example.invalid'
  printf 'initial\n' > "$repo/README.md"
  git -C "$repo" add README.md
  if ! git -C "$repo" commit -q -m 'initial commit'; then
    fail 'installer legacy-hook convergence: initial commit failed'
    rm -rf "$root"
    return
  fi
  printf 'feature\n' >> "$repo/README.md"
  git -C "$repo" add README.md
  if ! git -C "$repo" commit -q -m 'feat: active installed hook'; then
    fail 'installer legacy-hook convergence: second commit failed'
    rm -rf "$root"
    return
  fi

  status=$(git -C "$repo" status --porcelain)
  committed_files=$(git -C "$repo" show --format= --name-only HEAD)
  if ! grep -Fqx 'docs/CHANGELOG.md' <<< "$committed_files"; then
    fail 'installer legacy-hook convergence: CHANGELOG was not included in the second commit'
  elif [ -n "$status" ]; then
    fail "installer legacy-hook convergence: fresh repo was dirty after commit: $status"
  else
    pass 'installed template replaces the late-mutating legacy hook and leaves commits clean'
  fi
  rm -rf "$root"
}

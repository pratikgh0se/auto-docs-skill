#!/usr/bin/env bash
# Safe, explicit installer for the versioned Auto-Docs v2 source bundle.

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: install.sh --dry-run|--apply --repo-dir PATH [--git-template-dir PATH]

--dry-run              Report the fully preflighted transaction without writes.
--apply                Stage and atomically install the source bundle.
--repo-dir PATH        Required checkout containing the source artifacts.
--git-template-dir PATH
                       Absolute Git template directory. Defaults to the current
                       default global init.templateDir or ~/.git-templates.
EOF
}

die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 2
}

MODE=''
REPO_DIR=''
TEMPLATE_DIR=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|--apply)
      [ -z "$MODE" ] || die 'choose exactly one of --dry-run or --apply'
      MODE="$1"
      ;;
    --repo-dir|--git-template-dir)
      option="$1"; shift
      [ "$#" -gt 0 ] && [ -n "$1" ] || die "$option requires a non-empty path"
      if [ "$option" = '--repo-dir' ]; then REPO_DIR="$1"; else TEMPLATE_DIR="$1"; fi
      ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[ -n "$MODE" ] && [ -n "$REPO_DIR" ] || die '--dry-run or --apply and --repo-dir are required'
[ -d "$REPO_DIR" ] || die "--repo-dir is not a directory: $REPO_DIR"
case "${HOME:-}" in /*) ;; *) die 'HOME must be an absolute directory' ;; esac
[ -n "${GIT_CONFIG_GLOBAL:-}" ] || :
if [ -n "${GIT_CONFIG_GLOBAL:-}" ]; then
  die 'GIT_CONFIG_GLOBAL is not supported; unset it to use the default HOME/XDG global config'
fi

REPO_DIR=$(CDPATH= cd -- "$REPO_DIR" && pwd -P)
for source in skill/SKILL.md workflow/auto-docs.js \
  hooks/auto-docs-stop.sh hooks/auto-docs-pre-commit.sh \
  hooks/auto-docs-post-commit.sh hooks/auto-docs-feature-complete.sh \
  hooks/auto-docs-prepare-commit-msg.sh; do
  [ ! -L "$REPO_DIR/$source" ] && [ -f "$REPO_DIR/$source" ] || die "source must be a regular non-symlink file: $REPO_DIR/$source"
done
command -v jq >/dev/null 2>&1 || die 'jq is required to merge Claude settings safely'
command -v git >/dev/null 2>&1 || die 'git is required to configure the hook template'

# Git uses the XDG candidate only when it already exists and ~/.gitconfig does
# not. Pin every later read/write to this same selected target.
XDG_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
case "$XDG_CONFIG_DIR" in /*) ;; *) die 'XDG_CONFIG_HOME must be absolute when set' ;; esac
XDG_GIT_CONFIG_FILE="$XDG_CONFIG_DIR/git/config"
if [ -e "$HOME/.gitconfig" ]; then
  GIT_CONFIG_FILE="$HOME/.gitconfig"
  GIT_CONFIG_BOUNDARY="$HOME"
elif [ -e "$XDG_GIT_CONFIG_FILE" ]; then
  GIT_CONFIG_FILE="$XDG_GIT_CONFIG_FILE"
  GIT_CONFIG_BOUNDARY="$XDG_CONFIG_DIR"
else
  GIT_CONFIG_FILE="$HOME/.gitconfig"
  GIT_CONFIG_BOUNDARY="$HOME"
fi

git_global() {
  env GIT_CONFIG_GLOBAL="$GIT_CONFIG_FILE" git config --global "$@"
}

if [ -z "$TEMPLATE_DIR" ]; then
  TEMPLATE_DIR=$(git_global --get init.templateDir 2>/dev/null || true)
fi
[ -n "$TEMPLATE_DIR" ] || TEMPLATE_DIR="$HOME/.git-templates"
case "$TEMPLATE_DIR" in
  '~') TEMPLATE_DIR="$HOME" ;;
  '~/'*) TEMPLATE_DIR="$HOME/${TEMPLATE_DIR#\~/}" ;;
esac
case "$TEMPLATE_DIR" in /*) ;; *) die "--git-template-dir must be an absolute path: $TEMPLATE_DIR" ;; esac

validate_template_dir() {
  local component="$1"
  while :; do
    if [ -L "$component" ]; then
      # macOS exposes its standard temporary hierarchy through two system aliases.
      # Permit only their known physical targets; reject every other link.
      case "$(uname -s):$component:$(readlink "$component")" in
        Darwin:/tmp:private/tmp|Darwin:/var:private/var) ;;
        *) die "git template directory has a symlinked ancestor: $component" ;;
      esac
    elif [ -e "$component" ] && [ ! -d "$component" ]; then
      die "git template directory ancestor must be a directory: $component"
    fi
    [ "$component" = '/' ] && break
    component=$(dirname "$component")
  done
}
validate_template_dir "$TEMPLATE_DIR"

CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
STOP_COMMAND='$HOME/.claude/hooks/auto-docs-stop.sh'
declare -a COPY_SOURCES=(
  skill/SKILL.md workflow/auto-docs.js hooks/auto-docs-stop.sh
  hooks/auto-docs-pre-commit.sh hooks/auto-docs-post-commit.sh
  hooks/auto-docs-feature-complete.sh hooks/auto-docs-prepare-commit-msg.sh
  hooks/auto-docs-pre-commit.sh hooks/auto-docs-post-commit.sh
  hooks/auto-docs-prepare-commit-msg.sh
)
declare -a COPY_DESTINATIONS=(
  "$CLAUDE_DIR/skills/auto-docs/SKILL.md" "$CLAUDE_DIR/workflows/auto-docs.js" "$CLAUDE_DIR/hooks/auto-docs-stop.sh"
  "$CLAUDE_DIR/hooks/auto-docs-pre-commit.sh" "$CLAUDE_DIR/hooks/auto-docs-post-commit.sh"
  "$CLAUDE_DIR/hooks/auto-docs-feature-complete.sh" "$CLAUDE_DIR/hooks/auto-docs-prepare-commit-msg.sh"
  "$TEMPLATE_DIR/hooks/pre-commit" "$TEMPLATE_DIR/hooks/post-commit" "$TEMPLATE_DIR/hooks/prepare-commit-msg"
)
declare -a COPY_MODES=(0644 0644 0755 0755 0755 0755 0755 0755 0755 0755)

copy_count=${#COPY_SOURCES[@]}
[ "$copy_count" -eq "${#COPY_DESTINATIONS[@]}" ] && [ "$copy_count" -eq "${#COPY_MODES[@]}" ] \
  || die 'internal copy manifest is inconsistent'
copy_fields() {
  local index="$1"
  source="${COPY_SOURCES[$index]}"
  destination="${COPY_DESTINATIONS[$index]}"
  mode="${COPY_MODES[$index]}"
}

validate_destination() {
  local target="$1" boundary="$2" parent
  [ ! -L "$target" ] || die "destination must not be a symlink: $target"
  [ ! -e "$target" ] || [ -f "$target" ] || die "destination must be absent or a regular file: $target"
  parent=$(dirname "$target")
  while [ "$parent" != "$boundary" ] && [ "$parent" != '/' ] && [ "$parent" != '.' ]; do
    [ ! -L "$parent" ] || die "destination parent must not be a symlink: $parent"
    [ ! -e "$parent" ] || [ -d "$parent" ] || die "destination parent must be a directory: $parent"
    parent=$(dirname "$parent")
  done
}

desired_copy_change() {
  local source="$1" destination="$2" mode="$3" current_mode
  [ -f "$destination" ] || return 0
  cmp -s "$source" "$destination" || return 0
  current_mode=$(stat -f '%Lp' "$destination" 2>/dev/null || stat -c '%a' "$destination")
  [ "$current_mode" = "${mode#0}" ] || return 0
  return 1
}

settings_rendered() {
  if [ -e "$SETTINGS_FILE" ]; then
    jq -e 'type == "object" and ((.hooks // {}) | type == "object") and ((.hooks.Stop // []) | type == "array")' "$SETTINGS_FILE" >/dev/null \
      || return 1
    jq --arg command "$STOP_COMMAND" '
      .hooks //= {}
      | .hooks.Stop //= []
      | .hooks.Stop |= map(
          if (.hooks | type) == "array" then
            .hooks |= map(select((.type == "command" and .command == $command) | not))
          else . end
        )
      | .hooks.Stop |= map(select((.hooks | type) == "array" and (.hooks | length) > 0))
      | .hooks.Stop += [{matcher:"*",hooks:[{type:"command",command:$command,async:false}]}]
    ' "$SETTINGS_FILE"
  else
    jq -n --arg command "$STOP_COMMAND" '{hooks:{Stop:[{matcher:"*",hooks:[{type:"command",command:$command,async:false}]}]}}'
  fi
}

# Complete preflight: no target, ancestor, source, or settings path is accepted
# until all targets are safe to replace.
for ((index = 0; index < copy_count; index++)); do
  copy_fields "$index"
  case "$destination" in
    "$TEMPLATE_DIR"/*) validate_destination "$destination" "$TEMPLATE_DIR" ;;
    *) validate_destination "$destination" "$HOME" ;;
  esac
done
validate_destination "$SETTINGS_FILE" "$HOME"
validate_destination "$GIT_CONFIG_FILE" "$GIT_CONFIG_BOUNDARY"
validate_destination "$CLAUDE_DIR/auto-docs-backups/.transaction-probe" "$HOME"
SETTINGS_RENDERED=$(settings_rendered) || die 'refusing to modify invalid Claude settings'
if [ -f "$SETTINGS_FILE" ] && [ "$(cat "$SETTINGS_FILE")" = "$SETTINGS_RENDERED" ]; then SETTINGS_CHANGED=0; else SETTINGS_CHANGED=1; fi
CURRENT_TEMPLATE=$(git_global --get init.templateDir 2>/dev/null || true)
[ "$CURRENT_TEMPLATE" = "$TEMPLATE_DIR" ] && GIT_CONFIG_CHANGED=0 || GIT_CONFIG_CHANGED=1

declare -a COPY_CHANGED=()
ANY_CHANGED=$((SETTINGS_CHANGED + GIT_CONFIG_CHANGED))
for ((index = 0; index < copy_count; index++)); do
  copy_fields "$index"
  if desired_copy_change "$REPO_DIR/$source" "$destination" "$mode"; then COPY_CHANGED+=(1); ANY_CHANGED=$((ANY_CHANGED + 1)); else COPY_CHANGED+=(0); fi
done

if [ "$MODE" = '--dry-run' ]; then
  printf 'Auto-Docs installation dry run (no files or configuration will change)\n'
  printf '  source checkout: %s\n' "$REPO_DIR"
  for ((index = 0; index < copy_count; index++)); do
    copy_fields "$index"
    if [ "${COPY_CHANGED[$index]}" -eq 1 ]; then printf '  REPLACE %s -> %s (mode %s)\n' "$source" "$destination" "$mode"; else printf '  KEEP %s\n' "$destination"; fi
  done
  [ "$SETTINGS_CHANGED" -eq 1 ] && printf '  MERGE Stop hook registration into %s\n' "$SETTINGS_FILE" || printf '  KEEP Stop hook registration in %s\n' "$SETTINGS_FILE"
  [ "$GIT_CONFIG_CHANGED" -eq 1 ] && printf '  SET default global git init.templateDir -> %s\n' "$TEMPLATE_DIR" || printf '  KEEP default global git init.templateDir -> %s\n' "$TEMPLATE_DIR"
  exit 0
fi

if [ "$ANY_CHANGED" -eq 0 ]; then
  printf 'Auto-Docs is already current; no transaction was needed.\n'
  exit 0
fi

BACKUP_DIR="$CLAUDE_DIR/auto-docs-backups/$(date -u +%Y%m%dT%H%M%SZ)"
suffix=1
while [ -e "$BACKUP_DIR" ]; do BACKUP_DIR="$CLAUDE_DIR/auto-docs-backups/$(date -u +%Y%m%dT%H%M%SZ)-$suffix"; suffix=$((suffix + 1)); done
mkdir -p "$BACKUP_DIR/files" "$BACKUP_DIR/stage"
MANIFEST="$BACKUP_DIR/manifest.tsv"
ROLLBACK="$BACKUP_DIR/rollback.sh"
TRANSACTION_RESTORE="$BACKUP_DIR/.transaction-restore.sh"
printf 'index\tstate\ttarget\tmode\n' > "$MANIFEST"
emit_restore_function() {
  cat <<'EOF'
restore() {
  local state="$1" target="$2" backup="$3" mode="$4"
  if [ "$state" = absent ]; then
    [ ! -e "$target" ] || [ -f "$target" ] || { printf 'rollback refuses non-file target: %s\n' "$target" >&2; return 1; }
    rm -f -- "$target"
  else
    mkdir -p "$(dirname "$target")"
    [ ! -e "$target" ] || [ -f "$target" ] || { printf 'rollback refuses non-file target: %s\n' "$target" >&2; return 1; }
    rm -f -- "$target"
    cp -p -- "$backup" "$target"
    chmod "$mode" "$target"
  fi
}
EOF
}

cat > "$ROLLBACK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
file_digest() {
  shasum -a 256 -- "$1" | awk '{print $1}'
}
file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}
check_target() {
  local state="$1" target="$2" digest="$3" mode="$4" current_digest current_mode
  if [ "$state" = absent ]; then
    [ ! -e "$target" ] && [ ! -L "$target" ] || { printf 'rollback refuses drifted target: %s\n' "$target" >&2; return 1; }
    return 0
  fi
  [ ! -L "$target" ] && [ -f "$target" ] || { printf 'rollback refuses drifted target: %s\n' "$target" >&2; return 1; }
  current_digest=$(file_digest "$target")
  current_mode=$(file_mode "$target")
  [ "$current_digest" = "$digest" ] && [ "$current_mode" = "$mode" ] \
    || { printf 'rollback refuses drifted target: %s\n' "$target" >&2; return 1; }
}
EOF
emit_restore_function >> "$ROLLBACK"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' > "$TRANSACTION_RESTORE"
emit_restore_function >> "$TRANSACTION_RESTORE"

declare -a TARGET_STATES=()
declare -a TARGET_MODES=()
declare -a TARGET_PATHS=()

record_target() {
  local target="$1" index="$2" state mode='-'
  if [ -e "$target" ]; then
    state=present
    mode=$(stat -f '%Lp' "$target" 2>/dev/null || stat -c '%a' "$target")
    cp -p -- "$target" "$BACKUP_DIR/files/$index"
    printf '%s\tpresent\t%s\t%s\n' "$index" "$target" "$mode" >> "$MANIFEST"
  else
    state=absent
    printf '%s\tabsent\t%s\t-\n' "$index" "$target" >> "$MANIFEST"
  fi
  TARGET_STATES[$index]="$state"
  TARGET_MODES[$index]="$mode"
  TARGET_PATHS[$index]="$target"
  printf 'restore %q %q %q %q\n' "$state" "$target" "$BACKUP_DIR/files/$index" "$mode" >> "$TRANSACTION_RESTORE"
}

# Record every target, not only changed ones, before the first mutation.
record_index=0
for ((index = 0; index < copy_count; index++)); do
  copy_fields "$index"
  record_target "$destination" "$record_index"
  record_index=$((record_index + 1))
done
record_target "$SETTINGS_FILE" "$record_index"; record_index=$((record_index + 1))
record_target "$GIT_CONFIG_FILE" "$record_index"
printf 'git_init_template_dir\t%s\n' "$CURRENT_TEMPLATE" >> "$MANIFEST"
chmod 0700 "$ROLLBACK" "$TRANSACTION_RESTORE"

rollback_on_error() {
  local status="$1"
  trap - ERR INT TERM
  "$TRANSACTION_RESTORE" >&2 || true
  exit "$status"
}
trap 'rollback_on_error $?' ERR INT TERM

# Stage all output before touching destinations.
for ((index = 0; index < copy_count; index++)); do
  copy_fields "$index"
  if [ "${COPY_CHANGED[$index]}" -eq 1 ]; then
    cp -P -- "$REPO_DIR/$source" "$BACKUP_DIR/stage/copy-$index"
    chmod "$mode" "$BACKUP_DIR/stage/copy-$index"
  fi
done
if [ "$SETTINGS_CHANGED" -eq 1 ]; then printf '%s\n' "$SETTINGS_RENDERED" > "$BACKUP_DIR/stage/settings.json"; chmod 0600 "$BACKUP_DIR/stage/settings.json"; fi

for ((index = 0; index < copy_count; index++)); do
  copy_fields "$index"
  if [ "${COPY_CHANGED[$index]}" -eq 1 ]; then
    mkdir -p "$(dirname "$destination")"
    mv -f "$BACKUP_DIR/stage/copy-$index" "$destination"
  fi
done
if [ "$SETTINGS_CHANGED" -eq 1 ]; then mkdir -p "$(dirname "$SETTINGS_FILE")"; mv -f "$BACKUP_DIR/stage/settings.json" "$SETTINGS_FILE"; fi
if [ "$GIT_CONFIG_CHANGED" -eq 1 ]; then git_global init.templateDir "$TEMPLATE_DIR"; fi

# A user-invoked rollback is safe only while every managed target still equals
# the state installed by this transaction. Emit all checks before all restores
# so drift cannot produce a partial rollback.
ROLLBACK_CHECKS="$BACKUP_DIR/stage/rollback-checks"
ROLLBACK_RESTORES="$BACKUP_DIR/stage/rollback-restores"
: > "$ROLLBACK_CHECKS"
: > "$ROLLBACK_RESTORES"
for ((index = 0; index < ${#TARGET_PATHS[@]}; index++)); do
  target=${TARGET_PATHS[$index]}
  old_state=${TARGET_STATES[$index]}
  old_mode=${TARGET_MODES[$index]}
  if [ -e "$target" ]; then
    installed_state=present
    installed_mode=$(stat -f '%Lp' "$target" 2>/dev/null || stat -c '%a' "$target")
    installed_digest=$(shasum -a 256 -- "$target" | awk '{print $1}')
  else
    installed_state=absent
    installed_mode='-'
    installed_digest='-'
  fi
  printf 'check_target %q %q %q %q\n' "$installed_state" "$target" "$installed_digest" "$installed_mode" >> "$ROLLBACK_CHECKS"
  printf 'restore %q %q %q %q\n' "$old_state" "$target" "$BACKUP_DIR/files/$index" "$old_mode" >> "$ROLLBACK_RESTORES"
done
cat "$ROLLBACK_CHECKS" "$ROLLBACK_RESTORES" >> "$ROLLBACK"
rm -f -- "$ROLLBACK_CHECKS" "$ROLLBACK_RESTORES"
trap - ERR INT TERM
rm -f -- "$TRANSACTION_RESTORE"

printf 'Installed Auto-Docs transaction. Rollback: %s\n' "$ROLLBACK"

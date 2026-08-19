#!/usr/bin/env bash
# Append one user-confirmed feature summary to the ignored project worklog.

set -eu

usage() {
  printf 'Usage: %s --id <merge-request-url-or-id> --title <title> --summary <summary>\n' "${0##*/}" >&2
}

die() {
  printf 'auto-docs: %s\n' "$1" >&2
  exit 2
}

id=''
title=''
summary=''
seen_id=0
seen_title=0
seen_summary=0

while [ "$#" -gt 0 ]; do
  option=$1
  case "$option" in
    --id|--title|--summary)
      [ "$#" -ge 2 ] || { usage; die "missing value for $option"; }
      value=$2
      case "$option" in
        --id)
          [ "$seen_id" -eq 0 ] || die 'duplicate --id'
          id=$value; seen_id=1
          ;;
        --title)
          [ "$seen_title" -eq 0 ] || die 'duplicate --title'
          title=$value; seen_title=1
          ;;
        --summary)
          [ "$seen_summary" -eq 0 ] || die 'duplicate --summary'
          summary=$value; seen_summary=1
          ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $option"
      ;;
  esac
done

[ "$seen_id" -eq 1 ] || { usage; die 'missing --id'; }
[ "$seen_title" -eq 1 ] || { usage; die 'missing --title'; }
[ "$seen_summary" -eq 1 ] || { usage; die 'missing --summary'; }
[ -n "$id" ] || die '--id must not be empty'
[ -n "$title" ] || die '--title must not be empty'
[ -n "$summary" ] || die '--summary must not be empty'

if ! printf '%s' "$id" | LC_ALL=C grep -Eq '^[A-Za-z0-9._:/#?=&%+-]+$'; then
  die '--id contains unsupported characters'
fi
for field in "$title" "$summary"; do
  case "$field" in
    *$'\n'*|*$'\r'*) die 'title and summary must be single-line printable text' ;;
  esac
  if printf '%s' "$field" | LC_ALL=C grep -Eq '^[[:space:]]*$'; then
    die 'title and summary must not be blank'
  fi
  if printf '%s' "$field" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    die 'title and summary must be single-line printable text'
  fi
done

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || die 'not inside a Git worktree'
[ -f "$repo_root/.claude/no-docs" ] && exit 0

docs_dir="$repo_root/docs"
worklog="$docs_dir/WORKLOG.md"
ignore_file="$repo_root/.gitignore"

[ ! -L "$docs_dir" ] || die 'docs must not be a symbolic link'
[ ! -L "$worklog" ] || die 'docs/WORKLOG.md must not be a symbolic link'
[ ! -L "$ignore_file" ] || die '.gitignore must not be a symbolic link'

git_dir=$(git -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null) || die 'cannot resolve Git directory'
lock_dir="$git_dir/auto-docs-feature-complete.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  die 'another feature-summary update is in progress'
fi
worklog_tmp=''
ignore_tmp=''
cleanup() {
  [ -z "$worklog_tmp" ] || rm -f -- "$worklog_tmp"
  [ -z "$ignore_tmp" ] || rm -f -- "$ignore_tmp"
  rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

feature_key=$(printf '%s' "$id" | git -C "$repo_root" hash-object --stdin)
marker="<!-- auto-docs:feature:$feature_key -->"
end_marker="<!-- auto-docs:feature-end:$feature_key -->"
feature_entry_complete() {
  local candidate="$1"
  awk -v marker="$marker" -v end_marker="$end_marker" -v id="$id" '
    $0 == marker {
      if ((getline title) <= 0 || title !~ /^## Feature: .+ \[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]$/) next
      if ((getline blank_one) <= 0 || blank_one != "") next
      if ((getline feature_id) <= 0 || feature_id != "**Feature ID:** " id) next
      if ((getline blank_two) <= 0 || blank_two != "") next
      if ((getline summary) <= 0 || summary !~ /^\*\*Summary:\*\* .+/) next
      if ((getline bounded_end) <= 0 || bounded_end != end_marker) next
      complete = 1
      exit
    }
    END { exit complete ? 0 : 1 }
  ' "$candidate"
}
if [ -f "$worklog" ] && feature_entry_complete "$worklog"; then
  exit 0
fi

mkdir -p "$docs_dir"
if ! grep -Fqx 'docs/WORKLOG.md' "$ignore_file" 2>/dev/null; then
  ignore_tmp=$(mktemp "$repo_root/.auto-docs-gitignore.XXXXXX")
  [ ! -f "$ignore_file" ] || cp -- "$ignore_file" "$ignore_tmp"
  if [ -s "$ignore_tmp" ]; then
    last_byte=$(tail -c 1 "$ignore_tmp" | od -An -t u1 | tr -d ' ')
    [ "$last_byte" = '10' ] || printf '\n' >> "$ignore_tmp"
  fi
  printf '%s\n' 'docs/WORKLOG.md' >> "$ignore_tmp"
  mv "$ignore_tmp" "$ignore_file"
  ignore_tmp=''
fi

worklog_tmp=$(mktemp "$docs_dir/.auto-docs-worklog.XXXXXX")
if [ -f "$worklog" ]; then
  # A lone marker is not completion. Remove stale boundary lines for this ID;
  # retain every other byte, then append one complete bounded replacement.
  if grep -Fvx -e "$marker" -e "$end_marker" "$worklog" > "$worklog_tmp"; then
    :
  else
    grep_status=$?
    [ "$grep_status" -eq 1 ] || die 'could not read docs/WORKLOG.md'
  fi
fi
if [ -s "$worklog_tmp" ]; then
  last_byte=$(tail -c 1 "$worklog_tmp" | od -An -t u1 | tr -d ' ')
  [ "$last_byte" = '10' ] || printf '\n' >> "$worklog_tmp"
  printf '\n' >> "$worklog_tmp"
fi

today=$(date +%Y-%m-%d)
{
  printf '%s\n' "$marker"
  printf '## Feature: %s [%s]\n\n' "$title" "$today"
  printf '**Feature ID:** %s\n\n' "$id"
  printf '**Summary:** %s\n' "$summary"
  printf '%s\n' "$end_marker"
} >> "$worklog_tmp"
feature_entry_complete "$worklog_tmp" || die 'generated feature entry failed validation'
mv "$worklog_tmp" "$worklog"
worklog_tmp=''

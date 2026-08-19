# Reliable Auto-Docs v2 Design

## Goal

Make auto-docs safe to install globally and reliable in normal, untracked-only, and initial Git repositories, then implement every documented v2 document flow without pretending that a Git hook can make an LLM decision.

## Boundaries

The repository contains the distributable artifacts. Applying them to `~/.claude`, Git templates, or an existing repository is a separate, explicit installer action after tests pass. Tests use disposable repositories only and never call GitLab.

## Architecture

### Stop hook

The Stop hook remains a small Bash program. It reads Claude's supported Stop JSON, resolves the Git root, honors `.claude/no-docs`, and counts `git status --porcelain=v1 --untracked-files=all` entries. This works before `HEAD` exists and includes untracked files. Session de-duplication is stored under `${XDG_STATE_HOME:-$HOME/.local/state}/claude-auto-docs`, keyed by a hash of the repo root and session ID; it never writes inside a project.

### Commit hooks

`pre-commit` owns the deterministic CHANGELOG update and stages it before Git creates the commit tree. A non-mutating `prepare-commit-msg` compatibility hook replaces the legacy Auto-Docs hook that staged a second CHANGELOG edit after Git captured the tree. `post-commit` owns the optional GitLab MR description update, which now runs after the commit exists. It only sends `GITLAB_TOKEN` to an explicit allowlist (`AUTO_DOCS_GITLAB_HOSTS`, default `gitlab.com`) and replaces a bounded `<!-- auto-docs:ai-review-context:start/end -->` block.

### Documentation workflow

`auto-docs-write` is an idempotent dynamic workflow. It receives `args` including `sessionSummary`, `commitBoundary`, and optional confirmed decision metadata. A detector reads Git state and a local `.claude/auto-docs-state.json` cursor. It bootstraps `docs/`, `WORKLOG.md`, and its ignore rule before fan-out. It writes CHANGLELOG entries only for commits after the cursor; structural and interface changes update architecture and usage respectively; a decision entry is written only when the caller supplies a user-confirmed decision. The cursor is committed because it is project documentation state.

### Feature summaries

Git cannot know that an MR was closed. The installed skill therefore asks Claude to verify closure through the configured GitLab tool/API, then run a small `auto-docs-feature-complete.sh` command with a user-confirmed summary. The command appends one idempotent feature entry keyed by merge request URL/ID. This makes the advertised MR-close flow executable without guessing from branch state.

## Contracts

- Stop output uses `hookSpecificOutput.hookEventName = "Stop"` and `additionalContext`.
- `.claude/no-docs` disables all project-side hooks and feature-summary commands.
- `pre-commit` writes/stages only `docs/CHANGELOG.md`; it does not call external services.
- `prepare-commit-msg` is installed as a non-mutating compatibility hook so a stale legacy version cannot leave post-commit staged changes.
- `post-commit` performs no network call without both `GITLAB_TOKEN` and an allowlisted host.
- Marker replacement touches only text between the two exact HTML markers.
- Workflow cursor records the newest processed commit SHA and skips duplicate WORKLOG and CHANGELOG entries.
- All generated per-project state is either ignored (`WORKLOG.md`) or deliberately tracked (`.claude/auto-docs-state.json`).

## Testing

A Bash test runner creates isolated Git repos and verifies: ordinary tracked change detection, untracked-only detection, initial-repo detection, opt-out, state outside the project, same-commit changelog staging, clean consecutive commits from an installed template seeded with the legacy mutating hook, multiline commit subjects, host deny/allow behavior using a fake `curl`, bounded MR replacement, workflow source/runtime contracts, and feature-summary idempotency. It runs with no credentials or network access.

## Rollout and rollback

`install.sh --dry-run` reports every target. `install.sh --apply` backs up changed global settings and hook-template files, copies the versioned artifacts, and installs `pre-commit` plus `post-commit` templates. Re-running is idempotent. Rollback restores the backup directory printed by the installer.

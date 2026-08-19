---
name: auto-docs
description: Use when documenting Git project work after a coding session, commit, structural or interface change, significant confirmed decision, or confirmed feature completion.
---

# Auto-Docs v2

Keep project documentation current without treating a Git hook as an LLM or
claiming that a dynamic workflow can prompt a user mid-run.

## Safety gate

Resolve the Git root first. If `<root>/.claude/no-docs` exists, stop silently.
Never write through symlinked documentation or state paths. Never stage
`docs/WORKLOG.md`.

The distributable hooks and workflow are source artifacts. Installing them in
global Claude settings, Git templates, or another repository is a separate,
explicit action.

## Executable components

### Stop hook

`auto-docs-stop.sh` reads the supported Stop payload fields `cwd`,
`session_id`, and `stop_hook_active`. When porcelain Git status finds tracked,
staged, or untracked work, it emits `hookSpecificOutput.additionalContext` once
per repository/session. Deduplication state lives outside the project under
`${XDG_STATE_HOME:-$HOME/.local/state}/claude-auto-docs`.

The Stop hook does not update docs or question the user itself. On receiving
its context, ask `Document this work?`. Run `auto-docs-write` only after the
user agrees.

### Commit hooks

- `auto-docs-pre-commit.sh` records deterministic staged-file information in
  `docs/CHANGELOG.md` and stages that file in the same commit. It performs no
  network access.
- `auto-docs-post-commit.sh` optionally replaces one bounded AI Review Context
  block in an open GitLab merge request. It requires `GITLAB_TOKEN`, skips
  `main` and `master`, and sends the token only to an exact host in
  `AUTO_DOCS_GITLAB_HOSTS` (default `gitlab.com`).
- `auto-docs-prepare-commit-msg.sh` is a deprecated, silent, non-mutating
  compatibility hook. Install it alongside pre-commit and post-commit so a
  stale legacy version cannot stage another CHANGELOG edit after Git captures
  the commit tree.

All project hooks honor `.claude/no-docs`.

### Documentation workflow

Invoke `auto-docs-write` with:

```json
{
  "workingDir": "/absolute/project/path",
  "sessionSummary": "User-confirmed summary of this work",
  "commitBoundary": "optional-exclusive-lower-commit",
  "decision": {
    "confirmed": true,
    "title": "Decision title",
    "context": "Why a choice was needed",
    "decision": "What was chosen and why",
    "alternativesConsidered": "Other options and why rejected",
    "consequences": "What this choice shapes"
  }
}
```

`commitBoundary` and `decision` are optional. Supply `decision` only after the
user explicitly confirms capture; all five text fields are required when
`confirmed` is `true`. The workflow ignores incomplete or unconfirmed decision
objects. It never asks for confirmation in process.

The workflow runs these phases:

1. A bootstrap agent honors the opt-out, creates `docs/WORKLOG.md`, adds exactly
   one `docs/WORKLOG.md` ignore rule, and initializes tracked state at
   `.claude/auto-docs-state.json`.
2. A detector reads working-tree paths, HEAD, the optional boundary, and
   `lastProcessedCommit` from the cursor.
3. Haiku agents update only the documents whose conditions apply.
4. After every planned writer succeeds, a checkpoint agent advances and stages
   the cursor to the newest processed commit.

The workflow is idempotent: WORKLOG sessions and commit-derived CHANGELOG
entries use stable markers, and the cursor limits later runs to commits after
the recorded SHA. `docs/WORKLOG.md` stays ignored; CHANGELOG, ARCHITECTURE,
USAGE, DECISIONS, `.gitignore`, and cursor state are deliberately stageable.

## Document conditions

| File | Condition | Behavior |
| --- | --- | --- |
| `docs/WORKLOG.md` | Every confirmed workflow run | Append one deduplicated session entry; never stage |
| `docs/CHANGELOG.md` | Commits exist after boundary/cursor | Add only unseen commit entries under Unreleased |
| `docs/ARCHITECTURE.md` | Non-test source structure changed | Create if missing or update affected sections; include a focused Mermaid diagram when applicable |
| `docs/USAGE.md` | API, route, CLI, handler, service, or similar interface path changed | Create if missing or update affected sections |
| `docs/DECISIONS.md` | Complete `decision.confirmed: true` metadata supplied | Append the user-confirmed decision; never infer one |

Agents read existing documents before writing, preserve unrelated content, use
the pinned Haiku model, and do not commit.

## User-confirmed feature summaries

Git does not prove that a merge request closed. First verify merged/closed
state through the configured GitLab tool or API. Then ask the user to confirm
the title and one-line summary. Only after confirmation, run from anywhere in
the project:

```bash
bash /path/to/auto-docs-feature-complete.sh \
  --id 'https://gitlab.com/group/project/-/merge_requests/42' \
  --title 'Reliable auto-docs' \
  --summary 'Made documentation updates deterministic and safe.'
```

`--id`, `--title`, and `--summary` are required exactly once. The command
rejects unsafe input before writing, honors `.claude/no-docs`, ensures the
WORKLOG ignore rule, and appends at most one feature entry for the confirmed
merge request URL or ID. Retrying the same ID does not replace the original
confirmed entry.

## Common mistakes

- Do not claim the workflow prompts the user; collect confirmation before
  invocation.
- Do not infer a significant decision or merge-request closure.
- Do not use post-commit for deterministic same-commit CHANGELOG staging.
- Do not leave the legacy mutating `prepare-commit-msg` hook active; replace it
  with the shipped non-mutating compatibility hook.
- Do not send a GitLab token to a host outside the explicit allowlist.
- Do not commit `docs/WORKLOG.md` or store Stop-hook session sentinels in the
  project.

# Reliable Auto-Docs v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a secure, tested, and installable Auto-Docs v2 implementation.

**Architecture:** Separate deterministic Git operations from model-directed documentation work. Store only session deduplication outside repositories, while committing a narrow workflow cursor that makes document updates idempotent.

**Tech Stack:** Bash, Git hooks, jq, Claude Code dynamic-workflow JavaScript.

**Spec:** `docs/superpowers/specs/2026-08-19-reliable-auto-docs-v2-design.md`

## Global Constraints

- Do not mutate `~/.claude`, Git templates, or remote GitLab during tests.
- Use a fake curl executable for all MR updater tests.
- All behavior changes begin with a failing executable test.
- Keep `docs/WORKLOG.md` ignored and preserve unrelated working-tree files.

---

### Task 1: Add an executable hook integration suite

**Files:** Create `tests/run-tests.sh`; modify `.gitignore`.

**Interfaces:** The runner invokes each hook with disposable Git repos and exits nonzero for any failed assertion.

- [ ] Write failing tests for tracked, untracked, no-HEAD, opt-out, and non-polluting Stop-hook behavior.
- [ ] Run `bash tests/run-tests.sh`; expect missing-file failure.
- [ ] Add test helpers and assertions, without production changes.
- [ ] Re-run the suite; expect Stop cases to fail against the old implementation.

### Task 2: Harden Stop and commit hooks

**Files:** Modify `hooks/auto-docs-stop.sh`, `hooks/auto-docs-prepare-commit-msg.sh`; create `hooks/auto-docs-pre-commit.sh`, `hooks/auto-docs-post-commit.sh`.

**Interfaces:** Stop emits a one-per-session context prompt; pre-commit stages CHANGELOG for its own commit; prepare-commit-msg is a non-mutating legacy neutralizer; post-commit performs bounded, allowlisted MR updates.

- [ ] Extend tests for same-commit staging, clean installed-template commits with a seeded legacy hook, multiline subjects, denied hosts, and bounded marker replacement.
- [ ] Run the focused tests and observe failures.
- [ ] Implement the minimal hook behavior to satisfy each case.
- [ ] Run `bash tests/run-tests.sh`; expect all hook cases to pass.

### Task 3: Complete idempotent workflow and feature summaries

**Files:** Modify `workflow/auto-docs.js`, `skill/SKILL.md`; create `hooks/auto-docs-feature-complete.sh`.

**Interfaces:** Workflow accepts `{ workingDir, sessionSummary, commitBoundary?, decision? }`; feature command accepts `--id`, `--title`, `--summary`.

- [ ] Add failing source/runtime-contract and feature-idempotency tests.
- [ ] Run focused tests and observe failures.
- [ ] Implement bootstrap, cursor, decision, architecture, usage, and feature-summary behavior.
- [ ] Run the full suite; expect all cases to pass.

### Task 4: Make installation safe and documentation accurate

**Files:** Create `install.sh`; modify `CLAUDE-INSTALL.md`, `README.md`.

**Interfaces:** `install.sh --dry-run|--apply` takes `--repo-dir`; dry run has no writes and apply creates a timestamped backup.

- [ ] Add failing dry-run and installer-content tests.
- [ ] Run focused tests and observe failures.
- [ ] Implement idempotent install of all three commit-hook paths, safe backup, and accurate instructions.
- [ ] Run `bash tests/run-tests.sh`, `bash -n` for all hooks/installer, and `git diff --check`.

### Task 5: Review, rollout, and verify

**Files:** All changed artifacts.

- [ ] Review the diff against the spec and audit findings.
- [ ] Run the complete test and syntax verification matrix.
- [ ] Run `./install.sh --dry-run --repo-dir "$PWD"` only.
- [ ] Present the verified diff and explicit global-apply command; do not apply globally without a fresh confirmation.

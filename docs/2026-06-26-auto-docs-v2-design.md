# Auto-Docs v2 Design

**Date:** 2026-06-26  
**Status:** Approved

## Problem

Current auto-docs skill only fires at commit time or brainstorming sessions. Adhoc work (no commits) goes undocumented. No resume-oriented work tracking. No AI context continuity between sessions. No MR-level context for code reviewers or AI review tools.

## Goals

1. Capture all meaningful work automatically, not just committed work
2. Maintain resume-ready work log (problems solved, effort, impact)
3. Give AI full project context on new sessions without burning tokens re-deriving architecture
4. Give MR reviewers (human + AI) key decisions and tradeoffs inline
5. Propagate doc maintenance to engineers without the skill via `CLAUDE.md` injection

## Design

### Triggers

Two complementary triggers:

**Stop Hook (per-turn)**
- Fires after every Claude turn via `.claude/settings.json` `stop` hook
- Heuristic gate: skip if no files changed AND no bash ran AND no agents spawned (pure Q&A)
- Work detected → `AskUserQuestion`: "Document this work?"
- Yes → spawn haiku doc agents. No → silent skip.

Heuristic detection:
```
files_changed = git diff --name-only (staged + unstaged) | wc -l > 0
bash_ran     = hook received Bash tool_use events this turn
agents_ran   = hook received Agent tool_use events this turn
work         = files_changed OR bash_ran OR agents_ran
```

**Commit Gate (per-commit)**
- `prepare-commit-msg` git hook
- Always updates `docs/CHANGELOG.md`
- On feature branch with open MR → updates MR description with AI Review Context block
- Uses `rtk git` for all git commands

### Document Structure

All docs in `docs/` at project root.

| File | Trigger | Mode |
|------|---------|------|
| `docs/CHANGELOG.md` | Commit gate | Auto |
| `docs/ARCHITECTURE.md` | Structural change | Auto |
| `docs/USAGE.md` | Interface change | Auto |
| `docs/DECISIONS.md` | Ask always | Manual confirm |
| `docs/WORKLOG.md` | Stop hook | Auto (session) + prompted (feature) |

**`docs/WORKLOG.md` format:**

```markdown
## Session: YYYY-MM-DD

**What I worked on:** Brief summary.
**Challenges:** Technical blockers and how resolved.
**Outcome:** State of code after session.

---

## Feature: <Name> [YYYY-MM-DD]

**Problem:** What was broken or missing.
**Solution:** How solved, key technical decisions.
**Effort:** Rough estimate (hours/days).
**Impact:** What it unblocks or improves.
**Technical challenges:** Non-obvious things worth remembering.
```

Session entries: auto on Stop hook.  
Feature entries: triggered when MR is closed/merged — prompts "Feature complete? Add feature summary?" Fallback for no-MR workflows: ask once per session if branch has commits and no feature entry exists for this branch yet.

`docs/WORKLOG.md` always added to `.gitignore` — personal tracking, not repo history.

### Agent Architecture

Stop hook fans out parallel haiku agents:

```
User confirms "Document this work?"
  → Workflow (haiku, caveman ultra)
    ├── Agent A: docs/CHANGELOG.md  (if commits present)
    ├── Agent B: docs/ARCHITECTURE.md  (if structural change)
    ├── Agent C: docs/USAGE.md  (if interface change)
    ├── Agent D: docs/DECISIONS.md  (only if decision confirmed this session)
    └── Agent E: docs/WORKLOG.md  (always — session entry)
```

Each agent:
- `model: "claude-haiku-4-5-20251001"` hardcoded — no session model inheritance
- Caveman ultra system prompt for internal reasoning
- `rtk` for all shell/git commands
- Reads existing doc first, appends/updates only — never full rewrites
- Writes only its assigned file

Commit gate: single sequential agent — `docs/CHANGELOG.md` + MR description in one pass.

### Permissions

Auto-docs injects into project `.claude/settings.json` on first run:

```json
{
  "permissions": {
    "allow": [
      "Read(*)",
      "Bash(ls:*)",
      "Bash(cat:*)",
      "Bash(git diff*)",
      "Bash(git log*)",
      "Bash(git status*)",
      "Bash(rtk git*)",
      "Write(docs/*)",
      "Edit(docs/*)",
      "Bash(echo * >> docs/*)"
    ]
  }
}
```

Read: unrestricted. Write/Edit: `docs/` only. Merged into existing `settings.json`, never overwritten. Committed to repo so other engineers inherit same permissions.

### MR Description Format

Commit gate appends once, updates on subsequent commits (never duplicates):

```markdown
---
## AI Review Context

**Changes in this MR:**
- Bullet per logical change

**Key decisions & tradeoffs:**
- Decision: chose X over Y because Z

**Known limitations / follow-ups:**
- ...

**Full context:** `docs/ARCHITECTURE.md`, `docs/DECISIONS.md`
```

Sourced from `docs/DECISIONS.md` entries since branch creation. Omits sections with no data. Only runs on feature branches with open MR — skips `main`/`master`.

### CLAUDE.md Injection

Auto-docs appends to project `CLAUDE.md` on first run (creates if missing):

```markdown
# Auto-Docs
Docs live in `docs/`. Update them when making changes.
Run `auto-docs` skill or answer Yes to "Document this work?" prompt.
```

Dedup-safe: only appends if `# Auto-Docs` section not already present.

### Toggle

Unchanged from v1: `.claude/no-docs` file disables all doc actions silently.

## What Changes from v1

| v1 | v2 |
|----|----|
| Docs in project root | Docs in `docs/` |
| Commit-only trigger | Stop hook + commit gate |
| No work log | `WORKLOG.md` (session + feature) |
| No MR updates | MR description AI Review Context block |
| No CLAUDE.md injection | Auto-injects per project |
| Single inline agent | Parallel haiku agents per doc |
| No permission setup | Auto-configures `.claude/settings.json` |

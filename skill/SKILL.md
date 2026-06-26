---
name: auto-docs
description: Use when working in any git project — governs automatic documentation triggered by Stop hook, commit gate, and explicit invocation. Skip if `.claude/no-docs` exists in project root.
---

# Auto-Docs v2

Maintain five living documents per project. Triggered by Stop hook (per-turn), commit gate, and explicit invocation.

## Toggle

```bash
[ -f .claude/no-docs ] && echo "SKIP" || echo "PROCEED"
```

- Present → skip all doc actions silently
- "stop docs" → `touch .claude/no-docs`
- "start docs" / "enable docs" → `rm .claude/no-docs`

---

## The Five Documents

All docs live in `docs/` at project root.

| File | Trigger | Mode |
|------|---------|------|
| `docs/CHANGELOG.md` | Commit gate | Auto |
| `docs/ARCHITECTURE.md` | Structural change | Auto (ask first time) |
| `docs/USAGE.md` | Interface change | Auto (ask first time) |
| `docs/DECISIONS.md` | Significant decision | Ask every time |
| `docs/WORKLOG.md` | Stop hook, MR close | Auto (session) + prompted (feature) |

`docs/WORKLOG.md` is always added to `.gitignore`. Never commit it.

---

### docs/CHANGELOG.md

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)

```markdown
## [Unreleased]

### Added
- Payment webhook — chose idempotency key over dedup table for simpler rollback

### Changed
- Auth module — removed session token storage (compliance)

### Fixed
- Race condition in async handler — missing await on DB write
```

Write before commit. Stage with other files. One line per logical change, include WHY for non-obvious choices.

Skip if: typo/formatting, WIP marker, test fixtures with no logic change, merge commit.

---

### docs/ARCHITECTURE.md

Living system overview. Written for a new engineer joining the project.

```markdown
# Architecture

## What This Is
## System Overview
## Key Design Principles
## Data Model
## External Dependencies
## Known Constraints & Tradeoffs
```

Auto-update on: new service/module/layer, core data model change, significant dependency change, component responsibility shift.

First time (file missing): ask once — "No ARCHITECTURE.md found. Generate one?"

Update strategy: update only affected section(s). Never full rewrite.

---

### docs/USAGE.md

Practical guide: setup, run, configure, deploy, API/CLI reference.

Auto-update on: new CLI command/flag, API endpoint change, new required env var, setup change, deployment config change, new prerequisite.

First time (file missing): ask once.

Update strategy: update only affected section(s).

---

### docs/DECISIONS.md

Append-only log of significant decisions. Always ask before writing — never auto-write.

```markdown
## [DATE] Decision Title

**Context:** What prompted this.
**Decision:** What was chosen and why.
**Alternatives considered:** What else, why rejected.
**Consequences:** What this shapes going forward.
```

Ask when: architecture choice made, significant tradeoff accepted, non-obvious pattern adopted.

Prompt: `"Significant decision on [topic]. Capture in DECISIONS.md?"`

---

### docs/WORKLOG.md — Session + Feature entries

**Session entry** (auto on Stop hook):

```markdown
## Session: YYYY-MM-DD

**What I worked on:** Brief summary.
**Challenges:** Technical blockers and how resolved.
**Outcome:** State of code after session.
```

**Feature entry** (prompted on MR close, or once per session if no MR workflow):

```markdown
## Feature: <Name> [YYYY-MM-DD]

**Problem:** What was broken or missing.
**Solution:** How solved, key technical decisions.
**Effort:** Rough estimate (hours/days).
**Impact:** What it unblocks or improves.
**Technical challenges:** Non-obvious things worth remembering.
```

---

## Stop Hook Workflow

The Stop hook fires after every Claude turn. Auto-docs is invoked when work is detected.

```
1. Check .claude/no-docs → skip if present
2. Detect work: files_changed OR bash_ran OR agents_ran?
3. No work detected → skip silently (pure Q&A)
4. Work detected → AskUserQuestion: "Document this work?"
5. No → skip
6. Yes → fan out parallel haiku agents (see Agent Architecture)
7. Check MR state: MR closed since last feature entry? → "Feature complete? Add feature summary?"
```

---

## Commit Gate Workflow

Runs via `prepare-commit-msg` git hook in the project repo.

```
1. Check .claude/no-docs → skip if present
2. Trivial commit? → skip all docs
3. Update docs/CHANGELOG.md → stage it
4. Structural change? → update docs/ARCHITECTURE.md → stage it
5. Interface change? → update docs/USAGE.md → stage it
6. On feature branch with open MR? → update MR description (AI Review Context block)
```

---

## Agent Architecture

Parallel haiku agents, one per doc:

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
- `model: "global.anthropic.claude-haiku-4-5-20251001-v1:0"`
- Caveman ultra system prompt
- Uses `rtk` for all shell/git commands
- Reads existing doc first, appends/updates — never full rewrite
- Writes only its assigned file

---

## MR Description Format

Commit gate appends once, updates on subsequent commits (never duplicates block):

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

---

## Project Bootstrap (first run in a project)

When auto-docs first runs in a project, execute:

```bash
# 1. Create docs/ if missing
mkdir -p docs

# 2. Add WORKLOG.md to .gitignore (dedup-safe)
grep -q 'docs/WORKLOG.md' .gitignore 2>/dev/null || echo 'docs/WORKLOG.md' >> .gitignore

# 3. Inject CLAUDE.md entry (dedup-safe)
grep -q '# Auto-Docs' CLAUDE.md 2>/dev/null || cat >> CLAUDE.md << 'EOF'

# Auto-Docs
Docs live in `docs/`. Update them when making changes.
Run auto-docs skill or answer Yes to "Document this work?" prompt.
EOF

# 4. Merge permissions into .claude/settings.json
mkdir -p .claude
[ -f .claude/settings.json ] || echo '{}' > .claude/settings.json
jq '.permissions.allow += ["Read(*)", "Bash(ls:*)", "Bash(cat:*)", "Bash(git diff*)", "Bash(git log*)", "Bash(git status*)", "Bash(rtk git*)", "Write(docs/*)", "Edit(docs/*)"] | .permissions.allow |= unique' \
  .claude/settings.json > /tmp/settings-merged.json && mv /tmp/settings-merged.json .claude/settings.json

# 5. Install prepare-commit-msg git hook (only needed for existing repos cloned before global template was set)
# New git init/clone picks up hook automatically via ~/.git-templates
if [ ! -f ".git/hooks/prepare-commit-msg" ]; then
  cp ~/.claude/hooks/auto-docs-prepare-commit-msg.sh .git/hooks/prepare-commit-msg
  chmod +x .git/hooks/prepare-commit-msg
fi
```

Then for each missing doc, ask once: `"No [FILE] found. Initialize it?"`

---

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Writing DECISIONS.md without asking | Always ask first, every time |
| Rewriting full doc on small change | Update only affected section |
| Updating CHANGELOG after commit | Stage with the commit |
| Skipping ARCHITECTURE/USAGE on structural/interface changes | Check diff triggers |
| Creating docs in repos with `.claude/no-docs` | Check toggle first |
| Committing WORKLOG.md | Must be in .gitignore |
| Doc agents using session model | Hardcode haiku model always |

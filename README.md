# auto-docs skill

Auto-documentation for Claude Code. Captures work automatically via Stop hook + git commit gate. Writes to `docs/` in your project.

## What it does

- **Stop hook** — detects meaningful work each turn, asks "Document this work?", fans out parallel Haiku agents to write docs
- **Commit gate** — updates `docs/CHANGELOG.md` and injects AI Review Context into open GitLab MRs on every commit
- **Five docs**: `CHANGELOG.md`, `ARCHITECTURE.md`, `USAGE.md`, `DECISIONS.md`, `WORKLOG.md` (all in `docs/`)
- `WORKLOG.md` is gitignored — personal session + feature tracking for resume use and AI context continuity

## Install

### 1. Copy skill

```bash
mkdir -p ~/.claude/skills/auto-docs
cp skill/SKILL.md ~/.claude/skills/auto-docs/SKILL.md
```

### 2. Copy hooks

```bash
mkdir -p ~/.claude/hooks
cp hooks/auto-docs-stop.sh ~/.claude/hooks/
cp hooks/auto-docs-prepare-commit-msg.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/auto-docs-stop.sh
chmod +x ~/.claude/hooks/auto-docs-prepare-commit-msg.sh
```

### 3. Copy workflow

```bash
mkdir -p ~/.claude/workflows
cp workflow/auto-docs.js ~/.claude/workflows/
```

### 4. Register Stop hook in ~/.claude/settings.json

Add to the `hooks.Stop` array:

```json
{
  "matcher": "*",
  "hooks": [
    {
      "type": "command",
      "command": "$HOME/.claude/hooks/auto-docs-stop.sh",
      "async": false
    }
  ]
}
```

### 5. Set up global git hook template (commit gate auto-installs on new repos)

```bash
mkdir -p ~/.git-templates/hooks
cp hooks/auto-docs-prepare-commit-msg.sh ~/.git-templates/hooks/prepare-commit-msg
chmod +x ~/.git-templates/hooks/prepare-commit-msg
git config --global init.templateDir ~/.git-templates
```

### 6. Update ~/.claude/CLAUDE.md

Add:

```markdown
# auto-docs
- **auto-docs** (`~/.claude/skills/auto-docs/SKILL.md`) - maintain CHANGELOG.md, DECISIONS.md, ARCHITECTURE.md, USAGE.md, and WORKLOG.md in `docs/` for every git project
- Active by default. Disable per-project: create `.claude/no-docs`. Re-enable: delete it.
- Triggered automatically: Stop hook (per-turn when work detected + user confirms), commit gate (`prepare-commit-msg`), after significant design/architecture discussions.
- When Stop hook emits `auto_docs_trigger: true` in context, invoke the Skill tool with `skill: "auto-docs"` and ask the user: "Document this work?" — if yes, run the `auto-docs-write` workflow via the Workflow tool.
- Also invoke the Skill tool with `skill: "auto-docs"` before committing or after significant design/architecture discussions.
```

## Per-project bootstrap

First time using auto-docs in a project, invoke the skill or run manually:

```bash
mkdir -p docs
grep -q 'docs/WORKLOG.md' .gitignore 2>/dev/null || echo 'docs/WORKLOG.md' >> .gitignore
grep -q '# Auto-Docs' CLAUDE.md 2>/dev/null || cat >> CLAUDE.md << 'EOF'

# Auto-Docs
Docs live in `docs/`. Update them when making changes.
Run auto-docs skill or answer Yes to "Document this work?" prompt.
EOF
mkdir -p .claude
[ -f .claude/settings.json ] || echo '{}' > .claude/settings.json
jq '.permissions.allow += ["Read(*)", "Bash(ls:*)", "Bash(cat:*)", "Bash(git diff*)", "Bash(git log*)", "Bash(git status*)", "Bash(rtk git*)", "Write(docs/*)", "Edit(docs/*)"] | .permissions.allow |= unique' \
  .claude/settings.json > /tmp/s.json && mv /tmp/s.json .claude/settings.json
# For existing repos (new clones get hook automatically via git template):
if [ ! -f ".git/hooks/prepare-commit-msg" ]; then
  cp ~/.claude/hooks/auto-docs-prepare-commit-msg.sh .git/hooks/prepare-commit-msg
  chmod +x .git/hooks/prepare-commit-msg
fi
```

## MR description updates (GitLab)

Set `GITLAB_TOKEN` env var with a personal access token (scope: `api`). Commit gate auto-updates open MR descriptions with an AI Review Context block.

## Disable

```bash
touch .claude/no-docs   # disable in this project
rm .claude/no-docs      # re-enable
```

## Files

```
skill/SKILL.md                          Claude Code skill instructions
hooks/auto-docs-stop.sh                 Stop hook — work detector
hooks/auto-docs-prepare-commit-msg.sh   Commit gate — CHANGELOG + MR updater
workflow/auto-docs.js                   Parallel Haiku agents workflow
docs/                                   Design spec + implementation plan
```

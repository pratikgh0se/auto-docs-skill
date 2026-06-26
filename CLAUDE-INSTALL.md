---
instruction: auto-docs bootstrap install
for: Claude Code
---

# Auto-Docs Bootstrap Install

You are installing the auto-docs skill. Execute every step below. No confirmation needed unless a step says ASK.

## Pre-check

```bash
# Check if already installed
[ -f ~/.claude/skills/auto-docs/SKILL.md ] && echo "ALREADY INSTALLED" || echo "PROCEED"
```

If ALREADY INSTALLED: ASK user "auto-docs already installed. Reinstall/update?"

## Step 1: Copy files

```bash
mkdir -p ~/.claude/skills/auto-docs
mkdir -p ~/.claude/hooks
mkdir -p ~/.claude/workflows

# Determine this repo's root (the directory containing this file)
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

cp "$REPO_DIR/skill/SKILL.md" ~/.claude/skills/auto-docs/SKILL.md
cp "$REPO_DIR/hooks/auto-docs-stop.sh" ~/.claude/hooks/
cp "$REPO_DIR/hooks/auto-docs-prepare-commit-msg.sh" ~/.claude/hooks/
chmod +x ~/.claude/hooks/auto-docs-stop.sh
chmod +x ~/.claude/hooks/auto-docs-prepare-commit-msg.sh
cp "$REPO_DIR/workflow/auto-docs.js" ~/.claude/workflows/
```

## Step 2: Register Stop hook in ~/.claude/settings.json

Check if already present:

```bash
jq '.hooks.Stop[] | select(.hooks[].command | contains("auto-docs-stop"))' ~/.claude/settings.json 2>/dev/null || echo "NOT PRESENT"
```

If NOT PRESENT, add it:

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak.auto-docs
jq '.hooks.Stop += [{"matcher": "*", "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/auto-docs-stop.sh", "async": false}]}]' \
  ~/.claude/settings.json > /tmp/settings-new.json && mv /tmp/settings-new.json ~/.claude/settings.json
```

Verify:

```bash
jq '.hooks.Stop[-1].hooks[0].command' ~/.claude/settings.json
# expect: "$HOME/.claude/hooks/auto-docs-stop.sh"
```

## Step 3: Global git hook template (commit gate)

```bash
mkdir -p ~/.git-templates/hooks
cp ~/.claude/hooks/auto-docs-prepare-commit-msg.sh ~/.git-templates/hooks/prepare-commit-msg
chmod +x ~/.git-templates/hooks/prepare-commit-msg
git config --global init.templateDir ~/.git-templates
```

Verify:

```bash
git config --global init.templateDir
# expect: /Users/<you>/.git-templates
```

## Step 4: Update ~/.claude/CLAUDE.md

Check if already present:

```bash
grep -q '# auto-docs' ~/.claude/CLAUDE.md 2>/dev/null && echo "PRESENT" || echo "NOT PRESENT"
```

If NOT PRESENT, append:

```bash
cat >> ~/.claude/CLAUDE.md << 'EOF'

# auto-docs
- **auto-docs** (`~/.claude/skills/auto-docs/SKILL.md`) - maintain CHANGELOG.md, DECISIONS.md, ARCHITECTURE.md, USAGE.md, and WORKLOG.md in `docs/` for every git project
- Active by default. Disable per-project: create `.claude/no-docs`. Re-enable: delete it.
- Triggered automatically: Stop hook (per-turn when work detected + user confirms), commit gate (`prepare-commit-msg`), after significant design/architecture discussions.
- When Stop hook emits `auto_docs_trigger: true` in context, invoke the Skill tool with `skill: "auto-docs"` and ask the user: "Document this work?" — if yes, run the `auto-docs-write` workflow via the Workflow tool.
- Also invoke the Skill tool with `skill: "auto-docs"` before committing or after significant design/architecture discussions.
EOF
```

If PRESENT: update the existing block to match the content above (replace old block, keep rest of file intact).

## Step 5: Verify install

```bash
echo "=== Skill ===" && ls -la ~/.claude/skills/auto-docs/SKILL.md
echo "=== Hooks ===" && ls -la ~/.claude/hooks/auto-docs-*.sh
echo "=== Workflow ===" && ls -la ~/.claude/workflows/auto-docs.js
echo "=== Stop hook in settings ===" && jq '.hooks.Stop | map(select(.hooks[].command | contains("auto-docs"))) | length' ~/.claude/settings.json
echo "=== Git template ===" && git config --global init.templateDir
echo "=== CLAUDE.md ===" && grep -A3 '# auto-docs' ~/.claude/CLAUDE.md
```

Expected: all files present, Stop hook count = 1, git template set, CLAUDE.md has auto-docs section.

## Step 6: Report to user

Tell the user:
- Install complete
- Restart Claude Code for Stop hook + skill to take effect
- For MR description updates: set `GITLAB_TOKEN` env var (GitLab personal access token, scope: `api`)
- For existing git repos (cloned before this install): run `cp ~/.claude/hooks/auto-docs-prepare-commit-msg.sh .git/hooks/prepare-commit-msg && chmod +x .git/hooks/prepare-commit-msg` once in each repo
- New git clones/inits get the commit hook automatically

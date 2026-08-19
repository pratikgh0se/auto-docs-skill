# auto-docs skill

Auto-Docs v2 keeps project documentation current without pretending that a Git
hook can make an LLM decision. It is a source bundle: installation into global
Claude settings and Git templates is a separate, explicit action.

## What it does

- **Stop hook:** detects tracked, staged, or untracked Git work once per
  repository/session. It emits context only; Claude asks whether to document
  and invokes `auto-docs-write` only after the user agrees.
- **Pre-commit hook:** adds deterministic staged-file information to
  `docs/CHANGELOG.md` and stages it in the same commit. It has no network path.
- **Post-commit hook:** optionally replaces its bounded AI Review Context block
  in an open GitLab MR. It requires `GITLAB_TOKEN` and an allowlisted host in
  `AUTO_DOCS_GITLAB_HOSTS` (default: `gitlab.com`).
- **Dynamic workflow:** bootstraps ignored `docs/WORKLOG.md`, updates only
  applicable tracked docs, and advances a committed idempotency cursor after
  writers succeed.
- **Feature summaries:** after independently verifying an MR closure and user
  confirmation, the explicit `auto-docs-feature-complete.sh` command appends a
  single idempotent summary.

All project-side components honor `.claude/no-docs`.

## Install

Use the bundled installer from a known checkout. `--repo-dir` is mandatory;
this prevents path guessing. Always inspect a dry run first:

```bash
cd /absolute/path/to/auto-docs-skill
./install.sh --dry-run --repo-dir "$PWD"
./install.sh --apply --repo-dir "$PWD"
```

By default the installer reuses the configured global Git template directory,
or uses `~/.git-templates`. Supply an explicit absolute template path when
needed:

```bash
./install.sh --dry-run --repo-dir "$PWD" \
  --git-template-dir "$HOME/.git-templates"
```

The installer copies the skill, workflow, and all Auto-Docs hook commands into
`~/.claude`; it uses `jq` to merge exactly one Stop-hook registration while
preserving unrelated settings. It installs v2 `pre-commit` and `post-commit`
template hooks plus a non-mutating `prepare-commit-msg` compatibility hook, and
configures `git init.templateDir`. Replacing an older mutating Auto-Docs
`prepare-commit-msg` hook is required: that late hook can otherwise stage a
second CHANGELOG edit after Git has captured the commit tree.

New repositories initialized after installation receive the template hooks. In
an existing repository, inspect any existing hooks first and deliberately merge
them if needed before installing the three v2 hook paths. In particular, replace
the old Auto-Docs `prepare-commit-msg` hook with the shipped non-mutating
compatibility hook so commits do not leave a CHANGELOG edit staged:

```bash
for hook in pre-commit post-commit prepare-commit-msg; do
  if [ -e ".git/hooks/$hook" ]; then
    echo "Refusing to overwrite existing .git/hooks/$hook; merge it deliberately." >&2
    exit 1
  fi
done
cp ~/.claude/hooks/auto-docs-pre-commit.sh .git/hooks/pre-commit
cp ~/.claude/hooks/auto-docs-post-commit.sh .git/hooks/post-commit
cp ~/.claude/hooks/auto-docs-prepare-commit-msg.sh .git/hooks/prepare-commit-msg
chmod +x .git/hooks/pre-commit .git/hooks/post-commit .git/hooks/prepare-commit-msg
```

## Workflow and feature-summary use

After the Stop hook reports work, ask the user `Document this work?`. With a
confirmed summary, invoke `auto-docs-write` explicitly with:

```json
{
  "workingDir": "/absolute/project/path",
  "sessionSummary": "User-confirmed summary of the work"
}
```

For a significant decision, add complete confirmed decision metadata as
documented in [skill/SKILL.md](skill/SKILL.md). The workflow does not prompt
users itself and never infers decisions.

Git cannot prove an MR was closed. Verify closure through the configured GitLab
tool/API, ask the user to confirm a title and summary, then run:

```bash
bash ~/.claude/hooks/auto-docs-feature-complete.sh \
  --id 'https://gitlab.com/group/project/-/merge_requests/42' \
  --title 'Reliable auto-docs' \
  --summary 'Made documentation updates deterministic and safe.'
```

## Disable

```bash
touch .claude/no-docs # disable in this project
rm .claude/no-docs    # re-enable
```

## Rollback

When the installer replaces an existing Claude settings file, template hook, or
global Git configuration, it saves the original in a timestamped directory
under `~/.claude/auto-docs-backups/` and prints an executable rollback command.
The transaction manifest records both replaced and newly-created paths, so run
the printed `rollback.sh` to restore originals and remove clean-install files.
Run the dry run again afterwards to verify the rollback.

## Files

```
skill/SKILL.md                          Claude Code skill instructions
hooks/auto-docs-stop.sh                 Stop work detector
hooks/auto-docs-pre-commit.sh           Deterministic CHANGELOG hook
hooks/auto-docs-post-commit.sh          Optional bounded GitLab MR updater
hooks/auto-docs-prepare-commit-msg.sh   Silent legacy-hook neutralizer
hooks/auto-docs-feature-complete.sh     Confirmed feature-summary command
workflow/auto-docs.js                   Dynamic documentation workflow
install.sh                              Explicit dry-run/apply installer
```

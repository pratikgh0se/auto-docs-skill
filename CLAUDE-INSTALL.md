---
instruction: auto-docs v2 installation
for: Claude Code
---

# Auto-Docs v2 installation

The versioned source bundle is installed only by an explicit command. Inspect
the planned targets first; the dry run makes no changes.

```bash
cd /absolute/path/to/auto-docs-skill
./install.sh --dry-run --repo-dir "$PWD"
```

When the reported targets are correct, explicitly apply the same source bundle:

```bash
./install.sh --apply --repo-dir "$PWD"
```

`--repo-dir` is required so the installer never guesses a checkout. To use a
specific Git template directory instead of the existing global
`init.templateDir` (or `~/.git-templates` when unset), pass an absolute path:

```bash
./install.sh --dry-run --repo-dir "$PWD" \
  --git-template-dir "$HOME/.git-templates"
```

## What installation changes

- Copies `skill/SKILL.md` to `~/.claude/skills/auto-docs/SKILL.md`.
- Copies the workflow and all distributable Auto-Docs hook commands to
  `~/.claude/workflows` and `~/.claude/hooks`.
- Safely merges one Stop-hook registration into `~/.claude/settings.json` with
  `jq`; it preserves unrelated JSON and does not duplicate the registration.
- Installs `pre-commit`, `post-commit`, and the non-mutating
  `prepare-commit-msg` compatibility hook in the configured Git template, then
  sets `git config --global init.templateDir` to that template. New repositories
  initialized after installation receive all three hook paths.

The active commit hooks have distinct responsibilities:

- `pre-commit` deterministically adds and stages a pending-change entry in
  `docs/CHANGELOG.md`; it makes no network requests.
- `post-commit` is optional GitLab integration. It updates only its bounded MR
  context block and only with `GITLAB_TOKEN` plus an allowlisted
  `AUTO_DOCS_GITLAB_HOSTS` host (default `gitlab.com`).

`auto-docs-prepare-commit-msg.sh` is a silent, non-mutating compatibility hook.
The installer puts it in the template specifically to replace older Auto-Docs
versions that updated and staged CHANGELOG too late, after Git had captured the
commit tree.

For repositories created before the template was configured, install the v2
hooks only after reviewing any existing hook content. Git supports one hook per
event, so merge a pre-existing custom hook deliberately rather than overwriting
it blindly. Replace an old Auto-Docs `prepare-commit-msg` with the shipped
non-mutating compatibility hook; leaving the old mutating version active can
leave `docs/CHANGELOG.md` staged after every commit:

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

## Using the workflow

The Stop hook only detects Git work and returns context. It never writes docs
or asks a question itself. After receiving its context, ask the user
`Document this work?`; run `auto-docs-write` only after a yes. Invoke the
workflow explicitly with an absolute project directory and a user-confirmed
summary. Supply decision metadata only after the user confirms that decision
should be recorded.

Feature summaries are also explicit: verify that the merge request is closed
through the configured GitLab integration, ask the user to confirm a title and
summary, then run `auto-docs-feature-complete.sh --id ... --title ... --summary
...`. The installed skill documents the full argument contract.

Disable all project-side behavior with `.claude/no-docs` in that project.

## Verify and roll back

```bash
ls -l ~/.claude/skills/auto-docs/SKILL.md ~/.claude/workflows/auto-docs.js
ls -l ~/.claude/hooks/auto-docs-*.sh
jq '[.hooks.Stop[].hooks[] | select(.command | contains("auto-docs-stop.sh"))] | length' \
  ~/.claude/settings.json
git config --global --get init.templateDir
```

Before replacing an existing settings file, template hook, or global Git config,
the installer creates a timestamped directory under
`~/.claude/auto-docs-backups/` and prints an executable rollback command. Its
manifest records both replaced and newly-created paths, so run the printed
`rollback.sh` to restore originals and remove clean-install files. Re-run
`./install.sh --dry-run --repo-dir "$PWD"` afterwards to confirm the resulting
state.

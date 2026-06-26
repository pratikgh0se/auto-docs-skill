export const meta = {
  name: 'auto-docs-write',
  description: 'Fan out haiku agents to update project docs after work session',
  phases: [
    { title: 'Detect', detail: 'Determine which docs need updating' },
    { title: 'Write', detail: 'Parallel haiku agents write each doc' },
  ],
}

const HAIKU = 'global.anthropic.claude-haiku-4-5-20251001-v1:0'

const CAVEMAN = 'CAVEMAN MODE ULTRA. Max compression. No articles/filler/pleasantries. Fragments OK. Technical terms exact. Code blocks unchanged.'

const workingDir = args && args.workingDir ? args.workingDir : '.'
const sessionSummary = args && args.sessionSummary ? args.sessionSummary : ''

phase('Detect')

// Get date via shell — no new Date() allowed in workflows
const dateResult = await agent(
  `Run: date +%Y-%m-%d
Return only the date string, nothing else.`,
  {
    label: 'detect:date',
    phase: 'Detect',
    model: HAIKU,
    schema: {
      type: 'object',
      properties: { date: { type: 'string' } },
      required: ['date'],
    },
  }
)

const TODAY = dateResult && dateResult.date ? dateResult.date : '(unknown)'

const context = await agent(
  `${CAVEMAN}

Detect which docs need updating. Working dir: ${workingDir}

Run these commands (use rtk prefix for git):
1. rtk git diff --name-only HEAD 2>/dev/null | head -30
2. rtk git diff --cached --name-only 2>/dev/null | head -30
3. rtk git log --oneline -10 2>/dev/null
4. rtk git branch --show-current 2>/dev/null
5. ls ${workingDir}/docs/ 2>/dev/null

Return JSON with exactly these fields:
{
  "filesChanged": ["list of changed files"],
  "stagedFiles": ["list of staged files"],
  "recentCommits": ["list of recent commit one-liners"],
  "currentBranch": "branch name",
  "existingDocs": ["list of files in docs/ dir"]
}`,
  {
    label: 'detect:context',
    phase: 'Detect',
    model: HAIKU,
    schema: {
      type: 'object',
      properties: {
        filesChanged: { type: 'array', items: { type: 'string' } },
        stagedFiles: { type: 'array', items: { type: 'string' } },
        recentCommits: { type: 'array', items: { type: 'string' } },
        currentBranch: { type: 'string' },
        existingDocs: { type: 'array', items: { type: 'string' } },
      },
      required: ['filesChanged', 'stagedFiles', 'recentCommits', 'currentBranch', 'existingDocs'],
    },
  }
)

if (!context) {
  log('Detection failed — skipping doc updates')
  return { docsUpdated: 0 }
}

const allChanged = context.filesChanged.concat(context.stagedFiles)
const hasCommits = context.recentCommits.length > 0

const hasStructuralChange = allChanged.some(f =>
  f.match(/\.(go|py|ts|tsx|js|jsx|java|rs|rb|cs|cpp|c|h|kt|swift)$/) && !f.match(/test|spec|mock/i)
)

const hasInterfaceChange = allChanged.some(f =>
  f.match(/(api|route|endpoint|cli|cmd|handler|controller|service|grpc|proto)/i)
)

const hasDecisionsDoc = context.existingDocs.includes('DECISIONS.md')

log(`Branch: ${context.currentBranch} | Files: ${allChanged.length} | Commits: ${context.recentCommits.length} | Structural: ${hasStructuralChange} | Interface: ${hasInterfaceChange}`)

phase('Write')

const agentTasks = []

// WORKLOG.md — always (session entry)
agentTasks.push(() => agent(
  `${CAVEMAN}

Task: Append session entry to ${workingDir}/docs/WORKLOG.md

Date: ${TODAY}
Branch: ${context.currentBranch}
Files changed: ${allChanged.join(', ') || 'none'}
Recent commits: ${context.recentCommits.join(' | ') || 'none'}
Session summary: ${sessionSummary || 'not provided'}

Steps:
1. Read ${workingDir}/docs/WORKLOG.md (ok if missing)
2. Prepend new session entry at TOP of file (before existing content):

## Session: ${TODAY}

**What I worked on:** [infer from commits and files — 1-2 sentences]
**Challenges:** [infer from commit messages, or "none noted" if unclear]
**Outcome:** [current state based on branch/commits]

3. Write full updated content to ${workingDir}/docs/WORKLOG.md
4. DO NOT git add or commit this file — it is gitignored`,
  { label: 'write:worklog', phase: 'Write', model: HAIKU }
))

// CHANGELOG.md — if commits exist
if (hasCommits) {
  agentTasks.push(() => agent(
    `${CAVEMAN}

Task: Update ${workingDir}/docs/CHANGELOG.md

Recent commits:
${context.recentCommits.join('\n')}

Files changed: ${allChanged.join(', ')}

Steps:
1. Read ${workingDir}/docs/CHANGELOG.md
2. If missing, create with keep-a-changelog header:
   # Changelog
   ...
   ## [Unreleased]
3. Add entries under ## [Unreleased] — one line per logical change, include WHY for non-obvious choices
4. Categorize as Added/Changed/Fixed/Removed based on commit type
5. Write updated file to ${workingDir}/docs/CHANGELOG.md
6. Run: rtk git add ${workingDir}/docs/CHANGELOG.md`,
    { label: 'write:changelog', phase: 'Write', model: HAIKU }
  ))
}

// ARCHITECTURE.md — if structural change
if (hasStructuralChange) {
  agentTasks.push(() => agent(
    `${CAVEMAN}

Task: Update ${workingDir}/docs/ARCHITECTURE.md for structural changes

Files changed: ${allChanged.filter(f => f.match(/\.(go|py|ts|tsx|js|jsx|java|rs|rb|cs|cpp|c|h|kt|swift)$/)).join(', ')}

Steps:
1. Read ${workingDir}/docs/ARCHITECTURE.md
2. If missing: run "rtk git ls-files | head -60" in ${workingDir} to understand structure, then write full doc
3. If exists: update ONLY the section(s) affected by changed files
   Sections: What This Is, System Overview, Key Design Principles, Data Model, External Dependencies, Known Constraints & Tradeoffs
4. Write updated file to ${workingDir}/docs/ARCHITECTURE.md`,
    { label: 'write:architecture', phase: 'Write', model: HAIKU }
  ))
}

// USAGE.md — if interface change
if (hasInterfaceChange) {
  agentTasks.push(() => agent(
    `${CAVEMAN}

Task: Update ${workingDir}/docs/USAGE.md for interface changes

Interface files changed: ${allChanged.filter(f => f.match(/(api|route|endpoint|cli|cmd|handler|controller|service|grpc|proto)/i)).join(', ')}

Steps:
1. Read ${workingDir}/docs/USAGE.md
2. If missing: scan project for CLI/API surface area, write from scratch
3. If exists: update ONLY the section(s) touched by changed files
   Sections: Prerequisites, Installation & Setup, Running Locally, Configuration, API Reference, CLI Reference, Deployment, Troubleshooting
4. Write updated file to ${workingDir}/docs/USAGE.md`,
    { label: 'write:usage', phase: 'Write', model: HAIKU }
  ))
}

// Fan out all agents in parallel
const results = await parallel(agentTasks)
const succeeded = results.filter(Boolean).length

log(`Done: ${succeeded}/${agentTasks.length} doc agents succeeded`)

return { docsUpdated: succeeded, date: TODAY, branch: context.currentBranch }

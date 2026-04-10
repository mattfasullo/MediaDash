---
name: pull
description: >-
  Fetches from git origin and pulls when the current branch is behind its
  upstream; reports clearly when already up to date. Use when the user runs
  /pull, asks to pull latest changes, sync with origin, or update from remote.
---

# Pull (sync with origin)

## When this applies

Use when syncing the **current branch** with **origin** (not a specific PR branch workflow unless the user asked for that branch).

## Workflow

1. **Repository root**: `cd` to `git rev-parse --show-toplevel` (or confirm cwd is inside the repo). If not a git repository, say so and stop.

2. **Fetch**: Run `git fetch origin`. If it fails, report the error and stop.

3. **Upstream**: Resolve what “latest” means for the current branch:
   - If `git rev-parse --abbrev-ref @{u} 2>/dev/null` succeeds, use that as the upstream ref (e.g. `origin/main`).
   - Otherwise use `origin/<current-branch>` where current branch is `git branch --show-current`. If that ref is missing after fetch, say there is no matching remote branch and stop.

4. **Behind count**: After fetch, compute how many commits the local branch is behind upstream, e.g. `git rev-list --count HEAD..@{u}` when upstream is set, or `git rev-list --count HEAD..origin/<branch>` otherwise.

5. **If behind (`count` > 0)**:
   - Run `git pull` (preferred when upstream is configured) or `git pull origin <branch>` so local matches remote.
   - Summarize: pulled N commit(s), current short SHA or `git status -sb` line.

6. **If not behind (`count` == 0)**:
   - Do **not** run `git pull`.
   - Tell the user clearly they are **already up to date** with the upstream (name the local branch and the remote ref, e.g. `main` and `origin/main`).

7. **Ahead and behind**: If status shows both ahead and behind, say so before pulling; `git pull` is still the default unless the user prefers rebase—only rebase if they ask.

## Output

Keep the final message short: either “up to date with …” or “pulled N commit(s); now at …” plus any notable warnings (uncommitted files, diverged history).

---
name: commit-and-push
description: Stage intentional changes, create a safe git commit, and push to origin with clear status reporting. Use when the user asks to commit, push, "save latest", or publish branch updates.
---

# Commit And Push

## When this applies

Use this workflow when the user asks to commit current changes and push to `origin`.

## Workflow

1. **Inspect first**:
   - `git status --short --branch`
   - `git diff --staged && git diff`
   - `git log --oneline -8`

2. **Protect staging scope**:
   - Do not stage everything blindly.
   - Exclude obvious local/runtime artifacts (for this repo: `.claude/worktrees/` unless explicitly requested).
   - Stage only intentional files with `git add <path>...`.

3. **Create a precise commit message**:
   - Match repository style from recent commits.
   - Keep it short and purpose-focused.
   - Use a heredoc for reliability:
     ```bash
     git commit -m "$(cat <<'EOF'
     Commit message here
     EOF
     )"
     ```

4. **Push safely**:
   - Run `git push origin <current-branch>` (or `git push` if upstream already configured and explicit target is not required).
   - If push fails with GitHub credential prompt errors, instruct the user to run:
     - `brew install gh`
     - `gh auth login`
     - `gh auth setup-git`

5. **Report outcome**:
   - Commit hash + message.
   - Push destination and result.
   - Any skipped files and why.

## Output format

Keep the response concise:
- what was committed
- where it was pushed
- any follow-up needed

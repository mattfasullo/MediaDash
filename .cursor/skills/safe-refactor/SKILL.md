---
name: safe-refactor
description: Refactors code with a short plan first, preserves behavior unless the user asks otherwise, keeps edits local and reversible, updates or adds tests to lock behavior, and surfaces risky changes with a safer incremental path. Use when the user asks for a refactor, restructuring, cleanup, or code improvement without changing product behavior.
---

# Safe Refactor

## When this applies

Use this skill whenever the user requests a **refactor** (restructuring, cleanup, renaming, extraction, deduplication, readability pass, etc.), unless they clearly want a behavior change or new feature.

## Workflow

### 1. Start with a short plan

Before editing, output a **brief plan** (a few bullets or short paragraphs):

- **What** will change (files, types, functions, or regions).
- **Why** (goal: clarity, duplication removal, testability, etc.).
- **What stays the same** (intended behavior and public contracts).

Keep the plan proportional to the size of the refactor.

### 2. Preserve behavior

- Treat current behavior as **correct unless the user says otherwise**.
- Do **not** “fix” unrelated bugs, change UX, or alter APIs unless the user explicitly asked.
- If behavior must change to complete the refactor, **call it out** and get alignment (or treat it as out of scope).

### 3. Keep changes local and reversible

- Prefer **small, focused diffs** in the **smallest set of files** that achieves the goal.
- Avoid drive-by edits in unrelated modules, formatting-only sweeps across the repo, or opportunistic renames outside the requested scope.
- Structure work so it can be **reverted in one or a few commits** (logical chunks).

### 4. Tests

- **Update** existing tests that would break or that should assert the same behavior more clearly.
- **Add** tests when coverage is missing for behavior the refactor could affect.
- Prefer tests that fail if behavior regresses (same inputs → same outputs / same side effects where relevant).

If the project has no test harness for the touched code, say so briefly and add the **minimal** test support only if it fits the codebase; do not invent a whole framework.

### 5. How to show code changes

When presenting edits:

- Show **only modified functions or blocks**, plus **minimal surrounding context** so the user can apply a patch (not whole files unless the change is file-small).
- Use the project’s normal citation/patch style (e.g. fenced hunks with file path and enough lines above/below to apply safely).

Avoid dumping unrelated code.

### 6. Risk assessment

If the refactor is **risky** (e.g. concurrency, timing, persistence, crypto, distributed state, subtle domain rules, or changes that touch many call sites):

- **Warn** explicitly: what could go wrong and why.
- Propose a **safer incremental approach** (steps, order, checkpoints, optional feature flags if the project uses them).
- Prefer smaller steps that each keep tests green over one large risky change.

## Out of scope

- New features or product behavior changes unless requested.
- Large-scale style or lint rewrites unless the user asked for that specifically.

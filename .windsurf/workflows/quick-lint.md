---
description: Quick syntax and style checks
description: Find potential issues in Swift code
---

# MediaDash Quick Lint

Performs basic code quality checks on Swift files.

## Usage

```bash
.windsurf/workflows/quick-lint.sh
```

## What It Checks

- TODO/FIXME markers
- Debug print statements
- Force unwraps (`!`)
- Force casts (`as!`)
- Trailing whitespace
- Large files (1000+ lines)

## Exit Codes

- **0** - Always exits 0 (warnings only)

## Notes

This is a lightweight check, not a full SwiftLint. It flags potential issues for manual review.

## Related

- Use findings to prioritize refactoring work

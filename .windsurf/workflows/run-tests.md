---
description: Run MediaDash unit tests
description: Execute the full test suite with formatted output
---

# MediaDash Test Runner

Runs the MediaDash unit test suite and displays results with color-coded output.

## Usage

```bash
.windsurf/workflows/run-tests.sh
```

## What It Does

1. Checks for xcodebuild availability
2. Runs tests for the MediaDash scheme
3. Displays pass/fail status
4. Shows test count and any failures

## Exit Codes

- **0** - All tests passed
- **1** - Tests failed or build error

## Related

- Use `check-build.sh` to verify the app builds before running tests

---
description: Verify MediaDash builds
description: Check that the Xcode project compiles without errors
---

# MediaDash Build Checker

Verifies the MediaDash app builds successfully without archiving or exporting.

## Usage

```bash
.windsurf/workflows/check-build.sh
```

## What It Does

1. Checks xcodebuild availability
2. Cleans build folder
3. Builds Debug configuration
4. Reports success/failure with warning count

## Why Use This

- Quick sanity check before committing
- Verify changes compile without full release process
- CI/CD pre-check

## Exit Codes

- **0** - Build successful
- **1** - Build failed

## Related

- `run-tests.sh` - Run unit tests after successful build
- `validate-release.sh` - Full release validation

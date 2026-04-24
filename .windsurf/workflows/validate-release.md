---
description: Validate MediaDash release readiness
description: Run pre-release checks without actually releasing
---

# MediaDash Release Validation

Validates that your MediaDash build is ready for release WITHOUT actually performing the release.

## When to Use

- Before running `./release_update.sh`
- After making significant changes
- Before creating a PR with build changes
- As a sanity check before releasing to production

## What It Checks

1. **Git Status** - Uncommitted changes, current branch, unpushed commits
2. **Required Files** - All files needed for release exist
3. **Xcode Project** - Project validity and buildability
4. **Signing Tools** - sign_update and codesign availability
5. **GitHub CLI** - gh installed and authenticated
6. **Appcast.xml** - Valid XML with Sparkle namespace
7. **Version Info** - Current version from Info.plist
8. **Unit Tests** - Runs test suite
9. **Python Validator** - Syntax check media_validator.py
10. **Release Scripts** - All scripts are executable

## Usage

Run from project root:

```bash
.windsurf/workflows/validate-release.sh
```

## Exit Codes

- **0** - Success (warnings allowed)
- **1** - Errors found, fix before releasing

## Next Steps

After validation passes:

```bash
./release_update.sh
```

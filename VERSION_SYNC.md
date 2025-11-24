# Version Synchronization Guide

## Problem
The app version needs to be kept in sync across multiple places:
- `MediaDash/Info.plist` - `CFBundleShortVersionString` and `CFBundleVersion`
- `MediaDash.xcodeproj/project.pbxproj` - `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`
- The About window reads from the bundle, which comes from the Xcode project settings

## Solution: `sync_version.sh`

Use the `sync_version.sh` script to update all version sources at once:

```bash
./sync_version.sh <version> [build_number]
```

**Examples:**
```bash
# Auto-generate build number from version (0.3.0 -> 30)
./sync_version.sh 0.3.0

# Specify both version and build number
./sync_version.sh 0.3.0 30
```

## What Gets Updated

The script updates:
1. ✅ `MediaDash/Info.plist`
   - `CFBundleShortVersionString` (marketing version)
   - `CFBundleVersion` (build number)
2. ✅ `MediaDash.xcodeproj/project.pbxproj`
   - `MARKETING_VERSION` (all build configurations)
   - `CURRENT_PROJECT_VERSION` (all build configurations)

## Release Scripts

The release scripts (`release.sh` and `release_update.sh`) automatically use `sync_version.sh`, so versions stay in sync during releases.

## Manual Updates

If you need to update the version manually:

1. **Use the sync script (recommended):**
   ```bash
   ./sync_version.sh 0.3.0 30
   ```

2. **Or use set_version.sh (also uses sync_version.sh):**
   ```bash
   ./set_version.sh 0.3.0
   ```

## Verify Version Sync

Check that everything is in sync:
```bash
# Check Info.plist
defaults read MediaDash/Info.plist CFBundleShortVersionString
defaults read MediaDash/Info.plist CFBundleVersion

# Check Xcode project
xcrun agvtool what-marketing-version
xcrun agvtool what-version

# Or check the project file directly
grep MARKETING_VERSION MediaDash.xcodeproj/project.pbxproj | head -1
grep CURRENT_PROJECT_VERSION MediaDash.xcodeproj/project.pbxproj | head -1
```

## Build Number Convention

Build numbers are auto-generated from version numbers:
- `0.2.3` → `23` (0*100 + 2*10 + 3)
- `0.3.0` → `30` (0*100 + 3*10 + 0)
- `1.0.0` → `100` (1*100 + 0*10 + 0)

You can override this by providing a build number as the second argument.


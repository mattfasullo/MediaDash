#!/bin/bash
# Sync version across all sources: Info.plist, Xcode project, and build tools
# Usage: ./sync_version.sh <version> [build_number]
# Example: ./sync_version.sh 0.3 30

set -e

if [ -z "$1" ]; then
    echo "Usage: ./sync_version.sh <version> [build_number]"
    echo "Example: ./sync_version.sh 0.3 30"
    exit 1
fi

VERSION=$1
BUILD_NUMBER=${2:-$(echo "$VERSION" | awk -F. '{printf "%d", $1*100 + $2*10 + $3}')}

echo "Syncing version to $VERSION (build $BUILD_NUMBER)..."

# 1. Update Info.plist
echo "📝 Updating Info.plist..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "MediaDash/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "MediaDash/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "MediaDash/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "MediaDash/Info.plist"

# 2. Update Xcode project using agvtool (preferred method)
echo "📝 Updating Xcode project (agvtool)..."
xcrun agvtool new-marketing-version "$VERSION" 2>/dev/null || echo "⚠️  agvtool marketing version failed, using manual update"
xcrun agvtool new-version -all "$BUILD_NUMBER" 2>/dev/null || echo "⚠️  agvtool build version failed, using manual update"

# 3. Manually update Xcode project file (fallback/ensure)
echo "📝 Updating Xcode project file directly..."
PROJECT_FILE="MediaDash.xcodeproj/project.pbxproj"

# Update MARKETING_VERSION
sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/g" "$PROJECT_FILE"

# Update CURRENT_PROJECT_VERSION
sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/g" "$PROJECT_FILE"

echo "✅ Version synced to $VERSION (build $BUILD_NUMBER)"
echo ""
echo "Updated in:"
echo "  - MediaDash/Info.plist (CFBundleShortVersionString, CFBundleVersion)"
echo "  - MediaDash.xcodeproj/project.pbxproj (MARKETING_VERSION, CURRENT_PROJECT_VERSION)"
echo ""
echo "You can verify with:"
echo "  defaults read $(pwd)/MediaDash/Info.plist CFBundleShortVersionString"
echo "  xcrun agvtool what-version"


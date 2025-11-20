#!/bin/bash
# Set version number before archiving
# Usage: ./set_version.sh 0.1.3

set -e

if [ -z "$1" ]; then
    echo "Usage: ./set_version.sh <version>"
    echo "Example: ./set_version.sh 0.1.3"
    exit 1
fi

VERSION=$1

echo "Setting version to $VERSION..."

# Update Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "MediaDash/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "MediaDash/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "MediaDash/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "MediaDash/Info.plist"

# Also try to set marketing version in project (Xcode 13+)
xcrun agvtool new-marketing-version "$VERSION" 2>/dev/null || true
xcrun agvtool new-version -all "$VERSION" 2>/dev/null || true

echo "✅ Version set to $VERSION"
echo ""
echo "Now archive in Xcode:"
echo "  Product → Archive → Distribute App → Copy App"
echo "  Save to: $(pwd)/release/"

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

# Use sync_version.sh to keep everything in sync
BUILD_NUMBER=$(echo "$VERSION" | awk -F. '{printf "%d", $1*100 + $2*10 + $3}')
./sync_version.sh "$VERSION" "$BUILD_NUMBER"

echo "✅ Version set to $VERSION (build $BUILD_NUMBER)"
echo ""
echo "Now archive in Xcode:"
echo "  Product → Archive → Distribute App → Copy App"
echo "  Save to: $(pwd)/release/"

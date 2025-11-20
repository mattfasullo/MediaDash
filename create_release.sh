#!/bin/bash
# MediaDash Release Helper Script
# This script helps you create and sign releases for Sparkle auto-updates

set -e

echo "======================================"
echo "MediaDash Release Helper"
echo "======================================"
echo ""

# Check if version is provided
if [ -z "$1" ]; then
    echo "Usage: ./create_release.sh <version>"
    echo "Example: ./create_release.sh 0.1.3"
    exit 1
fi

VERSION=$1
APP_NAME="MediaDash"
ZIP_NAME="${APP_NAME}.zip"
RELEASE_DIR="release"

echo "Creating release for version $VERSION"
echo ""

# Step 1: Build instructions
echo "📦 Step 1: Build and Archive"
echo "1. Open MediaDash.xcodeproj in Xcode"
echo "2. Set version to $VERSION in General → Identity"
echo "3. Product → Archive"
echo "4. Export as Mac App (NOT for App Store)"
echo "5. Save the exported app to: $(pwd)/$RELEASE_DIR/"
echo ""
read -p "Press Enter when you've exported the app to $RELEASE_DIR/ ..."

# Check if app exists
if [ ! -d "$RELEASE_DIR/${APP_NAME}.app" ]; then
    echo "❌ Error: $RELEASE_DIR/${APP_NAME}.app not found"
    exit 1
fi

# Step 2: Create ZIP
echo ""
echo "📦 Step 2: Creating ZIP archive..."
cd "$RELEASE_DIR"
ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "$ZIP_NAME"
cd ..

# Step 3: Sign the update
echo ""
echo "🔐 Step 3: Signing update..."
SIGNATURE=$(./sign_update "$RELEASE_DIR/$ZIP_NAME")
echo "Signature: $SIGNATURE"

# Step 4: Get file size
FILE_SIZE=$(stat -f%z "$RELEASE_DIR/$ZIP_NAME")
echo "File size: $FILE_SIZE bytes"

# Step 5: Update appcast.xml
echo ""
echo "📝 Step 4: Update appcast.xml with these values:"
echo ""
echo "  url: https://github.com/mattfasullo/MediaDash/releases/download/v$VERSION/MediaDash.zip"
echo "  sparkle:version: $VERSION"
echo "  sparkle:shortVersionString: $VERSION"
echo "  sparkle:edSignature: $SIGNATURE"
echo "  length: $FILE_SIZE"
echo ""
echo "Then commit and push appcast.xml to GitHub"
echo ""

# Step 6: Create GitHub release instructions
echo "📤 Step 5: Create GitHub Release"
echo ""
echo "Run these commands:"
echo ""
echo "  git add appcast.xml"
echo "  git commit -m 'Release v$VERSION'"
echo "  git push"
echo "  gh release create v$VERSION $RELEASE_DIR/$ZIP_NAME --title 'MediaDash v$VERSION' --notes 'See appcast.xml for details'"
echo ""
echo "Or manually:"
echo "1. Go to https://github.com/mattfasullo/MediaDash/releases/new"
echo "2. Tag: v$VERSION"
echo "3. Title: MediaDash v$VERSION"
echo "4. Upload: $RELEASE_DIR/$ZIP_NAME"
echo "5. Publish release"
echo ""
echo "✅ Done! The ZIP is ready at: $RELEASE_DIR/$ZIP_NAME"

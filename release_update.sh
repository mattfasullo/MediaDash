#!/bin/bash
# MediaDash One-Click Release Script
# Builds, signs, and publishes updates automatically

set -e

echo "======================================"
echo "   MediaDash Auto-Release Tool"
echo "======================================"
echo ""

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration
APP_NAME="MediaDash"
SCHEME="MediaDash"
PROJECT="MediaDash.xcodeproj"
RELEASE_DIR="release"
APPCAST_FILE="appcast.xml"

# Step 1: Get version number
echo -e "${BLUE}📋 Step 1: Version Information${NC}"
echo ""
read -p "Enter new version number (e.g., 0.2.3): " VERSION
if [ -z "$VERSION" ]; then
    echo -e "${RED}❌ Version required${NC}"
    exit 1
fi

# Get build number (numeric, for Sparkle version comparison)
read -p "Enter build number (numeric, e.g., 23 for 0.2.3): " BUILD_NUMBER
if [ -z "$BUILD_NUMBER" ]; then
    # Auto-generate build number from version if not provided
    # Convert 0.2.3 -> 23, 0.3.0 -> 30, etc.
    BUILD_NUMBER=$(echo "$VERSION" | awk -F. '{printf "%d", $1*100 + $2*10 + $3}')
    echo -e "${YELLOW}⚠️  Auto-generated build number: $BUILD_NUMBER${NC}"
fi

# Step 2: Get release notes
echo ""
echo -e "${BLUE}📝 Step 2: Release Notes${NC}"
echo "Enter release notes (press Ctrl+D when done):"
echo "Example:"
echo "  - Added new video converter feature"
echo "  - Fixed session search bug"
echo "  - Performance improvements"
echo ""
RELEASE_NOTES=$(cat)

# Step 3: Build the app
echo ""
echo -e "${BLUE}🔨 Step 3: Building App${NC}"
echo "This may take a few minutes..."

# Clean build folder
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

# Update version in project
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PROJECT/../MediaDash/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PROJECT/../MediaDash/Info.plist" 2>/dev/null || true

# Build and archive
echo "Building..."
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$RELEASE_DIR/$APP_NAME.xcarchive" \
    archive \
    CODE_SIGN_STYLE=Automatic \
    > "$RELEASE_DIR/build.log" 2>&1

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Build failed. Check $RELEASE_DIR/build.log for details${NC}"
    exit 1
fi

# Export archive
echo "Exporting..."
cat > "$RELEASE_DIR/export_options.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>mac-application</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>thinning</key>
    <string>&lt;none&gt;</string>
    <key>teamID</key>
    <string>9XPBY59H89</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath "$RELEASE_DIR/$APP_NAME.xcarchive" \
    -exportPath "$RELEASE_DIR" \
    -exportOptionsPlist "$RELEASE_DIR/export_options.plist" \
    >> "$RELEASE_DIR/build.log" 2>&1

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Export failed. Check $RELEASE_DIR/build.log for details${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Build successful${NC}"

# Step 4: Create ZIP
echo ""
echo -e "${BLUE}📦 Step 4: Creating ZIP Archive${NC}"
cd "$RELEASE_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME.zip"
cd ..
echo -e "${GREEN}✅ ZIP created${NC}"

# Step 5: Sign the update
echo ""
echo -e "${BLUE}🔐 Step 5: Signing Update${NC}"
SIGNATURE=$(./sign_update "$RELEASE_DIR/$APP_NAME.zip")
echo "Signature: $SIGNATURE"
echo -e "${GREEN}✅ Update signed${NC}"

# Step 6: Get file size
FILE_SIZE=$(stat -f%z "$RELEASE_DIR/$APP_NAME.zip")
echo "File size: $FILE_SIZE bytes"

# Step 7: Update appcast.xml
echo ""
echo -e "${BLUE}📝 Step 6: Updating Appcast${NC}"

# Format release notes for XML
NOTES_HTML="<h2>What's New in $VERSION</h2><ul>"
while IFS= read -r line; do
    if [ ! -z "$line" ]; then
        # Remove leading "- " if present
        clean_line=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//')
        NOTES_HTML="${NOTES_HTML}<li>${clean_line}</li>"
    fi
done <<< "$RELEASE_NOTES"
NOTES_HTML="${NOTES_HTML}</ul>"

# Get current date in RFC 2822 format
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

# Create new item XML
NEW_ITEM="        <item>
            <title>Version $VERSION</title>
            <description><![CDATA[
                $NOTES_HTML
            ]]></description>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <enclosure
                url=\"https://github.com/mattfasullo/MediaDash/releases/download/v$VERSION/$APP_NAME.zip\"
                sparkle:version=\"$BUILD_NUMBER\"
                sparkle:shortVersionString=\"$VERSION\"
                sparkle:edSignature=\"$SIGNATURE\"
                length=\"$FILE_SIZE\"
                type=\"application/octet-stream\"
            />
        </item>"

# Backup current appcast
cp "$APPCAST_FILE" "$APPCAST_FILE.backup"

# Insert new item after <language>en</language>
awk -v item="$NEW_ITEM" '
/<language>en<\/language>/ {
    print;
    print item;
    next;
}
/<item>/ { skip=1 }
/<\/item>/ { skip=0; next }
!skip
' "$APPCAST_FILE.backup" > "$APPCAST_FILE"

echo -e "${GREEN}✅ Appcast updated${NC}"

# Step 8: Commit and push
echo ""
echo -e "${BLUE}🚀 Step 7: Publishing to GitHub${NC}"

# Commit appcast
git add "$APPCAST_FILE"
git add "MediaDash/Info.plist" 2>/dev/null || true
git commit -m "Release v$VERSION"
git push

echo -e "${GREEN}✅ Appcast pushed to GitHub${NC}"

# Step 9: Create GitHub release
echo ""
echo -e "${BLUE}📤 Step 8: Creating GitHub Release${NC}"

# Format release notes for GitHub
GITHUB_NOTES=$(echo "$RELEASE_NOTES" | sed 's/^[[:space:]]*-[[:space:]]*/- /')

gh release create "v$VERSION" \
    "$RELEASE_DIR/$APP_NAME.zip" \
    --title "$APP_NAME v$VERSION" \
    --notes "$GITHUB_NOTES"

echo -e "${GREEN}✅ GitHub release created${NC}"

# Step 10: Verify appcast is accessible
echo ""
echo -e "${BLUE}🔍 Step 9: Verifying Appcast${NC}"
echo "Waiting for GitHub CDN to update (this may take a moment)..."

MAX_RETRIES=12
RETRY_COUNT=0
VERIFIED=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    sleep 5
    RETRY_COUNT=$((RETRY_COUNT + 1))
    
    echo -n "  Attempt $RETRY_COUNT/$MAX_RETRIES: Checking appcast... "
    
    # Fetch appcast and check if signature matches
    FETCHED_SIG=$(curl -s "https://raw.githubusercontent.com/mattfasullo/MediaDash/main/appcast.xml?t=$(date +%s)" | grep -o 'sparkle:edSignature="[^"]*"' | head -1 | cut -d'"' -f2)
    
    if [ "$FETCHED_SIG" = "$SIGNATURE" ]; then
        echo -e "${GREEN}✅ Verified!${NC}"
        VERIFIED=true
        break
    else
        if [ -z "$FETCHED_SIG" ]; then
            echo -e "${YELLOW}⏳ Still waiting for CDN...${NC}"
        else
            echo -e "${YELLOW}⏳ CDN cache not updated yet (got different signature)${NC}"
        fi
    fi
done

if [ "$VERIFIED" = false ]; then
    echo -e "${YELLOW}⚠️  Warning: Could not verify appcast signature after $MAX_RETRIES attempts${NC}"
    echo -e "${YELLOW}   The appcast may still be cached. It should update within 5-10 minutes.${NC}"
    echo -e "${YELLOW}   Users can manually check for updates (Cmd+U) once the cache clears.${NC}"
else
    echo -e "${GREEN}✅ Appcast verified and ready!${NC}"
fi

# Cleanup
echo ""
echo -e "${BLUE}🧹 Cleaning up${NC}"
rm -f "$APPCAST_FILE.backup"
echo -e "${GREEN}✅ Cleanup complete${NC}"

# Summary
echo ""
echo "======================================"
echo -e "${GREEN}🎉 Release Complete!${NC}"
echo "======================================"
echo ""
echo "Version: $VERSION"
echo "Release URL: https://github.com/mattfasullo/MediaDash/releases/tag/v$VERSION"
echo ""
echo "Your coworker will receive this update automatically within 24 hours,"
echo "or they can check manually with CMD+U (Check for Updates)"
echo ""
echo -e "${YELLOW}Note: Build artifacts saved in $RELEASE_DIR/${NC}"

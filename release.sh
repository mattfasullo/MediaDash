#!/bin/bash
# MediaDash Quick Release Script
# Usage: ./release.sh <version> "<release notes>"
# Example: ./release.sh 0.1.3 "Bug fixes and improvements"

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Check arguments
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: ./release.sh <version> \"<release notes>\""
    echo "Example: ./release.sh 0.1.3 \"Bug fixes and improvements\""
    exit 1
fi

VERSION=$1
RELEASE_NOTES=$2

APP_NAME="MediaDash"
SCHEME="MediaDash"
PROJECT="MediaDash.xcodeproj"
RELEASE_DIR="release"
APPCAST_FILE="appcast.xml"

echo "======================================"
echo "   MediaDash Release v$VERSION"
echo "======================================"
echo ""

# Clean build
echo -e "${BLUE}🧹 Cleaning...${NC}"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

# Update version
echo -e "${BLUE}📝 Updating version...${NC}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "MediaDash/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "MediaDash/Info.plist" 2>/dev/null || true

# Build
echo -e "${BLUE}🔨 Building...${NC}"
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$RELEASE_DIR/$APP_NAME.xcarchive" \
    archive \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Automatic \
    > "$RELEASE_DIR/build.log" 2>&1

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Build failed. Check $RELEASE_DIR/build.log${NC}"
    exit 1
fi

# Export
echo -e "${BLUE}📦 Exporting...${NC}"
cat > "$RELEASE_DIR/export_options.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>mac-application</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath "$RELEASE_DIR/$APP_NAME.xcarchive" \
    -exportPath "$RELEASE_DIR" \
    -exportOptionsPlist "$RELEASE_DIR/export_options.plist" \
    >> "$RELEASE_DIR/build.log" 2>&1

# Create ZIP
echo -e "${BLUE}🗜️  Creating ZIP...${NC}"
cd "$RELEASE_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME.zip"
cd ..

# Sign
echo -e "${BLUE}🔐 Signing...${NC}"
SIGNATURE=$(./sign_update "$RELEASE_DIR/$APP_NAME.zip")
FILE_SIZE=$(stat -f%z "$RELEASE_DIR/$APP_NAME.zip")

# Update appcast
echo -e "${BLUE}📡 Updating appcast...${NC}"
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

NEW_ITEM="        <item>
            <title>Version $VERSION</title>
            <description><![CDATA[
                <p>$RELEASE_NOTES</p>
            ]]></description>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <enclosure
                url=\"https://github.com/mattfasullo/MediaDash/releases/download/v$VERSION/$APP_NAME.zip\"
                sparkle:version=\"$VERSION\"
                sparkle:shortVersionString=\"$VERSION\"
                sparkle:edSignature=\"$SIGNATURE\"
                length=\"$FILE_SIZE\"
                type=\"application/octet-stream\"
            />
        </item>"

cp "$APPCAST_FILE" "$APPCAST_FILE.backup"
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
rm "$APPCAST_FILE.backup"

# Commit and push
echo -e "${BLUE}🚀 Publishing...${NC}"
git add "$APPCAST_FILE" "MediaDash/Info.plist"
git commit -m "Release v$VERSION"
git push

# Create release
gh release create "v$VERSION" \
    "$RELEASE_DIR/$APP_NAME.zip" \
    --title "$APP_NAME v$VERSION" \
    --notes "$RELEASE_NOTES"

echo ""
echo -e "${GREEN}✅ Release v$VERSION published!${NC}"
echo "URL: https://github.com/mattfasullo/MediaDash/releases/tag/v$VERSION"

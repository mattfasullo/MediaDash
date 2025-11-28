#!/bin/bash
# Sign and Release - Use after building in Xcode
# Usage: ./sign_and_release.sh <version> "<release notes>"

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: ./sign_and_release.sh <version> \"<release notes>\""
    exit 1
fi

VERSION=$1
RELEASE_NOTES=$2
RELEASE_DIR="release"
APP_NAME="MediaDash"

echo "======================================"
echo "   Signing & Publishing v$VERSION"
echo "======================================"

# Check if app exists
if [ ! -d "$RELEASE_DIR/$APP_NAME.app" ]; then
    echo "❌ Error: $RELEASE_DIR/$APP_NAME.app not found"
    echo "Please build and export the app from Xcode first:"
    echo "  Product → Archive → Distribute App → Copy App"
    echo "  Save to: $(pwd)/$RELEASE_DIR/"
    exit 1
fi

# Re-sign app if media_validator.py was added (maintains code signature seal)
if [ -f "$RELEASE_DIR/$APP_NAME.app/Contents/Resources/media_validator.py" ]; then
    echo -e "${BLUE}🔐 Re-signing app after adding media_validator.py...${NC}"
    codesign --force --deep --sign "Developer ID Application: Matt Fasullo (9XPBY59H89)" "$RELEASE_DIR/$APP_NAME.app" 2>/dev/null || \
    codesign --force --deep --sign - "$RELEASE_DIR/$APP_NAME.app" 2>&1
    
    # Verify signature
    if codesign -vv --deep --strict "$RELEASE_DIR/$APP_NAME.app" 2>&1 | grep -q "valid on disk"; then
        echo -e "${GREEN}✓ App re-signed and verified${NC}"
    else
        echo -e "${YELLOW}⚠️  Warning: Signature verification had issues${NC}"
    fi
fi

# Create ZIP
echo -e "${BLUE}🗜️  Creating ZIP...${NC}"
cd "$RELEASE_DIR"
rm -f "$APP_NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME.zip"
cd ..

# Sign
echo -e "${BLUE}🔐 Signing...${NC}"
SIGNATURE=$(./sign_update "$RELEASE_DIR/$APP_NAME.zip")
FILE_SIZE=$(stat -f%z "$RELEASE_DIR/$APP_NAME.zip")

# Update appcast
echo -e "${BLUE}📡 Updating appcast...${NC}"
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

# Create new appcast with updated info
cat > appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>MediaDash Updates</title>
        <description>Most recent updates to MediaDash</description>
        <language>en</language>
        <item>
            <title>Version $VERSION</title>
            <description><![CDATA[
                <p>$RELEASE_NOTES</p>
            ]]></description>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <enclosure
                url="https://github.com/mattfasullo/MediaDash/releases/download/v$VERSION/$APP_NAME.zip"
                sparkle:version="$VERSION"
                sparkle:shortVersionString="$VERSION"
                sparkle:edSignature="$SIGNATURE"
                length="$FILE_SIZE"
                type="application/octet-stream"
            />
        </item>
    </channel>
</rss>
EOF

# Show info
echo ""
echo -e "${GREEN}✅ Ready to publish!${NC}"
echo ""
echo "Version: $VERSION"
echo "File: $RELEASE_DIR/$APP_NAME.zip"
echo "Size: $FILE_SIZE bytes"
echo "Signature: $SIGNATURE"
echo ""
echo "Next steps:"
echo "1. git add appcast.xml && git commit -m 'Release v$VERSION' && git push"
echo "2. Upload $RELEASE_DIR/$APP_NAME.zip to GitHub release v$VERSION"
echo "   https://github.com/mattfasullo/MediaDash/releases/new"

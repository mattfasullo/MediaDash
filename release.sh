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

# Update version (syncs Info.plist and Xcode project)
echo -e "${BLUE}📝 Updating version...${NC}"
BUILD_NUMBER=$(echo "$VERSION" | awk -F. '{printf "%d", $1*100 + $2*10 + $3}')

# Validate BUILD_NUMBER is numeric
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}❌ ERROR: Invalid build number calculated: $BUILD_NUMBER${NC}"
    echo -e "${RED}Version: $VERSION${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Version: $VERSION, Build: $BUILD_NUMBER${NC}"
./sync_version.sh "$VERSION" "$BUILD_NUMBER"

# Store BUILD_NUMBER for use in appcast
export BUILD_NUMBER

# Build
echo -e "${BLUE}🔨 Building...${NC}"
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$RELEASE_DIR/$APP_NAME.xcarchive" \
    archive \
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
    <key>teamID</key>
    <string>9XPBY59H89</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath "$RELEASE_DIR/$APP_NAME.xcarchive" \
    -exportPath "$RELEASE_DIR" \
    -exportOptionsPlist "$RELEASE_DIR/export_options.plist" \
    >> "$RELEASE_DIR/build.log" 2>&1

# Copy media_validator.py into app bundle Resources
echo -e "${BLUE}📝 Copying media_validator.py into app bundle...${NC}"
if [ -f "media_validator.py" ]; then
    mkdir -p "$RELEASE_DIR/$APP_NAME.app/Contents/Resources"
    cp "media_validator.py" "$RELEASE_DIR/$APP_NAME.app/Contents/Resources/"
    echo -e "${GREEN}✓ media_validator.py copied to bundle${NC}"
else
    echo -e "${RED}❌ WARNING: media_validator.py not found in project root!${NC}"
fi

# Re-sign with available certificate (REQUIRED after copying files to maintain code signature seal)
echo -e "${BLUE}🔐 Re-signing app after adding media_validator.py...${NC}"
# Try Developer ID first, fall back to ad-hoc signing
codesign --force --deep --sign "Developer ID Application: Matt Fasullo (9XPBY59H89)" "$RELEASE_DIR/$APP_NAME.app" 2>/dev/null || \
codesign --force --deep --sign - "$RELEASE_DIR/$APP_NAME.app" 2>&1 || {
    echo -e "${YELLOW}⚠️  Warning: Re-signing failed, app may need manual signing${NC}"
}

# Verify signature
echo -e "${BLUE}🔍 Verifying signature...${NC}"
if codesign -vv --deep --strict "$RELEASE_DIR/$APP_NAME.app" 2>&1 | grep -q "valid on disk"; then
    echo -e "${GREEN}✓ App signature verified${NC}"
else
    echo -e "${RED}❌ WARNING: Signature verification failed!${NC}"
    codesign -vv --deep --strict "$RELEASE_DIR/$APP_NAME.app" 2>&1 | head -5
fi

# Create ZIP
echo -e "${BLUE}🗜️  Creating ZIP...${NC}"
cd "$RELEASE_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME.zip"
cd ..

# Sign
echo -e "${BLUE}🔐 Signing...${NC}"
if [ ! -f "./sign_update" ]; then
    echo -e "${RED}❌ ERROR: sign_update tool not found!${NC}"
    exit 1
fi

SIGN_OUTPUT=$(./sign_update "$RELEASE_DIR/$APP_NAME.zip" 2>&1)
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ ERROR: Signing failed!${NC}"
    echo "$SIGN_OUTPUT"
    exit 1
fi

SIGNATURE=$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
if [ -z "$SIGNATURE" ]; then
    echo -e "${RED}❌ ERROR: Failed to extract signature from sign_update output!${NC}"
    echo "Output was: $SIGN_OUTPUT"
    exit 1
fi

FILE_SIZE=$(stat -f%z "$RELEASE_DIR/$APP_NAME.zip")
if [ -z "$FILE_SIZE" ] || [ "$FILE_SIZE" -eq 0 ]; then
    echo -e "${RED}❌ ERROR: Invalid file size!${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Signed successfully${NC}"
echo -e "  Signature: ${SIGNATURE:0:20}..."
echo -e "  File size: $FILE_SIZE bytes"

# Update appcast
echo -e "${BLUE}📡 Updating appcast...${NC}"
echo -e "   Using version: $VERSION"
echo -e "   Using build number: $BUILD_NUMBER"
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
                sparkle:version=\"$BUILD_NUMBER\"
                sparkle:shortVersionString=\"$VERSION\"
                sparkle:edSignature=\"$SIGNATURE\"
                length=\"$FILE_SIZE\"
                type=\"application/octet-stream\"
            />
        </item>"

cp "$APPCAST_FILE" "$APPCAST_FILE.backup"

if command -v python3 &> /dev/null; then
    python3 <<PYTHON
import re
import sys

version = "$VERSION"
build_number = "$BUILD_NUMBER"
release_notes = """$RELEASE_NOTES""".replace('"""', "'")
pub_date = "$PUB_DATE"
signature = "$SIGNATURE"
file_size = "$FILE_SIZE"
app_name = "$APP_NAME"

new_item = f"""        <item>
            <title>Version {version}</title>
            <description><![CDATA[
                <p>{release_notes}</p>
            ]]></description>
            <pubDate>{pub_date}</pubDate>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <enclosure
                url="https://github.com/mattfasullo/MediaDash/releases/download/v{version}/{app_name}.zip"
                sparkle:version="{build_number}"
                sparkle:shortVersionString="{version}"
                sparkle:edSignature="{signature}"
                length="{file_size}"
                type="application/octet-stream"
            />
        </item>"""

with open("$APPCAST_FILE.backup", "r") as f:
    content = f.read()

# Find the language tag and insert new item after it
pattern = r'(<language>en</language>)'
replacement = r'\1\n' + new_item

content = re.sub(pattern, replacement, content, count=1)

with open("$APPCAST_FILE", "w") as f:
    f.write(content)
PYTHON
else
    # Fallback: use sed (less reliable for multiline)
    sed -i '' "/<language>en<\/language>/a\\
        <item>\\
            <title>Version $VERSION</title>\\
            <description><![CDATA[\\
                <p>$RELEASE_NOTES</p>\\
            ]]></description>\\
            <pubDate>$PUB_DATE</pubDate>\\
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>\\
            <enclosure\\
                url=\"https://github.com/mattfasullo/MediaDash/releases/download/v$VERSION/$APP_NAME.zip\"\\
                sparkle:version=\"$BUILD_NUMBER\"\\
                sparkle:shortVersionString=\"$VERSION\"\\
                sparkle:edSignature=\"$SIGNATURE\"\\
                length=\"$FILE_SIZE\"\\
                type=\"application/octet-stream\"\\
            />\\
        </item>
" "$APPCAST_FILE.backup" 2>/dev/null && mv "$APPCAST_FILE.backup" "$APPCAST_FILE" || {
        echo "Failed to update appcast. Please update manually."
        exit 1
    }
fi

rm -f "$APPCAST_FILE.backup"

# Verify appcast before committing
echo -e "${BLUE}🔍 Verifying appcast...${NC}"
if [ -f "verify_appcast.sh" ]; then
    if ./verify_appcast.sh; then
        echo -e "${GREEN}✓ Appcast verification passed${NC}"
    else
        echo -e "${RED}❌ Appcast verification failed!${NC}"
        echo -e "${RED}Please fix the appcast before committing.${NC}"
        exit 1
    fi
else
    echo -e "${RED}⚠️  Warning: verify_appcast.sh not found, skipping verification${NC}"
fi

# Commit and push
echo -e "${BLUE}🚀 Publishing...${NC}"
git add "$APPCAST_FILE" "MediaDash/Info.plist"
git commit -m "Release v$VERSION"
git push

# Prepare release notes with Gatekeeper instructions
GATEKEEPER_NOTES="## ⚠️ Installation Note

This app is not notarized (no Developer ID certificate). macOS may show a security warning.

**To install:**
1. Download and extract \`MediaDash.zip\`
2. Run: \`./install_mediadash.sh\` (included in release)
   - OR manually: \`xattr -d com.apple.quarantine MediaDash.app\`
3. First launch: Right-click → Open (or System Settings → Privacy & Security → Allow)

**Alternative:** Drag to Applications, then right-click → Open on first launch.

---

$RELEASE_NOTES"

# Create release (as pre-release)
gh release create "v$VERSION" \
    "$RELEASE_DIR/$APP_NAME.zip" \
    "install_mediadash.sh" \
    --title "$APP_NAME v$VERSION" \
    --notes "$GATEKEEPER_NOTES" \
    --prerelease

echo ""
echo -e "${GREEN}✅ Release v$VERSION published!${NC}"
echo "URL: https://github.com/mattfasullo/MediaDash/releases/tag/v$VERSION"

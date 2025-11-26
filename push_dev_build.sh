#!/bin/bash
# MediaDash Dev Build Push Script
# Creates a dev build, signs it, updates appcast-dev.xml, and pushes to dev-builds branch.

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

APP_NAME="MediaDash-Dev"  # Dev app name
DEV_APP_NAME="MediaDash-Dev"  # Final app name
SCHEME="MediaDash"
PROJECT="MediaDash.xcodeproj"
RELEASE_DIR="builds" # Use 'builds' directory for dev builds
APPCAST_DEV_FILE="appcast-dev.xml"
DEV_BRANCH="dev-builds"
DEV_BUNDLE_ID="mattfasullo.MediaDash-Dev"  # Separate bundle ID for dev

echo "======================================"
echo "   MediaDash Dev Build"
echo "======================================"
echo ""

# Get latest production version from appcast.xml
LATEST_PROD_VERSION=$(curl -s "https://raw.githubusercontent.com/mattfasullo/MediaDash/main/appcast.xml" | grep -o 'sparkle:shortVersionString="[^"]*"' | head -1 | cut -d'"' -f2)
LATEST_PROD_BUILD_NUMBER=$(curl -s "https://raw.githubusercontent.com/mattfasullo/MediaDash/main/appcast.xml" | grep -o 'sparkle:version="[^"]*"' | head -1 | cut -d'"' -f2)

# Get latest dev build number
LATEST_DEV_BUILD=$(curl -s "https://raw.githubusercontent.com/mattfasullo/MediaDash/dev-builds/appcast-dev.xml" | grep -o 'sparkle:version="[^"]*"' | head -1 | cut -d'"' -f2 || echo "0")

# Determine next dev version
# If production is 0.3.4 (build 34), next dev should be 0.4.0-dev39 (build 39)
# This ensures dev builds are always "newer" than production for Sparkle comparison
if [[ "$LATEST_PROD_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    MAJOR=${BASH_REMATCH[1]}
    MINOR=${BASH_REMATCH[2]}
    PATCH=${BASH_REMATCH[3]}
    
    # Increment minor version for dev builds to ensure it's higher
    # Or if minor is 9, increment major
    if [ "$MINOR" -eq 9 ]; then
        MAJOR=$((MAJOR + 1))
        MINOR=0
    else
        MINOR=$((MINOR + 1))
    fi
    DEV_VERSION="$MAJOR.$MINOR.0" # Use a clean version string for Sparkle comparison
    DEV_BUILD_NUMBER=$((LATEST_DEV_BUILD + 1)) # Increment from latest dev build
else
    echo -e "${RED}WARNING: Could not parse latest production version. Defaulting to 0.4.0-dev1.${NC}"
    DEV_VERSION="0.4.0"
    DEV_BUILD_NUMBER=$((LATEST_DEV_BUILD + 1))
fi

VERSION_STRING="$DEV_VERSION-dev$DEV_BUILD_NUMBER" # Full version string for display

echo "Latest production: $LATEST_PROD_VERSION (build $LATEST_PROD_BUILD_NUMBER)"
echo "Latest dev build: $LATEST_DEV_BUILD"
echo "Next dev version: $DEV_VERSION-dev$DEV_BUILD_NUMBER (build $DEV_BUILD_NUMBER)"
echo ""

# Clean build directory
echo -e "${BLUE}🧹 Cleaning...${NC}"
rm -rf "$RELEASE_DIR/$DEV_APP_NAME.app" "$RELEASE_DIR/$DEV_APP_NAME-*.zip" "$RELEASE_DIR/$APP_NAME.app" "$RELEASE_DIR/$APP_NAME-*.zip"
mkdir -p "$RELEASE_DIR"

# Update version in Info-Dev.plist (dev builds use separate Info.plist)
echo -e "${BLUE}📝 Updating version in Info-Dev.plist...${NC}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $DEV_VERSION" "MediaDash/Info-Dev.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $DEV_VERSION" "MediaDash/Info-Dev.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $DEV_BUILD_NUMBER" "MediaDash/Info-Dev.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $DEV_BUILD_NUMBER" "MediaDash/Info-Dev.plist"

# Verify Info-Dev.plist has correct dev appcast URL before building
echo -e "${BLUE}🔍 Verifying Info-Dev.plist has dev appcast URL...${NC}"
DEV_APPCAST_URL="https://raw.githubusercontent.com/mattfasullo/MediaDash/$DEV_BRANCH/$APPCAST_DEV_FILE"
CURRENT_DEV_APPCAST=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "MediaDash/Info-Dev.plist" 2>/dev/null)
if [ "$CURRENT_DEV_APPCAST" != "$DEV_APPCAST_URL" ]; then
    echo -e "${RED}❌ ERROR: Info-Dev.plist has wrong appcast URL!${NC}"
    echo -e "   Expected: $DEV_APPCAST_URL"
    echo -e "   Got: $CURRENT_DEV_APPCAST"
    echo -e "   Setting correct URL..."
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $DEV_APPCAST_URL" "MediaDash/Info-Dev.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $DEV_APPCAST_URL" "MediaDash/Info-Dev.plist"
    echo -e "${GREEN}✓ Fixed appcast URL in Info-Dev.plist${NC}"
else
    echo -e "${GREEN}✓ Info-Dev.plist has correct dev appcast URL${NC}"
fi

# Also update main Info.plist for consistency (but we'll use Info-Dev.plist for build)
./sync_version.sh "$DEV_VERSION" "$DEV_BUILD_NUMBER"

# Build with dev settings: different bundle ID, product name, and Info.plist
echo -e "${BLUE}🔨 Building MediaDash-Dev...${NC}"
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$RELEASE_DIR/$DEV_APP_NAME.xcarchive" \
    PRODUCT_BUNDLE_IDENTIFIER="$DEV_BUNDLE_ID" \
    PRODUCT_NAME="$DEV_APP_NAME" \
    INFOPLIST_FILE="MediaDash/Info-Dev.plist" \
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
    -archivePath "$RELEASE_DIR/$DEV_APP_NAME.xcarchive" \
    -exportPath "$RELEASE_DIR" \
    -exportOptionsPlist "$RELEASE_DIR/export_options.plist" \
    >> "$RELEASE_DIR/build.log" 2>&1

# Rename app to MediaDash-Dev.app if needed
if [ -d "$RELEASE_DIR/$APP_NAME.app" ] && [ ! -d "$RELEASE_DIR/$DEV_APP_NAME.app" ]; then
    mv "$RELEASE_DIR/$APP_NAME.app" "$RELEASE_DIR/$DEV_APP_NAME.app"
fi

# Copy media_validator.py into app bundle Resources
echo -e "${BLUE}📝 Copying media_validator.py into app bundle...${NC}"
if [ -f "media_validator.py" ]; then
    mkdir -p "$RELEASE_DIR/$DEV_APP_NAME.app/Contents/Resources"
    cp "media_validator.py" "$RELEASE_DIR/$DEV_APP_NAME.app/Contents/Resources/"
    echo -e "${GREEN}✓ media_validator.py copied to bundle${NC}"
else
    echo -e "${RED}❌ WARNING: media_validator.py not found in project root!${NC}"
fi

# Create ZIP using ditto (as per documentation and other release scripts)
echo -e "${BLUE}🗜️  Creating ZIP...${NC}"
ZIP_NAME="$DEV_APP_NAME-$VERSION_STRING.zip"
cd "$RELEASE_DIR"
ditto -c -k --sequesterRsrc --keepParent "$DEV_APP_NAME.app" "$ZIP_NAME"
cd ..

# Sign
echo -e "${BLUE}🔐 Signing...${NC}"
if [ ! -f "./sign_update" ]; then
    echo -e "${RED}❌ ERROR: sign_update tool not found!${NC}"
    exit 1
fi

SIGN_OUTPUT=$(./sign_update "$RELEASE_DIR/$ZIP_NAME" 2>&1)
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

FILE_SIZE=$(stat -f%z "$RELEASE_DIR/$ZIP_NAME")
if [ -z "$FILE_SIZE" ] || [ "$FILE_SIZE" -eq 0 ]; then
    echo -e "${RED}❌ ERROR: Invalid file size!${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Signed successfully${NC}"
echo -e "  Signature: ${SIGNATURE:0:20}..."
echo -e "  File size: $FILE_SIZE bytes"

# Verify built app has correct dev appcast URL
echo -e "${BLUE}🔍 Verifying built app has dev appcast URL...${NC}"
DEV_APPCAST_URL="https://raw.githubusercontent.com/mattfasullo/MediaDash/$DEV_BRANCH/$APPCAST_DEV_FILE"
BUILT_APPCAST_URL=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$RELEASE_DIR/$DEV_APP_NAME.app/Contents/Info.plist" 2>/dev/null)
if [ "$BUILT_APPCAST_URL" != "$DEV_APPCAST_URL" ]; then
    echo -e "${RED}❌ ERROR: Built app has wrong appcast URL!${NC}"
    echo -e "   Expected: $DEV_APPCAST_URL"
    echo -e "   Got: $BUILT_APPCAST_URL"
    echo -e "   Build will not receive dev updates!"
    exit 1
fi
echo -e "${GREEN}✓ Built app has correct dev appcast URL${NC}"

# Switch to dev-builds branch
echo -e "${BLUE}📡 Switching to dev-builds branch...${NC}"
git stash save "WIP on $(git rev-parse --abbrev-ref HEAD)" > /dev/null 2>&1
git checkout "$DEV_BRANCH" || git checkout -b "$DEV_BRANCH"
git pull origin "$DEV_BRANCH" 2>/dev/null || true

# Update appcast-dev.xml
echo -e "${BLUE}📝 Updating appcast-dev.xml...${NC}"
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

# Use the clean DEV_VERSION for sparkle:version for comparison
# Use VERSION_STRING for title and shortVersionString for display
NEW_ITEM="        <item>
                <title>Version $VERSION_STRING</title>
                <description><![CDATA[
                    <p>Dev build with path reset functionality - paths reset to defaults on each update</p>
                ]]></description>
                <pubDate>$PUB_DATE</pubDate>
                <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
                <enclosure
                    url=\"https://raw.githubusercontent.com/mattfasullo/MediaDash/$DEV_BRANCH/$RELEASE_DIR/$ZIP_NAME\"
                    sparkle:version=\"$DEV_BUILD_NUMBER\"
                    sparkle:shortVersionString=\"$DEV_VERSION\"
                    sparkle:edSignature=\"$SIGNATURE\"
                    length=\"$FILE_SIZE\"
                    type=\"application/octet-stream\"
                />
            </item>"

# Ensure appcast-dev.xml exists and has proper XML structure
if [ ! -f "$APPCAST_DEV_FILE" ] || ! grep -q "</channel>" "$APPCAST_DEV_FILE"; then
    echo "Creating new $APPCAST_DEV_FILE with proper structure..."
    cat > "$APPCAST_DEV_FILE" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>MediaDash Dev Builds</title>
        <description>Development builds for testing</description>
        <language>en</language>
    </channel>
</rss>
EOF
fi

# Insert new item after the <language> tag
awk -v new_item="$NEW_ITEM" '/<language>en<\/language>/ {print; print new_item; next} 1' "$APPCAST_DEV_FILE" > "$APPCAST_DEV_FILE.tmp"
mv "$APPCAST_DEV_FILE.tmp" "$APPCAST_DEV_FILE"

echo -e "${GREEN}✅ Updated appcast-dev.xml${NC}"

# Add and commit changes to dev-builds branch
git add -f "$RELEASE_DIR/$ZIP_NAME" # Force add the zip file
git add "$APPCAST_DEV_FILE"
git commit -m "Dev build: $VERSION_STRING - Path reset functionality"

# Push to dev-builds branch
echo -e "${BLUE}🚀 Pushing to dev-builds branch...${NC}"
git push origin "$DEV_BRANCH"

echo -e "${GREEN}✅ Dev build $VERSION_STRING pushed!${NC}"
echo -e "   Feed: https://raw.githubusercontent.com/mattfasullo/MediaDash/$DEV_BRANCH/$APPCAST_DEV_FILE"

# Switch back to main branch and apply stash
git checkout main
git stash pop > /dev/null 2>&1 || true # Apply stash, ignore if no stash

echo ""
echo "Current branch: $(git rev-parse --abbrev-ref HEAD)"
echo ""

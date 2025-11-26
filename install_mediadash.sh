#!/bin/bash
# MediaDash Installation Helper
# This script helps bypass macOS Gatekeeper for MediaDash.app
# Run this after downloading MediaDash.zip from GitHub

set -e

APP_NAME="MediaDash.app"
ZIP_NAME="MediaDash.zip"

echo "======================================"
echo "   MediaDash Installation Helper"
echo "======================================"
echo ""

# Check if ZIP exists in current directory
if [ -f "$ZIP_NAME" ]; then
    echo "📦 Found $ZIP_NAME, extracting..."
    unzip -q "$ZIP_NAME"
    echo "✅ Extracted successfully"
    echo ""
fi

# Check if app exists
if [ ! -d "$APP_NAME" ]; then
    echo "❌ Error: $APP_NAME not found!"
    echo ""
    echo "Please either:"
    echo "  1. Run this script in the same directory as $ZIP_NAME, or"
    echo "  2. Run this script in the same directory as $APP_NAME"
    exit 1
fi

# Get absolute path
APP_PATH="$(cd "$(dirname "$APP_NAME")" && pwd)/$(basename "$APP_NAME")"

echo "🔓 Removing quarantine attribute from $APP_NAME..."
xattr -d com.apple.quarantine "$APP_PATH" 2>/dev/null || {
    echo "⚠️  No quarantine attribute found (this is okay)"
}

echo ""
echo "✅ Installation complete!"
echo ""
echo "You can now:"
echo "  1. Open $APP_NAME normally"
echo "  2. Or drag it to your Applications folder"
echo ""
echo "If you still see a warning, try:"
echo "  Right-click → Open (first time only)"
echo ""


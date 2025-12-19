#!/bin/bash

# MediaDash Cache Sync Service Installer
# This script installs the cache sync service as a launchd daemon

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_NAME="com.mediadash.cache-sync.plist"
PLIST_SOURCE="${SCRIPT_DIR}/${PLIST_NAME}"
PLIST_DEST="${HOME}/Library/LaunchAgents/${PLIST_NAME}"
SYNC_SCRIPT="${SCRIPT_DIR}/sync_shared_cache.sh"

echo "MediaDash Cache Sync Service Installer"
echo "========================================"
echo ""

# Check if script exists
if [ ! -f "$SYNC_SCRIPT" ]; then
    echo "❌ Error: sync_shared_cache.sh not found at: $SYNC_SCRIPT"
    exit 1
fi

# Make script executable
chmod +x "$SYNC_SCRIPT"
echo "✅ Made sync script executable"

# Check if plist exists
if [ ! -f "$PLIST_SOURCE" ]; then
    echo "❌ Error: $PLIST_NAME not found at: $PLIST_SOURCE"
    exit 1
fi

# Update script path in plist (create temp copy)
TEMP_PLIST=$(mktemp)
sed "s|/Users/mattfasullo/Projects/MediaDash|${SCRIPT_DIR}|g" "$PLIST_SOURCE" > "$TEMP_PLIST"

# Copy plist to LaunchAgents
cp "$TEMP_PLIST" "$PLIST_DEST"
rm "$TEMP_PLIST"
echo "✅ Installed plist to: $PLIST_DEST"

# Unload existing service if it exists
if launchctl list | grep -q "com.mediadash.cache-sync"; then
    echo "🔄 Unloading existing service..."
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
fi

# Load the service
echo "🔄 Loading service..."
launchctl load "$PLIST_DEST"
echo "✅ Service loaded"

# Start the service
echo "🔄 Starting service..."
launchctl start com.mediadash.cache-sync
echo "✅ Service started"

echo ""
echo "Installation complete!"
echo ""
echo "To check status:"
echo "  launchctl list | grep mediadash"
echo ""
echo "To view logs:"
echo "  tail -f /tmp/mediadash-cache-sync.log"
echo ""
echo "To uninstall:"
echo "  launchctl unload ~/Library/LaunchAgents/${PLIST_NAME}"
echo "  rm ~/Library/LaunchAgents/${PLIST_NAME}"


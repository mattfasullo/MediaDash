#!/bin/bash

# MediaDash Cache Sync Status Checker
# Use this script to check if the cache sync is running and view progress

LOG_FILE="/tmp/mediadash-cache-sync.log"
PID_FILE="/tmp/mediadash-cache-sync.pid"
CACHE_PATH="/Volumes/Grayson Assets/MEDIA/Media Dept Misc. Folders/Misc./MediaDash_Cache"

echo "=== MediaDash Cache Sync Status ==="
echo ""

# Check if process is running
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null)
    if ps -p "$PID" > /dev/null 2>&1; then
        echo "✅ Status: RUNNING (PID: $PID)"
        echo ""
        echo "📊 Progress (last 10 lines of log):"
        echo "-----------------------------------"
        tail -10 "$LOG_FILE" 2>/dev/null || echo "No log entries yet"
        echo "-----------------------------------"
        echo ""
        echo "💡 To watch live progress, run:"
        echo "   tail -f $LOG_FILE"
    else
        echo "❌ Status: NOT RUNNING (stale PID file)"
        rm -f "$PID_FILE"
    fi
else
    echo "❌ Status: NOT RUNNING"
fi

echo ""
echo "📁 Cache File Info:"
if [ -f "$CACHE_PATH" ]; then
    SIZE=$(ls -lh "$CACHE_PATH" | awk '{print $5}')
    MODIFIED=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$CACHE_PATH" 2>/dev/null || stat -c "%y" "$CACHE_PATH" 2>/dev/null | cut -d' ' -f1-2)
    echo "   Path: $CACHE_PATH"
    echo "   Size: $SIZE"
    echo "   Last Modified: $MODIFIED"
    
    # Try to get docket count
    DOCKET_COUNT=$(python3 -c "
import json
try:
    with open('$CACHE_PATH', 'r') as f:
        data = json.load(f)
        print(len(data.get('dockets', [])))
except:
    print('N/A')
" 2>/dev/null)
    echo "   Dockets: $DOCKET_COUNT"
else
    echo "   Cache file not found"
fi

echo ""
echo "📝 Full log available at: $LOG_FILE"
echo ""


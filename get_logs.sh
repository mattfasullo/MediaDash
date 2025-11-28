#!/bin/bash

# Script to fetch MediaDash debug logs for AI assistant
# Usage: ./get_logs.sh [lines] [component] [source]
#   lines: number of lines to show (default: 100)
#   component: filter by component name (optional)
#   source: "file" (default), "system", or "both"

LINES=${1:-100}  # Default to last 100 lines
COMPONENT=${2:-""}  # Optional component filter
SOURCE=${3:-"file"}  # Log source: file, system, or both

LOG_FILE="$HOME/Library/Logs/MediaDash/mediadash-debug.log"
BUNDLE_ID="mattfasullo.MediaDash"
SUBSYSTEM="com.mediadash"

# Function to get logs from file
get_file_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        echo "⚠️  Log file not found at $LOG_FILE" >&2
        echo "   The app may not have created logs yet." >&2
        return 1
    fi
    
    if [ -n "$COMPONENT" ]; then
        tail -n "$LINES" "$LOG_FILE" | grep "\[$COMPONENT\]"
    else
        tail -n "$LINES" "$LOG_FILE"
    fi
}

# Function to get logs from macOS unified logging system
get_system_logs() {
    # Query unified logging system for MediaDash logs
    log show --predicate 'subsystem == "$SUBSYSTEM" OR processImagePath CONTAINS "MediaDash"' \
        --last "${LINES}s" \
        --style compact 2>/dev/null | \
        tail -n "$LINES"
}

# Main logic
case "$SOURCE" in
    "file")
        echo "=== MediaDash Debug Logs (File) ===" >&2
        echo "Reading from: $LOG_FILE" >&2
        echo "Showing last $LINES lines" >&2
        if [ -n "$COMPONENT" ]; then
            echo "Filtering for component: $COMPONENT" >&2
        fi
        echo "" >&2
        get_file_logs
        ;;
    "system")
        echo "=== MediaDash Debug Logs (System) ===" >&2
        echo "Reading from macOS unified logging system" >&2
        echo "Subsystem: $SUBSYSTEM" >&2
        echo "Showing last ${LINES}s of activity" >&2
        echo "" >&2
        get_system_logs
        ;;
    "both")
        echo "=== MediaDash Debug Logs (File) ===" >&2
        echo "Reading from: $LOG_FILE" >&2
        echo "Showing last $LINES lines" >&2
        if [ -n "$COMPONENT" ]; then
            echo "Filtering for component: $COMPONENT" >&2
        fi
        echo "" >&2
        get_file_logs
        echo "" >&2
        echo "=== MediaDash Debug Logs (System) ===" >&2
        echo "Reading from macOS unified logging system" >&2
        echo "Subsystem: $SUBSYSTEM" >&2
        echo "Showing last ${LINES}s of activity" >&2
        echo "" >&2
        get_system_logs
        ;;
    *)
        echo "Invalid source: $SOURCE" >&2
        echo "Use: file, system, or both" >&2
        exit 1
        ;;
esac


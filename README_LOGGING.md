# MediaDash Logging Setup

This setup allows the AI assistant to **automatically read and debug issues** without you having to copy/paste logs.

## How It Works

1. **File-Based Logging**: The app writes all debug output to `~/Library/Logs/MediaDash/mediadash-debug.log`
2. **Unified Logging**: Also uses macOS's unified logging system (OSLog) with subsystem `com.mediadash`
3. **Automatic Access**: The AI assistant can read logs directly from the file

## Automatic Debugging Workflow

**When you ask me to create/fix something and it's not working:**

1. ✅ I will **automatically read the logs** from `~/Library/Logs/MediaDash/mediadash-debug.log`
2. ✅ I will **analyze errors and debug output** to identify the issue
3. ✅ I will **add additional debug logging** if needed using `debugLog()`, `errorLog()`, or `debugValue()`
4. ✅ I will **fix the issue** based on what I find in the logs
5. ✅ **No need for you to copy/paste logs** - I'll read them automatically!

## Usage

### For You (Manual)

To view logs manually, run:
```bash
./get_logs.sh [lines] [component] [source]
```

Examples:
```bash
# Show last 100 lines from file
./get_logs.sh

# Show last 500 lines
./get_logs.sh 500

# Show logs for a specific component
./get_logs.sh 100 "EmailScanningService"

# Show logs from macOS unified logging system
./get_logs.sh 100 "" system

# Show logs from both sources
./get_logs.sh 100 "" both
```

### For AI Assistant (Automatic)

The AI assistant automatically reads logs by:
1. Reading the log file at `~/Library/Logs/MediaDash/mediadash-debug.log`
2. Running the `get_logs.sh` script when needed
3. Querying macOS unified logging system

**You don't need to do anything** - just say "this isn't working" and I'll read the logs and debug it!

## Log File Location

- **File logs**: `~/Library/Logs/MediaDash/mediadash-debug.log`
- **System logs**: Query via `log show --predicate 'subsystem == "com.mediadash"'`

## Implementation Details

- `FileLogger.swift`: Centralized logger that writes to both console and file
- `DebugHelper.swift`: Convenience functions for easy debugging (`debugLog()`, `errorLog()`, `debugValue()`)
- Logs include timestamps, log levels, component names, file names, function names, and line numbers
- Logs are written in real-time as the app runs

## Adding Debug Logging

When debugging, use these helpers:

```swift
// Simple debug message
debugLog("Processing started")

// Debug with value
debugValue("userCount", users.count)

// Error logging
errorLog("Failed to fetch data", error: error)

// Or use FileLogger directly
FileLogger.shared.log("Custom message", level: .info, component: "MyComponent")
```

The AI assistant will automatically read these logs when debugging issues.

## Notes

- Logs are only written when the app is running
- The log file is created automatically on first run
- Old logs are not automatically rotated (you may want to add log rotation later)
- File logging happens asynchronously to avoid blocking the main thread


# MediaDash Shared Cache Sync

This script automatically syncs Asana dockets and saves them to a shared cache location that all MediaDash instances can use.

## Setup

1. **Make the script executable:**
   ```bash
   chmod +x sync_shared_cache.sh
   ```

2. **Configure the script:**
   - Edit `sync_shared_cache.sh` and update the `CACHE_PATH` variable if needed
   - The default path is: `/Volumes/Grayson Assets/MEDIA/Media Dept Misc. Folders/Misc./MediaDash_Cache`
   - Optionally set `WORKSPACE_ID` or `PROJECT_ID` to limit which Asana data to sync

3. **Set up Asana authentication:**
   - The script will automatically try to read the Asana access token from macOS Keychain (where MediaDash stores it)
   - Alternatively, you can set the `ASANA_ACCESS_TOKEN` environment variable:
     ```bash
     export ASANA_ACCESS_TOKEN="your_token_here"
     ```

## Running the Script

### Manual Run
```bash
./sync_shared_cache.sh
```

### Automated Scheduling (macOS)

#### Option 1: Using launchd (Recommended)

Create a plist file at `~/Library/LaunchAgents/com.mediadash.cache-sync.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mediadash.cache-sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/sync_shared_cache.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/mediadash-cache-sync.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/mediadash-cache-sync-error.log</string>
</dict>
</plist>
```

Then load it:
```bash
launchctl load ~/Library/LaunchAgents/com.mediadash.cache-sync.plist
```

This will run the script every hour (3600 seconds). Adjust `StartInterval` as needed.

#### Option 2: Using cron

Edit your crontab:
```bash
crontab -e
```

Add a line to run every hour:
```
0 * * * * /path/to/sync_shared_cache.sh >> /tmp/mediadash-cache-sync.log 2>&1
```

## Requirements

- macOS (for keychain access)
- Python 3 (for JSON parsing)
- curl (usually pre-installed)
- Network access to Asana API
- Server path must be mounted/accessible

## Troubleshooting

1. **"Server path not available"**
   - Make sure the server is mounted before running the script
   - Check that the path exists and is accessible

2. **"Asana access token not found"**
   - Make sure you've authenticated MediaDash with Asana at least once
   - Or set the `ASANA_ACCESS_TOKEN` environment variable

3. **"Asana API error"**
   - Check your internet connection
   - Verify the access token is still valid
   - Check Asana API status

4. **Script runs but cache file is empty or invalid**
   - Check the error logs
   - Verify Python 3 is installed: `python3 --version`
   - Make sure you have write permissions to the cache path

## Verifying the Sync is Working

### Quick Check

Use the verification script to check if the sync is working:

```bash
./verify_asana_sync.sh
```

This will check:
- ✅ Cache file exists and is readable
- ✅ JSON structure is valid
- ✅ Cache statistics (docket count, metadata types, etc.)
- ✅ Compatibility with MediaDash
- ✅ Sync script status and recent log entries

### Manual Verification

1. **Check the cache file directly:**
   ```bash
   # View cache file info
   ls -lh "/Volumes/Grayson Assets/MEDIA/Media Dept Misc. Folders/Misc./MediaDash_Cache"
   
   # View docket count
   python3 -c "import json; data = json.load(open('/Volumes/Grayson Assets/MEDIA/Media Dept Misc. Folders/Misc./MediaDash_Cache')); print(f'Dockets: {len(data[\"dockets\"])}')"
   ```

2. **Check the sync log:**
   ```bash
   tail -f /tmp/mediadash-cache-sync.log
   ```

3. **Verify MediaDash is using the shared cache:**
   - Open MediaDash
   - Open Console.app (Applications > Utilities > Console)
   - Filter for "MediaDash" or search for "[Cache]"
   - Look for log messages like:
     - `🟢 [Cache] Loaded X dockets from SHARED cache` ✅ (using shared cache)
     - `🟢 [Cache] Loaded X dockets from LOCAL cache` ⚠️ (falling back to local)

4. **Check sync script status:**
   ```bash
   ./check_cache_sync.sh
   ```

### What to Look For

**✅ Signs the sync is working:**
- Cache file exists and was modified recently (within last few hours)
- Cache file contains valid JSON with a "dockets" array
- Docket count matches what you expect from Asana
- MediaDash console shows "Loaded X dockets from SHARED cache"
- Sync log shows successful completion messages

**⚠️ Signs there may be issues:**
- Cache file is very old (days/weeks)
- Cache file is empty or invalid JSON
- MediaDash console shows "falling back to local cache"
- Sync log shows errors or warnings
- Docket count is 0 or much lower than expected

## Notes

- The script performs an atomic write (writes to temp file, then moves) to prevent corruption
- The cache format matches what MediaDash expects
- The script will fetch ALL tasks from your Asana workspace/project (no limits)
- Large workspaces may take several minutes to sync


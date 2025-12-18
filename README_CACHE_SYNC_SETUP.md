# MediaDash Cache Sync Service Setup

The MediaDash cache sync service automatically updates the shared Asana docket cache on the server, so MediaDash can start instantly without waiting for sync.

## How It Works

1. **External Service** (`sync_shared_cache.sh`): Runs independently and syncs with Asana API every 30 minutes
2. **MediaDash**: Checks the shared cache on startup - if it's fresh (< 1 hour old), uses it immediately
3. **Manual Sync**: Users can still manually sync via the cache icon popup if needed

## Installation

### Option 1: Automatic Installation (Recommended)

Run the installer script from the MediaDash project directory:
```bash
./install_cache_sync.sh
```

This will:
- Make the sync script executable
- Install the launchd plist
- Load and start the service

**Before running**, make sure to:
1. Update the cache directory path in `sync_shared_cache.sh` (line 34) to match your server path:
   ```bash
   CACHE_DIR="/Volumes/Grayson Assets/MEDIA/Media Dept Misc. Folders/Misc./MediaDash_Cache"
   ```

### Option 2: Manual Installation

1. **Copy the plist file to LaunchAgents directory:**
   ```bash
   cp com.mediadash.cache-sync.plist ~/Library/LaunchAgents/
   ```

2. **Update the script path in the plist:**
   Edit `~/Library/LaunchAgents/com.mediadash.cache-sync.plist` and update the script path to match your MediaDash project location:
   ```xml
   <string>/path/to/MediaDash/sync_shared_cache.sh</string>
   ```

3. **Update the cache path in the script:**
   Edit `sync_shared_cache.sh` and update the `CACHE_DIR` variable (line 34) to match your server path:
   ```bash
   CACHE_DIR="/Volumes/Grayson Assets/MEDIA/Media Dept Misc. Folders/Misc./MediaDash_Cache"
   ```

4. **Make the script executable:**
   ```bash
   chmod +x /path/to/MediaDash/sync_shared_cache.sh
   ```

5. **Load the service:**
   ```bash
   launchctl load ~/Library/LaunchAgents/com.mediadash.cache-sync.plist
   ```

6. **Start the service:**
   ```bash
   launchctl start com.mediadash.cache-sync
   ```

### Option 2: Using cron (Alternative)

Add to crontab to run every 30 minutes:
```bash
crontab -e
```

Add this line:
```
*/30 * * * * /path/to/MediaDash/sync_shared_cache.sh >> /tmp/mediadash-cache-sync.log 2>&1
```

## Verification

1. **Check if service is running:**
   ```bash
   launchctl list | grep mediadash
   ```

2. **View logs:**
   ```bash
   tail -f /tmp/mediadash-cache-sync.log
   ```

3. **Test manually:**
   ```bash
   /path/to/MediaDash/sync_shared_cache.sh
   ```

4. **Check cache file:**
   ```bash
   ls -lh "/Volumes/Grayson Assets/MEDIA/Media Dept Misc. Folders/Misc./MediaDash_Cache/mediadash_docket_cache.json"
   ```

## Management

### Stop the service:
```bash
launchctl stop com.mediadash.cache-sync
```

### Unload the service:
```bash
launchctl unload ~/Library/LaunchAgents/com.mediadash.cache-sync.plist
```

### Restart the service:
```bash
launchctl unload ~/Library/LaunchAgents/com.mediadash.cache-sync.plist
launchctl load ~/Library/LaunchAgents/com.mediadash.cache-sync.plist
```

## Requirements

- **Asana Access Token**: The script reads the token from macOS keychain (same one MediaDash uses)
- **Server Mount**: The server path must be mounted/accessible
- **Python 3**: Required for JSON parsing
- **curl**: Required for API calls

## Troubleshooting

### Service not running
- Check logs: `tail -f /tmp/mediadash-cache-sync.log`
- Verify script path is correct in plist
- Ensure script is executable: `chmod +x sync_shared_cache.sh`

### Token not found
- Make sure MediaDash has authenticated with Asana first
- The script reads from keychain: `com.mediadash.keychain` / `asana_access_token`
- You can also set `ASANA_ACCESS_TOKEN` environment variable

### Server not accessible
- Ensure server is mounted before service runs
- Check the `CACHE_PATH` in the script matches your server path
- Verify network connectivity

### Cache not updating
- Check if service is running: `launchctl list | grep mediadash`
- View recent logs: `tail -50 /tmp/mediadash-cache-sync.log`
- Test manually: `./sync_shared_cache.sh`

## Configuration

### Change sync interval

Edit `com.mediadash.cache-sync.plist`:
```xml
<key>StartInterval</key>
<integer>1800</integer>  <!-- 30 minutes in seconds -->
```

Then reload:
```bash
launchctl unload ~/Library/LaunchAgents/com.mediadash.cache-sync.plist
launchctl load ~/Library/LaunchAgents/com.mediadash.cache-sync.plist
```

### Change cache location

Edit `sync_shared_cache.sh` line 34:
```bash
CACHE_DIR="/your/custom/path/here"
```

The script will automatically append `mediadash_docket_cache.json` to this path.

## Notes

- The service runs independently of MediaDash
- MediaDash will automatically use the cache if it's fresh (< 1 hour old)
- If cache is stale, users can manually sync via the cache icon popup
- The cache file is written atomically to prevent corruption


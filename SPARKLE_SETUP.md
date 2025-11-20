# Sparkle Auto-Update Setup Instructions

## Step 1: Add Sparkle Framework

1. Open **MediaDash.xcodeproj** in Xcode
2. Select the **MediaDash** project in the navigator
3. Select the **MediaDash** target
4. Go to the **Package Dependencies** tab
5. Click the **+** button
6. Enter this URL: `https://github.com/sparkle-project/Sparkle`
7. Click **Add Package**
8. Select **Sparkle** and click **Add Package**

## Step 2: Enable Sparkle in AppDelegate

After adding the package, edit `AppDelegate.swift`:

```swift
import Cocoa
import SwiftUI
import Sparkle  // Add this import

class AppDelegate: NSObject, NSApplicationDelegate {
    private var updaterController: SPUStandardUpdaterController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize Sparkle updater
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }
}
```

## Step 3: Add Info.plist to Xcode Project

An `Info.plist` file has been created at `MediaDash/Info.plist` with the necessary Sparkle keys.

**To add it to your Xcode project:**

1. Open **MediaDash.xcodeproj** in Xcode
2. Right-click on the **MediaDash** folder in the project navigator
3. Select **Add Files to "MediaDash"...**
4. Navigate to and select `MediaDash/Info.plist`
5. Click **Add**
6. Select the **MediaDash** target
7. Go to **Build Settings** tab
8. Search for "Info.plist File"
9. Set the value to `MediaDash/Info.plist`

The Info.plist contains these Sparkle configuration keys:
- `SUFeedURL` - Update server URL (currently set to placeholder)
- `SUPublicEDKey` - Public key for signature verification (update after generating keys)
- `SUEnableAutomaticChecks` - Enable automatic update checks
- `SUScheduledCheckInterval` - Check every 24 hours (86400 seconds)

## Step 4: Generate EdDSA Keys (for signing updates)

**Option 1: Download from Sparkle Releases**

1. Go to [Sparkle Releases](https://github.com/sparkle-project/Sparkle/releases/latest)
2. Download `generate_keys.tar.xz` from the assets
3. Extract and run:

```bash
cd ~/Documents/MediaDash
tar -xf ~/Downloads/generate_keys.tar.xz
./generate_keys
```

**Option 2: Use Sparkle Tools from Package**

After adding the Sparkle SPM package, Xcode downloads it to DerivedData. You can find generate_keys in:

```bash
find ~/Library/Developer/Xcode/DerivedData -name "generate_keys" -type f 2>/dev/null
```

Then run the tool from wherever it's located.

**The tool will output:**
- **Public key** → Copy this to Info.plist `SUPublicEDKey` value
- **Private key** → Save securely (password manager or encrypted location), DO NOT commit to git!

**Update Info.plist with your public key:**

After generating keys, open `MediaDash/Info.plist` and replace `YOUR_PUBLIC_KEY_HERE` with your actual public key.

## Step 5: Create Appcast XML

Create `appcast.xml` on your server:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>MediaDash Updates</title>
        <description>Most recent updates to MediaDash</description>
        <language>en</language>
        <item>
            <title>Version 1.0.1</title>
            <sparkle:releaseNotesLink>https://yourdomain.com/mediadash/release-notes-1.0.1.html</sparkle:releaseNotesLink>
            <pubDate>Wed, 20 Nov 2024 10:00:00 +0000</pubDate>
            <enclosure
                url="https://yourdomain.com/mediadash/MediaDash-1.0.1.zip"
                sparkle:version="1.0.1"
                sparkle:shortVersionString="1.0.1"
                sparkle:edSignature="SIGNATURE_HERE"
                length="FILE_SIZE_IN_BYTES"
                type="application/octet-stream"
            />
        </item>
    </channel>
</rss>
```

## Step 6: Build and Archive

1. Set version in Xcode (General → Identity → Version)
2. Archive: Product → Archive
3. Export app as Mac App
4. Sign the exported app with your private key:

```bash
./sign_update MediaDash.app -f ~/sparkle_private_key
```

5. Create a ZIP of the app
6. Update appcast.xml with signature and file size
7. Upload ZIP and appcast.xml to your server

## Quick Test

1. Build and run the app
2. Go to **MediaDash → Check for Updates...**
3. Should check your appcast URL

## Notes

- Store your **private key** securely (password manager, encrypted drive)
- Never commit the private key to git
- Update the `SUFeedURL` to your actual server URL
- Consider using GitHub Releases for hosting updates

---

## Summary of Files Created

- ✅ `MediaDash/AppDelegate.swift` - App delegate with Sparkle support (ready to uncomment after adding package)
- ✅ `MediaDash/MediaDashApp.swift` - Updated with "Check for Updates" menu (CMD+U)
- ✅ `MediaDash/Info.plist` - Sparkle configuration keys (needs public key after generation)
- 📝 `SPARKLE_SETUP.md` - This setup guide

## Next Steps

1. **Add Sparkle SPM package in Xcode** (Step 1)
2. **Add Info.plist to Xcode project** (Step 3)
3. **Uncomment Sparkle code in AppDelegate.swift** (Step 2)
4. **Generate EdDSA keys** (Step 4)
5. **Update Info.plist with your public key and feed URL** (Step 4)
6. **Set up your update server with appcast.xml** (Step 5)
7. **Build, sign, and distribute updates** (Step 6)

Once Steps 1-3 are complete, the "Check for Updates" menu item will be functional!

# How to Release Updates to Your Coworker

Sparkle is now fully configured to use **GitHub Releases**. Pushing updates is now **ONE COMMAND**!

## 🚀 One-Click Release Process

Just run this command and answer a few questions:

```bash
./release_update.sh
```

**The script will automatically:**
1. ✅ Ask for version number
2. ✅ Ask for release notes
3. ✅ Build the app with xcodebuild
4. ✅ Create and sign the ZIP
5. ✅ Update appcast.xml
6. ✅ Commit and push to GitHub
7. ✅ Create GitHub release
8. ✅ Done!

**That's it!** Your coworker gets the update automatically.

## Example Run

```bash
$ ./release_update.sh

Enter new version number: 0.1.3

Enter release notes (press Ctrl+D when done):
- Added video converter
- Fixed session search
- Performance improvements
^D

🔨 Building...
📦 Creating ZIP...
🔐 Signing...
📝 Updating appcast...
🚀 Publishing to GitHub...

🎉 Release Complete!
```

## Manual Process (If You Prefer)

If you want more control, you can still do it manually with `create_release.sh` (see old instructions below).

## What Happens Next

1. Your coworker's MediaDash app checks for updates every 24 hours
2. When they open the app, Sparkle finds the new version
3. They click "Install" and the app updates automatically
4. They can also manually check: MediaDash → Check for Updates (CMD+U)

## Files You Need to Know

- `appcast.xml` - Update feed (commit this to main branch)
- `generate_keys` - Tool to generate signing keys (already done)
- `sign_update` - Tool to sign your releases (used by create_release.sh)
- `create_release.sh` - Helper script to create releases

## First Release

To test it out, let's create your first release:

```bash
# 1. Set version to 0.1.3 in Xcode
# 2. Archive and export to release/ folder
# 3. Run the release script
./create_release.sh 0.1.3

# 4. Update appcast.xml with the output
# 5. Push everything to GitHub
git add appcast.xml
git commit -m "Release v0.1.3"
git push

# 6. Create GitHub release
gh release create v0.1.3 release/MediaDash.zip --title "MediaDash v0.1.3" --notes "First Sparkle-enabled release!"
```

## Important Notes

- **Private Key:** Stored securely in your macOS Keychain (automatically by generate_keys)
- **Public Key:** Already in Info.plist - your coworker's app uses this to verify updates
- **Feed URL:** `https://raw.githubusercontent.com/mattfasullo/MediaDash/main/appcast.xml`
- **Releases:** Hosted on GitHub Releases (free, unlimited bandwidth)

## Troubleshooting

**If your coworker gets "no updates available":**
- Make sure appcast.xml is committed to main branch
- Make sure GitHub release exists with the ZIP file
- Make sure version in appcast.xml matches the GitHub release tag
- Make sure their app version is lower than the release version

**To verify the feed is accessible:**
```bash
curl https://raw.githubusercontent.com/mattfasullo/MediaDash/main/appcast.xml
```

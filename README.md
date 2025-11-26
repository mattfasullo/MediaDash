# MediaDash

A media management application for macOS with automatic update support.

## 🚀 Releasing Updates

MediaDash uses [Sparkle](https://sparkle-project.org/) for automatic updates via GitHub Releases.

**To release a new version, simply run:**

```bash
./release_update.sh
```

The script will:
- Ask for version number and release notes
- Build and sign the app automatically
- Update the appcast.xml feed
- Create a GitHub release
- Push everything to GitHub

Your users will receive the update automatically within 24 hours.

See [RELEASE_GUIDE.md](RELEASE_GUIDE.md) for detailed instructions.

## 📋 Files

- `release_update.sh` - One-click release automation
- `RELEASE_GUIDE.md` - Complete release instructions
- `SPARKLE_SETUP.md` - Sparkle integration documentation
- `appcast.xml` - Update feed (auto-updated by release script)
- `generate_keys` - EdDSA key generation tool
- `sign_update` - Update signing tool

## 🔐 Security

- Private signing key: Stored in macOS Keychain
- Public key: Embedded in `MediaDash/Info.plist`
- All updates are cryptographically signed

## 📥 Installation

**For first-time installation from GitHub Releases:**

1. Download `MediaDash.zip` from the [latest release](https://github.com/mattfasullo/MediaDash/releases/latest)
2. Extract the ZIP file
3. Run the installation helper:
   ```bash
   ./install_mediadash.sh
   ```
   Or manually remove the quarantine attribute:
   ```bash
   xattr -d com.apple.quarantine MediaDash.app
   ```
4. **First launch:** Right-click on `MediaDash.app` → **Open** (macOS will ask for confirmation)
   - After the first launch, you can open it normally

**Note:** This app is not notarized (no Developer ID certificate), so macOS Gatekeeper requires manual approval on first launch. This is normal and safe.

## 🛠️ Development

Built with:
- Swift & SwiftUI
- macOS 13.0+
- Sparkle 2.x for auto-updates

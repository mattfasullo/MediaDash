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

## 🛠️ Development

Built with:
- Swift & SwiftUI
- macOS 13.0+
- Sparkle 2.x for auto-updates

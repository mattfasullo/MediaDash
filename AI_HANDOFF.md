# MediaDash AI Handoff Document

**Last Updated:** April 2026  
**Purpose:** Orient assistants and developers to the current architecture and main code locations.

---

## Project Overview

MediaDash is a macOS menu bar application that:

- Monitors Gmail for new docket notifications and file deliveries
- Parses email content with rule-based logic (`EmailDocketParser` and related helpers)
- Integrates with Asana for task management
- Manages media files with staging and filing workflows
- Provides a notification center for team coordination

**Tech stack:** Swift, SwiftUI, macOS native APIs (Security, Foundation).

---

## Email Processing Flow

```
Gmail API → EmailScanningService → EmailDocketParser / heuristics → NotificationCenter
```

Duplicate suppression uses `processedEmailIds` and `processedThreadIds` in `EmailScanningService`, plus deduplication in `NotificationCenter.add()` and `removeDuplicates()`.

---

## Key File Locations

| Area | Primary files |
|------|----------------|
| Email scanning | `MediaDash/Services/EmailScanningService.swift`, `MediaDash/Services/GmailService.swift` |
| Parsing | `MediaDash/Core/UseCases/EmailDocketParser.swift` |
| Notifications | `MediaDash/Core/Notifications/NotificationCenter.swift`, `NotificationModels.swift` |
| Notification UI | `MediaDash/Views/Notifications/` |
| Media | `MediaManager.swift` (project root), staging views under `MediaDash/Views/` |
| Keychain / OAuth | `MediaDash/Services/KeychainService.swift`, `SharedKeychainService.swift`, `OAuthService.swift` |
| Asana | `MediaDash/Services/AsanaService.swift`, `AsanaCacheManager.swift` |
| Settings | `MediaDash/SettingsView.swift`, `MediaDash/Settings.swift` |
| App entry | `MediaDash/MediaDashApp.swift`, `MediaDash/AppDelegate.swift` |

---

## Operational Notes

- **OAuth / secrets:** `MediaDash/Services/OAuthConfig.swift` is gitignored; use project conventions for local credentials.
- **Sparkle:** Historical release notes live in `appcast.xml`; do not rewrite old entries without a deliberate policy.
- **Build:** From repo root: `xcodebuild -scheme MediaDash -project MediaDash.xcodeproj -configuration Debug build`

---

## Testing

See `MediaDashTests/` for unit tests. Exercise Gmail scanning and notification flows after changes to parsing or deduplication.

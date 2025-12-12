# MediaDash AI Handoff Document

**Last Updated:** December 8, 2025
**Purpose:** Enable another AI assistant to continue development work on MediaDash

---

## Project Overview

MediaDash is a macOS menu bar application for Grayson Music Group that:
- Monitors Gmail for new docket notifications and file deliveries
- Uses CodeMind (AI-powered email classification) to categorize emails
- Integrates with Asana for task management
- Manages media files with staging and filing workflows
- Provides a notification center for team coordination

**Tech Stack:** Swift, SwiftUI, macOS native APIs (Security, Foundation)

---

## Recent Session Changes (December 8, 2025)

### 1. Notification Voting Fix
**Files:** `MediaDash/Views/Notifications/NotificationCenterView.swift`
- Fixed voting buttons not appearing for file delivery notifications
- Changed condition from requiring `codeMindMeta.wasUsed == true` to just checking if metadata exists

### 2. Duplicate Notification Prevention (Multi-layered)
**Files:**
- `MediaDash/Services/EmailScanningService.swift` - Added `processedThreadIds` tracking
- `MediaDash/Core/Notifications/NotificationCenter.swift` - Enhanced `add()` and `removeDuplicates()`
- `MediaDash/Services/CodeMindEmailClassifier.swift` - Fixed hardcoded 100% confidence for blocked emails

**Key Changes:**
- Track processed Gmail threadIds (not just emailIds)
- Check for duplicate docket+thread combinations before adding notifications
- Enhanced `removeDuplicates()` to clean up existing duplicates by threadId+docketNumber and docketNumber+jobName

### 3. Performance Optimizations
**Files:**
- `MediaDash/Views/CodeMindBrainView.swift` - Reduced physics timer from 60fps to 30fps
- `MediaDash/Services/AsanaCacheManager.swift` - Increased status check interval from 5s to 30s

### 4. File Progress Tracking
**Files:**
- `MediaDash/Services/MediaManager.swift` - Added `copyItemWithProgress()` for large file copy progress
- `MediaDash/Views/StagingAreaView.swift` - Clamped progress values to 0-1 range

**Implementation:** Streaming copy using InputStream/OutputStream with 1MB buffer and progress callbacks every 100ms

### 5. App Launch Speed
**Files:**
- `MediaDash/AppDelegate.swift` - Made keychain migration a detached task
- `MediaDash/Services/EmailScanningService.swift` - Made network operations (Gmail whitelist, CodeMind init) detached

---

## Optimization Sweep Results (42 Issues Found)

### HIGH PRIORITY

#### Performance Issues
1. **EmailScanningService.swift:~450** - `scanEmails()` fetches all emails then filters. Should use Gmail API query params.
2. **MediaManager.swift:~200** - Large file operations on main thread can block UI. Use background queues.
3. **NotificationCenter.swift:~100** - `notifications` array searched linearly. Consider dictionary for O(1) lookups.
4. **AsanaService.swift:~300** - Synchronous network calls. Ensure all are async/await.

#### Memory Issues
5. **CodeMindBrainView.swift** - Timer not invalidated on view disappear (partially fixed, verify)
6. **NotificationWindowManager.swift** - CVDisplayLink cleanup (fixed in previous session, verify)
7. **EmailScanningService.swift** - `processedEmailIds` grows unbounded. Add cleanup for old entries.

#### Thread Safety
8. **AsanaCacheManager.swift** - `@MainActor` but some closures may execute off main thread
9. **EmailFeedbackTracker.swift:~156** - File I/O on main actor could block

### MEDIUM PRIORITY

#### Code Quality
10. **SharedKeychainService.swift:55** - Redundant check: `hasSuffix` already covers `contains`
11. **KeychainService.swift:72** - `migrateItemIfNeeded` reads then deletes then stores - could lose data on failure
12. **NotificationModels.swift** - Consider using `@frozen` enum for performance
13. **CodeMindEmailClassifier.swift** - Large file (~1400 lines), consider splitting

#### SwiftUI Best Practices
14. **DashboardView.swift** - Complex view body, extract subviews
15. **SettingsView.swift** - Multiple `@State` could be consolidated into `@Observable`
16. **NotificationCenterView.swift** - Nested conditionals in view body, extract to computed properties

#### Network/I/O
17. **AsanaService.swift** - Missing retry logic for transient failures
18. **GmailService.swift** - Token refresh race condition possible
19. **MediaManager.swift** - No timeout on file operations

### LOW PRIORITY

#### Minor Optimizations
20. **Multiple files** - String interpolation in logging could use lazy evaluation
21. **NotificationCenter.swift** - `removeDuplicates()` creates multiple Set allocations
22. **CodeMindLogger.swift** - File writes not batched
23-42. Various minor code style, documentation, and optimization opportunities

---

## Key Architecture Notes

### Email Processing Flow
```
Gmail API → EmailScanningService → CodeMindEmailClassifier → NotificationCenter
                                         ↓
                                   (AI Classification)
                                         ↓
                              CodeMindClassificationMetadata
```

### Notification Deduplication Strategy
1. **First line:** Check `processedEmailIds` and `processedThreadIds` in EmailScanningService
2. **Second line:** Check threadId+docketNumber in NotificationCenter.add()
3. **Cleanup:** `removeDuplicates()` checks emailId, threadId+docketNumber, docketNumber+jobName

### Shared Keys System
- `SharedKeychainService.swift` - Manages team-shared API keys for Grayson employees
- `GraysonEmployeeWhitelist` - Gmail-authenticated whitelist for access control
- Falls back to personal keys if shared keys unavailable

### CodeMind Classification
- Uses multiple AI providers (Claude, OpenAI, Gemini, Grok)
- Classifies emails as: newDocket, mediaFiles (file delivery), request, junk, etc.
- Stores metadata for feedback/learning: confidence, reasoning, extractedData

---

## Known Issues / Technical Debt

1. **EmailScanningService.swift:77-79** - Fallback domain check marked "should eventually be removed"
2. **processedEmailIds/processedThreadIds** - Grow unbounded, need periodic cleanup
3. **Large file handling** - Progress tracking implemented but could use cancellation support
4. **CodeMind initialization** - Still somewhat slow, could be further optimized

---

## Testing Recommendations

1. **Duplicate Detection:** Send multiple replies to same thread, verify single notification
2. **File Progress:** Copy 1GB+ file, verify progress bar updates smoothly
3. **App Launch:** Cold start should feel responsive (network ops detached)
4. **Voting:** Test thumbs up/down on both new dockets AND file deliveries
5. **Keychain:** Update app version, should only prompt once (migration)

---

## File Locations Quick Reference

| Feature | Primary Files |
|---------|---------------|
| Email Scanning | `Services/EmailScanningService.swift` |
| CodeMind AI | `Services/CodeMindEmailClassifier.swift`, `Services/CodeMindLogger.swift` |
| Notifications | `Core/Notifications/NotificationCenter.swift`, `NotificationModels.swift` |
| Notification UI | `Views/Notifications/NotificationCenterView.swift`, `NotificationPopupView.swift` |
| Media Management | `Services/MediaManager.swift` |
| Keychain | `Services/KeychainService.swift`, `SharedKeychainService.swift` |
| Asana | `Services/AsanaService.swift`, `Services/AsanaCacheManager.swift` |
| Settings | `SettingsView.swift`, `Settings.swift` |
| App Entry | `MediaDashApp.swift`, `AppDelegate.swift` |

---

## Git Status at Handoff

Modified but uncommitted:
- AppDelegate.swift, ContentView.swift
- NotificationCenter.swift, NotificationModels.swift
- AsanaCacheManager.swift, AsanaService.swift
- CodeMindEmailClassifier.swift, CodeMindLogger.swift
- EmailScanningService.swift, KeychainService.swift
- MediaDashApp.swift, Settings.swift, SettingsView.swift
- Various view files

Untracked (new files):
- LAYOUT_EDITOR_USAGE.md
- DraggableLayoutModifier.swift
- EditModeInteractionBlocker.swift
- LayoutEditManager.swift

---

## Immediate Next Steps

1. **Commit current changes** - Many fixes are uncommitted
2. **Address HIGH priority issues** from optimization sweep
3. **Add cleanup mechanism** for processedEmailIds/processedThreadIds
4. **Consider splitting** CodeMindEmailClassifier.swift (1400+ lines)
5. **Add retry logic** to network services

---

*This document was generated to facilitate AI-assisted development continuity.*

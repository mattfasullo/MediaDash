# MediaDash — In-Depth Tutorial for Claude Cowork

**Document purpose:** Give Claude Cowork (or any AI assistant acting as a media-team teammate) a complete mental model of what MediaDash is, what it can do, how the UI and settings map to behavior, and how operators use it day to day. The final section suggests how to distill this into a **Cowork skill** (triggers, workflows, guardrails).

**Product:** MediaDash is a **native macOS application** (Swift / SwiftUI) for **post-production media operations**: staging files, filing into **Work Picture** and **SESSION PREP** (or equivalent) folder structures on a **shared server**, integrating **Asana** (dockets, calendar, prep flows), **Gmail** (new docket + file delivery notifications), **Simian** (project creation and uploads), **video tooling**, and a **notification center** for team coordination.

**Audience assumptions:** The operator has network access to the company server (often SMB), valid paths in Settings, and (where used) OAuth tokens in Keychain for Gmail/Asana.

---

## 1. High-level architecture (why things behave the way they do)

### 1.1 Runtime composition

After onboarding and login, a **Media Team Member** session wires together:

| Concern | Responsibility |
|--------|----------------|
| **SettingsManager** | Profiles stored in UserDefaults; path/theme/Gmail/Simian/etc. |
| **MediaManager** | Staging files, running file jobs, docket list from disk, video conversion hooks, caches for search |
| **DocketMetadataManager** | Per-docket metadata (CSV in Documents/MediaDash when not using Asana fields alone) |
| **AsanaCacheManager** | Synced Asana project data; optional **shared cache** JSON on server |
| **EmailScanningService** | Gmail polling, parsing, notification creation |
| **NotificationCenter** (app type) | In-app notifications list, statuses, grabbed state |
| **SimianService** | API client for Simian |
| **SessionManager** | Workspace profiles, optional sync of settings to shared storage |

Reference for developers: `AI_HANDOFF.md` in the repo root.

### 1.2 Email → notification flow (simplified)

```
Gmail API → EmailScanningService → EmailDocketParser (+ heuristics) → NotificationCenter (in-app)
```

Duplicate suppression uses processed message/thread IDs in the scanner and deduplication when adding notifications.

### 1.3 File job flow (simplified)

```
Staged files + chosen docket + job type → MediaManager.runJob → FileJobUseCase (background copy)
→ Work Picture dated subfolders and/or Prep category folders (PICTURE, MUSIC, AAF-OMF, OTHER, …)
```

---

## 2. Installation, updates, and first launch

### 2.1 Distribution

- Releases use **Sparkle** and **GitHub Releases** (see repo `README.md`, `RELEASE_GUIDE.md`).
- **Gatekeeper:** If the app is not notarized with Developer ID, first open may require **Right-click → Open**.

### 2.2 Updates

- **Production** feed: `appcast.xml` on the main branch (default in `UpdateChannel.production`).
- **Development** feed: `dev-builds/appcast-dev.xml` (`UpdateChannel.development`).
- Channel is configurable per profile in Settings.

### 2.3 Onboarding and login (`GatekeeperView`)

1. **First run:** `OnboardingView` runs until `hasCompletedOnboarding` is true (stored in `@AppStorage`).
2. Then **`LoginView`** appears until the user picks or creates a **workspace profile**.
3. **Logged-in routing by role:**
   - **Media Team Member** → full `AuthenticatedRootView` (main MediaDash UI).
   - **Producer** → `ProducerRootView` (Asana/Airtable-focused; no full staging stack).
   - **Tools** → `ToolsRootView` (sidebar + **Music Demos Latest** tool + settings).

Profiles can be **local** or **user** (username-based); user profiles can **sync settings** from shared storage with conflict resolution (newer wins or merge policy as implemented in `SessionManager`).

---

## 3. User roles — what each role is for

| Role | UI | Typical use |
|------|-----|-------------|
| **Media Team Member** | Sidebar + staging + notifications + calendar + Simian + archiver + video | Day-to-day filing, docket handling, deliveries |
| **Producer** | Tabs: **Dockets** \| **Contacts**; Asana cache; Airtable push; recent projects | Looking up jobs, pushing to Airtable, contacts CSV |
| **Tools** | Minimal rail + **MusicDemosLatestToolView** | Internal utilities; Music Demos “latest” workflow |

Role is part of `AppSettings` / onboarding; it changes which root view loads.

---

## 4. Main window layout (Media Team Member) — “Compact” mode

**Important:** In code, **Dashboard mode** exists (`DashboardView`, `WindowMode.dashboard`) but **`dashboardModeEnabled` is currently `false` in `ContentView`** — users effectively always get **compact** layout: **left sidebar (~300pt) + staging area**.

### 4.1 Sidebar (top to bottom)

1. **Logo** (theme-aware invert in light mode).
2. **Notification tab** + **server/Asana status indicator** — opens notification center; status reflects cache/server connectivity.
3. **Action button grid** (see §5).
4. **Divider**
5. **Search** (⌘F), **Job Info** (⌘D), **Archiver** (⌘⇧A) — linear stack below the grid.
6. Lower area: **docket list** and related controls (pick docket, dates, job type where surfaced in sidebar views — exact layout is in `SidebarView` / child views).

### 4.2 Staging area (`StagingAreaView`)

- **Drop files or folders** from Finder.
- Shows **queued items**, **progress**, **per-file state** for multi-step jobs (e.g. Work Picture + Prep in sequence).
- **Video** workflows may open separate sheets (see §8).
- After successful jobs, staging may **clear** depending on `StagingClearAfterFilingMode` (never / immediately / after delay) and video-related options.

### 4.3 Settings access

- **Gear** (top-right): opens **Settings** window (`SettingsWindowManager`).
- Menu: standard app menu includes **Check for Updates**, **Finder extension** helpers, **layout edit** commands (§12).

---

## 5. Action buttons — exact behaviors and shortcuts

Keyboard: **Arrow keys** move a virtual focus between buttons when the main area is focused; **Return** or **Space** activates. Holding **⌘** reveals shortcut badges on some buttons.

| UI control | Shortcut | Action |
|------------|----------|--------|
| **File** (Work Picture) | ⌘1 | Starts **Work Picture** job flow (`JobType.workPicture`). |
| **Simian** (Upload) | ⌘2 | Opens **Simian post** window (`SimianPostWindowManager`) — search projects, upload staged files. |
| **Calendar** (2 weeks) | ⌘3 | Opens **Asana full calendar** (`AsanaFullCalendarWindowManager`) for next two weeks. |
| **Video** | ⌘4 | Opens **popover** with **VideoView**: links to **Video Converter** sheet and **Restripe** window. |
| **Search** | ⌘F | Opens **search sheet** (docket/session/media postings per settings). |
| **Job Info** | ⌘D | Opens **quick search** sheet (default “Job Info” mode — `DefaultQuickSearch.jobInfo`). |
| **Archiver** | ⌘⇧A | Opens **Simian Archiver** (`SimianArchiverWindowManager`). |

**Context menu on File:** **“File + Prep”** — if `onFileThenPrep` is set, runs: stage → pick docket → file to Work Picture → then open prep for a **matching Asana calendar session** (same docket). Implemented via `attemptFileThenPrep` / `handleFileThenPrepConfirm` in `ContentView`.

### 5.1 “Attempt” semantics (`attempt(JobType)`)

When the user clicks **File**, **Prep**, or **Both** (where exposed):

1. **If staging is empty:** set `pendingJobType`, open **system file picker** (`manager.pickFiles()`).
2. **If staging has files:** set `pendingJobType` and open **docket selection sheet** — user must choose which docket receives the files.

This pattern prevents accidental jobs without a target docket.

---

## 6. Job types and filing semantics

### 6.1 `JobType`

- **`workPicture` — “Work Picture”**  
  - Resolves **year** from existing docket folder on server if possible; else current year.  
  - Under `…/{yearPrefix}{year}/{year}_{workPictureFolderName}/{docket}/` creates the **next numbered dated folder** (e.g. `01_Feb09.26`, `02_Feb09.26`) via `FolderNamingService` + `getNextFolder`.  
  - **Copies** staged items into that folder (not move — copy errors collected per file).

- **`prep` — “Prep”**  
  - Prep root: `…/{year}_{prepFolderName}/`.  
  - New folder name from `prepFolderFormat` (default pattern includes docket, job name, date token).  
  - Flattens nested files; assigns each file to **PICTURE / MUSIC / AAF-OMF / OTHER** (or skips if category disabled) from **extension lists** in settings.  
  - Runs **stem organization** helper after copy (`organizeStems`).

- **`both`**  
  - Runs Work Picture branch then Prep branch in one job (with completion states tracked in UI).

### 6.2 Category extension lists (settings defaults)

Defaults in `AppSettings.default` include typical **picture** (mp4, mov, …), **music** (wav, mp3, aiff, …), **aaf/omf** (aaf, omf). Operators can adjust in Settings.

### 6.3 Prep template subfolders

For prep created from **Sessions** staging flows, code ensures subfolders: **PICTURE, AAF-OMF, MUSIC, SFX** (and respects flags like `createPrepPictureFolder`).

### 6.4 Opening folders when done

Settings: `openPrepFolderWhenDone`, `openWorkPictureFolderWhenDone` — Finder can open the destination after success.

### 6.5 Staging clear behavior

- `stagingClearAfterFilingMode`: **never**, **immediately**, **afterDelay** (with `stagingClearDelayMinutes`, clamped 1…1440).
- Legacy `clearStagingAfterFiling` bool is migrated into the enum via `resolvedStagingClearAfterFilingMode`.
- Separate: **`clearStagingWhenDone`** for **video conversion** completion (when enabled).

---

## 7. Dates: Work Picture date vs Prep date

The UI exposes two dates (typically next to actions in sidebar parent views):

- **`wpDate`** — used when naming **Work Picture** dated subfolders.
- **`prepDate`** — used for prep folder naming; **business day** logic can apply via `BusinessDayCalculator` (weekends + **Canadian federal** holidays + custom ISO holidays in `customHolidays`).

Operators should verify dates before filing — they directly affect folder names.

---

## 8. Video tools

- **⌘4 / Video button:** `VideoView` popover — entry point only.
- **Video Converter** (sheet): batch conversion pipeline managed by `VideoConverterManager` (staging integration, completion sounds, optional staging clear).
- **Restripe:** `RestripeWindowManager` — separate window from popover action.

Sounds: `soundGlassCompletionEnabled` etc. control completion feedback (see Settings sound section).

---

## 9. Search and Job Info

### 9.1 Search folders (`SearchFolder`)

- **Work Picture** — docket folders under work picture trees.
- **Media Postings** — server areas used for postings (as implemented in indexer).
- **Pro Tools Sessions** — under `sessionsBasePath`.

Settings:

- **`defaultSearchFolder`** — default scope.
- **`searchFolderPreference`** — remember last vs always default.
- **`defaultQuickSearch`** — whether **⌘** type-to-open opens **Search** or **Job Info** sheet (`DefaultQuickSearch`).

### 9.2 Docket sort orders

`DocketSortOrder`: recently updated, docket number high/low, job name A–Z / Z–A — affects list ordering in UI.

### 9.3 Typing to open search

When **no sheet** is open and **no text field** is focused, typing a **single letter or digit** seeds `initialSearchText` and opens the configured default quick UI (**Search** or **Job Info**). **⌘** is ignored for this path so menu shortcuts still work.

---

## 10. Docket list and metadata

### 10.1 Where dockets come from (`DocketSource`)

- **Asana** — primary; uses cache + optional shared cache.
- **CSV** — metadata columns mapped in Settings.
- **Server Path** — scan filesystem for docket folders.

### 10.2 `DocketMetadataManager`

- Stores extended fields (client, producer, license totals, music type, track, media, notes, …).
- CSV path: `~/Documents/MediaDash/docket_metadata.csv` (auto-created directory).
- When Asana is source, Asana/custom fields still interact with job detail UIs — operators should keep **column mapping** in Settings aligned with the CSV export if used.

---

## 11. Asana integration

### 11.1 Workspace / project / custom fields

Settings fields: `asanaWorkspaceID`, `asanaProjectID`, optional **`asanaDocketField`** and **`asanaJobNameField`** when docket/job name live in custom fields.

OAuth tokens: **not** in plist — use Keychain (`SharedKeychainService` pattern per codebase).

### 11.2 Shared cache (team scale)

- **`sharedCacheURL`** + **`useSharedCache`**: prefer reading pre-synced JSON from a **mounted server path** so every Mac does not hammer Asana.
- Repo scripts: `sync_shared_cache.sh`, `verify_asana_sync.sh`, documented in `README_CACHE_SYNC.md` / `README_CACHE_SYNC_SETUP.md`.
- **Auto-sync in app:** On launch, if `docketSource == .asana` and token exists, app attempts `cacheManager.syncWithAsana(...)` with shared cache parameters. Hourly in-app sync is **disabled**; external launchd/cron is expected when using shared cache.

### 11.3 Calendar → Prep elements

- **Calendar** opens a **two-week Asana** window.
- Choosing a session can open **Calendar Prep** flow (`CalendarPrepWindowManager`) to build prep from **session metadata** (elements sheet under `Views/`).

---

## 12. Gmail, labels, and the notification center

### 12.1 Enabling Gmail

Settings: **`gmailEnabled`**, OAuth via Gmail service. **`gmailPollInterval`** default **3600** seconds (1 hour) after migration from older 300s default.

### 12.2 New docket detection

`EmailScanningService` uses a Gmail user label whose name must match exactly:

- **`New Docket`** (constant `newDocketGmailUserLabelName`)

Unread query (simplified): **unread** messages that either have that label **or** (if `companyMediaEmail` is set) are **recent unread to** the company media address (last **14** days) — so mis-labeled mail can still surface for **human review**.

Parser (`EmailDocketParser`):

- Uses **regex patterns** from settings (`docketParsingPatterns`) if non-empty; else **built-in defaults** (many formats: `25484-US`, `Docket: 12345 Job: …`, `NEW DOCKET`, bracketed docket, etc.).
- Requires **“docket intent”** heuristics (e.g. “new”+“docket” in body, early docket line, etc.) to reduce false positives.

**`requiresDocketConfirmation`:** If the message was not labeled `New Docket` but still parsed, the UI flags **review** before approval.

### 12.3 Notification types (`NotificationType`)

| Type | Operator meaning |
|------|------------------|
| **newDocket** | Parsed (or partially parsed) new job — approve to create **Work Picture folder** and/or **Simian project**. |
| **mediaFiles** | Shown in UI as **File Delivery** — links extracted (Drive, WeTransfer, Box, …) from whitelisted domains. |
| **request** | Team request — can be marked completed. |
| **error** / **info** | System or operational messages. |
| **junk** / **skipped** | Reclassify to remove noise (`reclassifiableTypes`). |

### 12.4 New docket approval → Simian + Work Picture

Per notification flags:

- **`shouldCreateWorkPicture`** (default true)
- **`shouldCreateSimianJob`** (default true)

On approve, logic (see `NotificationCenterView`):

1. May show **Simian project creation dialog** first when either system is targeted — user confirms **docket**, **job name**, **project manager** (defaults from email / Simian PM list).
2. Creates **Simian job** via `SimianService.createJob` if enabled and configured; handles “already exists”.
3. Creates **Work Picture docket folder** on disk when enabled and not duplicate.
4. Marks notification **completed** with **history note** (what succeeded/failed).

**Placeholder docket:** If no number parsed, generated pattern **`YYXXX`** (year suffix + literal XXX) can be used until human fixes it — documented in code paths like `handleApproveWithDocket`.

### 12.5 File deliveries and “grabbed” workflow

**File delivery** detection uses configurable:

- **`grabbedSubjectPatterns`** / **`grabbedSubjectExclusions`**
- **`grabbedAttachmentTypes`**
- **`grabbedFileHostingWhitelist`**
- **`grabbedSenderWhitelist`** (optional extra restriction)
- **`grabbedBodyExclusions`**
- **`mediaTeamEmails`** — who can “grab”
- **`companyMediaEmail`** — monitored inbox address

**Grabbed** state tracks thread ownership; **priority assist** if someone cannot access the file. Optional **“cursed image”** replies (`enableCursedImageReplies`, `cursedImageSubreddit`) replace boring auto-replies — usually off.

**Gmail thread replies** and read-state: service marks messages read when appropriate after actions.

### 12.6 Notification window

**`notificationWindowLocked`:** whether the notification panel tracks the main window.

---

## 13. Simian

### 13.1 Configuration

- **`simianEnabled`**, **`simianAPIBaseURL`**, credentials in **Keychain** (`simianUsername` / `simianPassword` in settings model but stored securely).
- **`simianProjectTemplate`** — template for **new** projects from notifications.
- **`simianProjectManagers`** — email list for default PM selection.

### 13.2 Post window

- Search existing Simian projects; upload **staged** media.

### 13.3 Archiver

- Separate **Archiver** window for archive-oriented Simian operations (wraps service calls configured in settings).

---

## 14. OMF / AAF validator

`MediaManager` owns `OMFAAFValidatorManager` with UI flag `showOMFAAFValidator` — operators can validate a selected OMF/AAF before or alongside handoff (exact entry point is in staging/menus; search codebase for `showOMFAAFValidator`).

---

## 15. Music Demos, writers, and local demo tasks

### 15.1 Year layout on server

`AppConfig.ensureYearFolderStructure()` creates standard year buckets including **`{year}_MUSIC DEMOS`**, `{year}_MUSIC LAYUPS`, `{year}_SESSION PREP`, `{year}_WORK PICTURE`, etc., when possible.

### 15.2 Composer → folder initials

- **`composerInitials`** map: Asana/display composer name → short folder token.
- **`displayNameForInitials`**: reverse map for UI and Asana subtasks.
- Defaults include a **preset table** for common composers (editable in Settings → section **MusicDemosComposerInitialsSection**).

### 15.3 `writers.json` and `local_media_tasks.json`

Stored under **`{serverBasePath}/_MediaDash/`** or prefer **`sharedCacheURL`** when that volume is mounted — team-wide writer list and **local media tasks** (demos rounds metadata).

### 15.4 Tools mode

`MusicDemosLatestToolView` exposes a **narrow** workflow for latest music demos without full media UI.

---

## 16. Finder integration and deep links

- **`FinderCommandBridge`**: handles **`onOpenURL`** from `MediaDashApp` — macOS can open the app with URLs from the **Finder Sync** extension.
- Menu: **Manage Finder Extensions…** opens system UI (`FIFinderSyncController.showExtensionManagementInterface()`).

Operators installing the extension get contextual commands that bridge into MediaDash.

---

## 17. Profiles, paths, and multi-machine

### 17.1 Profiles (`SettingsManager`)

- Multiple named profiles in UserDefaults; **`profileName`** inside each `AppSettings`.
- **Save** after material changes — many settings only persist on save.

### 17.2 Paths reset on app version bump

`resetPathsOnUpdateIfNeeded()` resets **path-related** fields to **`AppSettings.default`** when `CFBundleShortVersionString` changes — intentional so new installs don’t inherit broken paths from old machines. Operators should **re-verify paths** after each MediaDash update.

### 17.3 Default path pattern (Grayson-style)

Defaults (illustrative — always check live Settings):

- `serverBasePath`: `/Volumes/Grayson Assets/GM`
- `sessionsBasePath`: `/Volumes/Grayson Assets/SESSIONS`
- `yearPrefix`: `GM_`
- Work picture folder segment: `WORK PICTURE`
- Prep segment: `SESSION PREP`
- Shared cache: path under **Media Dept Misc.** (see `AppSettings.default.sharedCacheURL`)

---

## 18. Settings walkthrough (sections in `SettingsView`)

When training Cowork, treat each section as a **checklist** operators must align with facility standards:

1. **Profile** — name, role implications.
2. **Theme** — Modern vs Retro Desktop (beta); colors/typography differ.
3. **Sound effects** — completion / docket sounds and volumes.
4. **Paths** — server base, sessions base, connection URL, year prefix, folder names.
5. **Asana** — workspace, project, custom fields, token.
6. **Airtable** — base/table IDs, field mappings, music-type tags string (producer push).
7. **Contacts CSV** — producer “family tree” file path.
8. **Gmail** — enable, poll interval, parsing patterns override.
9. **Simian** — URL, credentials, template, PM emails.
10. **CSV column mapping** — when `docketSource == .csv`.
11. **General options** — browser (`BrowserPreference`), appearance, update channel, notification lock, staging clear, open-folder toggles, search defaults, skip weekends/holidays, docket sort, debug flag `showDebugFeatures`, etc.
12. **Music Demos composer initials** — maps for folder naming.

**Keychain-backed secrets** (Asana client secret, Gmail, Simian password, etc.) are **not** visible in plist — guide operators to reconnect OAuth / re-enter secrets if tokens expire.

---

## 19. Logging and support

- **File log:** `~/Library/Logs/MediaDash/mediadash-debug.log` (`FileLogger`).
- **Unified log:** subsystem `com.mediadash`.
- Helper script: `./get_logs.sh` (see `README_LOGGING.md`).

When Cowork helps debug, it should ask for **relevant time window** and optionally read that log file on the user’s machine if the user grants file access.

---

## 20. Menu commands worth knowing

From `MediaDashApp` / command groups:

- **Quit** — ⌘Q (rebound group).
- **Check for updates** (Sparkle).
- **Finder extension** management + help alert.
- **Layout edit mode** — ⌘⇧E toggle (`LayoutEditManager`) — draggable UI offsets for power users.
- **Export layout** — ⌘⌥E.
- **Undo / redo layout** — ⌘Z / ⌘⇧Z while editing layout.

---

## 21. Producer-specific UI (`ProducerRootView`)

- **Dockets tab:** `ProducerView` — search/push workflows tied to Asana cache and Airtable configuration.
- **Contacts tab:** `ContactsView` — reads **`contactsCSVPath`** (Company, Name, Email, Role, City, Country style tree).
- **Recent projects** sheet — reopens Asana projects from `producerRecentProjects`.
- **Services setup prompt** — optional first-run style prompt for Gmail/Asana/Simian connectivity.

---

## 22. Operational checklist (media team member — daily)

1. **Connect VPN / mount server** — verify status dot in sidebar.
2. **Open MediaDash** — confirm no path reset surprises after update.
3. **Scan notifications** — triage **new docket** vs **file delivery** vs junk.
4. **Stage files** — drag from Finder or pick files.
5. **Set wp/prep dates** if needed — holidays/weekends affect prep naming.
6. **Run File / Prep / Both** — complete docket picker.
7. **Simian** — post uploads; archiver when needed.
8. **Clear staging** — confirm auto-clear policy matches desk policy.
9. **Gmail hygiene** — ensure **`New Docket`** label applied by mail rules for clean auto-detection.

---

## 23. Limitations and flags Cowork should respect

- **Dashboard layout** is **disabled** in code (`dashboardModeEnabled == false`) even if `windowMode` exists in settings — do not instruct users to rely on dashboard until re-enabled.
- **Not all holidays** are modeled (e.g. Good Friday/Easter Monday noted as manual in `BusinessDayCalculator` comments).
- **Docket parsing** is heuristic — always prefer human confirmation when `requiresDocketConfirmation` or title says “review”.
- **Paths** are organization-specific — defaults in repo target **Grayson-style** layout; other facilities must retarget Settings.

---

## 24. Appendix — Turning this document into a **Claude Cowork skill**

Cowork skills usually have: **name**, **description** (when to load), **instructions** (procedures), **constraints**, and **examples**.

### Suggested skill metadata

- **Name:** `mediadash-media-team` (example).
- **Description:** “Use when the user is working in or asking about **MediaDash** (macOS), including staging, Work Picture, SESSION PREP, Asana, Gmail notifications, Simian, video conversion, archiver, Music Demos, shared Asana cache, or notification triage.”

### Suggested skill body (outline)

1. **Always** start by identifying **role** (media vs producer vs tools) — different roots.
2. **Never** assume paths — reference **profile Settings** and server mount.
3. **New docket flow:** label `New Docket` + unread; confirm **docket/job** before approve; respect toggles **Work Picture** / **Simian**.
4. **File job flow:** empty staging → file picker; non-empty → docket sheet; then `JobType` semantics.
5. **Keyboard:** ⌘1–4 main actions; ⌘F search; ⌘D job info; ⌘⇧A archiver; arrows+return for focus grid.
6. **Troubleshooting order:** mount/server path → Asana token/shared cache freshness → Gmail label/query → logs in `~/Library/Logs/MediaDash/`.
7. **Safety:** do not delete server data without explicit user instruction; MediaDash **copies** into jobs but operators may still duplicate work if they misuse dates/dockets.

### Example user queries the skill should catch

- “I filed to the wrong docket” — explain staging cannot undo copy; fix by moving files in Finder; adjust dates next time.
- “New docket not appearing” — check **`New Docket`** label, unread state, `gmailEnabled`, poll interval, parser patterns.
- “Job Info blank” — check `docketSource`, Asana cache sync, field mapping.

---

**End of tutorial.** For implementation details beyond UX, see `AI_HANDOFF.md` and the file table inside it. For release engineering, see `RELEASE_GUIDE.md` and `README.md`.

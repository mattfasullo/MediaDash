# Grayson Music Group — Process Guide for Claude
**Last Updated:** April 2026  
**Purpose:** This document encodes all Grayson Music Group workflows so Claude can operate as a knowledgeable, context-aware team tool without needing explanations every time.

---

## 1. Who We Are

**Grayson Music Group** is a Canadian music production and post-production company specializing in audio for advertising. The team creates original music, licenses tracks, and handles audio post-production (mixing, sound design) for TV, radio, web, and digital ad campaigns — primarily for Canadian advertisers and agencies.

**Company email domain:** `@graysonmusicgroup.com`  
**Company media email:** `media@graysonmusicgroup.com`  
**Server:** `192.168.200.200` — mounted as `/Volumes/Grayson Assets/`

---

## 2. Team & Roles

### Roles
- **Media Team Member** — Handles media files, session prep, filing, conversions, Simian archiving. Day-to-day file and session work.
- **Producer** — Manages dockets, Asana tasks, client communications, scheduling, budgets, licensing.

### Known Team Members
- **Matt Fasullo** (`mattfasullo@graysonmusicgroup.com`) — initials: `MF`
- **Kevin MacInnis** (`kevin@graysonmusicgroup.com`) — initials: `KJM`
- **Jeremy Ugro** (`jeremy@graysonmusicgroup.com`) — initials: `JU`
- **Kelly** (`kelly@graysonmusicgroup.com`) — Producer / Project Manager
- **Clare** (`clare@graysonmusicgroup.com`) — Producer / Project Manager
- **Sharon** (`sharon@graysonmusicgroup.com`) — Producer / Project Manager
- **Nicholas** (`nicholas@graysonmusicgroup.com`) — Producer / Project Manager

### Composers (with folder initials)
| Name | Initials/Folder Name |
|------|---------------------|
| Mark Domitric | MD |
| Jeff Milutinovic | JM |
| Andrew Austin | AA |
| Igor Correia | IC |
| Lowell Sostomi | LS |
| Tyson Kuteyi | TK |
| Tom Westin | TW |
| Kevin MacInnis | KJM |
| Jeremy Ugro | JU |
| Matt Fasullo | MF |
| Michael Goldchain | Goldie |
| Michael Go | MGo |

---

## 3. Docket System

### What is a Docket?
A **docket** is a job/project identifier. Every ad campaign or piece of work is assigned a docket number.

### Docket Number Format
- **5 digits**, where the **first 2 digits = year** (e.g., `25` = 2025, `26` = 2026)
- Optional **country code suffix**: `-US`, `-CA`, `-CAN` (e.g., `25484-US`)
- Examples: `26115`, `25483`, `26053-US`

### Docket Naming Convention (files/folders)
`{docketNumber}_{JobName}` — e.g., `26115_Bell World Cup`, `25483_HH - End of Year Sizzle`

### Docket Sources
- **Asana** — primary source of truth for all dockets
- **Email** — new dockets arrive via Gmail; auto-parsed from subject/body
- Docket numbers are validated against: current year prefix and next year prefix only

### Docket Metadata Fields
Each docket tracks: docket number, job name, client, producer (Grayson), status, license total, currency, agency, agency producer, music type, track, media, notes.

---

## 4. Folder & File Structure

### Server Base Paths
- **Work Picture / Media:** `/Volumes/Grayson Assets/GM/`
- **Pro Tools Sessions:** `/Volumes/Grayson Assets/SESSIONS/`
- **Shared Cache:** `/Volumes/Grayson Assets/MEDIA/Media Dept Misc. Folders/Misc./MediaDash_Cache/`

### Server Year-Folder Prefix
All year folders are prefixed with `GM_` — e.g., `GM_2026`

### Standard Project Folder Structure
Every docket/project folder follows this hierarchy (from intake to delivery):

```
{DocketNumber}_{JobName}/
├── SESSION PREP ELEMENTS/    ← Incoming files from agency: OMF/AAF, picture, music, etc.
├── PROTOOLS SESSIONS/        ← Pro Tools session files (.ptx, .ptxt)
├── PICTURE/                  ← Video reference files (MP4, MOV, MXF, ProRes)
├── CASTINGS/                 ← Casting audio files
├── POSTINGS/                 ← Dated delivery rounds
│   ├── 01_Mar25.26/          ← Round 1 (date format: MMMdd.yy)
│   │   ├── 01_Fullmixes/
│   │   │   ├── TV/
│   │   │   └── WEB/
│   │   ├── 02_Mixouts/
│   │   └── 03_Quicktimes/
│   ├── 02_Apr2.26/           ← Round 2
│   └── REVISIONS/            ← Ad-hoc revisions
├── APPROVALS/                ← Approved versions for archiving
└── FINALS/                   ← Final locked deliverables
```

### Work Picture Folder Naming
Format: `{sequenceNumber}_{date}` — e.g., `01_Feb09.26`, `02_Mar15.26`
- Sequence numbers are zero-padded: `01`, `02`, `03`...
- Date format is always `MMMdd.yy` (e.g., `Feb09.26`, `Apr15.26`)

### Session Prep Folder Naming
Format: `{docket}_{jobName}_PREP_{date}` — e.g., `26115_Bell World Cup_PREP_Apr15.26`

### Posting/Round Folder Naming
Format: `{sequenceNumber}_{date}` — e.g., `01_Mar25.26`, `02_Apr2.26`

### File Categories & Extensions
| Category | Extensions |
|----------|-----------|
| Picture/Video | mp4, mov, avi, mxf, prores, m4v |
| Music/Audio | wav, mp3, aiff, aif, flac, m4a, aac |
| AAF/OMF | aaf, omf |

---

## 5. Email & New Docket Intake Process

### How New Dockets Arrive
1. Producers receive a **"New Docket" email** from an agency or client
2. Gmail is scanned every hour for new emails
3. Email is parsed to extract: docket number + job name
4. A new docket notification is surfaced in MediaDash

### Email Parsing Rules
- Docket numbers must start with a valid 2-digit year prefix (current or next year)
- Key signals for docket intent: email contains "new" + "docket", or a `DDDDD JobName` line near the top, or "docket ... DDDDD" keyword pattern
- Formats recognized: `25484-US`, `Docket: 12345 Job: Name`, `NEW DOCKET 12345 - Name`, `[12345] Name`, `12345_JobName`
- Docket number validation: exactly 5 digits (optionally `-XX` suffix), year-prefixed

### File Delivery Emails
- Sent to `media@graysonmusicgroup.com`
- Qualified by subject keywords: `audio`, `sfx`, `mix`, `omf`, `aaf`, `prep`, `elements`, `avtc`, `dc`, `offline`
- File hosting services used: Google Drive, WeTransfer (wdrv.it / wetransfer.com), Box, Frame.io (f.io), School Editing (psi.schoolediting.com)
- Media team "grabs" the delivery — replies with confirmation
- Optional fun feature: reply with a random image from a subreddit instead of text

---

## 6. Session Prep Workflow

When the media team receives a new session to prep:

1. **Receive files** — OMF/AAF, picture reference, music files come via email or file hosting link
2. **Stage files** — Drop files into MediaDash staging area
3. **Create prep folder** — Auto-named `{docket}_{jobName}_PREP_{date}` inside SESSION PREP folder
4. **Sort files into subfolders:**
   - `PICTURE/` — video reference files
   - `MUSIC/` — audio/music files
   - `AAF-OMF/` — OMF/AAF interchange files
   - `OTHER/` — anything else
5. **Open folder** — Prep folder opens automatically when done
6. **Load into Pro Tools** — Engineer opens session, imports elements

---

## 7. Work Picture / Media Filing Workflow

When a new cut of picture arrives from the agency:

1. **Receive picture file** — Usually MP4, MOV, MXF, or ProRes
2. **Stage the file** in MediaDash
3. **File to Work Picture folder** — Creates/uses next sequential dated subfolder (e.g., `02_Apr15.26`) inside the `WORK PICTURE` folder for the docket
4. **Folder opens automatically** when filing is done

---

## 8. Postings / Deliveries Workflow

When a mix or version is ready to deliver to the agency:

1. **Create posting folder** — Sequential numbered + dated folder inside `POSTINGS/` (e.g., `03_Apr7.26`)
2. **Organize deliverables:**
   - `01_Fullmixes/` → `TV/` and `WEB/` subfolders
   - `02_Mixouts/` — individual stems/mixouts
   - `03_Quicktimes/` — video + audio combined QT files
3. **Post to Simian** — Upload to `graysonmusic.gosimian.com` for agency review
4. **Notify agency** via email that files are posted

---

## 9. Simian Archive Workflow

Simian is the client-facing media delivery and archiving platform.

- **URL:** `https://graysonmusic.gosimian.com`
- **API:** `https://graysonmusic.gosimian.com/api/prjacc`
- **Purpose:** Upload finished audio/video files for agency/client review and approval
- **Project structure:** Each Simian project mirrors the docket (e.g., `26115_Bell World Cup`)
- **Subfolders:** Match the posting structure — splits (acapella/instrumental), fullmixes, etc.
- **File types posted:** Audio files (WAV, AIFF), sometimes MP4 Quicktimes
- **Project managers notified on posts:** kelly, clare, sharon, nicholas

---

## 10. Asana Integration

Asana is the primary project management tool.

- All dockets exist as Asana tasks/projects
- **Calendar view** shows: Sessions (recording/mix dates), Media Tasks (delivery deadlines)
- **Music Type tags** used: Original Music, Stock Music, Licensed Music
- When a new docket is approved, Asana is updated with session dates, delivery dates
- **Subtasks** are created per composer for Music Demos folders

---

## 11. Video Conversion / Restriping

When delivering audio to picture:

- **Restriping** = replacing the audio track on a video file (QT/MP4) with the new mix
- Tool: FFmpeg (auto-installed by MediaDash)
- Output formats: TV (broadcast spec), WEB (web/digital spec)
- Files staged in MediaDash → converted → saved to appropriate `POSTINGS` subfolder

---

## 12. Music Demos Workflow

- Composers pitch demos for projects
- Demo folders are organized by composer initials under a `MUSIC DEMOS` or similar folder
- Folder name = composer initials/nickname (see composer list above)
- Dated subfolders: `01_Feb09.26`, `02_Mar15.26` etc.

---

## 13. Key Naming Conventions Summary

| Item | Format | Example |
|------|--------|---------|
| Docket number | 5 digits (YY + sequence) | `26115` |
| Docket with country | 5 digits + `-XX` | `25484-US` |
| Docket folder | `{num}_{JobName}` | `26115_Bell World Cup` |
| Date stamp | `MMMdd.yy` | `Apr15.26`, `Feb09.26` |
| Work picture subfolder | `{nn}_{date}` | `01_Feb09.26` |
| Posting round folder | `{nn}_{date}` | `03_Apr7.26` |
| Prep folder | `{docket}_{jobName}_PREP_{date}` | `26115_Bell World Cup_PREP_Apr15.26` |
| Composer demo folder | Initials/nickname | `MD`, `KJM`, `Goldie` |

---

## 14. Business Calendar

- Grayson operates on **Canadian business days**
- Canadian Federal Holidays observed: New Year's Day, Victoria Day, Canada Day, Labour Day, Thanksgiving (Canadian — 2nd Monday of October), Christmas, Boxing Day
- Sessions and deadlines skip weekends and holidays

---

## 15. File Hosting & Delivery Services Used

| Service | Domain |
|---------|--------|
| Google Drive | drive.google.com, docs.google.com |
| WeTransfer | wetransfer.com, wdrv.it |
| Box (WPP) | wpp.box.com, box.com |
| Frame.io | f.io |
| School Editing | psi.schoolediting.com |

---

## 16. How Claude Should Operate

Given the above, Claude should:

1. **Always know the docket format** — 5-digit year-prefixed number, optional `-XX` country code
2. **Know the folder structure** — SESSION PREP → PROTOOLS → PICTURE → CASTINGS → POSTINGS → APPROVALS → FINALS
3. **Know date formatting** — always `MMMdd.yy` (e.g., `Apr15.26`)
4. **Know the team** — refer to team members by first name; know their initials for composer folders
5. **Know the tools** — Pro Tools for audio, Simian for client delivery, Asana for task management, Airtable for data, Gmail for intake
6. **Know the server paths** — `/Volumes/Grayson Assets/GM/` for work, `/Volumes/Grayson Assets/SESSIONS/` for Pro Tools
7. **Understand delivery rounds** — postings are sequential dated folders; each round has Fullmixes (TV + WEB), Mixouts, Quicktimes
8. **Understand roles** — Media Team handles files/sessions; Producers handle client comms/scheduling
9. **Assume Canadian context** — holidays, currency (CAD), industry (advertising/broadcast)
10. **Default to asking for docket number** when work involves a specific job — it's the primary identifier for everything

---

## 17. Common Tasks Claude Can Help With

- **Create a new docket folder structure** on the server
- **Name files and folders** correctly using Grayson conventions
- **Parse a "new docket" email** and extract docket number + job name
- **Draft a "files posted to Simian" email** to the agency
- **Draft a "files grabbed" reply** to a media delivery email
- **Create an Asana task** or update task status for a docket
- **Check what's due** by reading the Asana calendar
- **Suggest next posting round number** based on existing folders
- **Rename files** to match Grayson naming conventions
- **Summarize a docket's history** from folder structure or Asana
- **Write session notes** or a session brief

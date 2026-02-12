# MediaDash v0.9.12 - Release Notes

## 🎉 New Features

### 📅 Asana Calendar Views
- **Session Prep Calendar** - View your upcoming sessions from today through the next 5 business days, organized by date
- **Full 2-Week Calendar** - Comprehensive calendar view showing all sessions, media tasks, and other tasks across 14 days
  - Click any day to expand and see detailed information
  - Filter by Sessions, Media Tasks, or Other Tasks
  - Collapsible sections for better organization
  - Tag colors for easy visual identification

### 📋 Task Detail Window
- **Resizable Task Detail Window** - Task details now open in their own separate, resizable window
  - Consistent window size that stays the same when switching apps
  - Drag and resize to your preferred size
  - No more window resizing issues when using Cmd+Tab
  - Works for Demos, Post, and other task types

### 🎵 Demos/Submit Task Improvements
- **Enhanced Demos Task View** - Completely redesigned interface for managing demo submissions
  - **Composer Organization** - Track submissions by composer with a spreadsheet-like table layout
  - **Color Tracking** - Assign colors to tracks by name (organized by composer)
  - **Freelance/Extra Composers** - Separate section for freelance and extra composers
  - **Completed Task Visibility** - Completed tasks stay visible with checkmarks and greyed-out appearance
  - **Unified Task Names** - Both "DEMOS" and "SUBMIT" task names are treated as demos tasks
  - **Track Status** - See which tracks are in use and which composers are submitting

### 📝 Posting Legend
- **Copy to Clipboard** - One-click button to copy the posting legend to your clipboard
- **Editable Post Task Description** - Edit the Post task description directly in MediaDash
- **Save to Asana** - Save your edited description and posting legend directly to the Post task in Asana
- **Automatic Formatting** - Posting legend automatically formats as "COLOUR - INITIALS - FILENAME"

### 📥 Download Prompt
- **Smart Download Detection** - When you download a file in your browser, MediaDash detects it automatically
- **"Use with MediaDash?" Popup** - Convenient popup appears in the top-right corner asking if you want to stage the downloaded file
- **One-Click Staging** - Click "Use with MediaDash" to instantly add the file to your staging area
- **Automatic Cleanup** - Popup automatically dismisses after a short time if you don't interact with it

### 🗂️ Session Prep Elements
- **Drag-and-Drop File Assignment** - Drag files from staging onto description lines to assign them
- **Description-Based Checklist** - Each line of the session description becomes a checklist item when files are assigned
- **Multiple View Modes** - View staged files by folder, by file type, as a flat list, or organized by description line
- **Visual Assignment Indicators** - See which files are assigned to which checklist items at a glance
- **Prep from Calendar** - Start prep directly from calendar sessions with all elements pre-loaded

### 📁 Manual Prep Sheet
- **Interactive Prep Checklist** - Create and manage prep checklists with file assignments
- **File Assignment Interface** - Assign files to specific checklist items
- **Visual File Organization** - See staged files alongside your checklist
- **Flexible Workflow** - Run prep with or without checklist assignments

## 🔧 Improvements & Enhancements

### ⚙️ Settings Window
- **Separate Settings Window** - Settings now open as a separate, resizable window instead of a sheet
  - Can be minimized and moved independently
  - Window size persists between sessions
  - Better for multi-monitor setups
- **Cleaned Up Interface** - Removed unused and irrelevant settings sections
  - Removed unused Mode selector (Producer/Engineer/Admin)
  - Removed Project Managers section from Simian Integration
  - Removed Work Culture Enhancements section

### 📂 Folder Naming & Organization
- **Standardized Date Format** - All dates now use consistent format (MmmDD.YY, e.g., "Feb09.26")
- **Prep Folder Format** - Prep folders now include job name in the format: `{docket}_{jobName}_PREP_{date}`
  - Example: `25464_TD Insurance_PREP_Feb09.26`
  - Customizable format string in settings
- **Centralized Naming Service** - New FolderNamingService ensures consistency across the entire app
- **Better Folder Parsing** - Improved detection and parsing of existing folders

### 🛠️ Technical Improvements
- **Better Resource Management** - Enhanced memory management with proper cleanup of timers and observers
- **Improved Error Handling** - More robust error handling throughout the application
- **Performance Optimizations** - Various performance improvements for smoother operation
- **Code Quality** - Better code organization and maintainability

## 🐛 Bug Fixes

- Fixed download prompt window crash (removed invalid collection behavior)
- Fixed window resizing issues when switching between apps
- Improved stability and reliability across the application

## 📊 Statistics

- **55 files changed**
- **8,314 additions, 1,930 deletions**
- Major new features: Calendar views, Task detail window, Download prompt, Session prep elements
- Significant improvements to existing features: Demos/Submit tasks, Settings, Folder naming

---

**Note:** This release includes significant improvements to the Asana integration, file organization, and user workflow. The new calendar views and task detail window make it easier than ever to manage your sessions and tasks, while the download prompt streamlines your file workflow.

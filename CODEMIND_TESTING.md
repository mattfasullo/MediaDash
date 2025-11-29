# How to See CodeMind in Action

## Quick Start

1. **Open Notification Center**
   - Press `⌘` + `` ` `` (backtick) OR
   - Click the notification icon in the sidebar

2. **Trigger Email Scan**
   - The notification center will auto-scan when opened (if >30 seconds since last scan)
   - Or click the "Scan Emails" button if available
   - Or wait for automatic periodic scanning (every 5 minutes by default)

3. **Watch the Console**
   - Open Xcode's console (View → Debug Area → Activate Console)
   - Look for CodeMind messages

## What to Look For

### When CodeMind Initializes (on app start):
```
CodeMindEmailClassifier: ✅ Initialized and enabled for email classification
```

### When Scanning Emails:
```
EmailScanningService: 🤖 Using CodeMind to classify email...
CodeMind Classification Result:
  Is New Docket: true/false
  Confidence: 0.95
  Docket Number: 12345
  Job Name: Client Name
  Reasoning: This email announces a new project...
EmailScanningService: ✅ CodeMind successfully extracted docket info
```

### For File Delivery Emails:
```
EmailScanningService: 🤖 Using CodeMind to classify file delivery email...
CodeMind File Delivery Classification Result:
  Is File Delivery: true
  Confidence: 0.92
  File Links: [https://...]
  Services: ["Dropbox", "WeTransfer"]
  Reasoning: This email contains file sharing links...
```

## Testing Steps

### 1. Verify CodeMind is Initialized
- Check console on app launch for initialization message
- If you see "No API key found", go to Settings → CodeMind AI and add your key

### 2. Test with Real Emails
- Make sure you have unread emails in Gmail
- Open Notification Center (⌘ + `)
- Watch console for CodeMind activity

### 3. Compare Results
- CodeMind will show its classification and confidence
- If confidence ≥ 70%, it uses CodeMind's result
- Otherwise falls back to regular parser
- You'll see both attempts in the logs

## Debug Features

If you have `showDebugFeatures` enabled in Settings:
- You can run a debug scan from the notification center
- This will show detailed information about email processing
- CodeMind activity will be included in debug output

## Expected Behavior

**With CodeMind:**
- More accurate classification
- Better extraction of docket numbers and job names
- Understands context (not just pattern matching)
- Learns from your email patterns over time

**Console Output:**
- Look for 🤖 emoji = CodeMind is working
- ✅ = CodeMind successfully classified
- ❌ = CodeMind determined it's NOT that type of email
- Falls back to regular parser if CodeMind confidence is low

## Troubleshooting

**No CodeMind messages?**
- Check Settings → CodeMind AI → Test connection
- Verify API key is saved (should show "CodeMind is active")
- Check console for initialization errors

**CodeMind not being used?**
- Check confidence scores in logs
- If confidence < 70%, it falls back to regular parser
- This is normal for edge cases

**Want to force CodeMind?**
- Currently uses CodeMind when confidence ≥ 70%
- You can adjust the threshold in `EmailScanningService.swift` if needed


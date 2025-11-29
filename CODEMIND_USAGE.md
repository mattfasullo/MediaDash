# CodeMind Integration Guide

CodeMind has been integrated into MediaDash to help intelligently classify emails and identify:
- **New Docket Emails** - Emails announcing new projects/jobs
- **File Delivery Emails** - Emails containing file sharing links

## Setup

1. **Set your API key** (choose one):
   ```bash
   # For Claude (recommended)
   export ANTHROPIC_API_KEY="sk-ant-..."
   
   # OR for OpenAI
   export OPENAI_API_KEY="sk-..."
   ```

2. **CodeMind will automatically initialize** when MediaDash starts if an API key is found.

## How It Works

### New Docket Email Classification

CodeMind analyzes email content (subject + body) to determine if it's a new docket email. It:
- Understands context better than pattern matching
- Extracts docket numbers and job names intelligently
- Provides confidence scores
- Falls back to regular parser if confidence is low

### File Delivery Email Classification

CodeMind identifies emails that contain file sharing links:
- Detects various file hosting services (Dropbox, WeTransfer, Google Drive, etc.)
- Understands context (not just link detection)
- Extracts all file links from the email
- Provides reasoning for its classification

## Usage

CodeMind is **automatically enabled** when:
- An API key is set in environment variables
- The email scanning service initializes

The system will:
1. Try CodeMind classification first (if enabled)
2. Use results if confidence ≥ 70%
3. Fall back to regular pattern matching if CodeMind is unavailable or confidence is low

## Logging

Look for these log messages to see CodeMind in action:

```
CodeMindEmailClassifier: ✅ Initialized and enabled for email classification
EmailScanningService: 🤖 Using CodeMind to classify email...
CodeMind Classification Result:
  Is New Docket: true
  Confidence: 0.95
  Docket Number: 12345
  Job Name: Client Name
  Reasoning: This email announces a new project...
```

## Disabling CodeMind

If you want to disable CodeMind and use only the regular parser:

1. Remove the API key from environment variables
2. Or modify `EmailScanningService` to call `setUseCodeMind(false)`

## Benefits

- **Better accuracy** - Understands context, not just patterns
- **Handles edge cases** - Works with unusual email formats
- **Extracts metadata** - Can identify agency, client, PM names
- **Self-improving** - CodeMind learns from your codebase context

## Cost Considerations

CodeMind uses API calls to Claude/OpenAI. Each email classification uses ~1 API call. Monitor your usage if processing many emails.


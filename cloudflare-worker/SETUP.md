# MediaDash APNs Relay — Setup Guide

## Overview

```
Airtable record created
   → Airtable Automation (HTTP POST /webhook)
      → Cloudflare Worker
         → Apple Push Notification service (APNs)
            → MediaDash on each registered Mac
               → New Docket notification appears in-app instantly
```

---

## 1. Apple Developer Portal

1. Go to [developer.apple.com](https://developer.apple.com) → **Certificates, Identifiers & Profiles**.
2. Under **Identifiers**, find `mattfasullo.MediaDash`.
3. Enable the **Push Notifications** capability and save.
4. Under **Keys**, click **+** → name it `MediaDash APNs Key` → enable **Apple Push Notifications service (APNs)** → continue.
5. **Download the `.p8` file** and note the **Key ID** (10 chars, shown on the key detail page).
6. Your **Team ID** is shown in the top-right of the developer portal.

> ⚠️ You can only download the `.p8` once. Store it safely.

---

## 2. Cloudflare Worker

### 2a. Create the Worker

1. Sign up at [cloudflare.com](https://cloudflare.com) (free).
2. Dashboard → **Workers & Pages** → **Create** → **Create Worker**.
3. Name it `mediadash-relay` → **Deploy**.
4. Click **Edit code** → paste the contents of `worker.js` → **Deploy**.

### 2b. Create a KV namespace

1. Dashboard → **Workers & Pages** → **KV** → **Create a namespace** → name it `DEVICE_TOKENS`.
2. Open your `mediadash-relay` Worker → **Settings** → **Bindings** → **Add binding**:
   - Variable name: `DEVICE_TOKENS`
   - KV namespace: `DEVICE_TOKENS`

### 2c. Set environment variables

In the Worker **Settings** → **Variables** → **Environment Variables**, add:

| Variable | Value |
|---|---|
| `SHARED_SECRET` | Any random string you choose (e.g. `sk_mediadash_abc123xyz`) |
| `APNS_PRIVATE_KEY` | Full content of the `.p8` file (paste everything including `-----BEGIN PRIVATE KEY-----` lines) |
| `APNS_KEY_ID` | The 10-char key ID from step 1.5 |
| `APNS_TEAM_ID` | Your 10-char Team ID from step 1.6 |
| `APNS_BUNDLE_ID` | `mattfasullo.MediaDash` |

Mark `APNS_PRIVATE_KEY` and `SHARED_SECRET` as **encrypted**.

Your Worker URL will be something like: `https://mediadash-relay.yourname.workers.dev`

---

## 3. MediaDash Settings

In MediaDash **Settings** → wherever Airtable settings live, set:

- **Detection mode**: `Airtable`
- **Worker URL**: `https://mediadash-relay.yourname.workers.dev`
- **Worker secret**: the `SHARED_SECRET` value you set above

On next launch, MediaDash will request notification permission and register automatically.

---

## 4. Airtable Automation

1. In your Airtable base, open **Automations** → **+ New automation**.
2. **Trigger**: `When a record is created` → select your dockets table.
3. **Action**: `Run a script` or `Send a webhook`.

If using **Send a webhook**:
- **URL**: `https://mediadash-relay.yourname.workers.dev/webhook`
- **Method**: POST
- **Headers**: `X-MediaDash-Secret: <your SHARED_SECRET>`
- **Body** (JSON):
  ```json
  {
    "docketNumber": "{{Docket}}",
    "jobName": "{{Project Title}}",
    "recordId": "{{Record ID}}"
  }
  ```
  Replace `Docket`, `Project Title` with your actual Airtable field names.

4. Test the automation with an existing record — you should see `{"success":true,"sent":1}` in the response.

---

## 5. Production build note

The entitlement in `MediaDash.entitlements` is currently set to `development` (for Xcode testing).
Before shipping a public release, change it to `production`:

```xml
<key>com.apple.developer.aps-environment</key>
<string>production</string>
```

And rebuild your distribution archive.

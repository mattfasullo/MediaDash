# One-time setup: run releases from Cursor agent

Complete these steps **once** on your Mac so the Cursor agent can run `./release.sh` and ship updates (build, sign, appcast, GitHub release) for you.

## 1. Use full Xcode (required for `xcodebuild`)

The agent runs in an environment where the active developer directory may be Command Line Tools only. Switch it to the full Xcode app:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Verify:

```bash
xcode-select -p
# Should print: /Applications/Xcode.app/Contents/Developer
```

If you don’t have Xcode installed: install from the Mac App Store, then run the command above.

## 2. GitHub CLI (for push and `gh release create`)

If you haven’t already (e.g. for git push from Cursor):

```bash
brew install gh
gh auth login
gh auth setup-git
```

## 3. Sparkle `sign_update` and private key

The release script expects Sparkle’s `sign_update` binary in the project root (executable).

**So the agent can sign when it runs the release**, use a key file and tell the script where it is:

1. Put your Sparkle **private** key in a file **outside** the repo (e.g. `~/sparkle_mediadash_private_key` or `~/.config/mediadash_sparkle_key`). You may already have this from when you ran `generate_keys`.
2. In the project root, create a **gitignored** file that contains only the path to that key file:
   ```bash
   echo '/Users/YOUR_USERNAME/path/to/your/sparkle_private_key' > .sparkle_key_path
   ```
   (Use your real path; no newlines. This file is in `.gitignore` as `.sparkle_key_path`.)
3. When the agent runs `release.sh`, it will read `.sparkle_key_path` and pass `--ed-key-file` to `sign_update`.

If you prefer not to use a path file, you can set the env var when running locally: `SPARKLE_PRIVATE_KEY_FILE=/path/to/key ./release.sh ...`

## 4. (Optional) Accept Xcode license

If you’ve never run Xcode or accepted the license:

```bash
sudo xcodebuild -license accept
```

---

## Releasing from either computer

To run `./release.sh` (or have the agent run it) from **both** your laptop and this computer you need the Sparkle private key in a **file** on both machines. Do this once from the laptop (where the key lives in Keychain).

### Get the key into a file (on the laptop)

**Important:** MediaDash does **not** include `generate_keys`—only `sign_update`. So `./generate_keys` from the project folder does nothing. Use one of these:

**Option A – Export with Sparkle’s `generate_keys` (on the laptop)**

1. Get the `generate_keys` binary on the laptop:
   - Either download a Sparkle release that includes it: [Sparkle Releases](https://github.com/sparkle-project/Sparkle/releases) → pick a release → look for an asset like `generate_keys` or a .tar.xz that contains it.
   - Or find it from Xcode’s Sparkle package:  
     `find ~/Library/Developer/Xcode/DerivedData -name "generate_keys" -type f 2>/dev/null`
2. In Terminal **on the laptop**, run it with the **full path** to the binary and an **absolute path** for the output file, for example:
   ```bash
   /path/to/generate_keys -x /Users/YOUR_LAPTOP_USERNAME/sparkle_mediadash_private_key
   ```
   Use the real path to `generate_keys` and a path where you want the file (e.g. `~/sparkle_mediadash_private_key`). The tool may not print anything; check that the file was created: `ls -la ~/sparkle_mediadash_private_key`. To see supported options (e.g. export flag name): `./generate_keys --help` or `./generate_keys -h`.

**Option B – Copy from Keychain Access (no `generate_keys` needed)**

1. On the **laptop**, open **Keychain Access**.
2. Search for **Sparkle** or **ed25519** (or look in “Passwords” / “login” keychain).
3. Double‑click the Sparkle/EdDSA key item → check **“Show password”** and authenticate.
4. Copy the **password** (the long string—that’s the private key). Paste it into a new TextEdit document.
5. Save as plain text with a name like `sparkle_mediadash_private_key` (no extension), e.g. in your home folder or `~/.config/`. **Do not** commit this file.
6. That file is exactly what `sign_update --ed-key-file` expects (one line: the private key string, no extra text). Copy this file to the other computer (USB, AirDrop, etc.) and use it there too.

**Then:**

2. **Put the key file on both machines**  
   Copy that file to this computer (USB, AirDrop, etc.). Keep it outside the repo on each machine (e.g. `~/sparkle_mediadash_private_key` or `~/.config/mediadash_sparkle_key`). Don’t commit the key file.

3. **Point the script at the key on each machine**  
   On **each** computer, in the project root, create `.sparkle_key_path` (gitignored) with one line: the **full path** to the key file **on that machine**:
   - Laptop: `echo '/Users/laptopuser/sparkle_mediadash_private_key' > .sparkle_key_path`
   - This computer: `echo '/Users/mediamini1/.config/mediadash_sparkle_key' > .sparkle_key_path`  
   Paths can differ per machine; each has its own `.sparkle_key_path`.

4. **Same repo, same script**  
   Pull the latest on whichever machine you’re using, then run `./release.sh <version> "<notes>"` (or ask the agent to run it on this computer). Both machines use the same Sparkle key, so updates verify correctly.

**Summary:** One key file, copied to both Macs; each Mac has its own `.sparkle_key_path` pointing at that file locally. Then you can push an update from either computer.

---

After this one-time setup, you can ask the agent to run a release, e.g.:

- “Run the release for 1.02 with notes: …”
- “Release the app with version 1.02”

The agent will run `./release.sh 1.02 "your notes"` with the right permissions.

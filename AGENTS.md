# MediaDash Development Notes

## Cursor Cloud specific instructions

### Platform constraints

MediaDash is a **macOS-native** Swift/SwiftUI menu bar application (Xcode project, `.xcodeproj`). It **cannot be built or run on Linux**. The Xcode build system (`xcodebuild`), XCTest-based unit/UI tests, and the macOS app itself all require macOS 14.0+ with Xcode installed.

### What works on Linux (Cloud Agent)

| Task | Command | Notes |
|------|---------|-------|
| **Lint Swift** | `swiftlint lint` | Requires Swift toolchain + SwiftLint installed; runs against all 136 `.swift` files |
| **Python validator** | `python3 media_validator.py <file>` | Cross-platform OMF/AAF media validator; needs `pyaaf2` (`pip3 install -r requirements.txt`) |
| **Code editing** | any editor | All Swift source files can be read and edited normally |

### What does NOT work on Linux

- `xcodebuild` (no Xcode on Linux)
- `./build_and_check.sh` (wraps `xcodebuild`)
- Running the `.app` binary
- XCTest unit tests (`MediaDashTests/`) and UI tests (`MediaDashUITests/`)
- Sparkle signing tools (`sign_update`, `generate_keys`)
- Release scripts (`release_update.sh`, `sign_and_release.sh`, etc.)

### Key files

- **Config files (gitignored):** `MediaDash/Services/OAuthConfig.swift` and `MediaDash/CodeMindConfig.swift` contain OAuth and AI API credentials. A template exists at `OAuthConfig.swift.template`.
- **Python dependency:** `requirements.txt` — install with `pip3 install -r requirements.txt`.
- **Release guide:** See `RELEASE_GUIDE.md` for release workflow details.
- **AI handoff doc:** `AI_HANDOFF.md` has architecture notes, file locations, and known issues.

### Running SwiftLint

```bash
swiftlint lint                    # Full lint (Xcode-style output)
swiftlint lint --reporter summary # Summary table of violations by rule
swiftlint lint --fix              # Auto-fix correctable violations
```

No `.swiftlint.yml` config file exists; SwiftLint uses its defaults. The codebase currently has ~7500 warnings and ~490 errors by default rules.

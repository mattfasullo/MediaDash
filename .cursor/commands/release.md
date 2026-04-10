# release

Ship a MediaDash update to users (git + Sparkle + GitHub release).

1. Read `.cursor/rules/release-from-agent.mdc` and follow it.
2. If there are uncommitted changes, commit them on `main` with a clear message (infer from the diff, or use any version/notes I put in this message).
3. Push `main` to `origin`.
4. **Version and release notes:** If I did not specify them in chat, read `MediaDash/Info.plist` / `MARKETING_VERSION` in the project, choose the **next** appropriate version (e.g. patch bump), and draft short user-facing release notes from the recent commits/diff. If anything is ambiguous, ask me before running the script.
5. Before running the release script: if the new version should be a **full** GitHub release (not prerelease), ensure `release.sh` includes that version string in the same `if` chain as `1.06` / `1.07` next to `gh release create`; add it if missing.
6. From the repo root, run non-interactively: `./release.sh <version> "<release notes>"` with **full** shell permissions and a **long** timeout (build/sign can take many minutes).
7. Do not use `release_update.sh` (interactive). Confirm `main` is pushed and the GitHub release URL when done.

If `xcode-select` or signing fails, tell me to complete one-time setup from `AGENT_RELEASE_SETUP.md`.
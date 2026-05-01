# Airtable read-only token (team)

MediaDash uses a personal access token with **`data.records:read`** and access limited to the dockets base for polling new dockets.

## Where the real value lives

1. **Canonical copy (with secrets):** `docs/AIRTABLE_READ_ONLY_TOKEN.local.md` — this file is **gitignored** and should hold the current PAT for operators who need to copy it (e.g. onto the server’s `mediadash_airtable_readonly_token.txt`).
2. **On the share:** one line in `mediadash_airtable_readonly_token.txt` next to `mediadash_docket_cache.json` (see `SharedKeychainService` / `AirtableConfig`).
3. **Per-Mac:** users can paste the same PAT in app Settings; it is stored in Keychain, not in this repo.

## Do not commit PATs

Never put the token in Swift, plists, or tracked markdown—only in the gitignored `.local.md` or in Keychain / the private team file on your server.

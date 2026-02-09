#!/bin/bash
# Run this on your Mac to sign the 0.9.12 zip and update appcast.xml.
# Then run the git/gh commands it prints.

set -e
cd "$(dirname "$0")"

ZIP="release/MediaDash.zip"
APPCAST="appcast.xml"

if [ ! -f "$ZIP" ]; then
    echo "Creating MediaDash.zip..."
    mkdir -p release
    cd release
    ditto -c -k --sequesterRsrc --keepParent MediaDash.app MediaDash.zip
    cd ..
fi

echo "Signing update (uses your Sparkle key from keychain)..."
SIGNATURE=$(./sign_update "$ZIP")
if [ -z "$SIGNATURE" ]; then
    echo "ERROR: sign_update produced no output. Is your key set up? Run generate_keys if needed."
    exit 1
fi

echo "Updating appcast.xml with signature..."
sed -i '' "s|sparkle:edSignature=\"REPLACE_WITH_SIGNATURE\"|sparkle:edSignature=\"$SIGNATURE\"|" "$APPCAST"

echo ""
echo "Done. appcast.xml is updated. Now run:"
echo ""
echo "  git add appcast.xml"
echo "  git commit -m \"Release v0.9.12\""
echo "  git push"
echo ""
echo "  gh release create v0.9.12 release/MediaDash.zip --title \"MediaDash v0.9.12\" --notes \"- Demos/Submit: Track colour selector reorganized like spreadsheet\n- Completed tasks stay visible with checkmark and greyed out; DEMOS and SUBMIT both treated as demos\n- Posting legend: Copy legend; editable Post task description with Save\n- Download prompt: Popup to stage downloaded files\n- Calendar: Task detail in resizable window\n- Fix: Download prompt window crash\""
echo ""

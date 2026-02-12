#!/bin/bash

# Script to push v0.9.12 commit and create GitHub release
# Run this in your terminal where you have GitHub credentials

set -e

cd "$(dirname "$0")"

echo "🚀 Pushing v0.9.12 to GitHub..."

# Push the commit
git push origin main

echo "✅ Code pushed successfully"
echo ""

echo "📦 Creating GitHub release v0.9.12..."

# Check if gh CLI is available
if command -v gh &> /dev/null; then
    echo "Using GitHub CLI..."
    gh release create v0.9.12 \
        release/MediaDash.zip \
        --title "MediaDash 0.9.12" \
        --notes-file RELEASE_NOTES_0.9.12.txt
    echo "✅ GitHub release created successfully!"
else
    echo "⚠️  GitHub CLI (gh) not found."
    echo ""
    echo "Please either:"
    echo "1. Install GitHub CLI: brew install gh && gh auth login"
    echo "   Then run this script again."
    echo ""
    echo "OR"
    echo ""
    echo "2. Create the release manually:"
    echo "   - Go to: https://github.com/mattfasullo/MediaDash/releases/new"
    echo "   - Tag: v0.9.12"
    echo "   - Title: MediaDash 0.9.12"
    echo "   - Upload: release/MediaDash.zip"
    echo "   - Description: (copy from RELEASE_NOTES_0.9.12.txt)"
    exit 1
fi

echo ""
echo "🎉 Release v0.9.12 is now available on GitHub!"
echo "   https://github.com/mattfasullo/MediaDash/releases/tag/v0.9.12"

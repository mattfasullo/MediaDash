#!/bin/bash
# Script to set the shared Gemini API key in Keychain
# Usage: ./set_shared_gemini_key.sh <API_KEY>

set -e

if [ -z "$1" ]; then
    echo "Usage: ./set_shared_gemini_key.sh <GEMINI_API_KEY>"
    echo ""
    echo "This script stores the Gemini API key in macOS Keychain"
    echo "so that all Grayson Music Group employees can use it automatically."
    exit 1
fi

API_KEY="$1"
KEYCHAIN_SERVICE="com.mediadash.keychain"
KEYCHAIN_ACCOUNT="codemind_shared_gemini_key"

echo "Setting shared Gemini API key in Keychain..."

# Delete existing key if it exists
security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" 2>/dev/null || true

# Add the new key
security add-generic-password \
    -s "$KEYCHAIN_SERVICE" \
    -a "$KEYCHAIN_ACCOUNT" \
    -w "$API_KEY" \
    -U

if [ $? -eq 0 ]; then
    echo "✅ Shared Gemini API key successfully stored in Keychain!"
    echo ""
    echo "All Grayson Music Group employees (@graysonmusicgroup.com) will now"
    echo "be able to use CodeMind automatically without configuring their own keys."
else
    echo "❌ Failed to store key in Keychain"
    exit 1
fi


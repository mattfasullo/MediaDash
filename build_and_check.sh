#!/bin/bash

# Script to build the project and check for all issues (errors, warnings)
# Usage: ./build_and_check.sh

set -e

PROJECT="MediaDash.xcodeproj"
SCHEME="MediaDash"
CONFIGURATION="Debug"
BUILD_LOG="/tmp/mediadash_build.log"

echo "🔨 Building $SCHEME ($CONFIGURATION)..."

# Clean and build, capturing all output
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    clean build \
    2>&1 | tee "$BUILD_LOG"

# Check build result
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo ""
    echo "❌ BUILD FAILED"
    echo ""
    echo "Errors and warnings:"
    grep -E "(error|warning)" "$BUILD_LOG" | grep -v "note: Using stub executor" | grep -v "note: Metadata extraction skipped" | grep -v "note: Building" | grep -v "note: Target" | grep -v "note: Emplaced" || echo "  (No specific errors found in output)"
    exit 1
fi

# Check for warnings (excluding informational notes)
WARNINGS=$(grep -E "warning:" "$BUILD_LOG" | grep -v "appintentsmetadataprocessor" | grep -v "note: Using stub executor" | grep -v "note: Metadata extraction skipped" | grep -v "note: Building" | grep -v "note: Target" | grep -v "note: Emplaced" || true)

if [ -n "$WARNINGS" ]; then
    echo ""
    echo "⚠️  BUILD SUCCEEDED BUT HAS WARNINGS:"
    echo ""
    echo "$WARNINGS"
    echo ""
    echo "Please fix these warnings before proceeding."
    exit 1
fi

echo ""
echo "✅ BUILD SUCCEEDED - No errors or warnings!"
exit 0


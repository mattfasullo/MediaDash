#!/bin/bash
# MediaDash Test Runner
# Runs unit tests with formatted output

set -e

echo "======================================"
echo "   MediaDash Unit Tests"
echo "======================================"
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PROJECT="MediaDash.xcodeproj"
SCHEME="MediaDash"

# Check if xcodebuild is available
if ! command -v xcodebuild &> /dev/null; then
    echo -e "${RED}❌ xcodebuild not found${NC}"
    exit 1
fi

echo -e "${BLUE}Running tests...${NC}"
echo ""

# Run tests and capture output
LOG_FILE="/tmp/mediadash-tests.log"

if xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    2>&1 | tee "$LOG_FILE"; then
    
    echo ""
    echo -e "${GREEN}✅ All tests passed${NC}"
    
    # Show test count
    TEST_COUNT=$(grep -c "Test Case" "$LOG_FILE" 2>/dev/null || echo "0")
    echo -e "${BLUE}Tests executed: $TEST_COUNT${NC}"
    
    exit 0
else
    echo ""
    echo -e "${RED}❌ Tests failed${NC}"
    
    # Show failed tests
    if grep -q "failed" "$LOG_FILE"; then
        echo ""
        echo -e "${YELLOW}Failed tests:${NC}"
        grep "failed" "$LOG_FILE" | head -10
    fi
    
    exit 1
fi

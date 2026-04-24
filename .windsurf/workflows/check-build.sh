#!/bin/bash
# MediaDash Build Checker
# Verifies the app builds without errors (does not archive/export)

set -e

echo "======================================"
echo "   MediaDash Build Check"
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

check_prerequisites() {
    if ! command -v xcodebuild &> /dev/null; then
        echo -e "${RED}❌ xcodebuild not found${NC}"
        exit 1
    fi
    
    if [ ! -d "$PROJECT" ]; then
        echo -e "${RED}❌ Project not found: $PROJECT${NC}"
        exit 1
    fi
}

echo -e "${BLUE}Checking prerequisites...${NC}"
check_prerequisites
echo -e "${GREEN}✅ Prerequisites OK${NC}"
echo ""

# Clean first
echo -e "${BLUE}Cleaning build folder...${NC}"
xcodebuild clean -project "$PROJECT" -scheme "$SCHEME" -quiet 2>/dev/null || true
echo -e "${GREEN}✅ Clean complete${NC}"
echo ""

# Build
echo -e "${BLUE}Building (Debug configuration)...${NC}"
echo "This may take a few minutes..."
echo ""

LOG_FILE="/tmp/mediadash-build.log"

if xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    CODE_SIGN_STYLE=Automatic \
    2>&1 | tee "$LOG_FILE"; then
    
    echo ""
    echo -e "${GREEN}✅ Build successful${NC}"
    
    # Show warnings count
    WARNING_COUNT=$(grep -c "warning:" "$LOG_FILE" 2>/dev/null || echo "0")
    if [ "$WARNING_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}⚠️  Warnings: $WARNING_COUNT${NC}"
    fi
    
    exit 0
else
    echo ""
    echo -e "${RED}❌ Build failed${NC}"
    
    # Show errors
    if grep -q "error:" "$LOG_FILE"; then
        echo ""
        echo -e "${RED}Errors:${NC}"
        grep "error:" "$LOG_FILE" | head -5
    fi
    
    exit 1
fi

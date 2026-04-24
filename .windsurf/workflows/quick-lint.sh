#!/bin/bash
# MediaDash Quick Lint
# Checks Swift syntax and finds obvious issues

echo "======================================"
echo "   MediaDash Quick Lint"
echo "======================================"
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ISSUES=0

report_issue() {
    echo -e "${YELLOW}⚠️  $1${NC}"
    ISSUES=$((ISSUES + 1))
}

ok() {
    echo -e "${GREEN}✅ $1${NC}"
}

echo -e "${BLUE}Checking for common issues...${NC}"
echo ""

# Check 1: Swift files for TODO/FIXME without context
echo "Checking for TODO/FIXME markers..."
TODO_COUNT=$(grep -r "TODO:" MediaDash/ 2>/dev/null | wc -l)
FIXME_COUNT=$(grep -r "FIXME:" MediaDash/ 2>/dev/null | wc -l)

if [ "$TODO_COUNT" -gt 0 ]; then
    echo "   Found $TODO_COUNT TODO markers"
fi
if [ "$FIXME_COUNT" -gt 0 ]; then
    echo "   Found $FIXME_COUNT FIXME markers"
fi

# Check 2: Debug print statements that might be left in
echo ""
echo "Checking for debug print statements..."
DEBUG_PRINTS=$(grep -rn "print(" MediaDash/ --include="*.swift" 2>/dev/null | grep -v "//" | wc -l)
if [ "$DEBUG_PRINTS" -gt 20 ]; then
    report_issue "$DEBUG_PRINTS print() statements found (some may be intentional)"
else
    ok "Debug print count looks reasonable"
fi

# Check 3: Force unwraps
echo ""
echo "Checking for force unwraps..."
FORCE_UNWRAPS=$(grep -rn "!" MediaDash/ --include="*.swift" 2>/dev/null | grep -v "//!" | grep -v "!= " | grep -v "!==" | grep -v "// MARK" | grep -v "Copyright" | wc -l)
if [ "$FORCE_UNWRAPS" -gt 100 ]; then
    report_issue "$FORCE_UNWRAP force unwraps found - review for safety"
else
    ok "Force unwrap count is acceptable"
fi

# Check 4: Force casts
echo ""
echo "Checking for force casts (as!)..."
FORCE_CASTS=$(grep -rn "as!" MediaDash/ --include="*.swift" 2>/dev/null | wc -l)
if [ "$FORCE_CASTS" -gt 0 ]; then
    report_issue "$FORCE_CASTS force casts found"
else
    ok "No force casts found"
fi

# Check 5: Trailing whitespace
echo ""
echo "Checking for trailing whitespace..."
TRAILING_WS=$(grep -rn "[[:space:]]$" MediaDash/ --include="*.swift" 2>/dev/null | wc -l)
if [ "$TRAILING_WS" -gt 0 ]; then
    report_issue "$TRAILING_WS lines with trailing whitespace"
else
    ok "No trailing whitespace"
fi

# Check 6: Large files (potential refactoring candidates)
echo ""
echo "Checking for very large files..."
LARGE_FILES=$(find MediaDash -name "*.swift" -exec wc -l {} \; 2>/dev/null | awk '$1 > 1000 {print $2, $1}' | head -5)
if [ -n "$LARGE_FILES" ]; then
    echo "   Large files (1000+ lines):"
    echo "$LARGE_FILES" | while read file lines; do
        echo "     - $file ($lines lines)"
    done
fi

# Summary
echo ""
echo "======================================"
echo -e "${BLUE}Lint Summary${NC}"
echo "======================================"
echo ""

if [ $ISSUES -eq 0 ]; then
    echo -e "${GREEN}🎉 No major issues found!${NC}"
    exit 0
else
    echo -e "${YELLOW}⚠️  $ISSUES potential issues found${NC}"
    echo "   Review the output above for details"
    exit 0  # Still exit 0 - these are warnings not errors
fi

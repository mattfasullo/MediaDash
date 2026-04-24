#!/bin/bash
# MediaDash Release Validation Workflow
# Validates that everything is ready for a release WITHOUT actually releasing
# Run this before ./release_update.sh to catch issues early

set -e

echo "======================================"
echo "   MediaDash Release Validation"
echo "======================================"
echo ""

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

ERRORS=0
WARNINGS=0

# Helper functions
error() {
    echo -e "${RED}❌ ERROR: $1${NC}"
    ERRORS=$((ERRORS + 1))
}

warn() {
    echo -e "${YELLOW}⚠️  WARNING: $1${NC}"
    WARNINGS=$((WARNINGS + 1))
}

ok() {
    echo -e "${GREEN}✅ $1${NC}"
}

info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# ============================================
# CHECK 1: Git Status
# ============================================
echo ""
echo -e "${BLUE}🔍 Check 1: Git Repository Status${NC}"
echo "--------------------------------------"

# Check if we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    error "Not in a git repository"
    exit 1
fi

# Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
    warn "You have uncommitted changes"
    git status --short
else
    ok "Working directory is clean"
fi

# Check if we're on main branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "main" ] && [ "$CURRENT_BRANCH" != "master" ]; then
    warn "Not on main/master branch (currently on: $CURRENT_BRANCH)"
else
    ok "On main branch"
fi

# Check for unpushed commits
UNPUSHED=$(git log --oneline @{upstream}..HEAD 2>/dev/null || echo "")
if [ -n "$UNPUSHED" ]; then
    warn "You have unpushed commits:"
    echo "$UNPUSHED"
else
    ok "All commits are pushed"
fi

# ============================================
# CHECK 2: Required Files Exist
# ============================================
echo ""
echo -e "${BLUE}🔍 Check 2: Required Files${NC}"
echo "--------------------------------------"

REQUIRED_FILES=(
    "MediaDash.xcodeproj"
    "MediaDash/Info.plist"
    "appcast.xml"
    "sign_update"
    "media_validator.py"
    "sync_version.sh"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ -e "$file" ]; then
        ok "$file exists"
    else
        error "$file is missing"
    fi
done

# ============================================
# CHECK 3: Xcode Project Validation
# ============================================
echo ""
echo -e "${BLUE}🔍 Check 3: Xcode Project${NC}"
echo "--------------------------------------"

# Check if xcodebuild is available
if ! command -v xcodebuild &> /dev/null; then
    error "xcodebuild not found. Install Xcode."
else
    ok "xcodebuild is available"
fi

# Check if project builds (without actually building - just check syntax)
info "Validating Xcode project..."
if xcodebuild -project MediaDash.xcodeproj -scheme MediaDash -configuration Release clean 2>&1 | grep -q "error:"; then
    warn "Xcode project has errors. Run build to see details."
else
    ok "Xcode project appears valid"
fi

# ============================================
# CHECK 4: Signing Tools
# ============================================
echo ""
echo -e "${BLUE}🔍 Check 4: Signing Tools${NC}"
echo "--------------------------------------"

# Check sign_update exists and is executable
if [ -x "./sign_update" ]; then
    ok "sign_update is executable"
else
    error "sign_update not found or not executable"
fi

# Check codesign is available
if command -v codesign &> /dev/null; then
    ok "codesign is available"
else
    error "codesign not found"
fi

# ============================================
# CHECK 5: GitHub CLI
# ============================================
echo ""
echo -e "${BLUE}🔍 Check 5: GitHub CLI${NC}"
echo "--------------------------------------"

if command -v gh &> /dev/null; then
    ok "GitHub CLI (gh) is installed"
    
    # Check if authenticated
    if gh auth status &> /dev/null; then
        ok "GitHub CLI is authenticated"
    else
        error "GitHub CLI is not authenticated. Run: gh auth login"
    fi
else
    error "GitHub CLI (gh) not found. Install with: brew install gh"
fi

# ============================================
# CHECK 6: Appcast Validation
# ============================================
echo ""
echo -e "${BLUE}🔍 Check 6: Appcast.xml${NC}"
echo "--------------------------------------"

if [ -f "appcast.xml" ]; then
    # Check if valid XML
    if xmllint --noout appcast.xml 2>/dev/null; then
        ok "appcast.xml is valid XML"
    else
        warn "appcast.xml has XML syntax issues"
    fi
    
    # Check for required Sparkle namespace
    if grep -q "xmlns:sparkle" appcast.xml; then
        ok "appcast.xml has Sparkle namespace"
    else
        warn "appcast.xml missing Sparkle namespace"
    fi
else
    error "appcast.xml not found"
fi

# ============================================
# CHECK 7: Version Consistency
# ============================================
echo ""
echo -e "${BLUE}🔍 Check 7: Version Information${NC}"
echo "--------------------------------------"

# Get version from Info.plist
if [ -f "MediaDash/Info.plist" ]; then
    PLIST_VERSION=$(plutil -extract CFBundleShortVersionString raw MediaDash/Info.plist 2>/dev/null || echo "unknown")
    PLIST_BUILD=$(plutil -extract CFBundleVersion raw MediaDash/Info.plist 2>/dev/null || echo "unknown")
    
    info "Current Info.plist version: $PLIST_VERSION (build: $PLIST_BUILD)"
else
    warn "Could not read Info.plist"
fi

# ============================================
# CHECK 8: Tests
# ============================================
echo ""
echo -e "${BLUE}🔍 Check 8: Unit Tests${NC}"
echo "--------------------------------------"

info "Running unit tests..."
if xcodebuild test -project MediaDash.xcodeproj -scheme MediaDash -destination 'platform=macOS' 2>&1 | grep -q "TEST FAILED"; then
    warn "Some unit tests failed"
else
    ok "Unit tests passed"
fi

# ============================================
# CHECK 9: Python Validator
# ============================================
echo ""
echo -e "${BLUE}🔍 Check 9: Python Validator${NC}"
echo "--------------------------------------"

if [ -f "media_validator.py" ]; then
    # Check Python syntax
    if python3 -m py_compile media_validator.py 2>/dev/null; then
        ok "media_validator.py syntax is valid"
    else
        warn "media_validator.py has syntax issues"
    fi
else
    warn "media_validator.py not found (needed for release)"
fi

# ============================================
# CHECK 10: Release Scripts
# ============================================
echo ""
echo -e "${BLUE}🔍 Check 10: Release Scripts${NC}"
echo "--------------------------------------"

SCRIPTS=(
    "release_update.sh"
    "sync_version.sh"
    "verify_appcast.sh"
)

for script in "${SCRIPTS[@]}"; do
    if [ -f "$script" ]; then
        if [ -x "$script" ]; then
            ok "$script is executable"
        else
            warn "$script exists but is not executable (run: chmod +x $script)"
        fi
    else
        warn "$script not found"
    fi
done

# ============================================
# SUMMARY
# ============================================
echo ""
echo "======================================"
echo -e "${BLUE}📊 Validation Summary${NC}"
echo "======================================"
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}🎉 All checks passed! Ready to release.${NC}"
    echo ""
    echo "Run the release with:"
    echo "  ./release_update.sh"
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo -e "${YELLOW}⚠️  $WARNINGS warning(s) found.${NC}"
    echo -e "${YELLOW}   You can proceed with caution.${NC}"
    echo ""
    echo "Run the release with:"
    echo "  ./release_update.sh"
    exit 0
else
    echo -e "${RED}❌ $ERRORS error(s) and $WARNINGS warning(s) found.${NC}"
    echo -e "${RED}   Please fix errors before releasing.${NC}"
    exit 1
fi

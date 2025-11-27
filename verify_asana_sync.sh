#!/bin/bash

# MediaDash Asana Sync Verification Script
# This script helps verify that the Asana sync on the shared cache is working correctly

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration (matches sync_shared_cache.sh)
CACHE_PATH="/Volumes/Grayson Assets/MEDIA/Media Dept Misc. Folders/Misc./MediaDash_Cache"
LOG_FILE="/tmp/mediadash-cache-sync.log"

# Function to print section headers
section() {
    echo ""
    echo -e "${CYAN}=== $1 ===${NC}"
    echo ""
}

# Function to print success
success() {
    echo -e "${GREEN}✅ $1${NC}"
}

# Function to print warning
warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# Function to print error
error() {
    echo -e "${RED}❌ $1${NC}"
}

# Function to print info
info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# Get Asana access token from macOS keychain
get_access_token() {
    local token=$(security find-generic-password \
        -s "com.mediadash.keychain" \
        -a "asana_access_token" \
        -w 2>/dev/null || echo "")
    
    if [ -z "$token" ]; then
        token="${ASANA_ACCESS_TOKEN}"
    fi
    
    echo "$token"
}

# Check 1: Cache file exists and is readable
check_cache_file() {
    section "1. Cache File Check"
    
    if [ ! -f "$CACHE_PATH" ]; then
        error "Cache file does not exist: $CACHE_PATH"
        info "The sync script may not have run yet, or the path is incorrect"
        return 1
    fi
    
    success "Cache file exists"
    
    # Check if readable
    if [ ! -r "$CACHE_PATH" ]; then
        error "Cache file is not readable (permission issue)"
        return 1
    fi
    
    success "Cache file is readable"
    
    # Get file info
    SIZE=$(ls -lh "$CACHE_PATH" | awk '{print $5}')
    MODIFIED=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$CACHE_PATH" 2>/dev/null || stat -c "%y" "$CACHE_PATH" 2>/dev/null | cut -d' ' -f1-2)
    
    info "Size: $SIZE"
    info "Last Modified: $MODIFIED"
    
    # Check if file is recent (within last 24 hours)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        MODIFIED_EPOCH=$(stat -f "%m" "$CACHE_PATH")
    else
        # Linux
        MODIFIED_EPOCH=$(stat -c "%Y" "$CACHE_PATH")
    fi
    
    CURRENT_EPOCH=$(date +%s)
    AGE_SECONDS=$((CURRENT_EPOCH - MODIFIED_EPOCH))
    AGE_HOURS=$((AGE_SECONDS / 3600))
    AGE_MINUTES=$(((AGE_SECONDS % 3600) / 60))
    
    if [ $AGE_SECONDS -lt 86400 ]; then
        success "Cache is recent (${AGE_HOURS}h ${AGE_MINUTES}m old)"
    else
        warning "Cache is ${AGE_HOURS}h ${AGE_MINUTES}m old (may be stale)"
    fi
    
    return 0
}

# Check 2: Validate JSON structure
check_json_structure() {
    section "2. JSON Structure Validation"
    
    if [ ! -f "$CACHE_PATH" ]; then
        error "Cache file not found"
        return 1
    fi
    
    # Validate JSON syntax
    if ! python3 -m json.tool "$CACHE_PATH" > /dev/null 2>&1; then
        error "Cache file is not valid JSON"
        return 1
    fi
    
    success "Cache file is valid JSON"
    
    # Check for required fields
    HAS_DOCKETS=$(python3 -c "
import json, sys
try:
    with open('$CACHE_PATH', 'r') as f:
        data = json.load(f)
    if 'dockets' in data:
        print('yes')
    else:
        print('no')
except:
    print('error')
" 2>/dev/null)
    
    if [ "$HAS_DOCKETS" != "yes" ]; then
        error "Cache file missing 'dockets' field"
        return 1
    fi
    
    success "Cache file has required 'dockets' field"
    
    # Check for lastSync field
    HAS_LAST_SYNC=$(python3 -c "
import json, sys
try:
    with open('$CACHE_PATH', 'r') as f:
        data = json.load(f)
    if 'lastSync' in data:
        print('yes')
    else:
        print('no')
except:
    print('error')
" 2>/dev/null)
    
    if [ "$HAS_LAST_SYNC" = "yes" ]; then
        LAST_SYNC=$(python3 -c "
import json, sys
try:
    with open('$CACHE_PATH', 'r') as f:
        data = json.load(f)
    print(data.get('lastSync', 'N/A'))
except:
    print('N/A')
" 2>/dev/null)
        info "Last Sync: $LAST_SYNC"
    else
        warning "Cache file missing 'lastSync' field"
    fi
    
    return 0
}

# Check 3: Cache statistics
check_cache_stats() {
    section "3. Cache Statistics"
    
    if [ ! -f "$CACHE_PATH" ]; then
        error "Cache file not found"
        return 1
    fi
    
    STATS=$(python3 -c "
import json
import sys
from datetime import datetime

try:
    with open('$CACHE_PATH', 'r') as f:
        data = json.load(f)
    
    dockets = data.get('dockets', [])
    total = len(dockets)
    
    # Count dockets with different metadata types
    metadata_counts = {}
    for docket in dockets:
        metadata_type = docket.get('metadataType') or 'None'
        metadata_counts[metadata_type] = metadata_counts.get(metadata_type, 0) + 1
    
    # Get sample docket numbers
    sample_dockets = [d.get('number', 'N/A') for d in dockets[:5]]
    
    # Get most recent update
    recent_dockets = sorted(
        [d for d in dockets if d.get('updatedAt')],
        key=lambda x: x.get('updatedAt', ''),
        reverse=True
    )[:3]
    
    print(f'Total Dockets: {total}')
    print(f'Metadata Types: {dict(metadata_counts)}')
    print(f'Sample Dockets: {\", \".join(sample_dockets)}')
    
    if recent_dockets:
        print('Most Recent Updates:')
        for d in recent_dockets:
            print(f'  - {d.get(\"number\", \"N/A\")}: {d.get(\"updatedAt\", \"N/A\")}')
    
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
")
    
    if [ $? -eq 0 ]; then
        echo "$STATS" | while IFS= read -r line; do
            info "$line"
        done
    else
        error "Failed to read cache statistics"
        return 1
    fi
    
    return 0
}

# Check 4: Compare with Asana API (sample verification)
check_asana_comparison() {
    section "4. Asana API Comparison (Sample)"
    
    local token=$(get_access_token)
    
    if [ -z "$token" ]; then
        warning "Cannot get Asana access token - skipping API comparison"
        warning "Set ASANA_ACCESS_TOKEN environment variable or ensure MediaDash has authenticated"
        return 0
    fi
    
    info "Fetching sample from Asana API (this may take a moment)..."
    
    # Get workspace ID first
    WORKSPACE_ID=$(curl -s -H "Authorization: Bearer ${token}" \
        "https://app.asana.com/api/1.0/workspaces" | \
        python3 -c "
import json, sys
data = json.load(sys.stdin)
workspaces = data.get('data', [])
if workspaces:
    print(workspaces[0]['gid'])
" 2>/dev/null)
    
    if [ -z "$WORKSPACE_ID" ]; then
        warning "Could not fetch workspace from Asana API"
        return 0
    fi
    
    info "Using workspace: $WORKSPACE_ID"
    
    # Fetch a small sample of projects and tasks
    SAMPLE=$(curl -s -H "Authorization: Bearer ${token}" \
        "https://app.asana.com/api/1.0/projects?workspace=${WORKSPACE_ID}&limit=5" | \
        python3 -c "
import json
import sys
import re

data = json.load(sys.stdin)
projects = data.get('data', [])
active_projects = [p for p in projects if not p.get('archived', False)]

if not active_projects:
    print('No active projects found')
    sys.exit(0)

# Get tasks from first project
project_id = active_projects[0]['gid']
print(f'Checking project: {active_projects[0].get(\"name\", \"N/A\")} ({project_id})')

# Fetch tasks (this would need to be done in bash, but we'll just note it)
print(f'Project ID for manual check: {project_id}')
")
    
    echo "$SAMPLE"
    info "Note: Full comparison requires fetching all tasks, which can take time"
    info "The sync script handles this - verify by checking docket counts match"
    
    return 0
}

# Check 5: Verify MediaDash can read it
check_mediadash_compatibility() {
    section "5. MediaDash Compatibility Check"
    
    if [ ! -f "$CACHE_PATH" ]; then
        error "Cache file not found"
        return 1
    fi
    
    # Check if structure matches what MediaDash expects
    COMPATIBLE=$(python3 -c "
import json
import sys

try:
    with open('$CACHE_PATH', 'r') as f:
        data = json.load(f)
    
    # Check structure
    if not isinstance(data, dict):
        print('no: Root must be an object')
        sys.exit(0)
    
    if 'dockets' not in data:
        print('no: Missing dockets field')
        sys.exit(0)
    
    if not isinstance(data['dockets'], list):
        print('no: dockets must be an array')
        sys.exit(0)
    
    # Check first docket structure if available
    if len(data['dockets']) > 0:
        docket = data['dockets'][0]
        required_fields = ['number', 'jobName', 'fullName']
        missing = [f for f in required_fields if f not in docket]
        
        if missing:
            print(f'no: Missing fields in docket: {\", \".join(missing)}')
            sys.exit(0)
    
    print('yes')
    
except Exception as e:
    print(f'no: {e}')
")
    
    if [ "$COMPATIBLE" = "yes" ]; then
        success "Cache structure is compatible with MediaDash"
    else
        error "Cache structure may not be compatible: $COMPATIBLE"
        return 1
    fi
    
    return 0
}

# Check 6: Sync script status
check_sync_script_status() {
    section "6. Sync Script Status"
    
    PID_FILE="/tmp/mediadash-cache-sync.pid"
    
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE" 2>/dev/null)
        if ps -p "$PID" > /dev/null 2>&1; then
            success "Sync script is currently running (PID: $PID)"
            info "Check progress with: tail -f $LOG_FILE"
        else
            warning "Stale PID file found (process not running)"
        fi
    else
        info "Sync script is not currently running"
    fi
    
    # Check log file
    if [ -f "$LOG_FILE" ]; then
        LOG_SIZE=$(ls -lh "$LOG_FILE" | awk '{print $5}')
        LOG_MODIFIED=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$LOG_FILE" 2>/dev/null || stat -c "%y" "$LOG_FILE" 2>/dev/null | cut -d' ' -f1-2)
        info "Log file: $LOG_FILE ($LOG_SIZE, modified: $LOG_MODIFIED)"
        
        # Show last few lines
        if [ -s "$LOG_FILE" ]; then
            echo ""
            info "Last 5 lines of sync log:"
            tail -5 "$LOG_FILE" | sed 's/^/   /'
        fi
    else
        info "No log file found (sync script may not have run yet)"
    fi
}

# Main execution
main() {
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║     MediaDash Asana Sync Verification Tool               ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Run all checks
    CHECKS_PASSED=0
    CHECKS_TOTAL=0
    
    check_cache_file && CHECKS_PASSED=$((CHECKS_PASSED + 1))
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    
    check_json_structure && CHECKS_PASSED=$((CHECKS_PASSED + 1))
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    
    check_cache_stats && CHECKS_PASSED=$((CHECKS_PASSED + 1))
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    
    check_asana_comparison
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    
    check_mediadash_compatibility && CHECKS_PASSED=$((CHECKS_PASSED + 1))
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    
    check_sync_script_status
    
    # Summary
    section "Summary"
    
    if [ $CHECKS_PASSED -eq $CHECKS_TOTAL ]; then
        success "All critical checks passed! ($CHECKS_PASSED/$CHECKS_TOTAL)"
        echo ""
        info "The shared cache appears to be working correctly."
        info "To verify MediaDash is using it:"
        info "  1. Open MediaDash"
        info "  2. Check Console.app for log messages containing '[Cache]'"
        info "  3. Look for: 'Loaded X dockets from SHARED cache'"
    else
        warning "Some checks had issues ($CHECKS_PASSED/$CHECKS_TOTAL passed)"
        echo ""
        info "Troubleshooting tips:"
        info "  - Run the sync script manually: ./sync_shared_cache.sh"
        info "  - Check the log file: tail -f $LOG_FILE"
        info "  - Verify the cache path is correct and accessible"
        info "  - Ensure the server/network share is mounted"
    fi
    
    echo ""
}

# Run main function
main


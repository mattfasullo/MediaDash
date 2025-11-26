#!/bin/bash

# MediaDash Shared Cache Sync Script
# This script syncs Asana dockets and saves them to the shared cache location
# Run this periodically (e.g., via cron or launchd) to keep the shared cache updated

# Log file for monitoring
LOG_FILE="${LOG_FILE:-/tmp/mediadash-cache-sync.log}"
PID_FILE="${PID_FILE:-/tmp/mediadash-cache-sync.pid}"

# If PID file exists and process is running, exit
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        echo "Script is already running (PID: $OLD_PID). Use 'tail -f $LOG_FILE' to monitor progress."
        exit 0
    else
        # Stale PID file, remove it
        rm -f "$PID_FILE"
    fi
fi

# Create PID file
echo $$ > "$PID_FILE"
trap "rm -f $PID_FILE" EXIT

# Redirect all output to log file (in addition to stderr for real-time viewing)
exec 1> >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

set -e  # Exit on error

# Configuration
CACHE_PATH="/Volumes/Grayson Assets/MEDIA/Media Dept Misc. Folders/Misc./MediaDash_Cache"
ASANA_ACCESS_TOKEN=""  # Will be read from keychain or environment variable
WORKSPACE_ID=""  # Optional: specify workspace ID
PROJECT_ID=""    # Optional: specify project ID

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to log messages
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if server path is mounted/available
check_server_path() {
    local parent_dir=$(dirname "$CACHE_PATH")
    
    if [ ! -d "$parent_dir" ]; then
        error "Server path not available: $parent_dir"
        error "Make sure the server is mounted before running this script"
        exit 1
    fi
    
    log "Server path is available: $parent_dir"
}

# Get Asana access token from macOS keychain
get_access_token() {
    # MediaDash stores tokens with service "com.mediadash.keychain" and account "asana_access_token"
    # Try to get from keychain using the correct service and account
    local token=$(security find-generic-password \
        -s "com.mediadash.keychain" \
        -a "asana_access_token" \
        -w 2>/dev/null || echo "")
    
    if [ -z "$token" ]; then
        # Try environment variable as fallback
        token="${ASANA_ACCESS_TOKEN}"
    fi
    
    if [ -z "$token" ]; then
        error "Asana access token not found!"
        error "Please set ASANA_ACCESS_TOKEN environment variable or ensure MediaDash has authenticated"
        error ""
        error "To set the token manually, run:"
        error "  export ASANA_ACCESS_TOKEN='your_token_here'"
        exit 1
    fi
    
    echo "$token"
}

# Fetch workspaces from Asana
# Outputs only the workspace ID to stdout (all logs go to stderr)
fetch_workspaces() {
    local token="$1"
    local api_url="https://app.asana.com/api/1.0"
    
    log "Fetching workspaces..." >&2
    
    local response_file=$(mktemp)
    local header_file=$(mktemp)
    
    local http_code=$(curl -s -o "$response_file" -D "$header_file" \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/json" \
        -w "%{http_code}" \
        "${api_url}/workspaces" 2>/dev/null)
    
    # If http_code from -w is empty, try to extract from headers
    if [ -z "$http_code" ] || ! echo "$http_code" | grep -qE '^[0-9]{3}$'; then
        http_code=$(grep -i "^HTTP" "$header_file" | head -1 | awk '{print $2}')
    fi
    
    local body=$(cat "$response_file" 2>/dev/null)
    rm -f "$response_file" "$header_file"
    
    if [ "$http_code" != "200" ]; then
        error "Failed to fetch workspaces (HTTP $http_code)" >&2
        return 1
    fi
    
    # Extract first workspace ID (output only to stdout)
    local workspace_id=$(echo "$body" | python3 -c "
import sys, json
data = json.load(sys.stdin)
workspaces = data.get('data', [])
if workspaces:
    print(workspaces[0]['gid'])
" 2>/dev/null)
    
    if [ -z "$workspace_id" ]; then
        error "No workspaces found" >&2
        return 1
    fi
    
    # Output ONLY the workspace ID (no log messages)
    echo "$workspace_id"
}

# Fetch projects from a workspace
fetch_projects() {
    local token="$1"
    local workspace_id="$2"
    local api_url="https://app.asana.com/api/1.0"
    
    # Validate inputs
    if [ -z "$token" ]; then
        error "Token is empty in fetch_projects" >&2
        return 1
    fi
    if [ -z "$workspace_id" ]; then
        error "Workspace ID is empty in fetch_projects" >&2
        return 1
    fi
    
    log "Fetching projects from workspace..." >&2
    
    local all_projects="[]"
    local offset=""
    local page=1
    
    while true; do
        local url="${api_url}/projects?workspace=${workspace_id}&opt_fields=gid,name,archived&limit=100"
        if [ -n "$offset" ]; then
            url="${url}&offset=${offset}"
        fi
        
        local response_file=$(mktemp)
        local header_file=$(mktemp)
        
        # Fetch with headers to get status code
        local http_code=$(curl -s -o "$response_file" -D "$header_file" \
            -H "Authorization: Bearer ${token}" \
            -H "Accept: application/json" \
            -w "%{http_code}" \
            "$url" 2>/dev/null)
        
        # If http_code from -w is empty, try to extract from headers
        if [ -z "$http_code" ] || ! echo "$http_code" | grep -qE '^[0-9]{3}$'; then
            http_code=$(grep -i "^HTTP" "$header_file" | head -1 | awk '{print $2}')
        fi
        
        local body=$(cat "$response_file" 2>/dev/null)
        rm -f "$response_file" "$header_file"
        
        # Validate http_code
        if [ -z "$http_code" ] || ! echo "$http_code" | grep -qE '^[0-9]{3}$'; then
            error "Invalid HTTP code received: '$http_code'. Body length: ${#body}"
            if [ ${#body} -gt 0 ]; then
                error "Body preview: ${body:0:200}"
            fi
            return 1
        fi
        
        if [ "$http_code" != "200" ]; then
            error "Failed to fetch projects (HTTP $http_code): ${body:0:500}"
            return 1
        fi
        
        if [ -z "$body" ] || [ "$body" = "null" ]; then
            break
        fi
        
        local projects=$(echo "$body" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    projects = data.get('data', [])
    print(json.dumps(projects))
except Exception as e:
    sys.exit(1)
" 2>/dev/null)
        
        if [ $? -ne 0 ] || [ -z "$projects" ] || [ "$projects" = "[]" ]; then
            break
        fi
        
        # Merge projects arrays properly using temp files to avoid shell escaping issues
        local temp_all=$(mktemp)
        local temp_new=$(mktemp)
        echo "$all_projects" > "$temp_all"
        echo "$projects" > "$temp_new"
        
        all_projects=$(python3 -c "
import sys, json
try:
    with open('$temp_all', 'r') as f:
        all = json.load(f)
    with open('$temp_new', 'r') as f:
        new = json.load(f)
    all.extend(new)
    print(json.dumps(all))
except Exception as e:
    sys.exit(1)
" 2>/dev/null)
        
        rm -f "$temp_all" "$temp_new"
        
        if [ $? -ne 0 ] || [ -z "$all_projects" ]; then
            error "Failed to merge projects JSON"
            break
        fi
        
        offset=$(echo "$body" | python3 -c "
import sys, json
data = json.load(sys.stdin)
next_page = data.get('next_page')
if next_page:
    print(next_page.get('offset', ''))
" 2>/dev/null || echo "")
        
        if [ -z "$offset" ]; then
            break
        fi
        
        page=$((page + 1))
    done
    
    echo "$all_projects"
}

# Fetch tasks from a specific project
fetch_tasks_from_project() {
    local token="$1"
    local project_id="$2"
    local api_url="https://app.asana.com/api/1.0"
    local request_url="${api_url}/tasks"
    local query_params="opt_fields=gid,name,custom_fields,modified_at,parent,memberships&limit=100&project=${project_id}"
    
    local all_tasks="[]"
    local offset=""
    
    while true; do
        local url="${request_url}?${query_params}"
        if [ -n "$offset" ]; then
            url="${url}&offset=${offset}"
        fi
        
        local response_file=$(mktemp)
        local error_file=$(mktemp)
        local http_code=$(curl --fail-with-body -s -o "$response_file" -w "%{http_code}" \
            -H "Authorization: Bearer ${token}" \
            -H "Accept: application/json" \
            "$url" 2>"$error_file")
        
        local curl_exit=$?
        local body=$(cat "$response_file" 2>/dev/null)
        rm -f "$response_file" "$error_file"
        
        if [ "$http_code" != "200" ]; then
            warning "Failed to fetch tasks from project (HTTP $http_code), skipping..."
            break
        fi
        
        local tasks=$(echo "$body" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tasks = data.get('data', [])
print(json.dumps(tasks))
" 2>/dev/null)
        
        if [ -z "$tasks" ] || [ "$tasks" = "[]" ]; then
            break
        fi
        
        # Merge tasks using temp files to avoid shell escaping issues
        local temp_all=$(mktemp)
        local temp_new=$(mktemp)
        echo "$all_tasks" > "$temp_all"
        echo "$tasks" > "$temp_new"
        
        all_tasks=$(python3 -c "
import sys, json
try:
    with open('$temp_all', 'r') as f:
        all = json.load(f)
    with open('$temp_new', 'r') as f:
        new = json.load(f)
    all.extend(new)
    print(json.dumps(all))
except Exception as e:
    print('[]', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)
        
        if [ $? -ne 0 ]; then
            all_tasks="[]"
        fi
        
        rm -f "$temp_all" "$temp_new"
        
        offset=$(echo "$body" | python3 -c "
import sys, json
data = json.load(sys.stdin)
next_page = data.get('next_page')
if next_page:
    print(next_page.get('offset', ''))
" 2>/dev/null || echo "")
        
        if [ -z "$offset" ]; then
            break
        fi
    done
    
    echo "$all_tasks"
}

# Fetch tasks from workspace (using assignee filter)
fetch_tasks_from_workspace() {
    local token="$1"
    local workspace_id="$2"
    local api_url="https://app.asana.com/api/1.0"
    local request_url="${api_url}/tasks"
    local query_params="opt_fields=gid,name,custom_fields,modified_at,parent,memberships&limit=100&workspace=${workspace_id}&assignee=me"
    
    local all_tasks="[]"
    local offset=""
    
    while true; do
        local url="${request_url}?${query_params}"
        if [ -n "$offset" ]; then
            url="${url}&offset=${offset}"
        fi
        
        local response_file=$(mktemp)
        local error_file=$(mktemp)
        local http_code=$(curl --fail-with-body -s -o "$response_file" -w "%{http_code}" \
            -H "Authorization: Bearer ${token}" \
            -H "Accept: application/json" \
            "$url" 2>"$error_file")
        
        local curl_exit=$?
        local body=$(cat "$response_file" 2>/dev/null)
        rm -f "$response_file" "$error_file"
        
        if [ "$http_code" != "200" ]; then
            error "Failed to fetch tasks from workspace (HTTP $http_code): ${body:0:500}"
            return 1
        fi
        
        local tasks=$(echo "$body" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tasks = data.get('data', [])
print(json.dumps(tasks))
" 2>/dev/null)
        
        if [ -z "$tasks" ] || [ "$tasks" = "[]" ]; then
            break
        fi
        
        # Merge tasks using temp files to avoid shell escaping issues
        local temp_all=$(mktemp)
        local temp_new=$(mktemp)
        echo "$all_tasks" > "$temp_all"
        echo "$tasks" > "$temp_new"
        
        all_tasks=$(python3 -c "
import sys, json
try:
    with open('$temp_all', 'r') as f:
        all = json.load(f)
    with open('$temp_new', 'r') as f:
        new = json.load(f)
    all.extend(new)
    print(json.dumps(all))
except Exception as e:
    print('[]', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)
        
        if [ $? -ne 0 ]; then
            all_tasks="[]"
        fi
        
        rm -f "$temp_all" "$temp_new"
        
        offset=$(echo "$body" | python3 -c "
import sys, json
data = json.load(sys.stdin)
next_page = data.get('next_page')
if next_page:
    print(next_page.get('offset', ''))
" 2>/dev/null || echo "")
        
        if [ -z "$offset" ]; then
            break
        fi
    done
    
    echo "$all_tasks"
}

# Sync with Asana API and save cache
sync_asana_cache() {
    local token="$1"
    local temp_file=$(mktemp)
    local api_url="https://app.asana.com/api/1.0"
    
    log "Starting Asana sync..."
    
    # Determine workspace and projects to fetch from
    local workspace_id="$WORKSPACE_ID"
    local project_id="$PROJECT_ID"
    
    # If no workspace specified, fetch it
    if [ -z "$workspace_id" ]; then
        workspace_id=$(fetch_workspaces "$token")
        if [ -z "$workspace_id" ]; then
            error "Could not determine workspace ID"
            rm -f "$temp_file"
            exit 1
        fi
        log "Using workspace: $workspace_id"
    fi
    
    # Validate token is not empty
    if [ -z "$token" ]; then
        error "Token is empty in sync_asana_cache function"
        rm -f "$temp_file"
        exit 1
    fi
    
    # Fetch all tasks from projects
    local all_tasks="[]"
    
    if [ -n "$project_id" ]; then
        # Fetch from specific project
        log "Fetching tasks from project: $project_id"
        all_tasks=$(fetch_tasks_from_project "$token" "$project_id")
    else
        # Fetch all projects and get tasks from each
        local projects_json=$(fetch_projects "$token" "$workspace_id")
        
        if [ -z "$projects_json" ] || [ "$projects_json" = "[]" ]; then
            warning "No projects found, trying to fetch tasks directly from workspace"
            all_tasks=$(fetch_tasks_from_workspace "$token" "$workspace_id")
        else
            # Get project count and list
            local projects_file=$(mktemp)
            echo "$projects_json" | python3 -c "
import sys, json
projects = json.load(sys.stdin)
active_projects = [p for p in projects if not p.get('archived', False)]
print(json.dumps(active_projects))
" > "$projects_file"
            
            local project_count=$(cat "$projects_file" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null)
            log "Found $project_count projects, fetching tasks from each..."
            
            # Fetch tasks from each project and accumulate in a file
            local all_tasks_file=$(mktemp)
            echo "[]" > "$all_tasks_file"
            local project_index=0
            
            cat "$projects_file" | python3 -c "
import sys, json
projects = json.load(sys.stdin)
for project in projects:
    print(project['gid'])
" | while read -r proj_id; do
                if [ -n "$proj_id" ]; then
                    project_index=$((project_index + 1))
                    if [ $((project_index % 10)) -eq 0 ] || [ $project_index -eq 1 ]; then
                        log "Progress: $project_index/$project_count projects" >&2
                    fi
                    
                    local project_tasks=$(fetch_tasks_from_project "$token" "$proj_id" 2>/dev/null)
                    if [ -n "$project_tasks" ] && [ "$project_tasks" != "[]" ]; then
                        # Merge into all_tasks_file
                        python3 -c "
import sys, json
with open('$all_tasks_file', 'r') as f:
    all = json.load(f)
new = json.loads('''$project_tasks''')
all.extend(new)
with open('$all_tasks_file', 'w') as f:
    json.dump(all, f)
" 2>/dev/null
                    fi
                fi
            done
            
            # Read merged tasks
            all_tasks=$(cat "$all_tasks_file" 2>/dev/null)
            rm -f "$projects_file" "$all_tasks_file"
        fi
    fi
    
    log "Fetched tasks, parsing dockets..."
    
    # Parse dockets from tasks (simplified - you may need to adjust based on your parsing logic)
    # This is a simplified version - the full parsing logic is in AsanaService.swift
    local dockets=$(echo "$all_tasks" | python3 << 'PYTHON_SCRIPT'
import sys
import json
import re
from datetime import datetime

tasks = json.load(sys.stdin)
dockets = []

# Docket pattern: 5 digits optionally followed by -XX
docket_pattern = re.compile(r'\d{5}(?:-[A-Z]{1,3})?')

for task in tasks:
    name = task.get('name', '')
    
    # Find docket number
    match = docket_pattern.search(name)
    if match:
        docket = match.group()
        
        # Extract job name (remove docket and clean up)
        job_name = name
        if match:
            job_name = name[:match.start()] + name[match.end():]
            job_name = re.sub(r'^[_\s-]+', '', job_name)  # Remove leading separators
            job_name = re.sub(r'[_\s-]+$', '', job_name)  # Remove trailing separators
            job_name = re.sub(r'\s+', ' ', job_name).strip()  # Collapse spaces
        
        if not job_name:
            job_name = name
        
        # Extract metadata type
        metadata_type = None
        for keyword in ["SESSION REPORT", "JOB INFO", "SESSION", "PREP", "POST"]:
            if re.match(rf'^\s*{re.escape(keyword)}(\s*-\s*|\s+|$)', name, re.IGNORECASE):
                metadata_type = keyword.uppercase()
                break
        
        # Parse modified_at
        modified_at = None
        if task.get('modified_at'):
            try:
                modified_at = task['modified_at']
            except:
                pass
        
        docket_info = {
            "id": str(task.get('gid', '')),
            "number": docket,
            "jobName": job_name,
            "fullName": f"{docket}_{job_name}",
            "updatedAt": modified_at,
            "metadataType": metadata_type,
            "subtasks": None
        }
        
        dockets.append(docket_info)

# Create cache structure
cache = {
    "dockets": dockets,
    "lastSync": datetime.utcnow().isoformat() + "Z"
}

print(json.dumps(cache, indent=2))
PYTHON_SCRIPT
)
    
    # Save to temporary file first, then move to final location (atomic write)
    echo "$dockets" > "$temp_file"
    
    # Validate JSON before moving
    if ! echo "$dockets" | python3 -m json.tool > /dev/null 2>&1; then
        error "Generated cache is not valid JSON!"
        rm -f "$temp_file"
        exit 1
    fi
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$CACHE_PATH")"
    
    # Move to final location (atomic)
    mv "$temp_file" "$CACHE_PATH"
    
    local docket_count=$(echo "$dockets" | python3 -c "import sys, json; print(len(json.load(sys.stdin)['dockets']))")
    log "Successfully synced $docket_count dockets to: $CACHE_PATH"
}

# Main execution
main() {
    log "MediaDash Shared Cache Sync Script"
    log "=================================="
    
    # Check if server is available
    check_server_path
    
    # Get access token
    local token=$(get_access_token)
    if [ -z "$token" ]; then
        exit 1
    fi
    
    # Sync cache
    sync_asana_cache "$token"
    
    log "Sync complete!"
}

# Run main function
main


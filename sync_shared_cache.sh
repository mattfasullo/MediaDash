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
        echo "Script is already running (PID: $OLD_PID). Use 'tail -f $LOG_FILE' to monitor progress." >&2
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
# Use process substitution to tee both stdout and stderr to the log file
exec 1> >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

set -e  # Exit on error

# Configuration
CACHE_DIR="/Volumes/Grayson Assets/MEDIA/Media Dept Misc. Folders/Misc./MediaDash_Cache"
CACHE_FILENAME="mediadash_docket_cache.json"
CACHE_PATH="${CACHE_DIR}/${CACHE_FILENAME}"
ASANA_ACCESS_TOKEN=""  # Will be read from keychain or environment variable
WORKSPACE_ID="${WORKSPACE_ID:-}"  # Read from environment variable (set by launchd plist)
PROJECT_ID="${PROJECT_ID:-}"      # Read from environment variable (set by launchd plist)

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
    if [ ! -d "$CACHE_DIR" ]; then
        error "Server path not available: $CACHE_DIR"
        error "Make sure the server is mounted before running this script"
        exit 1
    fi
    
    log "Server path is available: $CACHE_DIR"
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
        if [ "$http_code" = "401" ]; then
            error "Authentication failed (HTTP 401) - Asana access token is invalid or expired" >&2
            error "Please re-authenticate in MediaDash or update your access token" >&2
        else
            error "Failed to fetch workspaces (HTTP $http_code)" >&2
            if [ -n "$body" ]; then
                error "Response: ${body:0:500}" >&2
            fi
        fi
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
            if [ "$http_code" = "401" ]; then
                error "Authentication failed (HTTP 401) - Asana access token is invalid or expired"
                error "Please re-authenticate in MediaDash or update your access token"
            else
                error "Failed to fetch projects (HTTP $http_code): ${body:0:500}"
            fi
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
# Fetches ALL tasks with pagination until complete (or only modified since date if provided)
# Returns 0 on success, non-zero on failure
fetch_tasks_from_project() {
    local token="$1"
    local project_id="$2"
    local modified_since="${3:-}"  # Optional: ISO 8601 date string (e.g., "2024-01-01T00:00:00Z")
    local api_url="https://app.asana.com/api/1.0"
    local request_url="${api_url}/tasks"
    local query_params="opt_fields=gid,name,custom_fields,modified_at,parent,memberships&limit=100&project=${project_id}"
    
    # Add modified_since parameter for incremental sync
    if [ -n "$modified_since" ]; then
        query_params="${query_params}&modified_since=${modified_since}"
    fi
    
    local all_tasks="[]"
    local offset=""
    local page=1
    local max_pages=1000  # Safety limit to prevent infinite loops
    
    while true; do
        local url="${request_url}?${query_params}"
        if [ -n "$offset" ]; then
            url="${url}&offset=${offset}"
        fi
        
        local response_file=$(mktemp)
        local error_file=$(mktemp)
        # Add timeout (30 seconds) and max time (60 seconds total) to prevent hanging
        local http_code=$(curl --max-time 60 --connect-timeout 30 --fail-with-body -s -o "$response_file" -w "%{http_code}" \
            -H "Authorization: Bearer ${token}" \
            -H "Accept: application/json" \
            "$url" 2>"$error_file")
        
        local curl_exit=$?
        local body=$(cat "$response_file" 2>/dev/null)
        local curl_error=$(cat "$error_file" 2>/dev/null)
        rm -f "$response_file" "$error_file"
        
        if [ "$http_code" != "200" ]; then
            if [ "$http_code" = "401" ]; then
                error "Authentication failed (HTTP 401) - Asana access token is invalid or expired"
                error "Please re-authenticate in MediaDash or update your access token"
                return 1
            elif [ -n "$curl_error" ]; then
                warning "Failed to fetch tasks from project $project_id page $page (HTTP $http_code): ${curl_error:0:200}"
            else
                warning "Failed to fetch tasks from project $project_id page $page (HTTP $http_code), skipping..."
            fi
            break
        fi
        
        if [ $curl_exit -ne 0 ]; then
            warning "Curl error ($curl_exit) fetching project $project_id page $page: ${curl_error:0:200}, skipping..."
            break
        fi
        
        local tasks=$(echo "$body" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tasks = data.get('data', [])
print(json.dumps(tasks))
" 2>/dev/null)
        
        if [ -z "$tasks" ] || [ "$tasks" = "[]" ]; then
            # No more tasks on this page
            break
        fi
        
        local task_count=$(echo "$tasks" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
        local current_total=$(echo "$all_tasks" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
        if [ "$page" -eq 1 ] || [ $((page % 10)) -eq 0 ]; then
            log "  Project $project_id: Page $page - fetched $task_count tasks (total: $current_total)" >&2
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
            # No more pages - all tasks fetched
            local final_count=$(echo "$all_tasks" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
            log "  Project $project_id: Complete - fetched $final_count total tasks across $page pages" >&2
            break
        fi
        
        page=$((page + 1))
        
        # Safety check to prevent infinite loops
        if [ $page -gt $max_pages ]; then
            warning "Reached max pages limit ($max_pages) for project $project_id, stopping pagination"
            break
        fi
    done
    
    echo "$all_tasks"
    return 0
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
            if [ "$http_code" = "401" ]; then
                error "Authentication failed (HTTP 401) - Asana access token is invalid or expired"
                error "Please re-authenticate in MediaDash or update your access token"
            else
                error "Failed to fetch tasks from workspace (HTTP $http_code): ${body:0:500}"
            fi
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
    
    # Log configuration
    if [ -n "$project_id" ]; then
        log "Configuration: Using specific project ID: $project_id"
    elif [ -n "$workspace_id" ]; then
        log "Configuration: Using workspace ID: $workspace_id (will fetch all projects)"
    else
        log "Configuration: No project/workspace specified, will auto-detect workspace and fetch all projects"
    fi
    
    # Validate token is not empty
    if [ -z "$token" ]; then
        error "Token is empty in sync_asana_cache function"
        rm -f "$temp_file"
        exit 1
    fi
    
    # If no workspace specified, fetch it (this also validates the token)
    if [ -z "$workspace_id" ]; then
        workspace_id=$(fetch_workspaces "$token")
        if [ -z "$workspace_id" ]; then
            error "Could not determine workspace ID - authentication may have failed"
            error "Please check your Asana access token"
            rm -f "$temp_file"
            exit 1
        fi
        log "Auto-detected workspace: $workspace_id"
    else
        log "Using configured workspace: $workspace_id"
        # Still validate token by attempting a workspace fetch
        if ! fetch_workspaces "$token" > /dev/null 2>&1; then
            error "Token validation failed - cannot authenticate with Asana API"
            error "Please check your access token in MediaDash settings or keychain"
            rm -f "$temp_file"
            exit 1
        fi
    fi
    
    # Fetch all tasks from projects
    local all_tasks="[]"
    
    if [ -n "$project_id" ]; then
        # Fetch from specific project (much faster!)
        log "Fetching ALL tasks from specific project: $project_id"
        log "This will fetch all tasks with pagination until complete..."
        all_tasks=$(fetch_tasks_from_project "$token" "$project_id")
        local task_count=$(echo "$all_tasks" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
        log "Fetched $task_count tasks from project $project_id"
    else
        # Fetch all projects and get tasks from each
        local projects_json=$(fetch_projects "$token" "$workspace_id")
        
        if [ -z "$projects_json" ] || [ "$projects_json" = "[]" ]; then
            error "No projects found"
            rm -f "$temp_file"
            exit 1
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
            log "Found $project_count active projects, fetching ALL tasks from each..."
            log "NOTE: This will sync ALL projects. With $project_count projects, this may take several hours to complete."
            
            # Fetch tasks from each project and accumulate in a file
            # Use parallel processing (max 10 concurrent requests) to speed things up
            local all_tasks_file=$(mktemp)
            echo "[]" > "$all_tasks_file"
            local project_index=0
            local total_tasks=0
            local start_time=$(date +%s)
            local max_jobs=10  # Process up to 10 projects concurrently
            local job_count=0
            local project_results_dir=$(mktemp -d)
            
            # Function to fetch tasks from a single project
            fetch_project_tasks_worker() {
                local proj_id="$1"
                local result_file="$2"
                local worker_token="$3"
                
                local project_tasks=$(fetch_tasks_from_project "$worker_token" "$proj_id" 2>&1)
                echo "$project_tasks" > "$result_file"
            }
            
            # Array to track background job PIDs
            declare -a job_pids=()
            
            # Read project IDs into an array first (avoid subshell issue with pipe)
            declare -a project_ids=()
            while IFS= read -r proj_id; do
                if [ -n "$proj_id" ]; then
                    project_ids+=("$proj_id")
                fi
            done < <(python3 -c "
import sys, json
projects = json.load(sys.stdin)
for project in projects:
    print(project['gid'])
" < "$projects_file")
            
            local total_projects_to_process=${#project_ids[@]}
            log "Starting to process $total_projects_to_process projects with max $max_jobs concurrent jobs..." >&2
            
            # Process each project
            for proj_id in "${project_ids[@]}"; do
                project_index=$((project_index + 1))
                local result_file="${project_results_dir}/project_${project_index}.json"
                
                # Start background job to fetch tasks
                fetch_project_tasks_worker "$proj_id" "$result_file" "$token" &
                local job_pid=$!
                job_pids+=($job_pid)
                job_count=$((job_count + 1))
                
                # Wait when we hit max concurrent jobs, or process completed jobs
                while [ $job_count -ge $max_jobs ]; do
                    # Wait for any background job to complete (compatible with older bash)
                    local completed=false
                    for i in "${!job_pids[@]}"; do
                        local pid="${job_pids[$i]}"
                        if ! kill -0 "$pid" 2>/dev/null; then
                            # Job completed
                            wait "$pid" 2>/dev/null
                            unset 'job_pids[$i]'
                            job_pids=("${job_pids[@]}")
                            job_count=$((job_count - 1))
                            completed=true
                            break
                        fi
                    done
                    if [ "$completed" = false ]; then
                        # No job completed yet, wait a bit
                        sleep 0.1
                    fi
                    
                    # Process completed results
                    for completed_file in "${project_results_dir}"/project_*.json; do
                        if [ -f "$completed_file" ] && [ ! -f "${completed_file}.processed" ]; then
                            local project_tasks=$(cat "$completed_file" 2>/dev/null)
                            if [ -n "$project_tasks" ] && [ "$project_tasks" != "[]" ]; then
                                local task_count=$(echo "$project_tasks" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
                                total_tasks=$((total_tasks + task_count))
                                
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
                            touch "${completed_file}.processed"
                        fi
                    done
                    
                    # Log progress (more frequently for first 100 projects, then every 50)
                    local current_time=$(date +%s)
                    local elapsed=$((current_time - start_time))
                    local processed_count=$(find "$project_results_dir" -name "*.processed" 2>/dev/null | wc -l | tr -d ' ')
                    local should_log=false
                    if [ $processed_count -le 100 ] && [ $((processed_count % 10)) -eq 0 ]; then
                        should_log=true
                    elif [ $processed_count -gt 100 ] && [ $((processed_count % 50)) -eq 0 ]; then
                        should_log=true
                    fi
                    if [ "$should_log" = true ] || [ $processed_count -eq 1 ]; then
                        log "Progress: $processed_count/$project_count projects completed, $total_tasks total tasks fetched so far (elapsed: ${elapsed}s)" >&2
                    fi
                done
            done
            
            # Wait for all remaining background jobs to complete
            for pid in "${job_pids[@]}"; do
                wait "$pid" 2>/dev/null
            done
            
            # Process any remaining completed results
            for completed_file in "${project_results_dir}"/project_*.json; do
                if [ -f "$completed_file" ] && [ ! -f "${completed_file}.processed" ]; then
                    local project_tasks=$(cat "$completed_file" 2>/dev/null)
                    if [ -n "$project_tasks" ] && [ "$project_tasks" != "[]" ]; then
                        local task_count=$(echo "$project_tasks" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
                        total_tasks=$((total_tasks + task_count))
                        
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
                    touch "${completed_file}.processed"
                fi
            done
            
            # Read merged tasks
            all_tasks=$(cat "$all_tasks_file" 2>/dev/null)
            local final_task_count=$(echo "$all_tasks" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
            local end_time=$(date +%s)
            local total_elapsed=$((end_time - start_time))
            log "Completed: Fetched $final_task_count total tasks from $project_count projects in ${total_elapsed} seconds"
            rm -f "$projects_file" "$all_tasks_file"
        fi
    fi
    
    log "Fetched tasks, parsing dockets..."
    
    # Parse dockets from tasks
    local new_dockets=$(echo "$all_tasks" | python3 << 'PYTHON_SCRIPT'
import sys
import json
import re
import hashlib
from datetime import datetime

CACHE_FORMAT_VERSION = 2  # Must match CacheFormat.version in SharedComponents.swift

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
                metadata_type = keyword.upper()
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

# Compute integrity checksum (SHA256 of sorted fullNames joined by |)
sorted_names = sorted([d['fullName'] for d in dockets])
checksum_data = '|'.join(sorted_names)
checksum = hashlib.sha256(checksum_data.encode()).hexdigest()

now = datetime.utcnow().isoformat() + "Z"

# Create cache structure with integrity metadata
cache = {
    "dockets": dockets,
    "lastSync": now,
    "integrity": {
        "version": CACHE_FORMAT_VERSION,
        "docketCount": len(dockets),
        "checksum": checksum,
        "computedAt": now
    }
}

print(json.dumps(dockets, indent=2))
PYTHON_SCRIPT
)
    
    # If incremental sync, merge with existing dockets
    if [ -n "$modified_since" ] && [ -f "$CACHE_PATH" ]; then
        log "Merging new dockets with existing cache..."
        local final_dockets=$(python3 -c "
import sys, json

# Read existing cache
with open('$CACHE_PATH', 'r') as f:
    existing = json.load(f)

existing_dockets = existing.get('dockets', [])
existing_docket_map = {docket['id']: docket for docket in existing_dockets}

# Parse new dockets
new_dockets_str = '''$new_dockets'''
try:
    new_dockets = json.loads(new_dockets_str)
except:
    new_dockets = []

# Merge: update existing dockets with new data, add new ones
for new_docket in new_dockets:
    docket_id = new_docket.get('id')
    if docket_id:
        existing_docket_map[docket_id] = new_docket

# Convert back to list
all_dockets = list(existing_docket_map.values())
print(json.dumps(all_dockets))
")
        
        # Create final cache structure
        local final_cache=$(python3 -c "
import sys, json
from datetime import datetime

dockets = json.loads('''$final_dockets''')

# Compute integrity checksum
sorted_names = sorted([d['fullName'] for d in dockets if 'fullName' in d])
import hashlib
checksum_data = '|'.join(sorted_names)
checksum = hashlib.sha256(checksum_data.encode()).hexdigest()

now = datetime.utcnow().isoformat() + 'Z'

cache = {
    'dockets': dockets,
    'lastSync': now,
    'integrity': {
        'version': 2,
        'docketCount': len(dockets),
        'checksum': checksum,
        'computedAt': now
    }
}

print(json.dumps(cache, indent=2))
")
        
        echo "$final_cache" > "$temp_file"
    else
        # Full sync: use the parsed dockets directly (need to wrap in cache structure)
        local final_cache=$(echo "$new_dockets" | python3 -c "
import sys, json
import hashlib
from datetime import datetime

dockets = json.load(sys.stdin)

# Compute integrity checksum
sorted_names = sorted([d['fullName'] for d in dockets if 'fullName' in d])
checksum_data = '|'.join(sorted_names)
checksum = hashlib.sha256(checksum_data.encode()).hexdigest()

now = datetime.utcnow().isoformat() + 'Z'

cache = {
    'dockets': dockets,
    'lastSync': now,
    'integrity': {
        'version': 2,
        'docketCount': len(dockets),
        'checksum': checksum,
        'computedAt': now
    }
}

print(json.dumps(cache, indent=2))
")
        
        echo "$final_cache" > "$temp_file"
    fi
    
    # Validate JSON before moving
    if ! echo "$dockets" | python3 -m json.tool > /dev/null 2>&1; then
        error "Generated cache is not valid JSON!"
        rm -f "$temp_file"
        exit 1
    fi
    
    # Create directory if it doesn't exist
    mkdir -p "$CACHE_DIR"
    
    # Move to final location (atomic)
    mv "$temp_file" "$CACHE_PATH"
    
    local docket_count=$(echo "$final_cache" | python3 -c "import sys, json; print(len(json.load(sys.stdin)['dockets']))")
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


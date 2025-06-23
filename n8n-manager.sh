#!/usr/bin/env bash
# =========================================================
# n8n-manager.sh - Interactive backup/restore for n8n
# =========================================================
set -Eeuo pipefail
IFS=$'\n\t'

# --- Configuration ---
CONFIG_FILE_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/n8n-manager/config"

# --- Global variables ---
VERSION="3.0.25"
DEBUG_TRACE=${DEBUG_TRACE:-false} # Set to true for trace debugging
SELECTED_ACTION=""
SELECTED_CONTAINER_ID=""
GITHUB_TOKEN=""
GITHUB_REPO=""
GITHUB_BRANCH="main"
DEFAULT_CONTAINER=""
SELECTED_RESTORE_TYPE="all"
# Flags/Options
ARG_ACTION=""
ARG_CONTAINER=""
ARG_TOKEN=""
ARG_REPO=""
ARG_BRANCH=""
ARG_CONFIG_FILE=""
ARG_DATED_BACKUPS=false
ARG_RESTORE_TYPE="all"
ARG_DRY_RUN=false
ARG_VERBOSE=false
ARG_LOG_FILE=""
# New enhancement flags
ARG_WORKFLOW_ID=""
ARG_CREDENTIAL_ID=""
ARG_USER_ID=""
ARG_PROJECT_ID=""
ARG_SEPARATE_FILES=false
ARG_IMPORT_AS_NEW=false
ARG_INCLUDE_LINKED_CREDS=false
ARG_INCREMENTAL=false
CONF_DATED_BACKUPS=false
CONF_VERBOSE=false
CONF_LOG_FILE=""
# New configuration options
CONF_SEPARATE_FILES=false

# ANSI colors for better UI (using printf for robustness)
printf -v RED     '\033[0;31m'
printf -v GREEN   '\033[0;32m'
printf -v BLUE    '\033[0;34m'
printf -v YELLOW  '\033[1;33m'
printf -v NC      '\033[0m' # No Color
printf -v BOLD    '\033[1m'
printf -v DIM     '\033[2m'

# --- Logging Functions ---

# --- Git Helper Functions ---
# These functions isolate Git operations to avoid parse errors
git_add() {
    local repo_dir="$1"
    local target="$2"
    git -C "$repo_dir" add "$target"
    return $?
}

git_commit() {
    local repo_dir="$1"
    local message="$2"
    git -C "$repo_dir" commit -m "$message"
    return $?
}

git_push() {
    local repo_dir="$1"
    local remote="$2"
    local branch="$3"
    git -C "$repo_dir" push -u "$remote" "$branch"
    return $?
}

# --- Debug/Trace Function ---
trace_cmd() {
    if $DEBUG_TRACE; then
        echo -e "\033[0;35m[TRACE] Running command: $*\033[0m" >&2
        "$@"
        local ret=$?
        echo -e "\033[0;35m[TRACE] Command returned: $ret\033[0m" >&2
        return $ret
    else
        "$@"
        return $?
    fi
}

# Simplified and sanitized log function to avoid command not found errors
log() {
    # Define parameters
    local level="$1"
    local message="$2"
    
    # Skip debug messages if verbose is not enabled
    if [ "$level" = "DEBUG" ] && [ "$ARG_VERBOSE" != "true" ]; then 
        return 0;
    fi
    
    # Set color based on level
    local color=""
    local prefix=""
    local to_stderr=false
    
    if [ "$level" = "DEBUG" ]; then
        color="$DIM"
        prefix="[DEBUG]"
    elif [ "$level" = "INFO" ]; then
        color="$BLUE"
        prefix="==>"
    elif [ "$level" = "WARN" ]; then
        color="$YELLOW"
        prefix="[WARNING]"
    elif [ "$level" = "ERROR" ]; then
        color="$RED"
        prefix="[ERROR]"
        to_stderr=true
    elif [ "$level" = "SUCCESS" ]; then
        color="$GREEN"
        prefix="[SUCCESS]"
    elif [ "$level" = "HEADER" ]; then
        color="$BLUE$BOLD"
        message="\n$message\n"
    elif [ "$level" = "DRYRUN" ]; then
        color="$YELLOW"
        prefix="[DRY RUN]"
    else
        prefix="[$level]"
    fi
    
    # Format message
    local formatted="${color}${prefix} ${message}${NC}"
    local plain="$(date +'%Y-%m-%d %H:%M:%S') ${prefix} ${message}"
    
    # Output
    if [ "$to_stderr" = "true" ]; then
        echo -e "$formatted" >&2
    else
        echo -e "$formatted"
    fi
    
    # Log to file if specified
    if [ -n "$ARG_LOG_FILE" ]; then
        echo "$plain" >> "$ARG_LOG_FILE"
    fi
    
    return 0
}

# --- Helper Functions (using new log function) ---

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_host_dependencies() {
    log HEADER "Checking host dependencies..."
    local missing_deps=""
    if ! command_exists docker; then
        missing_deps="$missing_deps docker"
    fi
    if ! command_exists git; then
        missing_deps="$missing_deps git"
    fi
    if ! command_exists curl; then # Added curl check
        missing_deps="$missing_deps curl"
    fi

    if [ -n "$missing_deps" ]; then
        log ERROR "Missing required host dependencies:$missing_deps"
        log INFO "Please install the missing dependencies and try again."
        exit 1
    fi
    log SUCCESS "All required host dependencies are available!"
}

load_config() {
    local file_to_load="${ARG_CONFIG_FILE:-$CONFIG_FILE_PATH}"
    file_to_load="${file_to_load/#\~/$HOME}"

    if [ -f "$file_to_load" ]; then
        log INFO "Loading configuration from $file_to_load..."
        source <(grep -vE '^\s*(#|$)' "$file_to_load" 2>/dev/null || true)
        
        ARG_TOKEN=${ARG_TOKEN:-${CONF_GITHUB_TOKEN:-}}
        ARG_REPO=${ARG_REPO:-${CONF_GITHUB_REPO:-}}
        ARG_BRANCH=${ARG_BRANCH:-${CONF_GITHUB_BRANCH:-main}}
        ARG_CONTAINER=${ARG_CONTAINER:-${CONF_DEFAULT_CONTAINER:-}}
        DEFAULT_CONTAINER=${CONF_DEFAULT_CONTAINER:-}
        
        if ! $ARG_DATED_BACKUPS; then 
            CONF_DATED_BACKUPS_VAL=${CONF_DATED_BACKUPS:-false}
            if [[ "$CONF_DATED_BACKUPS_VAL" == "true" ]]; then ARG_DATED_BACKUPS=true; fi
        fi
        
        ARG_RESTORE_TYPE=${ARG_RESTORE_TYPE:-${CONF_RESTORE_TYPE:-all}}
        
        if ! $ARG_VERBOSE; then
            CONF_VERBOSE_VAL=${CONF_VERBOSE:-false}
            if [[ "$CONF_VERBOSE_VAL" == "true" ]]; then ARG_VERBOSE=true; fi
        fi
        
        ARG_LOG_FILE=${ARG_LOG_FILE:-${CONF_LOG_FILE:-}}
        
    elif [ -n "$ARG_CONFIG_FILE" ]; then
        log WARN "Configuration file specified but not found: $file_to_load"
    fi
    
    if [ -n "$ARG_LOG_FILE" ] && [[ "$ARG_LOG_FILE" != /* ]]; then
        log WARN "Log file path '$ARG_LOG_FILE' is not absolute. Prepending current directory."
        ARG_LOG_FILE="$(pwd)/$ARG_LOG_FILE"
    fi
    
    if [ -n "$ARG_LOG_FILE" ]; then
        log DEBUG "Ensuring log file exists and is writable: $ARG_LOG_FILE"
        mkdir -p "$(dirname "$ARG_LOG_FILE")" || { log ERROR "Could not create directory for log file: $(dirname "$ARG_LOG_FILE")"; exit 1; }
        touch "$ARG_LOG_FILE" || { log ERROR "Log file is not writable: $ARG_LOG_FILE"; exit 1; }
        log INFO "Logging output also to: $ARG_LOG_FILE"
    fi
}

show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Automated backup and restore tool for n8n Docker containers using GitHub.
Reads configuration from ${CONFIG_FILE_PATH} if it exists.

Options:
  --action <action>       Action to perform: 'backup' or 'restore'.
  --container <id|name>   Target Docker container ID or name.
  --token <pat>           GitHub Personal Access Token (PAT).
  --repo <user/repo>      GitHub repository (e.g., 'myuser/n8n-backup').
  --branch <branch>       GitHub branch to use (defaults to 'main').
  --dated                 Create timestamped subdirectory for backups (e.g., YYYY-MM-DD_HH-MM-SS/).
                          Overrides CONF_DATED_BACKUPS in config file.
  --restore-type <type>   Type of restore: 'all' (default), 'workflows', or 'credentials'.
                          Overrides CONF_RESTORE_TYPE in config file.
  
  Selective Backup/Restore:
  --workflow-id <ID>      Export/import a specific workflow by ID instead of all workflows.
                          Use with 'n8n list workflows' to find IDs.
  --credential-id <ID>    Export/import a specific credential by ID instead of all credentials.
                          Use with 'n8n list credentials' to find IDs.
  
  Assignment Options (Restore only):
  --user-id <ID>          Assign imported items to a specific user ID.
  --project-id <ID>       Assign imported items to a specific project ID.
  
  Advanced Options:
  --separate-files        Create individual JSON files per workflow/credential (git-friendly).
                          Backup: Uses 'n8n export --backup' to create separate files.
                          Restore: Imports from directory of separate JSON files.
  --import-as-new         Import items as new copies (strips IDs to avoid overwriting).
                          Useful for cloning workflows or safe imports.
  --include-linked-creds  Include linked credentials in backup (default: false).
  --incremental           Perform incremental backup (default: false).
  
  General Options:
  --dry-run               Simulate the action without making any changes.
  --verbose               Enable detailed debug logging.
  --log-file <path>       Path to a file to append logs to.
  --config <path>         Path to a custom configuration file.
  -h, --help              Show this help message and exit.

Configuration File (${CONFIG_FILE_PATH}):
  Define variables like:
    CONF_GITHUB_TOKEN="ghp_..."
    CONF_GITHUB_REPO="user/repo"
    CONF_GITHUB_BRANCH="main"
    CONF_DEFAULT_CONTAINER="n8n-container-name"
    CONF_DATED_BACKUPS=true # Optional, defaults to false
    CONF_RESTORE_TYPE="all" # Optional, defaults to 'all'
    CONF_SEPARATE_FILES=true # Optional, defaults to false
    CONF_VERBOSE=false      # Optional, defaults to false
    CONF_LOG_FILE="/var/log/n8n-manager.log" # Optional

Examples:
  # Backup all workflows and credentials to GitHub
  $(basename "$0") --action backup --container n8n --repo myuser/n8n-backup

  # Backup a specific workflow with separate files (git-friendly)
  $(basename "$0") --action backup --workflow-id 123 --separate-files --container n8n

  # Restore a specific credential to a project
  $(basename "$0") --action restore --credential-id 456 --project-id 789 --container n8n

  # Safe import without overwriting (import as new)
  $(basename "$0") --action restore --import-as-new --container n8n

Command-line arguments override configuration file settings.
For non-interactive use, required parameters (action, container, token, repo)
can be provided via arguments or the configuration file.
EOF
}

select_container() {
    log HEADER "Selecting n8n container..."
    mapfile -t containers < <(docker ps --format "{{.ID}}\t{{.Names}}\t{{.Image}}" 2>/dev/null || true)

    if [ ${#containers[@]} -eq 0 ]; then
        log ERROR "No running Docker containers found."
        exit 1
    fi

    local n8n_options=()
    local other_options=()
    local all_ids=()
    local default_option_num=-1

    log INFO "${BOLD}Available running containers:${NC}"
    log INFO "${DIM}------------------------------------------------${NC}"
    log INFO "${BOLD}Num\tID (Short)\tName\tImage${NC}"
    log INFO "${DIM}------------------------------------------------${NC}"

    local i=1
    for container_info in "${containers[@]}"; do
        local id name image
        IFS=$'\t' read -r id name image <<< "$container_info"
        local short_id=${id:0:12}
        all_ids+=("$id")
        local display_name="$name"
        local is_default=false

        if [ -n "$DEFAULT_CONTAINER" ] && { [ "$id" = "$DEFAULT_CONTAINER" ] || [ "$name" = "$DEFAULT_CONTAINER" ]; }; then
            is_default=true
            default_option_num=$i
            display_name="${display_name} ${YELLOW}(default)${NC}"
        fi

        local line
        if [[ "$image" == *"n8nio/n8n"* || "$name" == *"n8n"* ]]; then
            line=$(printf "%s%d)%s %s\t%s\t%s %s(n8n)%s" "$GREEN" "$i" "$NC" "$short_id" "$display_name" "$image" "$YELLOW" "$NC")
            n8n_options+=("$line")
        else
            line=$(printf "%d) %s\t%s\t%s" "$i" "$short_id" "$display_name" "$image")
            other_options+=("$line")
        fi
        i=$((i+1))
    done

    for option in "${n8n_options[@]}"; do echo -e "$option"; done
    for option in "${other_options[@]}"; do echo -e "$option"; done
    echo -e "${DIM}------------------------------------------------${NC}"

    local selection
    local prompt_text="Select container number"
    if [ "$default_option_num" -ne -1 ]; then
        prompt_text="$prompt_text [default: $default_option_num]"
    fi
    prompt_text+=": "

    while true; do
        printf "$prompt_text"
        read -r selection
        selection=${selection:-$default_option_num}

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#containers[@]} ]; then
            local selected_full_id="${all_ids[$((selection-1))]}"
            log SUCCESS "Selected container: $selected_full_id"
            SELECTED_CONTAINER_ID="$selected_full_id"
            return
        elif [ -z "$selection" ] && [ "$default_option_num" -ne -1 ]; then
             local selected_full_id="${all_ids[$((default_option_num-1))]}"
             log SUCCESS "Selected container (default): $selected_full_id"
             SELECTED_CONTAINER_ID="$selected_full_id"
             return
        else
            log ERROR "Invalid selection. Please enter a number between 1 and ${#containers[@]}."
        fi
    done
}

select_action() {
    log HEADER "Choose Action"
    echo "1) Backup n8n to GitHub"
    echo "2) Restore n8n from GitHub"
    echo "3) Quit"

    local choice
    while true; do
        printf "\nSelect an option (1-3): "
        read -r choice
        case "$choice" in
            1) SELECTED_ACTION="backup"; return ;; 
            2) SELECTED_ACTION="restore"; return ;; 
            3) log INFO "Exiting..."; exit 0 ;; 
            *) log ERROR "Invalid option. Please select 1, 2, or 3." ;; 
        esac
    done
}

select_restore_type() {
    log HEADER "Choose Restore Type"
    echo "1) All (Workflows & Credentials)"
    echo "2) Workflows Only"
    echo "3) Credentials Only"

    local choice
    while true; do
        printf "\nSelect an option (1-3) [default: 1]: "
        read -r choice
        choice=${choice:-1}
        case "$choice" in
            1) SELECTED_RESTORE_TYPE="all"; return ;; 
            2) SELECTED_RESTORE_TYPE="workflows"; return ;; 
            3) SELECTED_RESTORE_TYPE="credentials"; return ;; 
            *) log ERROR "Invalid option. Please select 1, 2, or 3." ;; 
        esac
    done
}

get_github_config() {
    local local_token="$ARG_TOKEN"
    local local_repo="$ARG_REPO"
    local local_branch="$ARG_BRANCH"

    log HEADER "GitHub Configuration"

    while [ -z "$local_token" ]; do
        printf "Enter GitHub Personal Access Token (PAT): "
        read -s local_token
        echo
        if [ -z "$local_token" ]; then log ERROR "GitHub token is required."; fi
    done

    while [ -z "$local_repo" ]; do
        printf "Enter GitHub repository (format: username/repo): "
        read -r local_repo
        if [ -z "$local_repo" ] || ! echo "$local_repo" | grep -q "/"; then
            log ERROR "Invalid GitHub repository format. It should be 'username/repo'."
            local_repo=""
        fi
    done

    if [ -z "$local_branch" ]; then
         printf "Enter Branch to use [main]: "
         read -r local_branch
         local_branch=${local_branch:-main}
    else
        log INFO "Using branch: $local_branch"
    fi

    GITHUB_TOKEN="$local_token"
    GITHUB_REPO="$local_repo"
    GITHUB_BRANCH="$local_branch"
}

check_github_access() {
    local token="$1"
    local repo="$2"
    local branch="$3"
    local action_type="$4" # 'backup' or 'restore'
    local check_branch_exists=false
    if [[ "$action_type" == "restore" ]]; then
        check_branch_exists=true
    fi

    log HEADER "Checking GitHub Access & Repository Status..."

    # 1. Check Token and Scopes
    log INFO "Verifying GitHub token and permissions..."
    local scopes
    scopes=$(curl -s -I -H "Authorization: token $token" https://api.github.com/user | grep -i '^x-oauth-scopes:' | sed 's/x-oauth-scopes: //i' | tr -d '\r')
    local http_status
    http_status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token $token" https://api.github.com/user)

    log DEBUG "Token check HTTP status: $http_status"
    log DEBUG "Detected scopes: $scopes"

    if [[ "$http_status" -ne 200 ]]; then
        log ERROR "GitHub token is invalid or expired (HTTP Status: $http_status)."
        return 1
    fi

    if ! echo "$scopes" | grep -qE '(^|,) *repo(,|$)'; then
        log ERROR "GitHub token is missing the required 'repo' scope."
        log INFO "Please create a new token with the 'repo' scope selected."
        return 1
    fi
    log SUCCESS "GitHub token is valid and has 'repo' scope."

    # 2. Check Repository Existence
    log INFO "Verifying repository existence: $repo ..."
    http_status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token $token" "https://api.github.com/repos/$repo")
    log DEBUG "Repo check HTTP status: $http_status"

    if [[ "$http_status" -ne 200 ]]; then
        log ERROR "Repository '$repo' not found or access denied (HTTP Status: $http_status)."
        log INFO "Please check the repository name and ensure the token has access."
        return 1
    fi
    log SUCCESS "Repository '$repo' found and accessible."

    # 3. Check Branch Existence (only if needed)
    if $check_branch_exists; then
        log INFO "Verifying branch existence: $branch ..."
        http_status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token $token" "https://api.github.com/repos/$repo/branches/$branch")
        log DEBUG "Branch check HTTP status: $http_status"

        if [[ "$http_status" -ne 200 ]]; then
            log ERROR "Branch '$branch' not found in repository '$repo' (HTTP Status: $http_status)."
            log INFO "Please check the branch name."
            return 1
        fi
        log SUCCESS "Branch '$branch' found in repository '$repo'."
    fi

    log SUCCESS "GitHub access checks passed."
    return 0
}

dockExec() {
    local container_id="$1"
    local cmd="$2"
    local is_dry_run=$3
    local output=""
    local exit_code=0

    if $is_dry_run; then
        log DRYRUN "Would execute in container $container_id: $cmd"
        return 0
    else
        log DEBUG "Executing in container $container_id: $cmd"
        output=$(docker exec "$container_id" sh -c "$cmd" 2>&1) || exit_code=$?
        
        # Use explicit string comparison to avoid empty command errors
        if [ "$ARG_VERBOSE" = "true" ] && [ -n "$output" ]; then
            log DEBUG "Container output:\n$(echo "$output" | sed 's/^/  /')"
        fi
        
        if [ $exit_code -ne 0 ]; then
            log ERROR "Command failed in container (Exit Code: $exit_code): $cmd"
            if [ "$ARG_VERBOSE" != "true" ] && [ -n "$output" ]; then
                log ERROR "Container output:\n$(echo "$output" | sed 's/^/  /')"
            fi
            return 1
        fi
        
        return 0
    fi
}

timestamp() {
    date +"%Y-%m-%d_%H-%M-%S"
}

# --- JSON Helper Functions ---

strip_json_ids() {
    local input_file="$1"
    local output_file="$2" 
    local item_type="${3:-workflow}"  # workflow or credential
    
    # Input validation
    if [ -z "$input_file" ] || [ -z "$output_file" ]; then
        log ERROR "strip_json_ids: Missing required parameters (input_file, output_file)"
        return 1
    fi
    
    if [ ! -f "$input_file" ]; then
        log ERROR "strip_json_ids: Input file does not exist: $input_file"
        return 1
    fi
    
    if [ ! -r "$input_file" ]; then
        log ERROR "strip_json_ids: Cannot read input file: $input_file"
        return 1
    fi
    
    # Check file size to avoid processing empty files
    if [ ! -s "$input_file" ]; then
        log WARN "strip_json_ids: Input file is empty, creating empty output: $input_file"
        echo "[]" > "$output_file"
        return 0
    fi
    
    log DEBUG "strip_json_ids: Processing $item_type IDs from $input_file -> $output_file"
    
    # Try Python3 first (preferred method)
    if command_exists python3; then
        log DEBUG "strip_json_ids: Using Python3 for JSON processing"
        python3 -c "
import json
import sys

def strip_ids_from_json(input_file, output_file, item_type):
    try:
        with open(input_file, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        if not isinstance(data, list):
            print(f'Error: Expected JSON array, got {type(data).__name__}', file=sys.stderr)
            return False
            
        processed_items = []
        for item in data:
            if isinstance(item, dict):
                # Create a copy without the 'id' field
                processed_item = {k: v for k, v in item.items() if k != 'id'}
                processed_items.append(processed_item)
            else:
                processed_items.append(item)
        
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(processed_items, f, indent=2, ensure_ascii=False)
        
        print(f'Processed {len(processed_items)} {item_type}s', file=sys.stderr)
        return True
        
    except json.JSONDecodeError as e:
        print(f'JSON decode error: {e}', file=sys.stderr)
        return False
    except Exception as e:
        print(f'Error processing JSON: {e}', file=sys.stderr)
        return False

if not strip_ids_from_json('$input_file', '$output_file', '$item_type'):
    sys.exit(1)
" 2>/dev/null
        local python_exit=$?
        if [ $python_exit -eq 0 ]; then
            log SUCCESS "strip_json_ids: Successfully processed with Python3"
            return 0
        else
            log WARN "strip_json_ids: Python3 processing failed, trying Node.js"
        fi
    fi
    
    # Try Node.js as fallback
    if command_exists node; then
        log DEBUG "strip_json_ids: Using Node.js for JSON processing"
        node -e "
const fs = require('fs');

function stripIdsFromJson(inputFile, outputFile, itemType) {
    try {
        const data = JSON.parse(fs.readFileSync(inputFile, 'utf8'));
        
        if (!Array.isArray(data)) {
            console.error(\`Error: Expected JSON array, got \${typeof data}\`);
            return false;
        }
        
        const processedItems = data.map(item => {
            if (typeof item === 'object' && item !== null) {
                const { id, ...itemWithoutId } = item;
                return itemWithoutId;
            }
            return item;
        });
        
        fs.writeFileSync(outputFile, JSON.stringify(processedItems, null, 2), 'utf8');
        console.error(\`Processed \${processedItems.length} \${itemType}s\`);
        return true;
        
    } catch (error) {
        console.error(\`Error processing JSON: \${error.message}\`);
        return false;
    }
}

if (!stripIdsFromJson('$input_file', '$output_file', '$item_type')) {
    process.exit(1);
}
" 2>/dev/null
        local node_exit=$?
        if [ $node_exit -eq 0 ]; then
            log SUCCESS "strip_json_ids: Successfully processed with Node.js"
            return 0
        else
            log WARN "strip_json_ids: Node.js processing failed, trying sed fallback"
        fi
    fi
    
    # Fallback to sed (less reliable but works in most cases)
    log DEBUG "strip_json_ids: Using sed fallback for JSON processing"
    if sed 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,*[[:space:]]*$//' "$input_file" > "$output_file"; then
        # Verify the output is still valid JSON by checking basic structure
        if grep -q '\[' "$output_file" && grep -q '\]' "$output_file"; then
            log SUCCESS "strip_json_ids: Successfully processed with sed (basic validation passed)"
            return 0
        else
            log ERROR "strip_json_ids: sed output failed basic JSON validation"
            return 1
        fi
    else
        log ERROR "strip_json_ids: sed processing failed"
        return 1
    fi
}

build_import_command() {
    local base_cmd="$1"
    local input_file="$2"
    local user_id="$3"
    local project_id="$4"
    
    local cmd="$base_cmd --input=$input_file"
    
    # Add user assignment if specified
    if [ -n "$user_id" ]; then
        cmd="$cmd --userId=$user_id"
        log DEBUG "Adding user assignment: --userId=$user_id"
    fi
    
    # Add project assignment if specified  
    if [ -n "$project_id" ]; then
        cmd="$cmd --projectId=$project_id"
        log DEBUG "Adding project assignment: --projectId=$project_id"
    fi
    
    echo "$cmd"
}

rollback_restore() {
    local container_id="$1"
    local backup_dir="$2"
    local restore_type="$3"
    local is_dry_run=$4

    log WARN "Attempting to roll back to pre-restore state..."

    local backup_workflows="${backup_dir}/workflows.json"
    local backup_credentials="${backup_dir}/credentials.json"
    local container_workflows="/tmp/rollback_workflows.json"
    local container_credentials="/tmp/rollback_credentials.json"
    local rollback_success=true

    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]] && [ ! -f "$backup_workflows" ]; then
        log ERROR "Pre-restore backup file workflows.json not found in $backup_dir. Cannot rollback workflows."
        rollback_success=false
    fi
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]] && [ ! -f "$backup_credentials" ]; then
        log ERROR "Pre-restore backup file credentials.json not found in $backup_dir. Cannot rollback credentials."
        rollback_success=false
    fi
    if ! $rollback_success; then return 1; fi

    log INFO "Copying pre-restore backup files back to container..."
    local copy_failed=false
    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        if $is_dry_run; then
            log DRYRUN "Would copy $backup_workflows to ${container_id}:${container_workflows}"
        elif ! docker cp "$backup_workflows" "${container_id}:${container_workflows}"; then
            log ERROR "Rollback failed: Could not copy workflows back to container."
            copy_failed=true
        fi
    fi
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if $is_dry_run; then
            log DRYRUN "Would copy $backup_credentials to ${container_id}:${container_credentials}"
        elif ! docker cp "$backup_credentials" "${container_id}:${container_credentials}"; then
            log ERROR "Rollback failed: Could not copy credentials back to container."
            copy_failed=true
        fi
    fi
    if $copy_failed; then 
        dockExec "$container_id" "rm -f $container_workflows $container_credentials" "$is_dry_run" || true
        return 1
    fi

    log INFO "Importing pre-restore backup data into n8n..."
    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        if ! dockExec "$container_id" "n8n import:workflow --separate --input=$container_workflows" "$is_dry_run"; then
            log ERROR "Rollback failed during workflow import."
            rollback_success=false
        fi
    fi
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if ! dockExec "$container_id" "n8n import:credentials --separate --input=$container_credentials" "$is_dry_run"; then
            log ERROR "Rollback failed during credential import."
            rollback_success=false
        fi
    fi

    log INFO "Cleaning up rollback files in container..."
    dockExec "$container_id" "rm -f $container_workflows $container_credentials" "$is_dry_run" || log WARN "Could not clean up rollback files in container."

    if $rollback_success; then
        log SUCCESS "Rollback completed. n8n should be in the state before restore was attempted."
        return 0
    else
        log ERROR "Rollback failed. Manual intervention may be required."
        log WARN "Pre-restore backup files are kept at: $backup_dir"
        return 1
    fi
}

backup() {
    local container_id="$1"
    local github_token="$2"
    local github_repo="$3"
    local branch="$4"
    local use_dated_backup=$5
    local is_dry_run=$6

    log HEADER "Performing Backup to GitHub"
    if $is_dry_run; then log WARN "DRY RUN MODE ENABLED - NO CHANGES WILL BE MADE"; fi

    local tmp_dir
    tmp_dir=$(mktemp -d -t n8n-backup-XXXXXXXXXX)
    log DEBUG "Created temporary directory: $tmp_dir"

    local container_workflows="/tmp/workflows.json"
    local container_credentials="/tmp/credentials.json"
    local container_env="/tmp/.env"

    # --- Git Setup First --- 
    log INFO "Preparing Git repository for backup..."
    local git_repo_url="https://${github_token}@github.com/${github_repo}.git"

    log DEBUG "Initializing Git repository in $tmp_dir"
    if ! git -C "$tmp_dir" init -q; then log ERROR "Git init failed."; rm -rf "$tmp_dir"; return 1; fi
    log DEBUG "Adding remote 'origin' with URL $git_repo_url"
    if ! git -C "$tmp_dir" remote add origin "$git_repo_url" 2>/dev/null; then
        log WARN "Git remote 'origin' already exists. Setting URL..."
        if ! git -C "$tmp_dir" remote set-url origin "$git_repo_url"; then log ERROR "Git set-url failed."; rm -rf "$tmp_dir"; return 1; fi
    fi

    log INFO "Configuring Git user identity for commit..."
    if ! git -C "$tmp_dir" config user.email "n8n-backup-script@localhost"; then log ERROR "Failed to set Git user email."; rm -rf "$tmp_dir"; return 1; fi
    if ! git -C "$tmp_dir" config user.name "n8n Backup Script"; then log ERROR "Failed to set Git user name."; rm -rf "$tmp_dir"; return 1; fi

    log INFO "Fetching remote branch '$branch'..."
    local branch_exists=true
    if ! git -C "$tmp_dir" fetch --depth 1 origin "$branch" 2>/dev/null; then
        log WARN "Branch '$branch' not found on remote or repo is empty. Will create branch."
        branch_exists=false
        if ! $is_dry_run; then
             if ! git -C "$tmp_dir" checkout -b "$branch"; then log ERROR "Git checkout -b failed."; rm -rf "$tmp_dir"; return 1; fi
        else
             log DRYRUN "Would create and checkout new branch '$branch'"
        fi
    else
        if ! $is_dry_run; then
            if ! git -C "$tmp_dir" checkout "$branch"; then log ERROR "Git checkout failed."; rm -rf "$tmp_dir"; return 1; fi
        else
            log DRYRUN "Would checkout existing branch '$branch'"
        fi
    fi
    log SUCCESS "Git repository initialized and branch '$branch' checked out."

    # --- Export Data --- 
    log INFO "Exporting data from n8n container..."
    local export_failed=false
    local no_data_found=false

    # Determine export strategy based on flags
    local workflow_export_cmd=""
    local credential_export_cmd=""
    local using_separate_files=false
    
    # Check if we're using separate files mode
    if [ "$ARG_SEPARATE_FILES" = "true" ] || [ "$CONF_SEPARATE_FILES" = "true" ]; then
        using_separate_files=true
        log INFO "Using separate files mode (git-friendly)"
    fi
    
    # Build workflow export command
    if [ -n "$ARG_WORKFLOW_ID" ]; then
        log INFO "Exporting specific workflow ID: $ARG_WORKFLOW_ID"
        if $using_separate_files; then
            workflow_export_cmd="n8n export:workflow --id=$ARG_WORKFLOW_ID --pretty --output=/tmp/workflow_$ARG_WORKFLOW_ID.json"
        else
            workflow_export_cmd="n8n export:workflow --id=$ARG_WORKFLOW_ID --output=$container_workflows"
        fi
    else
        log INFO "Exporting all workflows"
        if $using_separate_files; then
            workflow_export_cmd="n8n export:workflow --backup --output=/tmp/workflows/"
        else
            workflow_export_cmd="n8n export:workflow --all --output=$container_workflows"
        fi
    fi
    
    # Build credential export command  
    if [ -n "$ARG_CREDENTIAL_ID" ]; then
        log INFO "Exporting specific credential ID: $ARG_CREDENTIAL_ID"
        if $using_separate_files; then
            credential_export_cmd="n8n export:credentials --id=$ARG_CREDENTIAL_ID --decrypted --pretty --output=/tmp/credential_$ARG_CREDENTIAL_ID.json"
        else
            credential_export_cmd="n8n export:credentials --id=$ARG_CREDENTIAL_ID --decrypted --output=$container_credentials"
        fi
    else
        log INFO "Exporting all credentials"
        if $using_separate_files; then
            credential_export_cmd="n8n export:credentials --backup --decrypted --output=/tmp/credentials/"
        else
            credential_export_cmd="n8n export:credentials --all --decrypted --output=$container_credentials"
        fi
    fi

    # --- Advanced Feature Integration ---
    
    # Feature 1: Auto-include linked credentials for specific workflow backup
    local additional_credential_ids=""
    if [ -n "$ARG_WORKFLOW_ID" ] && [ "$ARG_INCLUDE_LINKED_CREDS" = "true" ]; then
        log INFO "Auto-discovering linked credentials for workflow ID: $ARG_WORKFLOW_ID"
        
        # First export the workflow to discover linked credentials
        local temp_workflow_file="/tmp/temp_workflow_for_creds.json"
        local temp_export_cmd="n8n export:workflow --id=$ARG_WORKFLOW_ID --output=$temp_workflow_file"
        
        if dockExec "$container_id" "$temp_export_cmd" false; then
            # Copy the workflow file to host for analysis
            local host_temp_workflow="$tmp_dir/temp_workflow.json"
            if docker cp "$container_id:$temp_workflow_file" "$host_temp_workflow"; then
                # Discover linked credentials
                if additional_credential_ids=$(discover_linked_credentials "$host_temp_workflow"); then
                    if [ -n "$additional_credential_ids" ]; then
                        log SUCCESS "Found linked credentials: $additional_credential_ids"
                        # Update credential export command to include discovered credentials
                        if $using_separate_files; then
                            # For separate files, export each credential individually
                            for cred_id in $additional_credential_ids; do
                                local extra_cred_cmd="n8n export:credentials --id=$cred_id --decrypted --pretty --output=/tmp/credential_$cred_id.json"
                                log DEBUG "Exporting linked credential: $extra_cred_cmd"
                                dockExec "$container_id" "$extra_cred_cmd" false || log WARN "Failed to export linked credential ID: $cred_id"
                            done
                        else
                            # For single file, modify the credential export to include specific IDs
                            local all_cred_ids="$additional_credential_ids"
                            if [ -n "$ARG_CREDENTIAL_ID" ]; then
                                all_cred_ids="$ARG_CREDENTIAL_ID $additional_credential_ids"
                            fi
                            # Build export command for multiple specific credentials
                            credential_export_cmd="n8n export:credentials --decrypted --output=$container_credentials"
                            for cred_id in $all_cred_ids; do
                                credential_export_cmd="$credential_export_cmd --id=$cred_id"
                            done
                        fi
                    else
                        log INFO "No linked credentials found for this workflow"
                    fi
                else
                    log WARN "Failed to discover linked credentials"
                fi
                # Clean up temp file
                rm -f "$host_temp_workflow"
            else
                log WARN "Failed to copy workflow file for credential discovery"
            fi
            # Clean up container temp file
            dockExec "$container_id" "rm -f $temp_workflow_file" false || true
        else
            log WARN "Failed to export workflow for credential discovery"
        fi
    fi
    
    # Feature 2: Incremental backup logic
    local incremental_files_to_export=""
    local skip_export_due_to_no_changes=false
    if [ "$ARG_INCREMENTAL" = "true" ]; then
        log INFO "Performing incremental backup analysis..."
        
        # Only proceed with incremental if we have an existing git repository
        if $branch_exists; then
            # Create temporary export to compare against
            local temp_export_dir="$tmp_dir/temp_export"
            mkdir -p "$temp_export_dir"
            
            # Export current data to temporary location for comparison
            local temp_workflows_file="$temp_export_dir/workflows.json"
            local temp_credentials_file="$temp_export_dir/credentials.json"
            
            if $using_separate_files; then
                # Export to separate files for comparison
                dockExec "$container_id" "n8n export:workflow --backup --output=/tmp/temp_workflows/" false || true
                dockExec "$container_id" "n8n export:credentials --backup --decrypted --output=/tmp/temp_credentials/" false || true
                docker cp "$container_id:/tmp/temp_workflows/" "$temp_export_dir/" 2>/dev/null || true
                docker cp "$container_id:/tmp/temp_credentials/" "$temp_export_dir/" 2>/dev/null || true
            else
                # Export to single files for comparison
                dockExec "$container_id" "n8n export:workflow --all --output=/tmp/temp_workflows.json" false || true
                dockExec "$container_id" "n8n export:credentials --all --decrypted --output=/tmp/temp_credentials.json" false || true
                docker cp "$container_id:/tmp/temp_workflows.json" "$temp_workflows_file" 2>/dev/null || true
                docker cp "$container_id:/tmp/temp_credentials.json" "$temp_credentials_file" 2>/dev/null || true
            fi
            
            # Analyze incremental changes
            if incremental_files_to_export=$(get_incremental_changes "$tmp_dir" "$temp_export_dir"); then
                log SUCCESS "Incremental analysis completed. Changed files: $incremental_files_to_export"
                
                # Filter export commands based on what has actually changed
                if ! echo "$incremental_files_to_export" | grep -q "workflow"; then
                    log INFO "No workflow changes detected - skipping workflow export"
                    workflow_export_cmd=""
                fi
                if ! echo "$incremental_files_to_export" | grep -q "credential"; then
                    log INFO "No credential changes detected - skipping credential export"
                    credential_export_cmd=""
                fi
                
                # Check if any exports are still needed
                if [ -z "$workflow_export_cmd" ] && [ -z "$credential_export_cmd" ]; then
                    log INFO "No changes detected since last backup - skipping export"
                    skip_export_due_to_no_changes=true
                fi
            else
                local incremental_exit_code=$?
                if [ $incremental_exit_code -eq 2 ]; then
                    log INFO "No changes detected since last backup"
                    skip_export_due_to_no_changes=true
                else
                    log WARN "Incremental analysis failed - performing full backup"
                fi
            fi
            
            # Clean up temporary export
            rm -rf "$temp_export_dir"
            dockExec "$container_id" "rm -rf /tmp/temp_workflows/ /tmp/temp_credentials/ /tmp/temp_workflows.json /tmp/temp_credentials.json" false || true
        else
            log INFO "No previous backup found - performing full initial backup"
        fi
    fi

    # Execute workflow export (unless skipped by incremental logic)
    if [ -n "$workflow_export_cmd" ] && ! $skip_export_due_to_no_changes; then
        if [ -n "$ARG_WORKFLOW_ID" ] || [ "$ARG_RESTORE_TYPE" != "credentials" ]; then
            log DEBUG "Executing workflow export: $workflow_export_cmd"
            if ! dockExec "$container_id" "$workflow_export_cmd" false; then 
                # Check if the error is due to no workflows or specific workflow not found
                if [ -n "$ARG_WORKFLOW_ID" ]; then
                    log ERROR "Failed to export workflow ID: $ARG_WORKFLOW_ID (workflow may not exist)"
                    export_failed=true
                elif docker exec "$container_id" n8n list workflows 2>&1 | grep -q "No workflows found"; then
                    log INFO "No workflows found to backup - this is a clean installation"
                    no_data_found=true
                else
                    log ERROR "Failed to export workflows"
                    export_failed=true
                fi
            else
                log SUCCESS "Workflow export completed successfully"
            fi
        fi
    fi

    # Execute credential export
    if [ -n "$credential_export_cmd" ] && ! $skip_export_due_to_no_changes; then
        if [ -n "$ARG_CREDENTIAL_ID" ] || [ "$ARG_RESTORE_TYPE" != "workflows" ]; then
            log DEBUG "Executing credential export: $credential_export_cmd"
            if ! dockExec "$container_id" "$credential_export_cmd" false; then 
                # Check if the error is due to no credentials or specific credential not found
                if [ -n "$ARG_CREDENTIAL_ID" ]; then
                    log ERROR "Failed to export credential ID: $ARG_CREDENTIAL_ID (credential may not exist)"
                    export_failed=true
                elif docker exec "$container_id" n8n list credentials 2>&1 | grep -q "No credentials found"; then
                    log INFO "No credentials found to backup - this is a clean installation"
                    no_data_found=true
                else
                    log ERROR "Failed to export credentials"
                    export_failed=true
                fi
            else
                log SUCCESS "Credential export completed successfully"
            fi
        fi
    fi

    if $export_failed; then
        log ERROR "Failed to export data from n8n"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Handle environment variables
    if ! dockExec "$container_id" "printenv | grep ^N8N_ > $container_env" false; then
        log WARN "Could not capture N8N_ environment variables from container."
    fi

    # If no data was found, create empty files to maintain backup structure
    if $no_data_found; then
        log INFO "Creating empty backup files for clean installation..."
        if ! docker exec "$container_id" test -f "$container_workflows"; then
            echo "[]" | docker exec -i "$container_id" sh -c "cat > $container_workflows"
        fi
        if ! docker exec "$container_id" test -f "$container_credentials"; then
            echo "[]" | docker exec -i "$container_id" sh -c "cat > $container_credentials"
        fi
    fi

    # --- Determine Target Directory and Copy --- 
    local target_dir="$tmp_dir"
    local backup_timestamp=""
    if [ "$use_dated_backup" = "true" ]; then
        backup_timestamp="backup_$(timestamp)"
        target_dir="${tmp_dir}/${backup_timestamp}"
        log INFO "Using dated backup directory: $backup_timestamp"
        if [ "$is_dry_run" = "true" ]; then
            log DRYRUN "Would create directory: $target_dir"
        elif ! mkdir -p "$target_dir"; then
            log ERROR "Failed to create dated backup directory: $target_dir"
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    log INFO "Copying exported files from container into Git directory..."
    local copy_status="success" # Use string instead of boolean to avoid empty command errors
    
    # Determine files/directories to copy based on mode
    local items_to_copy=()
    if $using_separate_files; then
        # Copy directories or specific files for separate files mode
        if [ -n "$ARG_WORKFLOW_ID" ]; then
            # Specific workflow: copy only the individual workflow file
            items_to_copy+=("workflow_$ARG_WORKFLOW_ID.json")
        elif [ -z "$ARG_CREDENTIAL_ID" ] && [[ "$ARG_RESTORE_TYPE" != "credentials" ]]; then
            # All workflows: copy entire workflows directory
            items_to_copy+=("workflows/")
        fi
        
        if [ -n "$ARG_CREDENTIAL_ID" ]; then
            # Specific credential: copy only the individual credential file
            items_to_copy+=("credential_$ARG_CREDENTIAL_ID.json")
        elif [ -z "$ARG_WORKFLOW_ID" ] && [[ "$ARG_RESTORE_TYPE" != "workflows" ]]; then
            # All credentials: copy entire credentials directory
            items_to_copy+=("credentials/")
        fi
        
        # For linked credentials in workflow-specific backup
        if [ -n "$ARG_WORKFLOW_ID" ] && [ "$ARG_INCLUDE_LINKED_CREDS" = "true" ]; then
            # Note: linked credential files will be handled by the credential discovery logic above
            # They are exported as individual files like credential_CREDID.json
            # These files will be copied in the main copy loop
            log DEBUG "Linked credential files will be copied individually"
        fi
        
        items_to_copy+=(".env")
    else
        # Copy JSON files for traditional mode
        if [ -z "$ARG_CREDENTIAL_ID" ] && [[ "$ARG_RESTORE_TYPE" != "credentials" ]]; then
            items_to_copy+=("workflows.json")
        fi
        if [ -z "$ARG_WORKFLOW_ID" ] && [[ "$ARG_RESTORE_TYPE" != "workflows" ]]; then
            items_to_copy+=("credentials.json")
        fi
        items_to_copy+=(".env")
    fi
    
    # Copy each item (file or directory)
    for item in "${items_to_copy[@]}"; do
        source_path="/tmp/${item}"
        if [ "$use_dated_backup" = "true" ]; then
            # Create timestamped subdirectory
            mkdir -p "${target_dir}" || return 1
            dest_path="${target_dir}/${item}"
        else
            dest_path="${tmp_dir}/${item}"
        fi

        # Check if item exists in container (file or directory)
        local item_exists=false
        if [[ "$item" == */ ]]; then
            # Directory check
            if docker exec "$container_id" test -d "$source_path"; then
                item_exists=true
            fi
        else
            # File check
            if docker exec "$container_id" test -f "$source_path"; then
                item_exists=true
            fi
        fi
        
        if ! $item_exists; then
            if [[ "$item" == ".env" ]]; then
                log WARN ".env file not found in container, skipping."
                continue
            else
                log ERROR "Required item $item not found in container"
                copy_status="failed"
                continue
            fi
        fi

        # Copy item from container
        if [[ "$item" == */ ]]; then
            # Copy directory
            log DEBUG "Copying directory $item from container"
            if ! docker cp "${container_id}:${source_path%/}" "$(dirname "$dest_path")"; then
                log ERROR "Failed to copy directory $item from container"
                copy_status="failed"
                continue
            fi
            # Count files in directory for reporting
            local file_count
            file_count=$(docker exec "$container_id" find "$source_path" -name "*.json" -type f | wc -l)
            log SUCCESS "Successfully copied directory $item ($file_count files) to ${dest_path}"
        else
            # Copy file
            local size
            size=$(docker exec "$container_id" du -h "$source_path" | awk '{print $1}')
            if ! docker cp "${container_id}:${source_path}" "${dest_path}"; then
                log ERROR "Failed to copy $item from container"
                copy_status="failed"
                continue
            fi
            log SUCCESS "Successfully copied $size to ${dest_path}"
        fi
        
        # Force Git to see changes by updating a separate timestamp file instead of modifying the JSON files
        # This preserves the integrity of the n8n files for restore operations
        
        # Create or update the timestamp file in the same directory
        local ts_file="${tmp_dir}/backup_timestamp.txt"
        echo "Backup generated at: $(date +"%Y-%m-%d %H:%M:%S.%N")" > "$ts_file"
        log DEBUG "Created timestamp file $ts_file to track backup uniqueness"
    done
    
    # Check if any copy operations failed
    if [ "$copy_status" = "failed" ]; then 
        log ERROR "Copy operations failed, aborting backup"
        rm -rf "$tmp_dir"
        return 1
    fi

    log INFO "Cleaning up temporary files in container..."
    dockExec "$container_id" "rm -f $container_workflows $container_credentials $container_env" "$is_dry_run" || log WARN "Could not clean up temporary files in container."

    # --- Git Commit and Push --- 
    log INFO "Adding files to Git..."
    
    if $is_dry_run; then
        if $use_dated_backup; then
            log DRYRUN "Would add dated backup directory '$backup_timestamp' to Git index"
        else
            log DRYRUN "Would add all files to Git index"
        fi
    else
        # Change to the git directory to avoid parsing issues
        cd "$tmp_dir" || { 
            log ERROR "Failed to change to git directory for add operation"; 
            rm -rf "$tmp_dir"; 
            return 1; 
        }
        
        if [ "$use_dated_backup" = "true" ] && [ -n "$backup_timestamp" ] && [ -d "$backup_timestamp" ]; then
            log DEBUG "Adding dated backup directory: $backup_timestamp"
            
            # First list what's in the directory (for debugging)
            log DEBUG "Files in backup directory:"
            ls -la "$backup_timestamp" || true
            
            # Add specific directory
            if ! git add "$backup_timestamp"; then
                log ERROR "Git add failed for dated backup directory"
                cd - > /dev/null || true
                rm -rf "$tmp_dir"
                return 1
            fi
        else
            # Standard repo-root backup
            log DEBUG "Adding files at repository root"
            
            # Check if we're using separate files mode
            local separate_files_mode=false
            if [ "$ARG_SEPARATE_FILES" = "true" ] || [ "$CONF_SEPARATE_FILES" = "true" ]; then
                separate_files_mode=true
                log DEBUG "Separate files mode detected for Git operations"
            fi
            
            if $separate_files_mode; then
                # Add separate files directories and timestamp
                local git_add_cmd="git add ./backup_timestamp.txt"
                
                # Add workflows directory if it exists
                if [ -d "workflows" ]; then
                    git_add_cmd="$git_add_cmd workflows/"
                    log DEBUG "Adding workflows directory to Git"
                fi
                
                # Add credentials directory if it exists
                if [ -d "credentials" ]; then
                    git_add_cmd="$git_add_cmd credentials/"
                    log DEBUG "Adding credentials directory to Git"
                fi
                
                # Add .env file if it exists
                if [ -f ".env" ]; then
                    git_add_cmd="$git_add_cmd .env"
                fi
                
                if ! eval "$git_add_cmd"; then
                    log ERROR "Git add failed for separate files mode"
                    cd - > /dev/null || true
                    return 1
                fi
            else
                # Standard JSON files mode
                log DEBUG "Adding individual files to Git"
                if ! git add ./backup_timestamp.txt workflows.json credentials.json .env 2>/dev/null; then
                    log ERROR "Git add failed for repository root files"
                    cd - > /dev/null || true
                    return 1
                fi
            fi
        fi
    fi
    
    log DEBUG "Staging status:"
    git status --short || true

    # --- Commit Logic --- 
    local commit_status="pending" # Use string instead of boolean to avoid empty command errors
    log INFO "Committing changes..."
    
    # Create a timestamp with seconds to ensure uniqueness
    local backup_time=$(date +"%Y-%m-%d_%H-%M-%S")
    
    # Get n8n version from container (optional, fallback to generic message if unavailable)
    local n8n_ver=""
    if n8n_ver=$(docker exec "$container_id" n8n --version 2>/dev/null | head -n1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n1); then
        local commit_msg="🛡️ n8n Backup (v$n8n_ver) - $backup_time"
    else
        local commit_msg="🛡️ n8n Backup - $backup_time"
    fi
    
    if [ "$use_dated_backup" = "true" ]; then
        commit_msg="$commit_msg [$backup_timestamp]"
    fi
    
    # Ensure git identity is configured (important for non-interactive mode)
    # This is crucial according to developer notes about Git user identity
    if [[ -z "$(git config user.email 2>/dev/null)" ]]; then
        log WARN "No Git user.email configured, setting default"
        git config user.email "n8n-backup-script@localhost" || true
    fi
    if [[ -z "$(git config user.name 2>/dev/null)" ]]; then
        log WARN "No Git user.name configured, setting default"
        git config user.name "n8n Backup Script" || true
    fi
    
    # Force Git to commit by adding a timestamp file to make each backup unique
    log DEBUG "Creating timestamp file to ensure backup uniqueness"
    echo "Backup generated at: $backup_time" > "./backup_timestamp.txt"
    
    # Explicitly add all n8n files AND the timestamp file
    log DEBUG "Adding all n8n files to Git..."
    if [ "$use_dated_backup" = "true" ] && [ -n "$backup_timestamp" ] && [ -d "$backup_timestamp" ]; then
        log DEBUG "Adding dated backup directory: $backup_timestamp"
        
        # First list what's in the directory (for debugging)
        log DEBUG "Files in backup directory:"
        ls -la "$backup_timestamp" || true
        
        # Add specific directory
        if ! git add "$backup_timestamp" ./backup_timestamp.txt; then
            log ERROR "Failed to add dated backup directory"
            cd - > /dev/null || true
            rm -rf "$tmp_dir"
            return 1
        fi
    else
        # Standard repo-root backup
        log DEBUG "Adding individual files to Git"
        if ! git add ./backup_timestamp.txt workflows.json credentials.json .env 2>/dev/null; then
            log ERROR "Failed to add n8n files"
            cd - > /dev/null || true
            return 1
        fi
    fi
    
    log DEBUG "Committing backup with message: $commit_msg"
    if [ "$is_dry_run" = "true" ]; then
        log DRYRUN "Would commit with message: $commit_msg"
        commit_status="success" # Assume commit would happen in dry run
    else
        # Force the commit with --allow-empty to ensure it happens
        if git commit --allow-empty -m "$commit_msg" 2>/dev/null; then
            commit_status="success" # Set flag to indicate commit success
        else
            log ERROR "Git commit failed"
            # Show detailed output in case of failure
            git status || true
            cd - > /dev/null || true
            rm -rf "$tmp_dir"
            return 1
        fi
    fi
    
    # We'll maintain the directory change until after push completes in the next section

    # --- Push Logic --- 
    log INFO "Pushing backup to GitHub repository '$github_repo' branch '$branch'..."
    
    if [ "$is_dry_run" = "true" ]; then
        log DRYRUN "Would push branch '$branch' to origin"
        return 0
    fi
    
    # Simple approach - we just committed changes successfully
    # So we'll push those changes now
    cd "$tmp_dir" || { 
        log ERROR "Failed to change to $tmp_dir"; 
        rm -rf "$tmp_dir"; 
        return 1; 
    }
    
    # Check if git log shows recent commits
    last_commit=$(git log -1 --pretty=format:"%H" 2>/dev/null || echo "")
    
    if [ -z "$last_commit" ]; then
        log ERROR "No commits found to push"
        cd - > /dev/null || true
        rm -rf "$tmp_dir"
        return 1
    fi
    
    log DEBUG "Pushing commit $last_commit to origin/$branch"
    
    # Use a direct git command with full output
    if ! git push -u origin "$branch" --verbose; then
        log ERROR "Failed to push to GitHub - connectivity issue or permissions problem"
        
        # Test GitHub connectivity
        if ! curl -s -I "https://github.com" > /dev/null; then
            log ERROR "Cannot reach GitHub - network connectivity issue"
        elif ! curl -s -H "Authorization: token $github_token" "https://api.github.com/user" | grep -q login; then
            log ERROR "GitHub API authentication failed - check token permissions"
        else
            log ERROR "Unknown error pushing to GitHub"
        fi
        
        cd - > /dev/null || true
        rm -rf "$tmp_dir"
        return 1
    fi
    
    log SUCCESS "Backup successfully pushed to GitHub repository"
    cd - > /dev/null || true

    log INFO "Cleaning up host temporary directory..."
    if $is_dry_run; then
        log DRYRUN "Would remove temporary directory: $tmp_dir"
    else
        rm -rf "$tmp_dir"
    fi

    log SUCCESS "Backup successfully completed and pushed to GitHub."
    if $is_dry_run; then log WARN "(Dry run mode was active)"; fi
    return 0
}

restore() {
    local container_id="$1"
    local github_token="$2"
    local github_repo="$3"
    local branch="$4"
    local restore_type="$5"
    local is_dry_run=$6

    log HEADER "Performing Restore from GitHub (Type: $restore_type)"
    if $is_dry_run; then log WARN "DRY RUN MODE ENABLED - NO CHANGES WILL BE MADE"; fi

    if [ -t 0 ] && ! $is_dry_run; then
        log WARN "This will overwrite existing data (type: $restore_type)."
        printf "Are you sure you want to proceed? (yes/no): "
        local confirm
        read -r confirm
        if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
            log INFO "Restore cancelled by user."
            return 0
        fi
    elif ! $is_dry_run; then
        log WARN "Running restore non-interactively (type: $restore_type). Proceeding without confirmation."
    fi

    # --- 1. Pre-restore Backup --- 
    log HEADER "Step 1: Creating Pre-restore Backup"
    local pre_restore_dir=""
    pre_restore_dir=$(mktemp -d -t n8n-prerestore-XXXXXXXXXX)
    log DEBUG "Created pre-restore backup directory: $pre_restore_dir"

    local pre_workflows="${pre_restore_dir}/workflows.json"
    local pre_credentials="${pre_restore_dir}/credentials.json"
    local container_pre_workflows="/tmp/pre_workflows.json"
    local container_pre_credentials="/tmp/pre_credentials.json"

    local backup_failed=false
    local no_existing_data=false
    log INFO "Exporting current n8n data for backup..."
    
    # Function to check if output indicates no data
    check_no_data() {
        local output="$1"
        if echo "$output" | grep -q "No workflows found" || echo "$output" | grep -q "No credentials found"; then
            return 0
        fi
        return 1
    }

    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        local workflow_output
        workflow_output=$(docker exec "$container_id" n8n export:workflow --all --output=$container_pre_workflows 2>&1) || {
            if check_no_data "$workflow_output"; then
                log INFO "No existing workflows found - this is a clean installation"
                no_data_found=true
                # Create empty workflows file
                echo "[]" | docker exec -i "$container_id" sh -c "cat > $container_pre_workflows"
            else
                log ERROR "Failed to export workflows: $workflow_output"
                backup_failed=true
            fi
        }
    fi

    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if ! $backup_failed; then
            local cred_output
            cred_output=$(docker exec "$container_id" n8n export:credentials --all --decrypted --output=$container_pre_credentials 2>&1) || {
                if check_no_data "$cred_output"; then
                    log INFO "No existing credentials found - this is a clean installation"
                    no_data_found=true
                    # Create empty credentials file
                    echo "[]" | docker exec -i "$container_id" sh -c "cat > $container_pre_credentials"
                else
                    log ERROR "Failed to export credentials: $cred_output"
                    backup_failed=true
                fi
            }
        fi
    fi

    if $backup_failed; then
        log ERROR "Could not export current data completely. Cannot create pre-restore backup."
        dockExec "$container_id" "rm -f $container_pre_workflows $container_pre_credentials" false || true
        rm -rf "$pre_restore_dir"
        pre_restore_dir=""
        if ! $is_dry_run; then
            log ERROR "Cannot proceed with restore safely without pre-restore backup."
            return 1
        fi
    elif $no_existing_data; then
        log INFO "No existing data found - proceeding with restore without pre-restore backup"
        # Copy the empty files we created to the backup directory
        if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
            docker cp "${container_id}:${container_pre_workflows}" "$pre_workflows" || true
        fi
        if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
            docker cp "${container_id}:${container_pre_credentials}" "$pre_credentials" || true
        fi
        dockExec "$container_id" "rm -f $container_pre_workflows $container_pre_credentials" false || true
    else
        log INFO "Copying current data to host backup directory..."
        local copy_failed=false
        if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
            if $is_dry_run; then
                log DRYRUN "Would copy ${container_id}:${container_pre_workflows} to $pre_workflows"
            elif ! docker cp "${container_id}:${container_pre_workflows}" "$pre_workflows"; then copy_failed=true; fi
        fi
        if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
             if $is_dry_run; then
                 log DRYRUN "Would copy ${container_id}:${container_pre_credentials} to $pre_credentials"
             elif ! docker cp "${container_id}:${container_pre_credentials}" "$pre_credentials"; then copy_failed=true; fi
        fi
        
        dockExec "$container_id" "rm -f $container_pre_workflows $container_pre_credentials" "$is_dry_run" || true

        if $copy_failed; then
            log ERROR "Failed to copy backup files from container. Cannot proceed with restore safely."
            rm -rf "$pre_restore_dir"
            return 1
        else
            log SUCCESS "Pre-restore backup created successfully."
        fi
    fi

    # --- 2. Fetch from GitHub --- 
    log HEADER "Step 2: Fetching Backup from GitHub"
    local download_dir
    download_dir=$(mktemp -d -t n8n-download-XXXXXXXXXX)
    log DEBUG "Created download directory: $download_dir"

    local git_repo_url="https://${github_token}@github.com/${github_repo}.git"

    log INFO "Cloning repository $github_repo branch $branch..."
    
    log DEBUG "Running: git clone --depth 1 --branch $branch $git_repo_url $download_dir"
    if ! git clone --depth 1 --branch "$branch" "$git_repo_url" "$download_dir"; then
        log ERROR "Failed to clone repository. Check URL, token, branch, and permissions."
        rm -rf "$download_dir"
        if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi
        return 1
    fi

    # Check if the restore should come from a dated backup directory
    local dated_backup_found=false
    local selected_backup=""
    local backup_dirs=()
    
    # Look for dated backup directories
    cd "$download_dir" || { 
        log ERROR "Failed to change to download directory";
        rm -rf "$download_dir";
        if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi;
        return 1;
    }
    
    # Debug - show what files exist in the repository
    log DEBUG "Repository root contents:"
    ls -la "$download_dir" || true
    find "$download_dir" -type f -name "*.json" | sort || true
    
    # Find all backup_* directories and sort them by date (newest first)
    readarray -t backup_dirs < <(find . -type d -name "backup_*" | sort -r)
    
    if [ ${#backup_dirs[@]} -gt 0 ]; then
        log INFO "Found ${#backup_dirs[@]} dated backup(s):"
        
        # If non-interactive mode, automatically select the most recent backup
        if ! [ -t 0 ]; then
            selected_backup="${backup_dirs[0]}"
            dated_backup_found=true
            log INFO "Auto-selecting most recent backup in non-interactive mode: $selected_backup"
        else
            # Interactive mode - show menu with newest backups first
            echo ""
            echo "Select a backup to restore:"
            echo "------------------------------------------------"
            echo "0) Use files from repository root (not a dated backup)"
            
            for i in "${!backup_dirs[@]}"; do
                # Extract the date part from backup_YYYY-MM-DD_HH-MM-SS format
                local backup_date="${backup_dirs[$i]#./backup_}"
                echo "$((i+1))) ${backup_date} (${backup_dirs[$i]})"
            done
            echo "------------------------------------------------"
            
            local valid_selection=false
            while ! $valid_selection; do
                echo -n "Select a backup number (0-${#backup_dirs[@]}): "
                local selection
                read -r selection
                
                if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -le "${#backup_dirs[@]}" ]; then
                    valid_selection=true
                    
                    if [ "$selection" -eq 0 ]; then
                        log INFO "Using repository root files (not a dated backup)"
                    else
                        selected_backup="${backup_dirs[$((selection-1))]}"
                        dated_backup_found=true
                        log INFO "Selected backup: $selected_backup"
                    fi
                else
                    echo "Invalid selection. Please enter a number between 0 and ${#backup_dirs[@]}."
                fi
            done
        fi
    fi
    
    # EMERGENCY DIRECT APPROACH: Use the files from repository without complex validation
    log INFO "Direct approach: Using files straight from repository..."
    
    # Set up container import paths
    local container_import_workflows="/tmp/import_workflows.json"
    local container_import_credentials="/tmp/import_credentials.json"
    
    # Find the workflow and credentials files directly
    local repo_workflows=""
    local repo_credentials=""
    
    # First try dated backup if specified
    if $dated_backup_found; then
        local dated_path="${selected_backup#./}"
        log INFO "Looking for files in dated backup: $dated_path"
        
        if [ -f "${download_dir}/${dated_path}/workflows.json" ]; then
            repo_workflows="${download_dir}/${dated_path}/workflows.json"
            log SUCCESS "Found workflows.json in dated backup directory"
        fi
        
        if [ -f "${download_dir}/${dated_path}/credentials.json" ]; then
            repo_credentials="${download_dir}/${dated_path}/credentials.json"
            log SUCCESS "Found credentials.json in dated backup directory"
        fi
    fi
    
    # Fall back to repository root if files weren't found in dated backup
    if [ -z "$repo_workflows" ] && [ -f "${download_dir}/workflows.json" ]; then
        repo_workflows="${download_dir}/workflows.json"
        log SUCCESS "Found workflows.json in repository root"
    fi
    
    if [ -z "$repo_credentials" ] && [ -f "${download_dir}/credentials.json" ]; then
        repo_credentials="${download_dir}/credentials.json"
        log SUCCESS "Found credentials.json in repository root"
    fi
    
    # Display file sizes for debug purposes
    if [ -n "$repo_workflows" ]; then
        log DEBUG "Workflow file size: $(du -h "$repo_workflows" | cut -f1)"
    fi
    
    if [ -n "$repo_credentials" ]; then
        log DEBUG "Credentials file size: $(du -h "$repo_credentials" | cut -f1)"
    fi
    
    # Proceed directly to import phase
    log INFO "Validating files for import..."
    local file_validation_passed=true
    
    # More robust file checking logic
    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        if [ ! -f "$repo_workflows" ] || [ ! -s "$repo_workflows" ]; then
            log ERROR "Valid workflows.json not found for $restore_type restore"
            file_validation_passed=false
        else
            log SUCCESS "Workflows file validated for import"
        fi
    fi
    
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if [ ! -f "$repo_credentials" ] || [ ! -s "$repo_credentials" ]; then
            log ERROR "Valid credentials.json not found for $restore_type restore"
            file_validation_passed=false
        else
            log SUCCESS "Credentials file validated for import"
        fi
    fi
    
    # Always use explicit comparison for clarity and to avoid empty commands
    if [ "$file_validation_passed" != "true" ]; then
        log ERROR "File validation failed. Cannot proceed with restore."
        log DEBUG "Repository contents (excluding .git):"
        find "$download_dir" -type f -not -path "*/\.git/*" | sort || true
        rm -rf "$download_dir"
        if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi
        return 1
    fi
    
    log SUCCESS "All required files validated successfully."
    
    # Skip temp directory completely and copy directly to container
    log INFO "Copying downloaded files directly to container..."
    
    local copy_status="success" # Use string instead of boolean to avoid empty command errors
    
    # Copy workflow file if needed
    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        if $is_dry_run; then
            log DRYRUN "Would copy $repo_workflows to ${container_id}:${container_import_workflows}"
        else
            log INFO "Copying workflows file to container..."
            if docker cp "$repo_workflows" "${container_id}:${container_import_workflows}"; then
                log SUCCESS "Successfully copied workflows.json to container"
            else
                log ERROR "Failed to copy workflows.json to container."
                copy_status="failed"
            fi
        fi
    fi
    
    # Copy credentials file if needed
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if $is_dry_run; then
            log DRYRUN "Would copy $repo_credentials to ${container_id}:${container_import_credentials}"
        else
            log INFO "Copying credentials file to container..."
            if docker cp "$repo_credentials" "${container_id}:${container_import_credentials}"; then
                log SUCCESS "Successfully copied credentials.json to container"
            else
                log ERROR "Failed to copy credentials.json to container."
                copy_status="failed"
            fi
        fi
    fi
    
    # Check copy status with explicit string comparison
    if [ "$copy_status" = "failed" ]; then
        log ERROR "Failed to copy files to container - cannot proceed with restore"
        rm -rf "$download_dir"
        if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi
        return 1
    fi
    
    log SUCCESS "All files copied to container successfully."
    
    # Handle import directly here to avoid another set of checks
    log INFO "Importing data into n8n..."
    local import_status="success"
    
    # Determine if we need to handle import-as-new (strip IDs)
    local process_import_as_new=false
    if [ "$ARG_IMPORT_AS_NEW" = "true" ]; then
        process_import_as_new=true
        log INFO "Import-as-new mode enabled - will strip IDs to create new copies"
    fi
    
    # Check if we're dealing with separate files mode
    local using_separate_files=false
    if [ "$ARG_SEPARATE_FILES" = "true" ] || [ "$CONF_SEPARATE_FILES" = "true" ]; then
        using_separate_files=true
        log INFO "Separate files mode detected for restore"
    fi
    
    # Import workflows if needed
    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]] && [ -z "$ARG_CREDENTIAL_ID" ]; then
        local workflow_import_file="$container_import_workflows"
        
        # Handle import-as-new processing
        if $process_import_as_new; then
            local temp_workflow_file="/tmp/import_workflows_no_ids.json"
            log INFO "Stripping IDs from workflows for import-as-new..."
            
            # Copy original file to host temporarily for processing
            local host_temp_workflows
            host_temp_workflows=$(mktemp)
            if ! docker cp "${container_id}:${container_import_workflows}" "$host_temp_workflows"; then
                log ERROR "Failed to copy workflows file from container for ID processing"
                import_status="failed"
            else
                local host_processed_workflows
                host_processed_workflows=$(mktemp)
                if strip_json_ids "$host_temp_workflows" "$host_processed_workflows" "workflow"; then
                    # Copy processed file back to container
                    if docker cp "$host_processed_workflows" "${container_id}:${temp_workflow_file}"; then
                        workflow_import_file="$temp_workflow_file"
                        log SUCCESS "Workflows processed for import-as-new"
                    else
                        log ERROR "Failed to copy processed workflows back to container"
                        import_status="failed"
                    fi
                else
                    log ERROR "Failed to strip IDs from workflows"
                    import_status="failed"
                fi
                rm -f "$host_temp_workflows" "$host_processed_workflows"
            fi
        fi
        
        # Build import command with user/project assignment
        if [ "$import_status" = "success" ]; then
            local workflow_import_cmd
            if [ -n "$ARG_WORKFLOW_ID" ]; then
                # This shouldn't happen in restore (workflow ID is for backup), but handle gracefully
                log WARN "Workflow ID specified in restore - this is unusual. Importing all workflows from file."
            fi
            
            if $using_separate_files; then
                workflow_import_cmd="n8n import:workflow --separate --input=/tmp/workflows/"
            else
                workflow_import_cmd="n8n import:workflow"
            fi
            
            workflow_import_cmd=$(build_import_command "$workflow_import_cmd" "$workflow_import_file" "$ARG_USER_ID" "$ARG_PROJECT_ID")
            
            if [ "$is_dry_run" = "true" ]; then
                log DRYRUN "Would run: $workflow_import_cmd"
            else
                log INFO "Importing workflows..."
                if ! dockExec "$container_id" "$workflow_import_cmd" false; then
                    log ERROR "Failed to import workflows"
                    import_status="failed"
                else
                    log SUCCESS "Workflows imported successfully"
                fi
            fi
        fi
    fi
    
    # Import credentials if needed
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]] && [ -z "$ARG_WORKFLOW_ID" ]; then
        local credential_import_file="$container_import_credentials"
        
        # Handle import-as-new processing
        if $process_import_as_new && [ "$import_status" = "success" ]; then
            local temp_credential_file="/tmp/import_credentials_no_ids.json"
            log INFO "Stripping IDs from credentials for import-as-new..."
            
            # Copy original file to host temporarily for processing
            local host_temp_credentials
            host_temp_credentials=$(mktemp)
            if ! docker cp "${container_id}:${container_import_credentials}" "$host_temp_credentials"; then
                log ERROR "Failed to copy credentials file from container for ID processing"
                import_status="failed"
            else
                local host_processed_credentials
                host_processed_credentials=$(mktemp)
                if strip_json_ids "$host_temp_credentials" "$host_processed_credentials" "credential"; then
                    # Copy processed file back to container
                    if docker cp "$host_processed_credentials" "${container_id}:${temp_credential_file}"; then
                        credential_import_file="$temp_credential_file"
                        log SUCCESS "Credentials processed for import-as-new"
                    else
                        log ERROR "Failed to copy processed credentials back to container"
                        import_status="failed"
                    fi
                else
                    log ERROR "Failed to strip IDs from credentials"
                    import_status="failed"
                fi
                rm -f "$host_temp_credentials" "$host_processed_credentials"
            fi
        fi
        
        # Build import command with user/project assignment
        if [ "$import_status" = "success" ]; then
            local credential_import_cmd
            if [ -n "$ARG_CREDENTIAL_ID" ]; then
                # This shouldn't happen in restore (credential ID is for backup), but handle gracefully
                log WARN "Credential ID specified in restore - this is unusual. Importing all credentials from file."
            fi
            
            if $using_separate_files; then
                credential_import_cmd="n8n import:credentials --separate --input=/tmp/credentials/"
            else
                credential_import_cmd="n8n import:credentials"
            fi
            
            credential_import_cmd=$(build_import_command "$credential_import_cmd" "$credential_import_file" "$ARG_USER_ID" "$ARG_PROJECT_ID")
            
            if [ "$is_dry_run" = "true" ]; then
                log DRYRUN "Would run: $credential_import_cmd"
            else
                log INFO "Importing credentials..."
                if ! dockExec "$container_id" "$credential_import_cmd" false; then
                    log ERROR "Failed to import credentials"
                    import_status="failed"
                else
                    log SUCCESS "Credentials imported successfully"
                fi
            fi
        fi
    fi
    
    # Clean up temporary files in container
    if [ "$is_dry_run" != "true" ]; then
        log INFO "Cleaning up temporary files in container..."
        # Try a more Alpine-friendly approach - first check if files exist
        if dockExec "$container_id" "[ -f $container_import_workflows ] && echo 'Workflow file exists'" "$is_dry_run"; then
            # Try with ash shell explicitly (common in Alpine)
            dockExec "$container_id" "ash -c 'rm -f $container_import_workflows 2>/dev/null || true'" "$is_dry_run" || true
            log DEBUG "Attempted cleanup of workflow import file"
        fi
        
        if dockExec "$container_id" "[ -f $container_import_credentials ] && echo 'Credentials file exists'" "$is_dry_run"; then
            # Try with ash shell explicitly (common in Alpine)
            dockExec "$container_id" "ash -c 'rm -f $container_import_credentials 2>/dev/null || true'" "$is_dry_run" || true
            log DEBUG "Attempted cleanup of credentials import file"
        fi
        
        log INFO "Temporary files in container will be automatically removed when container restarts"
    fi
    
    # Cleanup downloaded repository
    rm -rf "$download_dir"
    
    # Handle restore result based on import status
    if [ "$import_status" = "failed" ]; then
        log WARN "Restore partially completed with some errors. Check logs for details."
        if [ -n "$pre_restore_dir" ]; then 
            log WARN "Pre-restore backup kept at: $pre_restore_dir" 
        fi
        return 1
    fi
    
    # Success - restore completed successfully
    log SUCCESS "Restore completed successfully!"
    
    # Clean up pre-restore backup if successful
    if [ -n "$pre_restore_dir" ] && [ "$is_dry_run" != "true" ]; then
        rm -rf "$pre_restore_dir"
        log INFO "Pre-restore backup cleaned up."
    fi
    
    return 0 # Explicitly return success
}

# Helper function: Discover linked credentials from workflow JSON
discover_linked_credentials() {
    local workflow_json_file="$1"
    local discovered_creds=""
    
    log DEBUG "Discovering linked credentials from workflow: $workflow_json_file" >&2
    
    if [ ! -f "$workflow_json_file" ]; then
        log ERROR "Workflow JSON file not found: $workflow_json_file" >&2
        return 1
    fi
    
    # Method 1: Try with Python3 (most reliable)
    if command_exists python3; then
        log DEBUG "Using Python3 for credential discovery" >&2
        discovered_creds=$(python3 -c "
import json, sys
try:
    with open('$workflow_json_file', 'r') as f:
        data = json.load(f)
    
    creds = set()
    
    # Handle both single workflow export and multiple workflows export
    workflows_to_process = []
    
    if isinstance(data, list):
        # Multiple workflows (array format)
        workflows_to_process = data
    elif 'workflows' in data:
        # Multiple workflows (object with workflows key)
        workflows_to_process = data['workflows']
    elif 'nodes' in data:
        # Single workflow export (direct workflow object)
        workflows_to_process = [data]
    else:
        # Try to process as single workflow anyway
        workflows_to_process = [data]
    
    for workflow in workflows_to_process:
        if 'nodes' in workflow:
            for node in workflow['nodes']:
                if 'credentials' in node:
                    for cred_type, cred_info in node['credentials'].items():
                        if isinstance(cred_info, dict) and 'id' in cred_info:
                            creds.add(cred_info['id'])
    
    print(' '.join(sorted(creds)))
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)
    
    # Method 2: Fallback to grep/sed (basic extraction)  
    elif command_exists grep && command_exists sed; then
        log DEBUG "Using grep/sed for credential discovery" >&2
        discovered_creds=$(grep -o '"credentials":[^}]*"id":"[^"]*"' "$workflow_json_file" 2>/dev/null | \
                          sed 's/.*"id":"\([^"]*\)".*/\1/' | \
                          sort -u | tr '\n' ' ' | sed 's/ $//')
    else
        log WARN "No suitable JSON parsing tools available for credential discovery" >&2
        return 1
    fi
    
    # Clean any whitespace and validate output
    discovered_creds=$(echo "$discovered_creds" | xargs)
    
    if [ -n "$discovered_creds" ]; then
        log SUCCESS "Discovered linked credentials: $discovered_creds" >&2
        echo "$discovered_creds"
        return 0
    else
        log INFO "No linked credentials found in workflow" >&2
        return 0
    fi
}

# Helper function: Get changed files for incremental backup
get_incremental_changes() {
    local git_repo_path="$1"
    local temp_export_path="$2"
    local changes_list=""
    
    log DEBUG "Analyzing incremental changes in: $git_repo_path"
    
    # Check if we're in a git repository
    if [ ! -d "$git_repo_path/.git" ]; then
        log WARN "Not a git repository - performing full backup"
        return 1
    fi
    
    # Change to the git repository directory
    local original_pwd=$(pwd)
    cd "$git_repo_path" || {
        log ERROR "Failed to change to git repository: $git_repo_path"
        return 1
    }
    
    # Get last backup commit (look for commits with backup message pattern)
    local last_backup_commit=$(git log --oneline --grep="n8n Backup" --grep="🛡️" -1 --format="%H" 2>/dev/null || echo "")
    
    if [ -z "$last_backup_commit" ]; then
        log INFO "No previous backup found - performing full backup"
        cd "$original_pwd"
        return 1
    fi
    
    log DEBUG "Last backup commit: $last_backup_commit"
    
    # Export current data to temporary location for comparison
    if [ "$ARG_SEPARATE_FILES" = "true" ]; then
        # Compare individual workflow and credential files
        if [ -d "$temp_export_path/workflows" ]; then
            # Get list of current workflow files
            for workflow_file in "$temp_export_path"/workflows/*.json; do
                [ -f "$workflow_file" ] || continue
                local basename=$(basename "$workflow_file")
                
                # Check if file is new or modified
                if ! git show "$last_backup_commit:workflows/$basename" >/dev/null 2>&1; then
                    # New file
                    changes_list="$changes_list workflows/$basename"
                    log DEBUG "New workflow detected: $basename"
                elif ! git diff --quiet "$last_backup_commit" HEAD -- "workflows/$basename" 2>/dev/null; then
                    # Modified file (if it exists in current backup)
                    if [ -f "workflows/$basename" ]; then
                        changes_list="$changes_list workflows/$basename"
                        log DEBUG "Modified workflow detected: $basename"
                    fi
                fi
            done
        fi
        
        if [ -d "$temp_export_path/credentials" ]; then
            # Get list of current credential files
            for cred_file in "$temp_export_path"/credentials/*.json; do
                [ -f "$cred_file" ] || continue
                local basename=$(basename "$cred_file")
                
                # Check if file is new or modified
                if ! git show "$last_backup_commit:credentials/$basename" >/dev/null 2>&1; then
                    # New file
                    changes_list="$changes_list credentials/$basename"
                    log DEBUG "New credential detected: $basename"
                elif ! git diff --quiet "$last_backup_commit" HEAD -- "credentials/$basename" 2>/dev/null; then
                    # Modified file (if it exists in current backup)
                    if [ -f "credentials/$basename" ]; then
                        changes_list="$changes_list credentials/$basename"
                        log DEBUG "Modified credential detected: $basename"
                    fi
                fi
            done
        fi
    else
        # Compare single JSON files
        for file in workflows.json credentials.json; do
            if [ -f "$temp_export_path/$file" ]; then
                if ! git show "$last_backup_commit:$file" >/dev/null 2>&1; then
                    # New file
                    changes_list="$changes_list $file"
                    log DEBUG "New file detected: $file"
                elif ! cmp -s "$temp_export_path/$file" <(git show "$last_backup_commit:$file" 2>/dev/null); then
                    # Modified file
                    changes_list="$changes_list $file"
                    log DEBUG "Modified file detected: $file"
                fi
            fi
        done
    fi
    
    cd "$original_pwd"
    
    if [ -n "$changes_list" ]; then
        log SUCCESS "Incremental changes detected: $(echo $changes_list | wc -w) files"
        echo "$changes_list"
        return 0
    else
        log INFO "No changes detected since last backup"
        return 2  # Special return code for "no changes"
    fi
}

# --- Main Function --- 
main() {
    # Parse command-line arguments first
    while [ $# -gt 0 ]; do
        case "$1" in
            --action) ARG_ACTION="$2"; shift 2 ;; 
            --container) ARG_CONTAINER="$2"; shift 2 ;; 
            --token) ARG_TOKEN="$2"; shift 2 ;; 
            --repo) ARG_REPO="$2"; shift 2 ;; 
            --branch) ARG_BRANCH="$2"; shift 2 ;; 
            --config) ARG_CONFIG_FILE="$2"; shift 2 ;; 
            --dated) ARG_DATED_BACKUPS=true; shift 1 ;; 
            --restore-type) 
                if [[ "$2" == "all" || "$2" == "workflows" || "$2" == "credentials" ]]; then
                    ARG_RESTORE_TYPE="$2"
                else
                    echo -e "${RED}[ERROR]${NC} Invalid --restore-type: '$2'. Must be 'all', 'workflows', or 'credentials'." >&2
                    exit 1
                fi
                shift 2 ;;
            --dry-run) ARG_DRY_RUN=true; shift 1 ;; 
            --verbose) ARG_VERBOSE=true; shift 1 ;; 
            --log-file) ARG_LOG_FILE="$2"; shift 2 ;; 
            --trace) DEBUG_TRACE=true; shift 1;; 
            -h|--help) show_help; exit 0 ;; 
            # Selective backup/restore options
            --workflow-id) ARG_WORKFLOW_ID="$2"; shift 2 ;;
            --credential-id) ARG_CREDENTIAL_ID="$2"; shift 2 ;;
            # Assignment options (restore only)
            --user-id) ARG_USER_ID="$2"; shift 2 ;;
            --project-id) ARG_PROJECT_ID="$2"; shift 2 ;;
            # Advanced options
            --separate-files) ARG_SEPARATE_FILES=true; shift 1 ;;
            --import-as-new) ARG_IMPORT_AS_NEW=true; shift 1 ;;
            --include-linked-creds) ARG_INCLUDE_LINKED_CREDS=true; shift 1 ;;
            --incremental) ARG_INCREMENTAL=true; shift 1 ;;
            *) echo -e "${RED}[ERROR]${NC} Invalid option: $1" >&2; show_help; exit 1 ;; 
        esac
    done

    # Load config file (must happen after parsing args)
    load_config

    log HEADER "n8n Backup/Restore Manager v$VERSION"
    if [ "$ARG_DRY_RUN" = "true" ]; then log WARN "DRY RUN MODE ENABLED"; fi
    if [ "$ARG_VERBOSE" = "true" ]; then log DEBUG "Verbose mode enabled."; fi
    
    check_host_dependencies

    # Use local variables within main
    local action="$ARG_ACTION"
    local container_id="$ARG_CONTAINER"
    local github_token="$ARG_TOKEN"
    local github_repo="$ARG_REPO"
    local branch="${ARG_BRANCH:-main}"
    local use_dated_backup=$ARG_DATED_BACKUPS
    local restore_type="${ARG_RESTORE_TYPE:-all}"
    local is_dry_run=$ARG_DRY_RUN

    log DEBUG "Initial Action: $action"
    log DEBUG "Initial Container: $container_id"
    log DEBUG "Initial Repo: $github_repo"
    log DEBUG "Initial Branch: $branch"
    log DEBUG "Initial Dated Backup: $use_dated_backup"
    log DEBUG "Initial Dry Run: $is_dry_run"
    log DEBUG "Initial Verbose: $ARG_VERBOSE"
    log DEBUG "Initial Log File: $ARG_LOG_FILE"

    # Check if running non-interactively
    if ! [ -t 0 ]; then
        log DEBUG "Running in non-interactive mode."
        if { [ -z "$action" ] || [ -z "$container_id" ] || [ -z "$github_token" ] || [ -z "$github_repo" ]; }; then
            log ERROR "Running in non-interactive mode but required parameters are missing."
            log INFO "Please provide --action, --container, --token, and --repo via arguments or config file."
            show_help
            exit 1
        fi
        log DEBUG "Validating non-interactive container: $container_id"
        local found_id
        found_id=$(docker ps -q --filter "id=$container_id" --filter "name=$container_id" | head -n 1)
        if [ -z "$found_id" ]; then
             log ERROR "Container '$container_id' not found or not running."
             exit 1
        fi
        container_id=$found_id
        log SUCCESS "Using specified container: $container_id"

    else
        log DEBUG "Running in interactive mode."
        if [ -z "$action" ]; then 
            select_action
            action="$SELECTED_ACTION"
        fi
        log DEBUG "Action selected: $action"
        
        if [ -z "$container_id" ]; then
            select_container
            container_id="$SELECTED_CONTAINER_ID"
        else
            log DEBUG "Validating specified container: $container_id"
            local found_id
            found_id=$(docker ps -q --filter "id=$container_id" --filter "name=$container_id" | head -n 1)
            if [ -z "$found_id" ]; then
                 log ERROR "Container '$container_id' not found or not running."
                 log WARN "Falling back to interactive container selection..."
                 select_container
                 container_id="$SELECTED_CONTAINER_ID"
            else
                 container_id=$found_id
                 log SUCCESS "Using specified container: $container_id"
            fi
        fi
        log DEBUG "Container selected: $container_id"
        
        get_github_config
        github_token="$GITHUB_TOKEN"
        github_repo="$GITHUB_REPO"
        branch="$GITHUB_BRANCH"
        log DEBUG "GitHub Token: ****"
        log DEBUG "GitHub Repo: $github_repo"
        log DEBUG "GitHub Branch: $branch"
        
        if [[ "$action" == "backup" ]] && ! $use_dated_backup && ! grep -q "CONF_DATED_BACKUPS=true" "${ARG_CONFIG_FILE:-$CONFIG_FILE_PATH}" 2>/dev/null; then
             printf "Create a dated backup (in a timestamped subdirectory)? (yes/no) [no]: "
             local confirm_dated
             read -r confirm_dated
             if [[ "$confirm_dated" == "yes" || "$confirm_dated" == "y" ]]; then
                 use_dated_backup=true
             fi
        fi
        log DEBUG "Use Dated Backup: $use_dated_backup"
        
        if [[ "$action" == "restore" ]] && [[ "$restore_type" == "all" ]] && ! grep -q "CONF_RESTORE_TYPE=" "${ARG_CONFIG_FILE:-$CONFIG_FILE_PATH}" 2>/dev/null; then
            select_restore_type
            restore_type="$SELECTED_RESTORE_TYPE"
        elif [[ "$action" == "restore" ]]; then
             log INFO "Using restore type: $restore_type"
        fi
        log DEBUG "Restore Type: $restore_type"
    fi

    # Final validation
    if [ -z "$action" ] || [ -z "$container_id" ] || [ -z "$github_token" ] || [ -z "$github_repo" ] || [ -z "$branch" ]; then
        log ERROR "Missing required parameters (Action, Container, Token, Repo, Branch). Exiting."
        exit 1
    fi

    # Perform GitHub API pre-checks (skip in dry run? No, checks are read-only)
    if ! check_github_access "$github_token" "$github_repo" "$branch" "$action"; then
        log ERROR "GitHub access pre-checks failed. Aborting."
        exit 1
    fi

    # Execute action
    log INFO "Starting action: $action"
    case "$action" in
        backup)
            if backup "$container_id" "$github_token" "$github_repo" "$branch" "$use_dated_backup" "$is_dry_run"; then
                log SUCCESS "Backup operation completed successfully."
            else
                log ERROR "Backup operation failed."
                exit 1
            fi
            ;;
        restore)
            if restore "$container_id" "$github_token" "$github_repo" "$branch" "$restore_type" "$is_dry_run"; then
                 log SUCCESS "Restore operation completed successfully."
            else
                 log ERROR "Restore operation failed."
                 exit 1
            fi
            ;;
        *)
            log ERROR "Invalid action specified: $action. Use 'backup' or 'restore'."
            exit 1
            ;;
    esac

    exit 0
}

# --- Script Execution --- 

# Trap for unexpected errors
trap 'log ERROR "An unexpected error occurred (Line: $LINENO). Aborting."; exit 1' ERR

# Execute main function, passing all script arguments
main "$@"

exit 0

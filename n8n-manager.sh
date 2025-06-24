#!/usr/bin/env bash
# =========================================================
# n8n-manager.sh - Interactive backup/restore for n8n
# =========================================================
set -Eeuo pipefail
IFS=$'\n\t'

# --- Configuration ---
CONFIG_FILE_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/n8n-manager/config"

# --- Global variables ---
VERSION="3.1.1"
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
    local is_dry_run="${3:-$is_dry_run}"  # Use third parameter or fall back to global is_dry_run
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

    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        if [ ! -f "$backup_workflows" ]; then
            log ERROR "Pre-restore backup file workflows.json not found in $backup_dir. Cannot rollback workflows."
            rollback_success=false
        fi
    fi
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if [ ! -f "$backup_credentials" ]; then
            log ERROR "Pre-restore backup file credentials.json not found in $backup_dir. Cannot rollback credentials."
            rollback_success=false
        fi
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
        dockExec "$container_id" "rm -f $container_workflows $container_credentials" false || true
        return 1
    fi

    log INFO "Importing pre-restore backup data into n8n..."
    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        if ! dockExec "$container_id" "n8n import:workflow --separate --input=$container_workflows" false; then
            log ERROR "Rollback failed during workflow import."
            rollback_success=false
        fi
    fi
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if ! dockExec "$container_id" "n8n import:credentials --separate --input=$container_credentials" false; then
            log ERROR "Rollback failed during credential import."
            rollback_success=false
        fi
    fi

    log INFO "Cleaning up rollback files in container..."
    dockExec "$container_id" "rm -f $container_workflows $container_credentials" false || log WARN "Could not clean up rollback files in container."

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
    local container="$1"
    local github_token="$2"
    local github_repo="$3"
    local branch="$4"
    local use_dated_backup=$5
    local is_dry_run=$6

    log HEADER "Performing Backup to GitHub"
    if $is_dry_run; then log WARN "DRY RUN MODE ENABLED - NO CHANGES WILL BE MADE"; fi

    # Validate incremental + dated compatibility
    if $ARG_INCREMENTAL && $use_dated_backup; then
        log ERROR "Incremental backup (--incremental) is not compatible with dated backup (--dated)."
        log ERROR "Please use either --incremental OR --dated, but not both."
        log ERROR "Suggestion: Use --incremental for frequent backups, --dated for milestone backups."
        return 1
    fi

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

    # Export n8n data
    log INFO "Exporting data from n8n container..."

    # Determine if using separate files mode
    local using_separate_files=false
    if $ARG_SEPARATE_FILES; then
        using_separate_files=true
        log INFO "Using separate files mode (git-friendly)"
    fi

    # Export workflow(s)
    if [ -n "$ARG_WORKFLOW_ID" ]; then
        log INFO "Exporting specific workflow ID: $ARG_WORKFLOW_ID"
        if ! $is_dry_run; then
            if ! dockExec "$container" "n8n export:workflow --id=$ARG_WORKFLOW_ID --output=/tmp/workflow_$ARG_WORKFLOW_ID.json"; then
                log ERROR "Failed to export workflow $ARG_WORKFLOW_ID"
                rm -rf "$tmp_dir"
                return 1
            fi
        else
            log DRYRUN "Would export workflow ID: $ARG_WORKFLOW_ID"
        fi
    else
        if $using_separate_files; then
            log INFO "Exporting all workflows in separate files"
            if ! $is_dry_run; then
                if ! dockExec "$container" "n8n export:workflow --backup --output=/tmp/workflows/"; then
                    log ERROR "Failed to export workflows"
                    rm -rf "$tmp_dir"
                    return 1
                fi
            else
                log DRYRUN "Would export all workflows to separate files"
            fi
        else
            log INFO "Exporting all workflows"
            if ! $is_dry_run; then
                if ! dockExec "$container" "n8n export:workflow --output=$container_workflows"; then
                    log ERROR "Failed to export workflows"
                    rm -rf "$tmp_dir"
                    return 1
                fi
            else
                log DRYRUN "Would export all workflows to single file"
            fi
        fi
    fi

    # Auto-discover linked credentials if workflow ID specified
    local additional_credential_ids=""
    if [ -n "$ARG_WORKFLOW_ID" ] && $ARG_INCLUDE_LINKED_CREDS; then
        log INFO "Auto-discovering linked credentials for workflow ID: $ARG_WORKFLOW_ID"
        if ! $is_dry_run; then
            additional_credential_ids=$(discover_linked_credentials "$container" "$ARG_WORKFLOW_ID" "$tmp_dir")
            if [ -n "$additional_credential_ids" ]; then
                log SUCCESS "Found linked credentials: $additional_credential_ids"
            else
                log INFO "No linked credentials found for workflow $ARG_WORKFLOW_ID"
            fi
        else
            log DRYRUN "Would discover linked credentials for workflow $ARG_WORKFLOW_ID"
        fi
    fi

    # Export credential(s)
    if [ -n "$ARG_CREDENTIAL_ID" ]; then
        log INFO "Exporting specific credential ID: $ARG_CREDENTIAL_ID"
        if ! $is_dry_run; then
            if ! dockExec "$container" "n8n export:credentials --id=$ARG_CREDENTIAL_ID --decrypted --pretty --output=/tmp/credential_$ARG_CREDENTIAL_ID.json"; then
                log ERROR "Failed to export credential $ARG_CREDENTIAL_ID"
                rm -rf "$tmp_dir"
                return 1
            fi
        else
            log DRYRUN "Would export credential ID: $ARG_CREDENTIAL_ID"
        fi
    elif [ -n "$additional_credential_ids" ]; then
        # Export individual linked credentials
        log DEBUG "Processing credential IDs: $additional_credential_ids" >&2
        local remaining_creds="$additional_credential_ids"
        while [ -n "$remaining_creds" ]; do
            local cred_id="${remaining_creds%% *}"
            log DEBUG "Exporting individual credential ID: $cred_id" >&2
            local cmd="n8n export:credentials --id=$cred_id --decrypted --pretty --output=/tmp/credential_$cred_id.json"
            log DEBUG "Command: $cmd" >&2
            if ! $is_dry_run; then
                if ! dockExec "$container" "$cmd"; then
                    log ERROR "Failed to export credential $cred_id"
                    rm -rf "$tmp_dir"
                    return 1
                fi
            else
                log DRYRUN "Would export credential ID: $cred_id"
            fi
            
            # Remove processed credential from list
            if [ "$remaining_creds" = "$cred_id" ]; then
                remaining_creds=""
            else
                remaining_creds="${remaining_creds#* }"
            fi
        done
    else
        log INFO "Exporting all credentials"
        if $using_separate_files; then
            if ! $is_dry_run; then
                if ! dockExec "$container" "n8n export:credentials --backup --decrypted --output=/tmp/credentials/"; then
                    log ERROR "Failed to export credentials"
                    rm -rf "$tmp_dir"
                    return 1
                fi
            else
                log DRYRUN "Would export all credentials to separate files"
            fi
        else
            if ! $is_dry_run; then
                if ! dockExec "$container" "n8n export:credentials --decrypted --output=$container_credentials"; then
                    log ERROR "Failed to export credentials"
                    rm -rf "$tmp_dir"
                    return 1
                fi
            else
                log DRYRUN "Would export all credentials to single file"
            fi
        fi
    fi

    # Incremental backup analysis
    local incremental_changes=""
    if $ARG_INCREMENTAL; then
        log INFO "Performing incremental backup analysis..."
        if ! $is_dry_run; then
            incremental_changes=$(get_incremental_changes "$container" "$tmp_dir")
            if [ "$incremental_changes" = "no_changes" ]; then
                log INFO "No changes detected since last backup"
                # Clean up and exit
                if ! $is_dry_run; then
                    dockExec "$container" "rm -rf /tmp/temp_workflows/ /tmp/temp_credentials/ /tmp/temp_workflows.json /tmp/temp_credentials.json" 2>/dev/null || true
                fi
                rm -rf "$tmp_dir"
                return 0
            else
                log INFO "Changes detected: $incremental_changes"
            fi
        else
            log DRYRUN "Would perform incremental backup analysis"
        fi
    fi

    # Export environment variables
    if ! $is_dry_run; then
        if ! dockExec "$container" "printenv | grep ^N8N_ > $container_env"; then
            log WARN "Failed to export N8N environment variables (container might not have any)"
        fi
    else
        log DRYRUN "Would export N8N environment variables"
    fi

    # Create global backup directory structure: /Backups/{Dated|data}/
    local backup_base_dir="$tmp_dir/Backups"
    local backup_dir
    if $use_dated_backup; then
        backup_dir="$backup_base_dir/Dated/backup_$(timestamp)"
        log INFO "Using dated backup directory: Backups/Dated/backup_$(timestamp)"
    else
        backup_dir="$backup_base_dir/data"
        log INFO "Using standard backup directory: Backups/data"
    fi
    
    if ! $is_dry_run; then
        mkdir -p "$backup_dir"
    else
        log DRYRUN "Would create backup directory: $backup_dir"
    fi
    
    # Create proper subdirectories for separate files mode
    if $using_separate_files && ! $is_dry_run; then
        mkdir -p "$backup_dir/workflows"
        mkdir -p "$backup_dir/credentials"
        log DEBUG "Created subdirectories: workflows/, credentials/"
    fi

    log INFO "Copying exported files from container into Git directory..."
    
    # Determine items to copy with correct paths
    local items_to_copy=()
    
    if $using_separate_files; then
        # Separate files mode - organize into subdirectories
        if [ -n "$ARG_WORKFLOW_ID" ]; then
            items_to_copy+=("workflow_$ARG_WORKFLOW_ID.json:workflows/workflow_$ARG_WORKFLOW_ID.json")
        else
            # Copy individual workflow files from /tmp/workflows/ to workflows/ (avoiding duplication)
            items_to_copy+=("workflows:workflows")
        fi
        
        if [ -n "$ARG_CREDENTIAL_ID" ]; then
            items_to_copy+=("credential_$ARG_CREDENTIAL_ID.json:credentials/credential_$ARG_CREDENTIAL_ID.json")
        elif [ -n "$additional_credential_ids" ]; then
            # Add individual linked credential files to credentials/ subdirectory
            log DEBUG "Adding linked credential files to copy list: $additional_credential_ids" >&2
            local remaining_creds="$additional_credential_ids"
            while [ -n "$remaining_creds" ]; do
                local cred_id="${remaining_creds%% *}"
                items_to_copy+=("credential_$cred_id.json:credentials/credential_$cred_id.json")
                log DEBUG "Added credential file to copy list: credential_$cred_id.json -> credentials/" >&2
                
                # Remove processed credential from list
                if [ "$remaining_creds" = "$cred_id" ]; then
                    remaining_creds=""
                else
                    remaining_creds="${remaining_creds#* }"
                fi
            done
        else
            # Copy individual credential files from /tmp/credentials/ to credentials/ (avoiding duplication)
            items_to_copy+=("credentials:credentials")
        fi
        items_to_copy+=(".env:.env")  # .env stays in root
    else
        # Single file mode
        if [ -z "$ARG_WORKFLOW_ID" ]; then
            items_to_copy+=("workflows.json:workflows.json")
        fi
        if [ -z "$ARG_CREDENTIAL_ID" ]; then
            items_to_copy+=("credentials.json:credentials.json")
        fi
        items_to_copy+=(".env:.env")
    fi

    # Copy files from container to backup directory
    if ! $is_dry_run; then
        for item in "${items_to_copy[@]}"; do
            local src_path="${item%%:*}"
            local dest_path="${item##*:}"
            local full_dest_path="$backup_dir/$dest_path"
            
            log DEBUG "Copying /tmp/$src_path to $full_dest_path"
            
            # Ensure destination directory exists
            if [[ "$dest_path" == *"/"* ]]; then
                local dest_dir="${dest_path%/*}"
                mkdir -p "$backup_dir/$dest_dir"
            fi
            
            # Handle directory copying differently to avoid duplication
            if [[ "$src_path" == "workflows" ]] || [[ "$src_path" == "credentials" ]]; then
                # For directories, copy contents to avoid creating nested subdirectories
                local temp_dir=$(mktemp -d)
                if docker cp "$container:/tmp/$src_path" "$temp_dir/" 2>/dev/null; then
                    # Copy the contents of the extracted directory to the destination
                    if [ -d "$temp_dir/$src_path" ]; then
                        cp -r "$temp_dir/$src_path"/* "$backup_dir/$dest_path/" 2>/dev/null || true
                    fi
                    rm -rf "$temp_dir"
                else
                    log WARN "Failed to copy $src_path directory (might not exist)"
                fi
            else
                # For individual files, use normal docker cp
                if ! docker cp "$container:/tmp/$src_path" "$full_dest_path" 2>/dev/null; then
                    log WARN "Failed to copy $src_path (might not exist)"
                fi
            fi
        done
    else
        log DRYRUN "Would copy the following files:"
        for item in "${items_to_copy[@]}"; do
            local src_path="${item%%:*}"
            local dest_path="${item##*:}"
            log DRYRUN "  /tmp/$src_path -> $backup_dir/$dest_path"
        done
    fi

    # Clean up temporary files in container
    log INFO "Cleaning up temporary files in container..."
    if ! $is_dry_run; then
        dockExec "$container" "rm -f $container_workflows $container_credentials $container_env" 2>/dev/null || true
        if $using_separate_files; then
            dockExec "$container" "rm -rf /tmp/workflows/ /tmp/credentials/" 2>/dev/null || true
        fi
        if [ -n "$ARG_WORKFLOW_ID" ]; then
            dockExec "$container" "rm -f /tmp/workflow_$ARG_WORKFLOW_ID.json" 2>/dev/null || true
        fi
        if [ -n "$ARG_CREDENTIAL_ID" ]; then
            dockExec "$container" "rm -f /tmp/credential_$ARG_CREDENTIAL_ID.json" 2>/dev/null || true
        fi
        if [ -n "$additional_credential_ids" ]; then
            local remaining_creds="$additional_credential_ids"
            while [ -n "$remaining_creds" ]; do
                local cred_id="${remaining_creds%% *}"
                dockExec "$container" "rm -f /tmp/credential_$cred_id.json" 2>/dev/null || true
                
                if [ "$remaining_creds" = "$cred_id" ]; then
                    remaining_creds=""
                else
                    remaining_creds="${remaining_creds#* }"
                fi
            done
        fi
    else
        log DRYRUN "Would clean up temporary files in container"
    fi

    # Add files to Git
    log INFO "Adding files to Git..."
    if ! $is_dry_run; then
        log DEBUG "Adding Backups directory"
        if ! git -C "$tmp_dir" add Backups/ 2>/dev/null; then
            log ERROR "Failed to add backup files to Git"
            rm -rf "$tmp_dir"
            return 1
        fi
        
        log DEBUG "Files in backup directory:"
        ls -la "$backup_dir" 2>/dev/null || log WARN "Backup directory listing failed"
        
        log DEBUG "Staging status:"
        git -C "$tmp_dir" status --porcelain 2>/dev/null || log WARN "Git status failed"
    else
        log DRYRUN "Would add backup files to Git"
    fi

    # Commit changes
    log INFO "Committing changes..."
    if ! $is_dry_run; then
        log DEBUG "Creating timestamp file to ensure backup uniqueness"
        echo "$(timestamp)" > "$tmp_dir/.n8n-backup-timestamp"
        
        log DEBUG "Adding all n8n files to Git..."
        if ! git -C "$tmp_dir" add . 2>/dev/null; then
            log ERROR "Failed to add files to Git"
            rm -rf "$tmp_dir"
            return 1
        fi
        
        log DEBUG "Adding Backups directory"
        git -C "$tmp_dir" add Backups/ 2>/dev/null || true
        
        log DEBUG "Files in backup directory:"
        ls -la "$backup_dir" 2>/dev/null || log WARN "Backup directory listing failed"
        
        # Get n8n version for commit message
        local n8n_ver="unknown"
        n8n_ver=$(dockExec "$container" "n8n --version" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1) || n8n_ver="unknown"
        
        local backup_type="full"
        if [ -n "$ARG_WORKFLOW_ID" ]; then
            backup_type="workflow-specific"
        elif [ -n "$ARG_CREDENTIAL_ID" ]; then
            backup_type="credential-specific"
        elif $ARG_INCREMENTAL; then
            backup_type="incremental"
        fi
        
        local backup_identifier
        if $use_dated_backup; then
            backup_identifier="[Backups/Dated/backup_$(timestamp)]"
        else
            backup_identifier="[Backups/data]"
        fi
        
        local commit_message="🛡️ n8n Backup (v$n8n_ver) - $(timestamp) $backup_identifier"
        if [ "$backup_type" != "full" ]; then
            commit_message="$commit_message ($backup_type)"
        fi
        
        log DEBUG "Committing backup with message: $commit_message"
        
        if ! git -C "$tmp_dir" commit -m "$commit_message" 2>/dev/null; then
            log WARN "Git commit failed or no changes to commit"
            # Check if there are actually changes
            if git -C "$tmp_dir" diff --cached --quiet 2>/dev/null; then
                log INFO "No changes detected - backup already up to date"
                rm -rf "$tmp_dir"
                return 0
            else
                log ERROR "Git commit failed with changes present"
                rm -rf "$tmp_dir"
                return 1
            fi
        fi
    else
        log DRYRUN "Would commit backup with timestamped message"
    fi

    # Push to GitHub
    log INFO "Pushing backup to GitHub repository '$github_repo' branch '$branch'..."
    if ! $is_dry_run; then
        local commit_hash
        commit_hash=$(git -C "$tmp_dir" rev-parse HEAD 2>/dev/null)
        log DEBUG "Pushing commit $commit_hash to origin/$branch"
        
        if ! git -C "$tmp_dir" push origin "$branch" 2>/dev/null; then
            log ERROR "Failed to push backup to GitHub"
            rm -rf "$tmp_dir"
            return 1
        fi
        log SUCCESS "Backup successfully pushed to GitHub repository"
    else
        log DRYRUN "Would push backup to GitHub repository '$github_repo' branch '$branch'"
    fi

    # Clean up
    log INFO "Cleaning up host temporary directory..."
    rm -rf "$tmp_dir"

    if $is_dry_run; then
        log SUCCESS "Dry run completed successfully - no actual changes made"
    else
        log SUCCESS "Backup successfully completed and pushed to GitHub."
    fi
    log SUCCESS "Backup operation completed successfully."
}

restore() {
    local container="$1"
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
        if [ ! -f "$pre_workflows" ]; then
            log ERROR "Pre-restore backup file workflows.json not found in $pre_restore_dir. Cannot rollback workflows."
            backup_failed=true
        fi
    fi
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if [ ! -f "$pre_credentials" ]; then
            log ERROR "Pre-restore backup file credentials.json not found in $pre_restore_dir. Cannot rollback credentials."
            backup_failed=true
        fi
    fi
    if ! $backup_failed; then
        log INFO "Copying current data to host backup directory..."
        local copy_failed=false
        if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
            if $is_dry_run; then
                log DRYRUN "Would copy ${container}:${container_pre_workflows} to $pre_workflows"
            elif ! docker cp "${container}:${container_pre_workflows}" "$pre_workflows"; then copy_failed=true; fi
        fi
        if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
             if $is_dry_run; then
                 log DRYRUN "Would copy ${container}:${container_pre_credentials} to $pre_credentials"
             elif ! docker cp "${container}:${container_pre_credentials}" "$pre_credentials"; then copy_failed=true; fi
        fi
        
        dockExec "$container" "rm -f $container_pre_workflows $container_pre_credentials" "$is_dry_run" || true

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
    
    # Determine the backup source directory
    local backup_source_dir
    if $dated_backup_found; then
        backup_source_dir="$selected_backup"
        log INFO "Using dated backup source: $backup_source_dir"
    elif [ -d "$download_dir/Backups/data" ]; then
        backup_source_dir="$download_dir/Backups/data"
        log INFO "Using non-dated backup source: Backups/data/"
    else
        backup_source_dir="$download_dir"
        log INFO "Using legacy backup source: repository root"
    fi
    
    # Set up container import paths
    local container_import_workflows="/tmp/import_workflows.json"
    local container_import_credentials="/tmp/import_credentials.json"
    
    # Find the workflow and credentials files in the backup source
    local repo_workflows=""
    local repo_credentials=""
    local using_separate_files=false
    
    log INFO "Looking for backup files in: $backup_source_dir"
    
    # Check for separate files mode first (workflows/ and credentials/ subdirectories)
    if [ -d "$backup_source_dir/workflows" ] && [ -d "$backup_source_dir/credentials" ]; then
        using_separate_files=true
        log INFO "Detected separate files backup mode"
        
        # For separate files mode, we need to use n8n import --separate
        # But first, let's verify files exist in the subdirectories
        local workflow_files
        local credential_files
        workflow_files=$(find "$backup_source_dir/workflows" -name "*.json" -type f | wc -l)
        credential_files=$(find "$backup_source_dir/credentials" -name "*.json" -type f | wc -l)
        
        log DEBUG "Found $workflow_files workflow files and $credential_files credential files"
        
        if [ "$workflow_files" -gt 0 ] && [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
            repo_workflows="$backup_source_dir/workflows"
            log SUCCESS "Found workflows directory with $workflow_files files"
        fi
        
        if [ "$credential_files" -gt 0 ] && [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
            repo_credentials="$backup_source_dir/credentials"
            log SUCCESS "Found credentials directory with $credential_files files"
        fi
    else
        # Single file mode
        log INFO "Detected single file backup mode"
        
        if [ -f "$backup_source_dir/workflows.json" ] && [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
            repo_workflows="$backup_source_dir/workflows.json"
            log SUCCESS "Found workflows.json file"
        fi
        
        if [ -f "$backup_source_dir/credentials.json" ] && [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
            repo_credentials="$backup_source_dir/credentials.json"
            log SUCCESS "Found credentials.json file"
        fi
    fi
    
    # Display file information for debug purposes
    if [ -n "$repo_workflows" ]; then
        if $using_separate_files; then
            log DEBUG "Workflows directory: $repo_workflows ($(find "$repo_workflows" -name "*.json" | wc -l) files)"
        else
            log DEBUG "Workflow file size: $(du -h "$repo_workflows" | cut -f1)"
        fi
    fi
    
    if [ -n "$repo_credentials" ]; then
        if $using_separate_files; then
            log DEBUG "Credentials directory: $repo_credentials ($(find "$repo_credentials" -name "*.json" | wc -l) files)"
        else
            log DEBUG "Credentials file size: $(du -h "$repo_credentials" | cut -f1)"
        fi
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
            log DRYRUN "Would copy $repo_workflows to ${container}:${container_import_workflows}"
        else
            log INFO "Copying workflows file to container..."
            if docker cp "$repo_workflows" "${container}:${container_import_workflows}"; then
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
            log DRYRUN "Would copy $repo_credentials to ${container}:${container_import_credentials}"
        else
            log INFO "Copying credentials file to container..."
            if docker cp "$repo_credentials" "${container}:${container_import_credentials}"; then
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
            if ! docker cp "${container}:${container_import_workflows}" "$host_temp_workflows"; then
                log ERROR "Failed to copy workflows file from container for ID processing"
                import_status="failed"
            else
                local host_processed_workflows
                host_processed_workflows=$(mktemp)
                if strip_json_ids "$host_temp_workflows" "$host_processed_workflows" "workflow"; then
                    # Copy processed file back to container
                    if docker cp "$host_processed_workflows" "${container}:${temp_workflow_file}"; then
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
                if ! dockExec "$container" "$workflow_import_cmd" false; then
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
            if ! docker cp "${container}:${container_import_credentials}" "$host_temp_credentials"; then
                log ERROR "Failed to copy credentials file from container for ID processing"
                import_status="failed"
            else
                local host_processed_credentials
                host_processed_credentials=$(mktemp)
                if strip_json_ids "$host_temp_credentials" "$host_processed_credentials" "credential"; then
                    # Copy processed file back to container
                    if docker cp "$host_processed_credentials" "${container}:${temp_credential_file}"; then
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
                if ! dockExec "$container" "$credential_import_cmd" false; then
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
        if dockExec "$container" "[ -f $container_import_workflows ] && echo 'Workflow file exists'" "$is_dry_run"; then
            # Try with ash shell explicitly (common in Alpine)
            dockExec "$container" "ash -c 'rm -f $container_import_workflows 2>/dev/null || true'" "$is_dry_run" || true
            log DEBUG "Attempted cleanup of workflow import file"
        fi
        
        if dockExec "$container" "[ -f $container_import_credentials ] && echo 'Credentials file exists'" "$is_dry_run"; then
            # Try with ash shell explicitly (common in Alpine)
            dockExec "$container" "ash -c 'rm -f $container_import_credentials 2>/dev/null || true'" "$is_dry_run" || true
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
        # Single file mode
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

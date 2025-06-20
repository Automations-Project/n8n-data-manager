#!/usr/bin/env bash
# =========================================================
# n8n-workflows-bulk-editor.sh - Bulk workflow settings and tag management
# Part of n8n-data-manager project
# =========================================================
set -Eeuo pipefail
IFS=$'\n\t'

# --- Configuration ---
VERSION="1.0.0"
SCRIPT_NAME="n8n-workflows-bulk-editor"
CONFIG_FILE_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/n8n-manager/config"  # Shared with n8n-manager.sh
WORKFLOWS_CONFIG_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/n8n-manager/workflows-editor-config"

# --- Global Variables ---
DEBUG_TRACE=${DEBUG_TRACE:-false}
SELECTED_ACTION=""
TARGET_PATH=""
BACKUP_MODE="auto"  # auto, manual, none
DRY_RUN=false
INTERACTIVE_MODE=true
BATCH_MODE=false

# CLI Arguments
ARG_ACTION=""
ARG_TARGET=""
ARG_BACKUP_MODE="auto"
ARG_DRY_RUN=false
ARG_INTERACTIVE=false
ARG_BATCH=false
ARG_SETTING_PAIRS=()
ARG_SETTINGS_TEMPLATE=""
ARG_RESET_SETTINGS=false
ARG_ADD_TAGS=()
ARG_REMOVE_TAGS=()
ARG_TAG_ID_FORMAT="uuid4"
ARG_REGENERATE_TAG_IDS=false
ARG_SET_WORKFLOW_ID=""
ARG_REGENERATE_WORKFLOW_ID=false
ARG_SET_VERSION_ID=""
ARG_REGENERATE_VERSION_ID=false
ARG_CLEAR_TARGETS=""
ARG_CONFIG_FILE=""
ARG_VERBOSE=false
ARG_LOG_FILE=""

# Configuration variables (loaded from config file)
CONF_GITHUB_TOKEN=""
CONF_GITHUB_REPO=""
CONF_GITHUB_BRANCH="main"
CONF_DEFAULT_BACKUP_DIR=""
CONF_VERBOSE=false
CONF_LOG_FILE=""

# ANSI colors for better UI (using printf for robustness)
printf -v RED     '\033[0;31m'
printf -v GREEN   '\033[0;32m'
printf -v BLUE    '\033[0;34m'
printf -v YELLOW  '\033[1;33m'
printf -v PURPLE  '\033[0;35m'
printf -v CYAN    '\033[0;36m'
printf -v WHITE   '\033[1;37m'
printf -v NC      '\033[0m' # No Color
printf -v BOLD    '\033[1m'
printf -v DIM     '\033[2m'

# Valid workflow settings (all possible n8n workflow settings)
VALID_SETTINGS=(
    "executionOrder"
    "saveDataErrorExecution" 
    "saveDataSuccessExecution"
    "saveExecutionProgress"
    "saveManualExecutions"
    "callerPolicy"
    "executionTimeout"
    "errorWorkflow"
    "timeSavedPerExecution"
)

# Default settings values (n8n defaults)
DEFAULT_SETTINGS=(
    "executionOrder=v1"
    "saveDataErrorExecution=all"
    "saveDataSuccessExecution=all"
    "saveExecutionProgress=false"
    "saveManualExecutions=false"
    "callerPolicy=workflowsFromSameOwner"
    "executionTimeout=0"
    "errorWorkflow="
    "timeSavedPerExecution=0"
)

# --- Logging Functions ---
# Simplified and sanitized log function following n8n-manager.sh pattern
log() {
    local level="$1"
    local message="$2"
    
    # Skip debug messages if verbose is not enabled
    if [ "$level" = "DEBUG" ] && [ "$ARG_VERBOSE" != "true" ] && [ "$CONF_VERBOSE" != "true" ]; then 
        return 0
    fi
    
    # Set color based on level
    local color=""
    local prefix=""
    local to_stderr=false
    
    case "$level" in
        "DEBUG")   color="$DIM"; prefix="[DEBUG]" ;;
        "INFO")    color="$BLUE"; prefix="[INFO]" ;;
        "SUCCESS") color="$GREEN"; prefix="[SUCCESS]" ;;
        "WARN")    color="$YELLOW"; prefix="[WARN]"; to_stderr=true ;;
        "ERROR")   color="$RED"; prefix="[ERROR]"; to_stderr=true ;;
        "HEADER")  color="$BOLD$CYAN"; prefix="[===]" ;;
        "DRYRUN")  color="$PURPLE"; prefix="[DRY-RUN]" ;;
        *)         color="$NC"; prefix="[LOG]" ;;
    esac
    
    local timestamp=$(date '+%H:%M:%S')
    local formatted_message="${color}${prefix} ${timestamp} ${message}${NC}"
    
    if $to_stderr; then
        echo -e "$formatted_message" >&2
    else
        echo -e "$formatted_message"
    fi
    
    # Log to file if specified
    if [ -n "$ARG_LOG_FILE" ] || [ -n "$CONF_LOG_FILE" ]; then
        local log_file="${ARG_LOG_FILE:-$CONF_LOG_FILE}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message" >> "$log_file"
    fi
}

# --- Debug/Trace Function ---
trace_cmd() {
    if $DEBUG_TRACE; then
        echo -e "${PURPLE}[TRACE] Running command: $*${NC}" >&2
        "$@"
        local ret=$?
        echo -e "${PURPLE}[TRACE] Command returned: $ret${NC}" >&2
        return $ret
    else
        "$@"
        return $?
    fi
}

# --- Helper Functions ---
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_dependencies() {
    log INFO "Checking required dependencies..."
    
    local missing_deps=()
    
    if ! command_exists jq; then
        missing_deps+=("jq")
    fi
    
    if ! command_exists uuidgen; then
        missing_deps+=("uuidgen")
    fi
    
    if ! command_exists git; then
        missing_deps+=("git")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log ERROR "Missing required dependencies: ${missing_deps[*]}"
        log ERROR "Please install missing dependencies and try again."
        exit 1
    fi
    
    log SUCCESS "All required dependencies are available."
}

load_config() {
    log DEBUG "Loading configuration from $CONFIG_FILE_PATH"
    
    if [ -f "$CONFIG_FILE_PATH" ]; then
        # Source the config file safely
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ $key =~ ^[[:space:]]*# ]] && continue
            [[ -z $key ]] && continue
            
            # Remove quotes from value
            value=$(echo "$value" | sed 's/^["'\'']*//;s/["'\'']*$//')
            
            case "$key" in
                CONF_GITHUB_TOKEN) CONF_GITHUB_TOKEN="$value" ;;
                CONF_GITHUB_REPO) CONF_GITHUB_REPO="$value" ;;
                CONF_GITHUB_BRANCH) CONF_GITHUB_BRANCH="$value" ;;
                CONF_DEFAULT_BACKUP_DIR) CONF_DEFAULT_BACKUP_DIR="$value" ;;
                CONF_VERBOSE) CONF_VERBOSE="$value" ;;
                CONF_LOG_FILE) CONF_LOG_FILE="$value" ;;
            esac
        done < "$CONFIG_FILE_PATH"
        
        log DEBUG "Configuration loaded successfully"
    else
        log DEBUG "Configuration file not found at $CONFIG_FILE_PATH"
    fi
    
    # Load workflows-specific config if exists
    if [ -f "$WORKFLOWS_CONFIG_PATH" ]; then
        log DEBUG "Loading workflows-specific configuration"
        # Similar loading logic for workflow-specific settings
    fi
}

timestamp() {
    date +"%Y-%m-%d_%H-%M-%S"
}

# --- JSON Validation and Manipulation Functions ---
validate_workflow_json() {
    local workflow_file="$1"
    
    if [ ! -f "$workflow_file" ]; then
        log ERROR "Workflow file not found: $workflow_file"
        return 1
    fi
    
    if ! jq empty "$workflow_file" 2>/dev/null; then
        log ERROR "Invalid JSON format in workflow file: $workflow_file"
        return 1
    fi
    
    # Check if it's a valid n8n workflow (has required fields)
    if ! jq -e '.name and .nodes' "$workflow_file" >/dev/null 2>&1; then
        log ERROR "File does not appear to be a valid n8n workflow: $workflow_file"
        return 1
    fi
    
    return 0
}

backup_workflow_file() {
    local workflow_file="$1"
    local backup_mode="$2"
    
    case "$backup_mode" in
        "auto"|"manual")
            local backup_dir
            if [ -n "$CONF_DEFAULT_BACKUP_DIR" ]; then
                backup_dir="$CONF_DEFAULT_BACKUP_DIR"
            else
                backup_dir="$(dirname "$workflow_file")/.backups"
            fi
            
            local timestamp_dir="$backup_dir/backup_$(timestamp)"
            
            if $DRY_RUN; then
                log DRYRUN "Would create backup: $timestamp_dir/$(basename "$workflow_file")"
                return 0
            fi
            
            mkdir -p "$timestamp_dir"
            cp "$workflow_file" "$timestamp_dir/"
            
            # Create timestamp file (following n8n-manager.sh format)
            echo "Backup generated at: $(date +"%Y-%m-%d %H:%M:%S.%N")" > "$timestamp_dir/backup_timestamp.txt"
            
            log SUCCESS "Backup created: $timestamp_dir/$(basename "$workflow_file")"
            ;;
        "none")
            log DEBUG "Backup mode set to 'none', skipping backup"
            ;;
        *)
            log ERROR "Invalid backup mode: $backup_mode"
            return 1
            ;;
    esac
}

# --- Settings Management Functions ---
validate_setting() {
    local setting_key="$1"
    local setting_value="$2"
    
    # Check if setting key is valid
    local valid=false
    for valid_setting in "${VALID_SETTINGS[@]}"; do
        if [ "$setting_key" = "$valid_setting" ]; then
            valid=true
            break
        fi
    done
    
    if [ "$valid" = "false" ]; then
        log ERROR "Invalid setting key: $setting_key"
        log ERROR "Valid settings: ${VALID_SETTINGS[*]}"
        return 1
    fi
    
    # Validate setting value based on key
    case "$setting_key" in
        "executionOrder")
            if [[ ! "$setting_value" =~ ^v[0-9]+$ ]]; then
                log ERROR "Invalid executionOrder format. Expected: v1, v2, etc."
                return 1
            fi
            ;;
        "saveDataErrorExecution"|"saveDataSuccessExecution")
            if [[ ! "$setting_value" =~ ^(all|none)$ ]]; then
                log ERROR "Invalid value for $setting_key. Expected: all or none"
                return 1
            fi
            ;;
        "saveExecutionProgress"|"saveManualExecutions")
            if [[ ! "$setting_value" =~ ^(true|false)$ ]]; then
                log ERROR "Invalid value for $setting_key. Expected: true or false"
                return 1
            fi
            ;;
        "callerPolicy")
            if [[ ! "$setting_value" =~ ^(workflowsFromSameOwner|workflowsFromAnyOwner|none)$ ]]; then
                log ERROR "Invalid callerPolicy. Expected: workflowsFromSameOwner, workflowsFromAnyOwner, or none"
                return 1
            fi
            ;;
        "executionTimeout"|"timeSavedPerExecution")
            if [[ ! "$setting_value" =~ ^[0-9]+$ ]]; then
                log ERROR "Invalid value for $setting_key. Expected: positive integer"
                return 1
            fi
            ;;
        "errorWorkflow")
            # Can be empty or a valid workflow ID (alphanumeric)
            if [ -n "$setting_value" ] && [[ ! "$setting_value" =~ ^[a-zA-Z0-9]+$ ]]; then
                log ERROR "Invalid errorWorkflow ID format"
                return 1
            fi
            ;;
    esac
    
    return 0
}

edit_workflow_setting() {
    local workflow_file="$1"
    local setting_key="$2"
    local setting_value="$3"
    local backup_mode="$4"
    
    log INFO "Editing setting '$setting_key' in workflow: $(basename "$workflow_file")"
    
    # Validate inputs
    if ! validate_workflow_json "$workflow_file"; then
        return 1
    fi
    
    if ! validate_setting "$setting_key" "$setting_value"; then
        return 1
    fi
    
    # Create backup if needed
    if ! backup_workflow_file "$workflow_file" "$backup_mode"; then
        return 1
    fi
    
    if $DRY_RUN; then
        log DRYRUN "Would set $setting_key = $setting_value in $workflow_file"
        return 0
    fi
    
    # Update the setting using jq
    local temp_file
    temp_file=$(mktemp)
    
    if ! jq ".settings.${setting_key} = \"${setting_value}\"" "$workflow_file" > "$temp_file"; then
        log ERROR "Failed to update setting in workflow file"
        rm -f "$temp_file"
        return 1
    fi
    
    # Move temp file to original location
    if ! mv "$temp_file" "$workflow_file"; then
        log ERROR "Failed to save updated workflow file"
        rm -f "$temp_file"
        return 1
    fi
    
    log SUCCESS "Successfully updated setting '$setting_key' to '$setting_value'"
    return 0
}

apply_settings_template() {
    local workflow_file="$1"
    local template_file="$2"
    local backup_mode="$3"
    
    log INFO "Applying settings template to workflow: $(basename "$workflow_file")"
    
    # Validate inputs
    if ! validate_workflow_json "$workflow_file"; then
        return 1
    fi
    
    if [ ! -f "$template_file" ]; then
        log ERROR "Template file not found: $template_file"
        return 1
    fi
    
    # Create backup if needed
    if ! backup_workflow_file "$workflow_file" "$backup_mode"; then
        return 1
    fi
    
    # Parse template file (KEY=VALUE format)
    local settings_to_apply=()
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ $key =~ ^[[:space:]]*# ]] && continue
        [[ -z $key ]] && continue
        
        # Remove quotes from value
        value=$(echo "$value" | sed 's/^["'\'']*//;s/["'\'']*$//')
        
        # Validate setting
        if validate_setting "$key" "$value"; then
            settings_to_apply+=("$key=$value")
        else
            log WARN "Skipping invalid setting from template: $key=$value"
        fi
    done < "$template_file"
    
    if [ ${#settings_to_apply[@]} -eq 0 ]; then
        log ERROR "No valid settings found in template file"
        return 1
    fi
    
    if $DRY_RUN; then
        log DRYRUN "Would apply ${#settings_to_apply[@]} settings from template to $workflow_file"
        for setting in "${settings_to_apply[@]}"; do
            log DRYRUN "  - $setting"
        done
        return 0
    fi
    
    # Apply all settings in a single jq operation for atomicity
    local temp_file
    temp_file=$(mktemp)
    
    local jq_filter=".settings"
    for setting in "${settings_to_apply[@]}"; do
        local key="${setting%%=*}"
        local value="${setting#*=}"
        jq_filter="$jq_filter | .${key} = \"${value}\""
    done
    
    if ! jq "$jq_filter" "$workflow_file" > "$temp_file"; then
        log ERROR "Failed to apply settings template"
        rm -f "$temp_file"
        return 1
    fi
    
    # Move temp file to original location
    if ! mv "$temp_file" "$workflow_file"; then
        log ERROR "Failed to save updated workflow file"
        rm -f "$temp_file"
        return 1
    fi
    
    log SUCCESS "Successfully applied ${#settings_to_apply[@]} settings from template"
    return 0
}

reset_workflow_settings() {
    local workflow_file="$1"
    local backup_mode="$2"
    
    log INFO "Resetting workflow settings to defaults: $(basename "$workflow_file")"
    
    # Validate input
    if ! validate_workflow_json "$workflow_file"; then
        return 1
    fi
    
    # Create backup if needed
    if ! backup_workflow_file "$workflow_file" "$backup_mode"; then
        return 1
    fi
    
    if $DRY_RUN; then
        log DRYRUN "Would reset all settings to defaults in $workflow_file"
        return 0
    fi
    
    # Build default settings object
    local default_settings_json="{}"
    for default in "${DEFAULT_SETTINGS[@]}"; do
        local key="${default%%=*}"
        local value="${default#*=}"
        
        # Handle different value types
        if [[ "$value" =~ ^(true|false)$ ]]; then
            default_settings_json=$(echo "$default_settings_json" | jq ".${key} = ${value}")
        elif [[ "$value" =~ ^[0-9]+$ ]]; then
            default_settings_json=$(echo "$default_settings_json" | jq ".${key} = ${value}")
        elif [ -z "$value" ]; then
            default_settings_json=$(echo "$default_settings_json" | jq ".${key} = \"\"")
        else
            default_settings_json=$(echo "$default_settings_json" | jq ".${key} = \"${value}\"")
        fi
    done
    
    local temp_file
    temp_file=$(mktemp)
    
    if ! jq ".settings = $default_settings_json" "$workflow_file" > "$temp_file"; then
        log ERROR "Failed to reset settings to defaults"
        rm -f "$temp_file"
        return 1
    fi
    
    # Move temp file to original location
    if ! mv "$temp_file" "$workflow_file"; then
        log ERROR "Failed to save updated workflow file"
        rm -f "$temp_file"
        return 1
    fi
    
    log SUCCESS "Successfully reset all settings to defaults"
    return 0
}

# --- Tag Management Functions ---
generate_tag_id() {
    local format="$1"
    local custom_pattern="$2"
    
    case "$format" in
        "uuid4")
            if command_exists uuidgen; then
                uuidgen | tr '[:upper:]' '[:lower:]'
            else
                # Fallback UUID generation
                python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || \
                openssl rand -hex 16 | sed 's/\(..\)/\1-/g; s/-$//' | tr '[:upper:]' '[:lower:]'
            fi
            ;;
        "custom")
            if [ -n "$custom_pattern" ]; then
                # Simple custom pattern: replace X with random chars, N with numbers
                echo "$custom_pattern" | sed 's/X/'"$(openssl rand -hex 1 | head -c 1)"'/g; s/N/'"$(shuf -i 0-9 -n 1)"'/g'
            else
                log ERROR "Custom pattern required for custom tag ID format"
                return 1
            fi
            ;;
        "sequential")
            # Simple sequential ID (prefix + timestamp + random)
            echo "tag_$(date +%s)_$(openssl rand -hex 4)"
            ;;
        *)
            log ERROR "Invalid tag ID format: $format"
            return 1
            ;;
    esac
}

list_workflow_tags() {
    local workflow_file="$1"
    
    if ! validate_workflow_json "$workflow_file"; then
        return 1
    fi
    
    local tag_count
    tag_count=$(jq -r '.tags | length' "$workflow_file" 2>/dev/null || echo "0")
    
    if [ "$tag_count" -eq 0 ]; then
        log INFO "No tags found in workflow: $(basename "$workflow_file")"
        return 0
    fi
    
    log INFO "Found $tag_count tag(s) in workflow: $(basename "$workflow_file")"
    jq -r '.tags[] | "  - \(.name) (ID: \(.id))"' "$workflow_file"
}

add_workflow_tag() {
    local workflow_file="$1"
    local tag_name="$2"
    local tag_id_format="$3"
    local backup_mode="$4"
    
    log INFO "Adding tag '$tag_name' to workflow: $(basename "$workflow_file")"
    
    # Validate inputs
    if ! validate_workflow_json "$workflow_file"; then
        return 1
    fi
    
    if [ -z "$tag_name" ]; then
        log ERROR "Tag name cannot be empty"
        return 1
    fi
    
    # Check if tag already exists
    if jq -e ".tags[]? | select(.name == \"$tag_name\")" "$workflow_file" >/dev/null 2>&1; then
        log WARN "Tag '$tag_name' already exists in workflow"
        return 1
    fi
    
    # Generate tag ID
    local tag_id
    tag_id=$(generate_tag_id "$tag_id_format" "")
    if [ $? -ne 0 ]; then
        log ERROR "Failed to generate tag ID"
        return 1
    fi
    
    # Create backup if needed
    if ! backup_workflow_file "$workflow_file" "$backup_mode"; then
        return 1
    fi
    
    if $DRY_RUN; then
        log DRYRUN "Would add tag '$tag_name' with ID '$tag_id' to $workflow_file"
        return 0
    fi
    
    # Create new tag object
    local current_time=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    local new_tag=$(jq -n \
        --arg id "$tag_id" \
        --arg name "$tag_name" \
        --arg time "$current_time" \
        '{
            id: $id,
            name: $name,
            createdAt: $time,
            updatedAt: $time
        }')
    
    local temp_file
    temp_file=$(mktemp)
    
    # Add tag to workflow
    if ! jq ".tags += [$new_tag]" "$workflow_file" > "$temp_file"; then
        log ERROR "Failed to add tag to workflow file"
        rm -f "$temp_file"
        return 1
    fi
    
    # Move temp file to original location
    if ! mv "$temp_file" "$workflow_file"; then
        log ERROR "Failed to save updated workflow file"
        rm -f "$temp_file"
        return 1
    fi
    
    log SUCCESS "Successfully added tag '$tag_name' with ID '$tag_id'"
    return 0
}

remove_workflow_tag() {
    local workflow_file="$1"
    local tag_identifier="$2"  # name or ID
    local backup_mode="$3"
    
    log INFO "Removing tag '$tag_identifier' from workflow: $(basename "$workflow_file")"
    
    # Validate inputs
    if ! validate_workflow_json "$workflow_file"; then
        return 1
    fi
    
    if [ -z "$tag_identifier" ]; then
        log ERROR "Tag identifier cannot be empty"
        return 1
    fi
    
    # Check if tag exists (by name or ID)
    local tag_exists=false
    if jq -e ".tags[]? | select(.name == \"$tag_identifier\" or .id == \"$tag_identifier\")" "$workflow_file" >/dev/null 2>&1; then
        tag_exists=true
    fi
    
    if [ "$tag_exists" = "false" ]; then
        log WARN "Tag '$tag_identifier' not found in workflow"
        return 1
    fi
    
    # Create backup if needed
    if ! backup_workflow_file "$workflow_file" "$backup_mode"; then
        return 1
    fi
    
    if $DRY_RUN; then
        log DRYRUN "Would remove tag '$tag_identifier' from $workflow_file"
        return 0
    fi
    
    local temp_file
    temp_file=$(mktemp)
    
    # Remove tag from workflow
    if ! jq ".tags = (.tags | map(select(.name != \"$tag_identifier\" and .id != \"$tag_identifier\")))" "$workflow_file" > "$temp_file"; then
        log ERROR "Failed to remove tag from workflow file"
        rm -f "$temp_file"
        return 1
    fi
    
    # Move temp file to original location
    if ! mv "$temp_file" "$workflow_file"; then
        log ERROR "Failed to save updated workflow file"
        rm -f "$temp_file"
        return 1
    fi
    
    log SUCCESS "Successfully removed tag '$tag_identifier'"
    return 0
}

regenerate_tag_ids() {
    local workflow_file="$1"
    local tag_id_format="$2"
    local backup_mode="$3"
    
    log INFO "Regenerating tag IDs in workflow: $(basename "$workflow_file")"
    
    # Validate inputs
    if ! validate_workflow_json "$workflow_file"; then
        return 1
    fi
    
    local tag_count
    tag_count=$(jq -r '.tags | length' "$workflow_file" 2>/dev/null || echo "0")
    
    if [ "$tag_count" -eq 0 ]; then
        log INFO "No tags found to regenerate IDs"
        return 0
    fi
    
    # Create backup if needed
    if ! backup_workflow_file "$workflow_file" "$backup_mode"; then
        return 1
    fi
    
    if $DRY_RUN; then
        log DRYRUN "Would regenerate IDs for $tag_count tag(s) in $workflow_file"
        return 0
    fi
    
    local temp_file
    temp_file=$(mktemp)
    
    # Process each tag and generate new ID
    local current_time=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    jq --arg time "$current_time" '
        .tags = (.tags | map(
            . + {
                id: "'"$(generate_tag_id "$tag_id_format" "")"'",
                updatedAt: $time
            }
        ))
    ' "$workflow_file" > "$temp_file"
    
    if [ $? -ne 0 ]; then
        log ERROR "Failed to regenerate tag IDs"
        rm -f "$temp_file"
        return 1
    fi
    
    # Move temp file to original location
    if ! mv "$temp_file" "$workflow_file"; then
        log ERROR "Failed to save updated workflow file"
        rm -f "$temp_file"
        return 1
    fi
    
    log SUCCESS "Successfully regenerated IDs for $tag_count tag(s)"
    return 0
}

# --- Workflow ID Management Functions ---
view_workflow_ids() {
    local workflow_file="$1"
    
    if ! validate_workflow_json "$workflow_file"; then
        return 1
    fi
    
    local workflow_name
    local workflow_id
    local version_id
    
    workflow_name=$(jq -r '.name // "N/A"' "$workflow_file")
    workflow_id=$(jq -r '.id // "N/A"' "$workflow_file")
    version_id=$(jq -r '.versionId // "N/A"' "$workflow_file")
    
    log INFO "Workflow IDs for: $workflow_name"
    echo "  Workflow ID: $workflow_id"
    echo "  Version ID:  $version_id"
}

set_workflow_id() {
    local workflow_file="$1"
    local new_id="$2"
    local backup_mode="$3"
    
    log INFO "Setting workflow ID in: $(basename "$workflow_file")"
    
    # Validate inputs
    if ! validate_workflow_json "$workflow_file"; then
        return 1
    fi
    
    if [ -z "$new_id" ]; then
        log ERROR "Workflow ID cannot be empty"
        return 1
    fi
    
    # Validate ID format (alphanumeric)
    if [[ ! "$new_id" =~ ^[a-zA-Z0-9]+$ ]]; then
        log ERROR "Invalid workflow ID format. Use alphanumeric characters only."
        return 1
    fi
    
    # Create backup if needed
    if ! backup_workflow_file "$workflow_file" "$backup_mode"; then
        return 1
    fi
    
    if $DRY_RUN; then
        log DRYRUN "Would set workflow ID to '$new_id' in $workflow_file"
        return 0
    fi
    
    local temp_file
    temp_file=$(mktemp)
    
    if ! jq ".id = \"$new_id\"" "$workflow_file" > "$temp_file"; then
        log ERROR "Failed to set workflow ID"
        rm -f "$temp_file"
        return 1
    fi
    
    # Move temp file to original location
    if ! mv "$temp_file" "$workflow_file"; then
        log ERROR "Failed to save updated workflow file"
        rm -f "$temp_file"
        return 1
    fi
    
    log SUCCESS "Successfully set workflow ID to '$new_id'"
    return 0
}

set_version_id() {
    local workflow_file="$1"
    local new_version_id="$2"
    local backup_mode="$3"
    
    log INFO "Setting version ID in: $(basename "$workflow_file")"
    
    # Validate inputs
    if ! validate_workflow_json "$workflow_file"; then
        return 1
    fi
    
    if [ -z "$new_version_id" ]; then
        log ERROR "Version ID cannot be empty"
        return 1
    fi
    
    # Create backup if needed
    if ! backup_workflow_file "$workflow_file" "$backup_mode"; then
        return 1
    fi
    
    if $DRY_RUN; then
        log DRYRUN "Would set version ID to '$new_version_id' in $workflow_file"
        return 0
    fi
    
    local temp_file
    temp_file=$(mktemp)
    
    if ! jq ".versionId = \"$new_version_id\"" "$workflow_file" > "$temp_file"; then
        log ERROR "Failed to set version ID"
        rm -f "$temp_file"
        return 1
    fi
    
    # Move temp file to original location
    if ! mv "$temp_file" "$workflow_file"; then
        log ERROR "Failed to save updated workflow file"
        rm -f "$temp_file"
        return 1
    fi
    
    log SUCCESS "Successfully set version ID to '$new_version_id'"
    return 0
}

regenerate_workflow_ids() {
    local workflow_file="$1"
    local backup_mode="$2"
    
    log INFO "Regenerating workflow IDs in: $(basename "$workflow_file")"
    
    # Validate inputs
    if ! validate_workflow_json "$workflow_file"; then
        return 1
    fi
    
    # Generate new IDs
    local new_workflow_id
    local new_version_id
    
    new_workflow_id=$(generate_tag_id "uuid4" "" | sed 's/-//g' | head -c 16)
    new_version_id=$(generate_tag_id "uuid4" "")
    
    # Create backup if needed
    if ! backup_workflow_file "$workflow_file" "$backup_mode"; then
        return 1
    fi
    
    if $DRY_RUN; then
        log DRYRUN "Would regenerate workflow ID to '$new_workflow_id' and version ID to '$new_version_id'"
        return 0
    fi
    
    local temp_file
    temp_file=$(mktemp)
    
    if ! jq ".id = \"$new_workflow_id\" | .versionId = \"$new_version_id\"" "$workflow_file" > "$temp_file"; then
        log ERROR "Failed to regenerate workflow IDs"
        rm -f "$temp_file"
        return 1
    fi
    
    # Move temp file to original location
    if ! mv "$temp_file" "$workflow_file"; then
        log ERROR "Failed to save updated workflow file"
        rm -f "$temp_file"
        return 1
    fi
    
    log SUCCESS "Successfully regenerated workflow ID to '$new_workflow_id' and version ID to '$new_version_id'"
    return 0
}

# --- Cleanup Operations Functions ---
cleanup_workflow_data() {
    local workflow_file="$1"
    local cleanup_targets="$2"  # comma-separated
    local backup_mode="$3"
    
    log INFO "Performing cleanup operations on: $(basename "$workflow_file")"
    
    # Validate inputs
    if ! validate_workflow_json "$workflow_file"; then
        return 1
    fi
    
    if [ -z "$cleanup_targets" ]; then
        log ERROR "No cleanup targets specified"
        return 1
    fi
    
    # Parse cleanup targets
    IFS=',' read -ra targets <<< "$cleanup_targets"
    
    # Validate targets
    local valid_targets=("tags" "settings" "pindata" "meta" "version" "all")
    for target in "${targets[@]}"; do
        local valid=false
        for valid_target in "${valid_targets[@]}"; do
            if [ "$target" = "$valid_target" ]; then
                valid=true
                break
            fi
        done
        if [ "$valid" = "false" ]; then
            log ERROR "Invalid cleanup target: $target"
            log ERROR "Valid targets: ${valid_targets[*]}"
            return 1
        fi
    done
    
    # Create backup if needed
    if ! backup_workflow_file "$workflow_file" "$backup_mode"; then
        return 1
    fi
    
    if $DRY_RUN; then
        log DRYRUN "Would perform cleanup operations: $cleanup_targets"
        return 0
    fi
    
    local temp_file
    temp_file=$(mktemp)
    local jq_operations=()
    
    # Build jq operations based on targets
    for target in "${targets[@]}"; do
        case "$target" in
            "tags")
                jq_operations+=("del(.tags)")
                log INFO "  - Clearing tags"
                ;;
            "settings")
                # Reset to default settings
                local default_settings_json="{}"
                for default in "${DEFAULT_SETTINGS[@]}"; do
                    local key="${default%%=*}"
                    local value="${default#*=}"
                    
                    if [[ "$value" =~ ^(true|false)$ ]]; then
                        default_settings_json=$(echo "$default_settings_json" | jq ".${key} = ${value}")
                    elif [[ "$value" =~ ^[0-9]+$ ]]; then
                        default_settings_json=$(echo "$default_settings_json" | jq ".${key} = ${value}")
                    elif [ -z "$value" ]; then
                        default_settings_json=$(echo "$default_settings_json" | jq ".${key} = \"\"")
                    else
                        default_settings_json=$(echo "$default_settings_json" | jq ".${key} = \"${value}\"")
                    fi
                done
                jq_operations+=(".settings = $default_settings_json")
                log INFO "  - Resetting settings to defaults"
                ;;
            "pindata")
                jq_operations+=("del(.pinData)")
                log INFO "  - Clearing pin data"
                ;;
            "meta")
                jq_operations+=("del(.meta)")
                log INFO "  - Clearing metadata"
                ;;
            "version")
                jq_operations+=("del(.versionId)")
                log INFO "  - Clearing version ID"
                ;;
            "all")
                jq_operations=(
                    "del(.tags)"
                    "del(.pinData)"
                    "del(.meta)"
                    "del(.versionId)"
                    ".settings = {}"
                )
                log INFO "  - Clearing all non-essential data"
                break
                ;;
        esac
    done
    
    # Execute all operations in a single jq command
    local jq_filter="."
    for operation in "${jq_operations[@]}"; do
        jq_filter="$jq_filter | $operation"
    done
    
    if ! jq "$jq_filter" "$workflow_file" > "$temp_file"; then
        log ERROR "Failed to perform cleanup operations"
        rm -f "$temp_file"
        return 1
    fi
    
    # Move temp file to original location
    if ! mv "$temp_file" "$workflow_file"; then
        log ERROR "Failed to save updated workflow file"
        rm -f "$temp_file"
        return 1
    fi
    
    log SUCCESS "Successfully completed cleanup operations: $cleanup_targets"
    return 0
}

# --- Batch Processing Functions ---
find_workflow_files() {
    local directory="$1"
    local recursive="$2"  # true/false
    
    if [ ! -d "$directory" ]; then
        log ERROR "Directory not found: $directory"
        return 1
    fi
    
    local find_cmd="find"
    local depth_args=""
    
    if [ "$recursive" = "false" ]; then
        depth_args="-maxdepth 1"
    fi
    
    find "$directory" $depth_args -name "*.json" -type f | sort
}

process_workflow_directory() {
    local directory="$1"
    local operation="$2"
    local operation_params="$3"
    local error_handling="$4"  # ask, continue, stop
    
    log HEADER "Processing workflow directory: $directory"
    
    if [ ! -d "$directory" ]; then
        log ERROR "Directory not found: $directory"
        return 1
    fi
    
    # Find workflow files (non-recursive by default)
    local workflow_files
    workflow_files=$(find_workflow_files "$directory" "false")
    
    if [ -z "$workflow_files" ]; then
        log INFO "No JSON files found in directory: $directory"
        return 0
    fi
    
    local file_count
    file_count=$(echo "$workflow_files" | wc -l)
    log INFO "Found $file_count JSON file(s) to process"
    
    # Process each file
    local processed=0
    local errors=0
    local skipped=0
    
    while IFS= read -r workflow_file; do
        [ -z "$workflow_file" ] && continue
        
        log INFO "Processing file $((processed + 1))/$file_count: $(basename "$workflow_file")"
        
        # Validate it's a workflow file
        if ! validate_workflow_json "$workflow_file"; then
            log WARN "Skipping invalid workflow file: $(basename "$workflow_file")"
            ((skipped++))
            continue
        fi
        
        # Perform the requested operation
        local operation_result=0
        case "$operation" in
            "edit-setting")
                local setting_key=$(echo "$operation_params" | cut -d'=' -f1)
                local setting_value=$(echo "$operation_params" | cut -d'=' -f2-)
                edit_workflow_setting "$workflow_file" "$setting_key" "$setting_value" "$BACKUP_MODE"
                operation_result=$?
                ;;
            "apply-template")
                apply_settings_template "$workflow_file" "$operation_params" "$BACKUP_MODE"
                operation_result=$?
                ;;
            "reset-settings")
                reset_workflow_settings "$workflow_file" "$BACKUP_MODE"
                operation_result=$?
                ;;
            "add-tag")
                add_workflow_tag "$workflow_file" "$operation_params" "$ARG_TAG_ID_FORMAT" "$BACKUP_MODE"
                operation_result=$?
                ;;
            "remove-tag")
                remove_workflow_tag "$workflow_file" "$operation_params" "$BACKUP_MODE"
                operation_result=$?
                ;;
            "regenerate-tag-ids")
                regenerate_tag_ids "$workflow_file" "$ARG_TAG_ID_FORMAT" "$BACKUP_MODE"
                operation_result=$?
                ;;
            "regenerate-workflow-ids")
                regenerate_workflow_ids "$workflow_file" "$BACKUP_MODE"
                operation_result=$?
                ;;
            "cleanup")
                cleanup_workflow_data "$workflow_file" "$operation_params" "$BACKUP_MODE"
                operation_result=$?
                ;;
            *)
                log ERROR "Unknown operation: $operation"
                operation_result=1
                ;;
        esac
        
        if [ $operation_result -eq 0 ]; then
            ((processed++))
        else
            ((errors++))
            log ERROR "Operation failed for file: $(basename "$workflow_file")"
            
            # Handle errors based on error_handling mode
            case "$error_handling" in
                "ask")
                    if [ "$INTERACTIVE_MODE" = "true" ] && [ "$BATCH_MODE" = "false" ]; then
                        echo -n "Continue processing remaining files? [y/N]: "
                        read -r response
                        if [[ ! "$response" =~ ^[Yy]$ ]]; then
                            log INFO "Stopping batch processing at user request"
                            break
                        fi
                    else
                        log INFO "Continuing with next file (batch mode)"
                    fi
                    ;;
                "stop")
                    log ERROR "Stopping batch processing due to error"
                    break
                    ;;
                "continue")
                    log INFO "Continuing with next file"
                    ;;
            esac
        fi
    done <<< "$workflow_files"
    
    # Print summary
    log HEADER "Batch Processing Summary"
    log INFO "Total files found: $file_count"
    log INFO "Successfully processed: $processed"
    log INFO "Errors encountered: $errors"
    log INFO "Files skipped: $skipped"
    
    if [ $errors -gt 0 ]; then
        return 1
    else
        return 0
    fi
}

# --- CLI Argument Parsing ---
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --action)
                ARG_ACTION="$2"
                shift 2
                ;;
            --target)
                ARG_TARGET="$2"
                shift 2
                ;;
            --backup-mode)
                ARG_BACKUP_MODE="$2"
                shift 2
                ;;
            --dry-run)
                ARG_DRY_RUN=true
                shift
                ;;
            --interactive)
                ARG_INTERACTIVE=true
                shift
                ;;
            --batch)
                ARG_BATCH=true
                shift
                ;;
            --setting)
                ARG_SETTING_PAIRS+=("$2")
                shift 2
                ;;
            --settings-template)
                ARG_SETTINGS_TEMPLATE="$2"
                shift 2
                ;;
            --reset-settings)
                ARG_RESET_SETTINGS=true
                shift
                ;;
            --add-tag)
                ARG_ADD_TAGS+=("$2")
                shift 2
                ;;
            --remove-tag)
                ARG_REMOVE_TAGS+=("$2")
                shift 2
                ;;
            --tag-id-format)
                ARG_TAG_ID_FORMAT="$2"
                shift 2
                ;;
            --regenerate-tag-ids)
                ARG_REGENERATE_TAG_IDS=true
                shift
                ;;
            --set-workflow-id)
                ARG_SET_WORKFLOW_ID="$2"
                shift 2
                ;;
            --regenerate-workflow-id)
                ARG_REGENERATE_WORKFLOW_ID=true
                shift
                ;;
            --set-version-id)
                ARG_SET_VERSION_ID="$2"
                shift 2
                ;;
            --regenerate-version-id)
                ARG_REGENERATE_VERSION_ID=true
                shift
                ;;
            --clear-tags|--clear-settings|--clear-pindata|--clear-meta|--clear-version|--clear-all)
                local clear_type="${1#--clear-}"
                if [ -n "$ARG_CLEAR_TARGETS" ]; then
                    ARG_CLEAR_TARGETS="$ARG_CLEAR_TARGETS,$clear_type"
                else
                    ARG_CLEAR_TARGETS="$clear_type"
                fi
                shift
                ;;
            --config)
                ARG_CONFIG_FILE="$2"
                shift 2
                ;;
            --verbose)
                ARG_VERBOSE=true
                shift
                ;;
            --log-file)
                ARG_LOG_FILE="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                log ERROR "Unknown option: $1"
                echo "Use --help for usage information."
                exit 1
                ;;
            *)
                # Positional argument
                if [ -z "$ARG_TARGET" ]; then
                    ARG_TARGET="$1"
                fi
                shift
                ;;
        esac
    done
}

# --- Help Function ---
show_help() {
    cat << 'EOF'
n8n Workflows Bulk Editor v1.0.0
=================================

USAGE:
    n8n-workflows-bulk-editor.sh [OPTIONS] [ACTION] [TARGET]

DESCRIPTION:
    Bulk editor for n8n workflow settings, tags, IDs, and cleanup operations.
    Part of the n8n-data-manager project with full integration support.

ACTIONS:
    edit-settings         Edit workflow settings
    manage-tags          Manage workflow tags
    manage-ids           Manage workflow and version IDs  
    cleanup              Cleanup workflow data
    interactive          Launch interactive menu (default)

OPTIONS:
    Target Selection:
    --target <path>             Single file or directory path
    
    Backup Options:
    --backup-mode <mode>        auto (default), manual, none
    --dry-run                   Preview changes without execution
    
    Execution Modes:
    --interactive               Force interactive mode
    --batch                     Force non-interactive mode
    
    Settings Management:
    --setting <key=value>       Set specific setting (repeatable)
    --settings-template <file>  Apply settings template file
    --reset-settings            Reset to defaults
    
    Tag Management:
    --add-tag <name>            Add tag (generates UUID)
    --remove-tag <name|id>      Remove tag by name or ID
    --tag-id-format <format>    uuid4 (default), custom, sequential
    --regenerate-tag-ids        Generate new IDs for all tags
    
    ID Management:
    --set-workflow-id <id>      Set specific workflow ID
    --regenerate-workflow-id    Generate new workflow ID
    --set-version-id <id>       Set specific version ID
    --regenerate-version-id     Generate new version ID
    
    Cleanup Operations:
    --clear-tags                Remove all tags
    --clear-settings            Reset all settings
    --clear-pindata             Remove pin data
    --clear-meta                Remove metadata
    --clear-version             Remove version ID
    --clear-all                 Clear everything except core workflow
    
    General Options:
    --config <path>             Custom config file
    --verbose                   Detailed output
    --log-file <path>           Log to file
    -h, --help                  Show this help

EXAMPLES:
    # Interactive mode (default)
    n8n-workflows-bulk-editor.sh
    
    # Edit single workflow setting
    n8n-workflows-bulk-editor.sh --target workflow.json --setting "executionTimeout=120"
    
    # Apply settings template to directory
    n8n-workflows-bulk-editor.sh --target /workflows --settings-template template.conf
    
    # Add tag to all workflows in directory
    n8n-workflows-bulk-editor.sh --target /workflows --add-tag "Production"
    
    # Cleanup operations with backup
    n8n-workflows-bulk-editor.sh --target workflow.json --clear-tags --clear-pindata
    
    # Dry run batch operation
    n8n-workflows-bulk-editor.sh --target /workflows --clear-all --dry-run

INTEGRATION:
    This script integrates with n8n-manager.sh:
    - Shared configuration file: ~/.config/n8n-manager/config
    - Compatible backup format for direct restore
    - Cross-project parameter passing support

For more information: https://github.com/n8n-community/n8n-data-manager
EOF
}

# --- Interactive Menu System ---
show_interactive_menu() {
    while true; do
        clear
        echo -e "${CYAN}"
        echo "═══════════════════════════════════════════════════════════════"
        echo "                n8n Workflows Bulk Editor v1.0.0              "
        echo "═══════════════════════════════════════════════════════════════"
        echo -e "${NC}"
        echo
        echo "Choose an action:"
        echo -e "  ${GREEN}1)${NC} Edit Workflow Settings"
        echo -e "  ${GREEN}2)${NC} Manage Tags"
        echo -e "  ${GREEN}3)${NC} Manage Workflow/Version IDs"
        echo -e "  ${GREEN}4)${NC} Cleanup Operations"
        echo -e "  ${GREEN}5)${NC} Batch Processing"
        echo -e "  ${GREEN}6)${NC} Configuration"
        echo -e "  ${GREEN}7)${NC} Help & Documentation"
        echo -e "  ${GREEN}8)${NC} Exit"
        echo
        read -p "Enter your choice [1-8]: " choice
        
        case $choice in
            1) interactive_settings_menu ;;
            2) interactive_tags_menu ;;
            3) interactive_ids_menu ;;
            4) interactive_cleanup_menu ;;
            5) interactive_batch_menu ;;
            6) interactive_config_menu ;;
            7) show_help; read -p "Press Enter to continue..." ;;
            8) log SUCCESS "Goodbye!"; exit 0 ;;
            *) echo -e "${RED}Invalid choice. Please try again.${NC}"; sleep 1 ;;
        esac
    done
}

interactive_settings_menu() {
    while true; do
        clear
        echo -e "${CYAN}Settings Management${NC}"
        echo "═════════════════════"
        echo
        echo "1) Edit single setting"
        echo "2) Apply settings template"
        echo "3) Reset settings to defaults"
        echo "4) Back to main menu"
        echo
        read -p "Choice [1-4]: " choice
        
        case $choice in
            1)
                read -p "Workflow file path: " file_path
                read -p "Setting key: " key
                read -p "Setting value: " value
                if validate_workflow_file "$file_path"; then
                    edit_workflow_setting "$file_path" "$key" "$value"
                fi
                read -p "Press Enter to continue..."
                ;;
            2)
                read -p "Workflow file/directory path: " target_path
                read -p "Settings template file: " template_file
                if [ -f "$template_file" ]; then
                    if [ -d "$target_path" ]; then
                        process_directory "$target_path" "apply_settings_template" "$template_file"
                    else
                        apply_settings_template "$target_path" "$template_file"
                    fi
                else
                    log ERROR "Template file not found: $template_file"
                fi
                read -p "Press Enter to continue..."
                ;;
            3)
                read -p "Workflow file/directory path: " target_path
                if [ -d "$target_path" ]; then
                    process_directory "$target_path" "reset_workflow_settings"
                else
                    reset_workflow_settings "$target_path"
                fi
                read -p "Press Enter to continue..."
                ;;
            4) return ;;
            *) echo "Invalid choice"; sleep 1 ;;
        esac
    done
}

interactive_tags_menu() {
    while true; do
        clear
        echo -e "${CYAN}Tag Management${NC}"
        echo "════════════════"
        echo
        echo "1) List current tags"
        echo "2) Add new tag"
        echo "3) Remove tag"
        echo "4) Regenerate tag IDs"
        echo "5) Back to main menu"
        echo
        read -p "Choice [1-5]: " choice
        
        case $choice in
            1)
                read -p "Workflow file path: " file_path
                if validate_workflow_file "$file_path"; then
                    list_workflow_tags "$file_path"
                fi
                read -p "Press Enter to continue..."
                ;;
            2)
                read -p "Workflow file/directory path: " target_path
                read -p "Tag name: " tag_name
                echo "ID format options: uuid4, custom, sequential"
                read -p "ID format [uuid4]: " id_format
                id_format=${id_format:-uuid4}
                if [ -d "$target_path" ]; then
                    process_directory "$target_path" "add_workflow_tag" "$tag_name" "$id_format"
                else
                    add_workflow_tag "$target_path" "$tag_name" "$id_format"
                fi
                read -p "Press Enter to continue..."
                ;;
            3)
                read -p "Workflow file/directory path: " target_path
                read -p "Tag name or ID to remove: " tag_identifier
                if [ -d "$target_path" ]; then
                    process_directory "$target_path" "remove_workflow_tag" "$tag_identifier"
                else
                    remove_workflow_tag "$target_path" "$tag_identifier"
                fi
                read -p "Press Enter to continue..."
                ;;
            4)
                read -p "Workflow file/directory path: " target_path
                echo "ID format options: uuid4, custom, sequential"
                read -p "New ID format [uuid4]: " id_format
                id_format=${id_format:-uuid4}
                if [ -d "$target_path" ]; then
                    process_directory "$target_path" "regenerate_tag_ids" "$id_format"
                else
                    regenerate_tag_ids "$target_path" "$id_format"
                fi
                read -p "Press Enter to continue..."
                ;;
            5) return ;;
            *) echo "Invalid choice"; sleep 1 ;;
        esac
    done
}

interactive_ids_menu() {
    while true; do
        clear
        echo -e "${CYAN}ID Management${NC}"
        echo "═══════════════"
        echo
        echo "1) View current IDs"
        echo "2) Set workflow ID"
        echo "3) Regenerate workflow ID"
        echo "4) Set version ID"
        echo "5) Regenerate version ID"
        echo "6) Back to main menu"
        echo
        read -p "Choice [1-6]: " choice
        
        case $choice in
            1)
                read -p "Workflow file path: " file_path
                if validate_workflow_file "$file_path"; then
                    view_workflow_ids "$file_path"
                fi
                read -p "Press Enter to continue..."
                ;;
            2)
                read -p "Workflow file/directory path: " target_path
                read -p "New workflow ID: " workflow_id
                if [ -d "$target_path" ]; then
                    process_directory "$target_path" "set_workflow_id" "$workflow_id"
                else
                    set_workflow_id "$target_path" "$workflow_id"
                fi
                read -p "Press Enter to continue..."
                ;;
            3)
                read -p "Workflow file/directory path: " target_path
                if [ -d "$target_path" ]; then
                    process_directory "$target_path" "regenerate_workflow_id"
                else
                    regenerate_workflow_id "$target_path"
                fi
                read -p "Press Enter to continue..."
                ;;
            4)
                read -p "Workflow file/directory path: " target_path
                read -p "New version ID: " version_id
                if [ -d "$target_path" ]; then
                    process_directory "$target_path" "set_version_id" "$version_id"
                else
                    set_version_id "$target_path" "$version_id"
                fi
                read -p "Press Enter to continue..."
                ;;
            5)
                read -p "Workflow file/directory path: " target_path
                if [ -d "$target_path" ]; then
                    process_directory "$target_path" "regenerate_version_id"
                else
                    regenerate_version_id "$target_path"
                fi
                read -p "Press Enter to continue..."
                ;;
            6) return ;;
            *) echo "Invalid choice"; sleep 1 ;;
        esac
    done
}

interactive_cleanup_menu() {
    while true; do
        clear
        echo -e "${CYAN}Cleanup Operations${NC}"
        echo "════════════════════"
        echo
        echo "1) Clear tags"
        echo "2) Clear settings"
        echo "3) Clear pin data"
        echo "4) Clear metadata"
        echo "5) Clear version ID"
        echo "6) Clear all (dangerous)"
        echo "7) Back to main menu"
        echo
        read -p "Choice [1-7]: " choice
        
        case $choice in
            1-6)
                read -p "Workflow file/directory path: " target_path
                local clear_targets=""
                case $choice in
                    1) clear_targets="tags" ;;
                    2) clear_targets="settings" ;;
                    3) clear_targets="pindata" ;;
                    4) clear_targets="meta" ;;
                    5) clear_targets="version" ;;
                    6) 
                        echo -e "${RED}WARNING: This will clear ALL data except core workflow structure!${NC}"
                        read -p "Are you sure? [y/N]: " confirm
                        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                            continue
                        fi
                        clear_targets="all"
                        ;;
                esac
                
                if [ -d "$target_path" ]; then
                    process_directory "$target_path" "cleanup_workflow" "$clear_targets"
                else
                    cleanup_workflow "$target_path" "$clear_targets"
                fi
                read -p "Press Enter to continue..."
                ;;
            7) return ;;
            *) echo "Invalid choice"; sleep 1 ;;
        esac
    done
}

interactive_batch_menu() {
    while true; do
        clear
        echo -e "${CYAN}Batch Processing${NC}"
        echo "═══════════════════"
        echo
        echo "Current settings:"
        echo "  Error handling: ${CONF_BATCH_ERROR_MODE:-ask}"
        echo "  Dry run: ${ARG_DRY_RUN:-false}"
        echo "  Backup mode: ${ARG_BACKUP_MODE:-auto}"
        echo
        echo "1) Process directory with current settings"
        echo "2) Change error handling mode"
        echo "3) Toggle dry run mode"
        echo "4) Change backup mode"
        echo "5) Back to main menu"
        echo
        read -p "Choice [1-5]: " choice
        
        case $choice in
            1)
                read -p "Directory path: " dir_path
                read -p "Operation (settings/tags/ids/cleanup): " operation
                if [ -d "$dir_path" ]; then
                    case $operation in
                        settings)
                            read -p "Settings template file: " template
                            process_directory "$dir_path" "apply_settings_template" "$template"
                            ;;
                        tags)
                            read -p "Tag operation (add/remove/regenerate): " tag_op
                            case $tag_op in
                                add)
                                    read -p "Tag name: " tag_name
                                    process_directory "$dir_path" "add_workflow_tag" "$tag_name"
                                    ;;
                                remove)
                                    read -p "Tag to remove: " tag_name
                                    process_directory "$dir_path" "remove_workflow_tag" "$tag_name"
                                    ;;
                                regenerate)
                                    process_directory "$dir_path" "regenerate_tag_ids"
                                    ;;
                            esac
                            ;;
                        ids)
                            read -p "ID operation (workflow/version): " id_op
                            case $id_op in
                                workflow)
                                    process_directory "$dir_path" "regenerate_workflow_id"
                                    ;;
                                version)
                                    process_directory "$dir_path" "regenerate_version_id"
                                    ;;
                            esac
                            ;;
                        cleanup)
                            read -p "Clear targets (tags/settings/pindata/meta/version/all): " targets
                            process_directory "$dir_path" "cleanup_workflow" "$targets"
                            ;;
                    esac
                else
                    log ERROR "Directory not found: $dir_path"
                fi
                read -p "Press Enter to continue..."
                ;;
            2)
                echo "Error handling modes:"
                echo "  ask - Ask user on each error (default)"
                echo "  continue - Continue processing on errors"
                echo "  stop - Stop on first error"
                read -p "New mode [ask]: " mode
                CONF_BATCH_ERROR_MODE=${mode:-ask}
                ;;
            3)
                if [ "$ARG_DRY_RUN" = "true" ]; then
                    ARG_DRY_RUN=false
                    echo "Dry run mode disabled"
                else
                    ARG_DRY_RUN=true
                    echo "Dry run mode enabled"
                fi
                sleep 1
                ;;
            4)
                echo "Backup modes:"
                echo "  auto - Automatic timestamped backups"
                echo "  manual - Ask before each backup"
                echo "  none - No backups (dangerous)"
                read -p "New mode [auto]: " mode
                ARG_BACKUP_MODE=${mode:-auto}
                ;;
            5) return ;;
            *) echo "Invalid choice"; sleep 1 ;;
        esac
    done
}

interactive_config_menu() {
    clear
    echo -e "${CYAN}Configuration${NC}"
    echo "═══════════════"
    echo
    echo "Current configuration:"
    echo "  Config file: ${CONF_CONFIG_FILE}"
    echo "  Backup directory: ${CONF_BACKUP_DIR}"
    echo "  Verbose mode: ${ARG_VERBOSE:-false}"
    echo "  Log file: ${ARG_LOG_FILE:-none}"
    echo
    read -p "Press Enter to continue..."
}

# --- Main Execution Logic ---
execute_cli_action() {
    local action="$1"
    local target="$2"
    
    # Validate target
    if [ -z "$target" ]; then
        log ERROR "No target specified. Use --target or provide as positional argument."
        exit 1
    fi
    
    if [ ! -e "$target" ]; then
        log ERROR "Target does not exist: $target"
        exit 1
    fi
    
    # Execute based on action and arguments
    case "$action" in
        edit-settings)
            if [ -n "$ARG_SETTINGS_TEMPLATE" ]; then
                if [ -d "$target" ]; then
                    process_directory "$target" "apply_settings_template" "$ARG_SETTINGS_TEMPLATE"
                else
                    apply_settings_template "$target" "$ARG_SETTINGS_TEMPLATE"
                fi
            elif [ -n "$ARG_RESET_SETTINGS" ]; then
                if [ -d "$target" ]; then
                    process_directory "$target" "reset_workflow_settings"
                else
                    reset_workflow_settings "$target"
                fi
            elif [ ${#ARG_SETTING_PAIRS[@]} -gt 0 ]; then
                for setting_pair in "${ARG_SETTING_PAIRS[@]}"; do
                    if [[ "$setting_pair" =~ ^([^=]+)=(.*)$ ]]; then
                        local key="${BASH_REMATCH[1]}"
                        local value="${BASH_REMATCH[2]}"
                        if [ -d "$target" ]; then
                            process_directory "$target" "edit_workflow_setting" "$key" "$value"
                        else
                            edit_workflow_setting "$target" "$key" "$value"
                        fi
                    else
                        log ERROR "Invalid setting format: $setting_pair (expected key=value)"
                        exit 1
                    fi
                done
            else
                log ERROR "No settings operation specified. Use --setting, --settings-template, or --reset-settings."
                exit 1
            fi
            ;;
        manage-tags)
            if [ ${#ARG_ADD_TAGS[@]} -gt 0 ]; then
                for tag_name in "${ARG_ADD_TAGS[@]}"; do
                    local id_format="${ARG_TAG_ID_FORMAT:-uuid4}"
                    if [ -d "$target" ]; then
                        process_directory "$target" "add_workflow_tag" "$tag_name" "$id_format"
                    else
                        add_workflow_tag "$target" "$tag_name" "$id_format"
                    fi
                done
            elif [ ${#ARG_REMOVE_TAGS[@]} -gt 0 ]; then
                for tag_identifier in "${ARG_REMOVE_TAGS[@]}"; do
                    if [ -d "$target" ]; then
                        process_directory "$target" "remove_workflow_tag" "$tag_identifier"
                    else
                        remove_workflow_tag "$target" "$tag_identifier"
                    fi
                done
            elif [ -n "$ARG_REGENERATE_TAG_IDS" ]; then
                local id_format="${ARG_TAG_ID_FORMAT:-uuid4}"
                if [ -d "$target" ]; then
                    process_directory "$target" "regenerate_tag_ids" "$id_format"
                else
                    regenerate_tag_ids "$target" "$id_format"
                fi
            else
                log ERROR "No tag operation specified. Use --add-tag, --remove-tag, or --regenerate-tag-ids."
                exit 1
            fi
            ;;
        manage-ids)
            if [ -n "$ARG_SET_WORKFLOW_ID" ]; then
                if [ -d "$target" ]; then
                    process_directory "$target" "set_workflow_id" "$ARG_SET_WORKFLOW_ID"
                else
                    set_workflow_id "$target" "$ARG_SET_WORKFLOW_ID"
                fi
            elif [ -n "$ARG_REGENERATE_WORKFLOW_ID" ]; then
                if [ -d "$target" ]; then
                    process_directory "$target" "regenerate_workflow_id"
                else
                    regenerate_workflow_id "$target"
                fi
            elif [ -n "$ARG_SET_VERSION_ID" ]; then
                if [ -d "$target" ]; then
                    process_directory "$target" "set_version_id" "$ARG_SET_VERSION_ID"
                else
                    set_version_id "$target" "$ARG_SET_VERSION_ID"
                fi
            elif [ -n "$ARG_REGENERATE_VERSION_ID" ]; then
                if [ -d "$target" ]; then
                    process_directory "$target" "regenerate_version_id"
                else
                    regenerate_version_id "$target"
                fi
            else
                log ERROR "No ID operation specified. Use --set-workflow-id, --regenerate-workflow-id, --set-version-id, or --regenerate-version-id."
                exit 1
            fi
            ;;
        cleanup)
            if [ -n "$ARG_CLEAR_TARGETS" ]; then
                if [ -d "$target" ]; then
                    process_directory "$target" "cleanup_workflow" "$ARG_CLEAR_TARGETS"
                else
                    cleanup_workflow "$target" "$ARG_CLEAR_TARGETS"
                fi
            else
                log ERROR "No cleanup targets specified. Use --clear-tags, --clear-settings, etc."
                exit 1
            fi
            ;;
        *)
            log ERROR "Unknown action: $action"
            exit 1
            ;;
    esac
}

# --- Main Function ---
main() {
    # Initialize argument variables
    ARG_ACTION=""
    ARG_TARGET=""
    ARG_BACKUP_MODE="auto"
    ARG_DRY_RUN=false
    ARG_INTERACTIVE=false
    ARG_BATCH=false
    ARG_SETTING_PAIRS=()
    ARG_SETTINGS_TEMPLATE=""
    ARG_RESET_SETTINGS=false
    ARG_ADD_TAGS=()
    ARG_REMOVE_TAGS=()
    ARG_TAG_ID_FORMAT="uuid4"
    ARG_REGENERATE_TAG_IDS=false
    ARG_SET_WORKFLOW_ID=""
    ARG_REGENERATE_WORKFLOW_ID=false
    ARG_SET_VERSION_ID=""
    ARG_REGENERATE_VERSION_ID=false
    ARG_CLEAR_TARGETS=""
    ARG_CONFIG_FILE=""
    ARG_VERBOSE=false
    ARG_LOG_FILE=""
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Load configuration
    load_config
    
    # Apply argument overrides
    [ -n "$ARG_CONFIG_FILE" ] && CONF_CONFIG_FILE="$ARG_CONFIG_FILE"
    [ "$ARG_VERBOSE" = true ] && CONF_VERBOSE=1
    [ -n "$ARG_LOG_FILE" ] && CONF_LOG_FILE="$ARG_LOG_FILE"
    [ -n "$ARG_BACKUP_MODE" ] && CONF_BACKUP_MODE="$ARG_BACKUP_MODE"
    
    # Check dependencies
    check_dependencies
    
    # Determine execution mode
    if [ "$ARG_INTERACTIVE" = true ] || ([ -z "$ARG_ACTION" ] && [ "$ARG_BATCH" != true ]); then
        # Interactive mode
        log INFO "Starting n8n Workflows Bulk Editor in interactive mode"
        show_interactive_menu
    elif [ -n "$ARG_ACTION" ] && [ -n "$ARG_TARGET" ]; then
        # CLI mode
        log INFO "Starting n8n Workflows Bulk Editor in CLI mode"
        execute_cli_action "$ARG_ACTION" "$ARG_TARGET"
    else
        # Show help if no valid mode
        log ERROR "Invalid arguments. Provide either --interactive or specify action and target."
        echo
        show_help
        exit 1
    fi
    
    log SUCCESS "Operation completed successfully"
}

# --- Script Entry Point ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

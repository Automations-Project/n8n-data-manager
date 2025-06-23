#!/usr/bin/env bash
# =========================================================
# Installer for n8n-manager.sh and n8n-workflows-bulk-editor.sh
# =========================================================
set -euo pipefail

# --- Configuration ---
SCRIPT_NAME="n8n-manager.sh"
WORKFLOWS_EDITOR_NAME="n8n-workflows-bulk-editor.sh"
# IMPORTANT: Replace this URL with the actual raw URL of the script when hosted (e.g., GitHub Raw)
SCRIPT_URL="https://raw.githubusercontent.com/Automations-Project/n8n-data-manager/refs/heads/dev/n8n-manager.sh"
WORKFLOWS_EDITOR_URL="https://raw.githubusercontent.com/Automations-Project/n8n-data-manager/refs/heads/dev/n8n-workflows-bulk-editor.sh"
INSTALL_DIR="/usr/local/bin"
INSTALL_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"
WORKFLOWS_EDITOR_INSTALL_PATH="${INSTALL_DIR}/${WORKFLOWS_EDITOR_NAME}"

# Installation options
INSTALL_WORKFLOWS_EDITOR=true
FORCE_REINSTALL=true  # Always do cleanup for fresh installs

# ANSI Colors
printf -v GREEN   "\033[0;32m"
printf -v RED     "\033[0;31m"
printf -v BLUE    "\033[0;34m"
printf -v YELLOW  "\033[0;33m"
printf -v NC      "\033[0m" # No Color

# --- Functions ---

log_info() {
    echo -e "${BLUE}==>${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

cleanup_previous_installation() {
    log_info "Performing cleanup of previous installations..."
    
    # Remove existing scripts
    if [[ $EUID -eq 0 ]]; then
        # Running as root
        [ -f "$INSTALL_PATH" ] && rm -f "$INSTALL_PATH" && log_info "Removed existing $SCRIPT_NAME"
        [ -f "$WORKFLOWS_EDITOR_INSTALL_PATH" ] && rm -f "$WORKFLOWS_EDITOR_INSTALL_PATH" && log_info "Removed existing $WORKFLOWS_EDITOR_NAME"
    else
        # Use sudo
        [ -f "$INSTALL_PATH" ] && sudo rm -f "$INSTALL_PATH" && log_info "Removed existing $SCRIPT_NAME"
        [ -f "$WORKFLOWS_EDITOR_INSTALL_PATH" ] && sudo rm -f "$WORKFLOWS_EDITOR_INSTALL_PATH" && log_info "Removed existing $WORKFLOWS_EDITOR_NAME"
    fi
    
    # Clean up configuration directory (preserve user data but clean temp files)
    if [ -d ~/.config/n8n-manager ]; then
        log_info "Cleaning up temporary files in ~/.config/n8n-manager..."
        find ~/.config/n8n-manager -name "*.tmp" -delete 2>/dev/null || true
        find ~/.config/n8n-manager -name "*.lock" -delete 2>/dev/null || true
    fi
    
    # Clean up temporary files
    rm -rf /tmp/n8n-* 2>/dev/null || true
    rm -rf /tmp/workflow-* 2>/dev/null || true
    
    log_success "Cleanup completed"
}

check_dependencies() {
    log_info "Checking required dependencies..."
    local missing=""
    
    # Essential dependencies
    if ! command_exists curl; then
        missing="$missing curl"
    fi
    if ! command_exists sudo; then
        # Check if running as root, if so, sudo is not needed
        if [[ $EUID -ne 0 ]]; then
             missing="$missing sudo"
        fi
    fi
    
    # Check optional dependencies and warn if missing
    if ! command_exists jq; then
        log_warning "jq not found - required for workflows bulk editor JSON processing"
        log_info "Install with: sudo apt-get install jq (Ubuntu/Debian) or brew install jq (macOS)"
    fi
    
    if ! command_exists docker; then
        log_warning "docker not found - required for n8n container operations"
    fi
    
    if ! command_exists git; then
        log_warning "git not found - required for backup operations"
    fi

    if [ -n "$missing" ]; then
        log_error "Missing required dependencies:$missing"
        log_info "Please install them and try again."
        exit 1
    fi
    log_success "Core dependencies found."
}

download_script() {
    local script_name="$1"
    local script_url="$2"
    local install_path="$3"
    
    # Add cache-busting timestamp to URL
    local timestamp=$(date +%s)
    local cache_busted_url="${script_url}?v=${timestamp}"
    
    log_info "Downloading ${script_name} from ${script_url}..."
    local temp_script=$(mktemp)
    
    if ! curl -fsSL --connect-timeout 10 --max-time 30 "$cache_busted_url" -o "$temp_script"; then
        log_error "Failed to download ${script_name}. Check the URL and network connection."
        rm -f "$temp_script"
        return 1
    fi
    
    # Verify the downloaded script is not empty and appears to be a shell script
    if [ ! -s "$temp_script" ]; then
        log_error "Downloaded ${script_name} is empty"
        rm -f "$temp_script"
        return 1
    fi
    
    if ! head -n 1 "$temp_script" | grep -q "^#!/.*bash"; then
        log_error "Downloaded file does not appear to be a bash script"
        rm -f "$temp_script"
        return 1
    fi
    
    log_success "${script_name} downloaded successfully."
    
    log_info "Making ${script_name} executable..."
    if ! chmod +x "$temp_script"; then
        log_error "Failed to make ${script_name} executable."
        rm -f "$temp_script"
        return 1
    fi

    log_info "Installing ${script_name} to ${install_path}..."
    if [[ $EUID -ne 0 ]]; then
        # Not root, use sudo
        if ! sudo mv "$temp_script" "$install_path"; then
            log_error "Failed to install ${script_name} to ${install_path}. Check permissions."
            rm -f "$temp_script"
            return 1
        fi
    else
        # Already root, move directly
        if ! mv "$temp_script" "$install_path"; then
            log_error "Failed to install ${script_name} to ${install_path}. Check permissions."
            rm -f "$temp_script"
            return 1
        fi
    fi

    # Clean up temp file if it still exists
    [ -f "$temp_script" ] && rm -f "$temp_script"
    
    log_success "${script_name} installed successfully to ${install_path}"
    return 0
}

# --- Main Installation Logic ---

echo -e "${GREEN}"
echo "======================================================="
echo "           n8n Data Manager Installation"
echo "======================================================="
echo -e "${NC}"

log_info "Starting installation..."

# Perform cleanup if requested
if [ "$FORCE_REINSTALL" = true ]; then
    cleanup_previous_installation
fi

check_dependencies

# Check if script URL placeholder is still present
if [[ "$SCRIPT_URL" == *"PLACEHOLDER"* ]]; then
    log_error "Installation script needs configuration."
    log_info "Please edit the SCRIPT_URL variable in the install.sh script first."
    exit 1
fi

# Install main n8n-manager script
if ! download_script "$SCRIPT_NAME" "$SCRIPT_URL" "$INSTALL_PATH"; then
    exit 1
fi

# Install workflows bulk editor if enabled
if [ "$INSTALL_WORKFLOWS_EDITOR" = true ]; then
    if ! download_script "$WORKFLOWS_EDITOR_NAME" "$WORKFLOWS_EDITOR_URL" "$WORKFLOWS_EDITOR_INSTALL_PATH"; then
        log_warning "Failed to install workflows bulk editor, but main script is available"
    else
        log_success "Workflows bulk editor installed successfully."
    fi
fi

# Create config directory if it doesn't exist
if [ ! -d ~/.config/n8n-manager ]; then
    log_info "Creating configuration directory..."
    mkdir -p ~/.config/n8n-manager
    log_success "Configuration directory created at ~/.config/n8n-manager"
fi

echo
log_success "Installation completed successfully!"
echo
echo -e "${GREEN}Available commands:${NC}"
echo -e "  ${BLUE}${SCRIPT_NAME}${NC} - Main n8n data manager"
echo -e "  ${BLUE}${SCRIPT_NAME} --help${NC} - Show main script help"

if [ "$INSTALL_WORKFLOWS_EDITOR" = true ] && [ -f "$WORKFLOWS_EDITOR_INSTALL_PATH" ]; then
    echo -e "  ${BLUE}${WORKFLOWS_EDITOR_NAME}${NC} - Workflows bulk editor"
    echo -e "  ${BLUE}${WORKFLOWS_EDITOR_NAME} --help${NC} - Show bulk editor help"
fi

echo
echo -e "${GREEN}Quick start examples:${NC}"
echo -e "  ${BLUE}# Interactive mode${NC}"
echo -e "  ${WORKFLOWS_EDITOR_NAME}"
echo
echo -e "  ${BLUE}# Main backup command${NC}"
echo -e "  ${SCRIPT_NAME} --action backup --container \$(docker ps --filter 'name=n8n' --format '{{.Names}}' | head -n 1)"
echo
echo -e "${GREEN}Configuration:${NC}"
echo -e "  Edit ~/.config/n8n-manager/config for default settings"
echo
echo -e "${GREEN}Documentation:${NC}"
echo -e "  https://github.com/Automations-Project/n8n-data-manager"

exit 0

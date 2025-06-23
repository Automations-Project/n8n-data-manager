#!/usr/bin/env bash
# =========================================================
# Installer for n8n-manager.sh
# =========================================================
set -euo pipefail

# --- Configuration ---
SCRIPT_NAME="n8n-manager.sh"
# IMPORTANT: Replace this URL with the actual raw URL of the script when hosted (e.g., GitHub Raw)
SCRIPT_URL="https://raw.githubusercontent.com/Automations-Project/n8n-data-manager/refs/heads/multi-modes/n8n-manager.sh"
INSTALL_DIR="/usr/local/bin"
INSTALL_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"

# ANSI Colors
printf -v GREEN   "\033[0;32m"
printf -v RED     "\033[0;31m"
printf -v BLUE    "\033[0;34m"
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

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_dependencies() {
    log_info "Checking required dependencies (curl, sudo)..."
    local missing=""
    if ! command_exists curl; then
        missing="$missing curl"
    fi
    if ! command_exists sudo; then
        # Check if running as root, if so, sudo is not needed
        if [[ $EUID -ne 0 ]]; then
             missing="$missing sudo"
        fi
    fi

    if [ -n "$missing" ]; then
        log_error "Missing required dependencies:$missing"
        log_info "Please install them and try again."
        exit 1
    fi
    log_success "Dependencies found."
}

# --- Main Installation Logic ---

log_info "Starting n8n-manager installation..."

check_dependencies

# Check if script URL placeholder is still present
if [[ "$SCRIPT_URL" == *"PLACEHOLDER"* ]]; then
    log_error "Installation script needs configuration."
    log_info "Please edit the SCRIPT_URL variable in the install.sh script first."
    exit 1
fi

log_info "Downloading ${SCRIPT_NAME} from ${SCRIPT_URL}..."
temp_script=$(mktemp)
# Add multiple cache-busting parameters to prevent caching issues
timestamp="$(date +%s)"
random_suffix="$RANDOM"
script_url_with_cache_bust="${SCRIPT_URL}?t=${timestamp}&r=${random_suffix}&cache=false"
# Use aggressive cache-busting headers
if ! curl -fsSL --connect-timeout 10 \
    -H "Cache-Control: no-cache, no-store, must-revalidate" \
    -H "Pragma: no-cache" \
    -H "Expires: 0" \
    "$script_url_with_cache_bust" -o "$temp_script"; then
    log_error "Failed to download the script. Check the URL and network connection."
    rm -f "$temp_script"
    exit 1
fi
log_success "Script downloaded successfully."

log_info "Making the script executable..."
if ! chmod +x "$temp_script"; then
    log_error "Failed to make the script executable."
    rm -f "$temp_script"
    exit 1
fi

log_info "Moving the script to ${INSTALL_PATH} using sudo..."
if [[ $EUID -ne 0 ]]; then
    # Not root, use sudo
    if ! sudo mv "$temp_script" "$INSTALL_PATH"; then
        log_error "Failed to move the script to ${INSTALL_PATH}. Check permissions or run installer with sudo."
        rm -f "$temp_script"
        exit 1
    fi
else
    # Already root, move directly
    if ! mv "$temp_script" "$INSTALL_PATH"; then
        log_error "Failed to move the script to ${INSTALL_PATH}. Check permissions."
        rm -f "$temp_script"
        exit 1
    fi
fi

# Clean up temp file if move failed and it still exists (shouldn't happen often)
if [ -f "$temp_script" ]; then
    rm -f "$temp_script"
fi

log_success "${SCRIPT_NAME} installed successfully to ${INSTALL_PATH}"
log_info "You can now run the script using: ${SCRIPT_NAME}"
log_info "Run '${SCRIPT_NAME} --help' to see usage instructions."

exit 0

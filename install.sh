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

download_script() {
    local url="$1"
    local output_file="$2"
    local description="$3"
    
    log_info "${description}"
    log_info "URL: ${url}"
    
    if curl -fsSL --connect-timeout 30 --max-time 120 \
        -H "Cache-Control: no-cache" \
        -H "Pragma: no-cache" \
        "${url}" -o "${output_file}"; then
        
        # Check if file was actually downloaded and has content
        if [[ -s "${output_file}" ]]; then
            local file_size=$(stat -c%s "${output_file}" 2>/dev/null || wc -c < "${output_file}")
            log_success "Download completed successfully (${file_size} bytes)"
            return 0
        else
            log_error "Download completed but file is empty"
            rm -f "${output_file}"
            return 1
        fi
    else
        log_error "Download failed"
        rm -f "${output_file}"
        return 1
    fi
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

temp_script=$(mktemp)

# Generate cache-busting parameters
timestamp="$(date +%s)"
random_suffix="$RANDOM"

# Try downloading with cache-busting first
cache_busted_url="${SCRIPT_URL}?t=${timestamp}&r=${random_suffix}"
if download_script "${cache_busted_url}" "${temp_script}" "Downloading ${SCRIPT_NAME} with cache-busting..."; then
    log_success "Downloaded successfully with cache-busting"
else
    log_info "Cache-busted download failed, trying without cache parameters..."
    if download_script "${SCRIPT_URL}" "${temp_script}" "Downloading ${SCRIPT_NAME} (fallback)..."; then
        log_success "Downloaded successfully with fallback method"
    else
        log_error "All download attempts failed. Check the URL and network connection."
        exit 1
    fi
fi

# Validate the downloaded script
log_info "Validating downloaded script..."
first_line=$(head -n 1 "${temp_script}" 2>/dev/null || echo "")

if [[ -z "$first_line" ]]; then
    log_error "Downloaded script appears to be empty or unreadable"
    rm -f "${temp_script}"
    exit 1
fi

if ! echo "$first_line" | grep -q "^#!/"; then
    log_error "Downloaded file doesn't appear to be a valid shell script."
    log_info "First line: ${first_line}"
    rm -f "${temp_script}"
    exit 1
fi

log_success "Script validation passed"

log_info "Making the script executable..."
if ! chmod +x "${temp_script}"; then
    log_error "Failed to make the script executable."
    rm -f "${temp_script}"
    exit 1
fi

log_info "Moving the script to ${INSTALL_PATH}..."
if [[ $EUID -ne 0 ]]; then
    # Not root, use sudo
    if ! sudo mv "${temp_script}" "${INSTALL_PATH}"; then
        log_error "Failed to move the script to ${INSTALL_PATH}. Check permissions or run installer with sudo."
        rm -f "${temp_script}"
        exit 1
    fi
else
    # Already root, move directly
    if ! mv "${temp_script}" "${INSTALL_PATH}"; then
        log_error "Failed to move the script to ${INSTALL_PATH}. Check permissions."
        rm -f "${temp_script}"
        exit 1
    fi
fi

# Clean up temp file if it still exists
if [ -f "${temp_script}" ]; then
    rm -f "${temp_script}"
fi

log_success "${SCRIPT_NAME} installed successfully to ${INSTALL_PATH}"
log_info "You can now run the script using: ${SCRIPT_NAME}"
log_info "Run '${SCRIPT_NAME} --help' to see usage instructions."

exit 0
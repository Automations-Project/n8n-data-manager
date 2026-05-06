#!/usr/bin/env bash
## n8n-manager installer — zero-interaction setup for any Linux distro
## Usage:
##   Portable (one-time):  curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash
##   System install:       curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash -s -- --system
##   User install:         curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash -s -- --user
##   Custom location:      curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash -s -- --prefix /opt/n8n-manager
##   Standard:             curl -fsSL https://i.nskha.com/install.sh | sudo bash
##   User install (no sudo): curl -fsSL https://i.nskha.com/install.sh | bash -s -- --user
##   Uninstall:            curl -fsSL https://i.nskha.com/install.sh | sudo bash -s -- --uninstall --yes
##
## What it does:
##   1. Downloads n8n-manager script from GitHub releases
##   2. Downloads gum binary (for rich terminal UI)
##   3. Installs both to the chosen location (atomically replaces v4 if present)
##   4. Adds to PATH (for user/system installs)

set -Eeuo pipefail
IFS=$'\n\t'

# ─── Configuration ────────────────────────────────────────────────────────────
N8N_MANAGER_VERSION="5.0.0"
GUM_VERSION="0.17.0"
REPO="Automations-Project/n8n-data-manager"
RELEASE_BASE="https://github.com/${REPO}/releases/download"

# Pinned SHA-256 table for n8n-manager binary
# Run: bash scripts/refresh-pinned-shas.sh <version>  to regenerate on release
# PLACEHOLDER_SHA_UNTIL_FIRST_RELEASE signals pre-release — SHA check gracefully degrades.
declare -A N8N_MANAGER_SHA256
N8N_MANAGER_SHA256["5.0.0"]="PLACEHOLDER_SHA_UNTIL_FIRST_RELEASE"

# Colors (inline — no dependencies)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helpers ──────────────────────────────────────────────────────────────────
info()    { printf "${CYAN}i${NC} %s\n" "$*"; }
success() { printf "${GREEN}+${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}!${NC} %s\n" "$*"; }
error()   { printf "${RED}x${NC} %s\n" "$*" >&2; }
fatal()   { error "$*"; exit 1; }

# ─── Detect system ───────────────────────────────────────────────────────────
detect_arch() {
    local arch
    arch=$(uname -m 2>/dev/null || echo "unknown")
    case "$arch" in
        x86_64|amd64)   echo "x86_64" ;;
        aarch64|arm64)   echo "arm64" ;;
        armv7l|armhf)    echo "armv7" ;;
        i386|i686)       echo "i386" ;;
        *)               fatal "Unsupported architecture: $arch" ;;
    esac
}

detect_os() {
    local os
    os=$(uname -s 2>/dev/null || echo "unknown")
    case "$os" in
        Linux)  echo "Linux" ;;
        Darwin) echo "Darwin" ;;
        *)      fatal "Unsupported OS: $os. n8n-manager requires Linux or macOS." ;;
    esac
}

detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${ID:-unknown}"
    elif [ -f /etc/alpine-release ]; then
        echo "alpine"
    elif command -v lsb_release >/dev/null 2>&1; then
        lsb_release -si 2>/dev/null | tr '[:upper:]' '[:lower:]'
    else
        echo "unknown"
    fi
}

check_command() {
    command -v "$1" >/dev/null 2>&1
}

# ─── v4 binary detection ──────────────────────────────────────────────────────
# Returns: "v4" / "v5" / "unknown"
# D-06: primary signal — --version regex ^[Vv]?4\.
# D-07: fallback — grep binary for v4 sentinel string
_install_detect_v4() {
    local bin_path="$1"
    local ver_output
    ver_output=$("$bin_path" --version 2>/dev/null || true)
    local first_line
    first_line=$(printf '%s' "$ver_output" | head -1)
    if printf '%s' "$first_line" | grep -qE '^[Vv]?4\.'; then
        echo "v4"; return 0
    fi
    if printf '%s' "$first_line" | grep -qE '^[Vv]?5\.'; then
        echo "v5"; return 0
    fi
    # Fallback: grep binary for v4 sentinel string (D-07)
    if grep -qF 'n8n-manager v4' "$bin_path" 2>/dev/null; then
        echo "v4"; return 0
    fi
    echo "unknown"
}

# ─── Download gum binary ─────────────────────────────────────────────────────
install_gum() {
    local install_dir="$1"
    local os="$2"
    local arch="$3"
    local gum_bin="$install_dir/gum"

    # Skip if already present
    if [ -x "$gum_bin" ]; then
        local current_ver
        current_ver=$("$gum_bin" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        if [ "$current_ver" = "$GUM_VERSION" ]; then
            success "gum v$GUM_VERSION already installed"
            return 0
        fi
        info "Upgrading gum from v$current_ver to v$GUM_VERSION..."
    fi

    # System-wide gum is fine too
    if check_command gum; then
        local sys_ver
        sys_ver=$(gum --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        success "gum v$sys_ver found system-wide (skipping local install)"
        return 0
    fi

    local tarball="gum_${GUM_VERSION}_${os}_${arch}.tar.gz"
    local url="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/${tarball}"

    info "Downloading gum v${GUM_VERSION} (${os}/${arch})..."

    local tmp_dir
    tmp_dir=$(mktemp -d -t gum-install-XXXXXX)
    trap "rm -rf '$tmp_dir'" RETURN

    if ! curl -fsSL --connect-timeout 15 --max-time 120 -o "$tmp_dir/$tarball" "$url"; then
        warn "Failed to download gum from: $url"
        warn "n8n-manager will work without gum (basic UI mode)"
        return 1
    fi

    # Extract tarball — binary is inside a subdirectory (e.g. gum_0.17.0_Linux_x86_64/gum)
    if ! tar -xzf "$tmp_dir/$tarball" -C "$tmp_dir" --strip-components=1 2>/dev/null; then
        warn "Failed to extract gum binary"
        return 1
    fi

    if [ ! -f "$tmp_dir/gum" ]; then
        warn "gum binary not found in archive"
        return 1
    fi

    mkdir -p "$install_dir" 2>/dev/null
    mv "$tmp_dir/gum" "$gum_bin"
    chmod +x "$gum_bin"

    success "gum v${GUM_VERSION} installed to $gum_bin"
    return 0
}

# ─── Binary verification chain ────────────────────────────────────────────────
# Steps: bash -n → --version smoke → SHA pinned → SHA checksums.txt cross-check
# Args: <tmp_path> <version> <install_path>
# Returns 0 on success, 1 on any failure (logs error before returning)
# D-09, D-12 steps 2-5, D-25
_install_verify_binary() {
    local tmp_path="$1" version="$2" install_path="$3"

    # Step 2: syntax validation (D-12)
    if ! bash -n "$tmp_path" 2>/dev/null; then
        error "Downloaded file failed bash -n syntax check."
        error "  Original binary at ${install_path} remains unchanged."
        error "  Temp file removed."
        return 1
    fi

    # Step 3: --version smoke (D-12)
    local ver_out
    ver_out=$("$tmp_path" --version 2>/dev/null || true)
    if ! printf '%s' "$ver_out" | head -1 | grep -qE '^[Vv]?5\.'; then
        error "Downloaded binary --version does not report v5.x (got: ${ver_out:-<empty>})."
        error "  Original binary at ${install_path} remains unchanged."
        error "  Temp file removed."
        return 1
    fi

    # Step 4: SHA-256 against pinned table (D-08, D-12)
    local pinned_sha="${N8N_MANAGER_SHA256[$version]:-}"
    local skip_sha=false
    if [ -z "$pinned_sha" ] || [ "$pinned_sha" = "PLACEHOLDER_SHA_UNTIL_FIRST_RELEASE" ]; then
        warn "SHA-256 table not yet populated for v${version} — skipping hash verification (pre-release)."
        skip_sha=true
    fi

    local actual_sha=""
    if [ "$skip_sha" != "true" ]; then
        if command -v sha256sum >/dev/null 2>&1; then
            actual_sha=$(sha256sum "$tmp_path" | awk '{print $1}')
        elif command -v shasum >/dev/null 2>&1; then
            actual_sha=$(shasum -a 256 "$tmp_path" | awk '{print $1}')
        else
            warn "sha256sum and shasum not available — skipping hash verification."
            skip_sha=true
        fi
    fi

    if [ "$skip_sha" != "true" ] && [ "$actual_sha" != "$pinned_sha" ]; then
        error "SHA-256 mismatch for n8n-manager v${version}"
        error "  Expected: ${pinned_sha}"
        error "  Got:      ${actual_sha}"
        error "  Original binary at ${install_path} remains unchanged."
        error "  Temp file removed."
        return 1
    fi

    # Step 5: cross-check against upstream checksums.txt (D-09, D-12)
    if [ "$skip_sha" != "true" ]; then
        local checksums_url="${RELEASE_BASE}/v${version}/checksums.txt"
        local tmp_checksums
        tmp_checksums=$(mktemp -t n8n-manager-checksums-XXXXXX)
        if curl -fsSL --connect-timeout 10 --max-time 20 -o "$tmp_checksums" "$checksums_url" 2>/dev/null; then
            local upstream_sha
            upstream_sha=$(grep -E '^\S+\s+\.?/?n8n-manager$' "$tmp_checksums" 2>/dev/null | awk '{print $1}' | head -1 || true)
            if [ -n "$upstream_sha" ]; then
                if [ "$actual_sha" = "$pinned_sha" ] && [ "$actual_sha" != "$upstream_sha" ]; then
                    error "Pinned table out of sync with upstream — run: bash scripts/refresh-pinned-shas.sh ${version}"
                    error "  Original binary at ${install_path} remains unchanged."
                    error "  Temp file removed."
                    rm -f "$tmp_checksums" 2>/dev/null
                    return 1
                fi
                if [ "$actual_sha" != "$pinned_sha" ] && [ "$actual_sha" = "$upstream_sha" ]; then
                    error "Refusing to install unpinned version ${version}."
                    error "  checksums.txt SHA matches but pinned table does not — update the table."
                    error "  Original binary at ${install_path} remains unchanged."
                    error "  Temp file removed."
                    rm -f "$tmp_checksums" 2>/dev/null
                    return 1
                fi
            fi
            rm -f "$tmp_checksums" 2>/dev/null
        else
            warn "Could not fetch checksums.txt for v${version} — skipping upstream cross-check."
        fi
    fi

    return 0
}

# ─── Atomic binary replace ────────────────────────────────────────────────────
# Args: <new_binary_tmp> <install_path> <version>
# Returns 0 on success, 1 on failure
# D-11: .v4.bak timestamp collision guard
# D-12: atomic mv chain (steps 6-8)
# D-22: version-diff banner
_install_atomic_replace() {
    local new_tmp="$1" install_path="$2" version="$3"
    local _old_version _bak_path _new_version

    # Step 6: Collision guard — timestamp existing .v4.bak if present (D-11)
    # Example: n8n-manager.v4.bak.20260101-120000 (preserves prior backups)
    local bak_base="${install_path}.v4.bak"
    if [ -f "$bak_base" ]; then
        local ts
        ts=$(date -u '+%Y%m%d-%H%M%S')
        local bak_ts="${bak_base}.${ts}"
        if ! mv "$bak_base" "$bak_ts" 2>/dev/null; then
            error "Could not move existing .v4.bak to timestamped path. Aborting."
            return 1
        fi
    fi

    # Capture old version for banner (D-22)
    if [ -f "$install_path" ]; then
        local _raw_old
        _raw_old=$("$install_path" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        if [ -n "$_raw_old" ]; then
            _old_version="$_raw_old"
        else
            _old_version=$(_install_detect_v4 "$install_path" 2>/dev/null || true)
        fi
    else
        _old_version="none"
    fi

    # Step 7: Move original to .v4.bak (D-12)
    if [ -f "$install_path" ]; then
        if ! mv "$install_path" "$bak_base" 2>/dev/null; then
            error "Could not move ${install_path} to ${bak_base}."
            error "  Try: sudo n8n-manager update  (if permission denied)"
            return 1
        fi
    fi

    # Step 8: Move new binary into place (D-12 — atomic rename(2))
    if ! mv "$new_tmp" "$install_path" 2>/dev/null; then
        # Critical: restore from backup if mv fails
        if [ -f "$bak_base" ]; then
            mv "$bak_base" "$install_path" 2>/dev/null || true
        fi
        error "Could not install new binary to ${install_path}."
        error "  Attempted restore from ${bak_base}."
        return 1
    fi

    chmod +x "$install_path"

    # Print version-diff banner (D-22)
    _new_version=$("$install_path" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "$version")
    _bak_path="$bak_base"
    success "n8n-manager: v${_old_version} → v${_new_version}"
    info "  Backup at: ${_bak_path}"
    info "  Report issues: https://github.com/Automations-Project/n8n-data-manager/issues"
    return 0
}

# ─── Install n8n-manager script ──────────────────────────────────────────────
install_n8n_manager() {
    local install_dir="$1"
    local install_path="${install_dir}/n8n-manager"

    # Check if running from local build
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

    if [ -f "${script_dir}/n8n-manager" ] && \
       [ "$(realpath "${script_dir}/n8n-manager" 2>/dev/null)" != "$(realpath "$install_path" 2>/dev/null)" ]; then
        info "Installing n8n-manager from local build..."
        # Local install: set up traps and use atomic-replace (no SHA check — building from source)
        _tmp=$(mktemp -t n8n-manager-install-XXXXXX)
        # D-13: independent EXIT INT TERM handlers
        trap 'rm -f "${_tmp:-}" 2>/dev/null' EXIT INT TERM
        cp "${script_dir}/n8n-manager" "$_tmp"
        chmod +x "$_tmp"
        if ! _install_atomic_replace "$_tmp" "$install_path" "$N8N_MANAGER_VERSION"; then
            rm -f "$_tmp" 2>/dev/null
            exit 1
        fi
        return 0
    fi

    # Already in place (portable mode from same directory)
    if [ -f "${script_dir}/n8n-manager" ]; then
        local _realpath_src _realpath_dst
        _realpath_src=$(realpath "${script_dir}/n8n-manager" 2>/dev/null || true)
        _realpath_dst=$(realpath "$install_path" 2>/dev/null || true)
        if [ -n "$_realpath_src" ] && [ "$_realpath_src" = "$_realpath_dst" ]; then
            chmod +x "$install_path"
            success "n8n-manager already in place"
            return 0
        fi
    fi

    # Download from GitHub releases
    local url="${RELEASE_BASE}/v${N8N_MANAGER_VERSION}/n8n-manager"
    info "Downloading n8n-manager v${N8N_MANAGER_VERSION}..."

    _tmp=$(mktemp -t n8n-manager-install-XXXXXX)
    # D-13: independent EXIT INT TERM handlers
    trap 'rm -f "${_tmp:-}" 2>/dev/null' EXIT INT TERM

    if ! curl -fsSL --connect-timeout 15 --max-time 120 -o "$_tmp" "$url" 2>/dev/null; then
        fatal "Failed to download n8n-manager from: ${url}"
    fi

    chmod +x "$_tmp"

    if ! _install_verify_binary "$_tmp" "$N8N_MANAGER_VERSION" "$install_path"; then
        rm -f "$_tmp" 2>/dev/null
        exit 1
    fi

    if ! _install_atomic_replace "$_tmp" "$install_path" "$N8N_MANAGER_VERSION"; then
        rm -f "$_tmp" 2>/dev/null
        exit 1
    fi
}

# ─── Setup PATH ──────────────────────────────────────────────────────────────
setup_path() {
    local bin_dir="$1"
    local mode="$2"

    # D-17: check using POSIX case pattern — no hint needed if already on PATH
    case ":$PATH:" in
        *":${bin_dir}:"*)
            return 0  # Already on PATH — no hint needed (D-17)
            ;;
    esac

    if [ "$mode" = "system" ]; then
        # System install: symlink to /usr/local/bin
        if [ -w /usr/local/bin ]; then
            ln -sf "$bin_dir/n8n-manager" /usr/local/bin/n8n-manager 2>/dev/null || true
            ln -sf "$bin_dir/gum" /usr/local/bin/gum 2>/dev/null || true
            success "Symlinked to /usr/local/bin"
        else
            warn "Cannot write to /usr/local/bin — add $bin_dir to your PATH manually"
        fi
    else
        # User install: add to shell profile
        local shell_rc=""
        case "${SHELL:-/bin/bash}" in
            */zsh)  shell_rc="$HOME/.zshrc" ;;
            */fish) shell_rc="$HOME/.config/fish/config.fish" ;;
            *)      shell_rc="$HOME/.bashrc" ;;
        esac

        local path_line="export PATH=\"$bin_dir:\$PATH\""

        if [ -n "$shell_rc" ] && [ -f "$shell_rc" ]; then
            if ! grep -qF "$bin_dir" "$shell_rc" 2>/dev/null; then
                printf '\n# n8n-manager\n%s\n' "$path_line" >> "$shell_rc"
                success "Added to PATH in $shell_rc"
                info "Run: source $shell_rc  (or restart your terminal)"
            fi
        else
            warn "Add this to your shell profile:"
            echo "  $path_line"
        fi
    fi

    # D-17: emit PATH hint when install_dir not yet on $PATH (for non-system/non-portable modes)
    if [ "$mode" != "system" ] && [ "$mode" != "portable" ]; then
        case ":$PATH:" in
            *":${bin_dir}:"*) ;;
            *)
                info "Add ${bin_dir} to your PATH: export PATH=\"${bin_dir}:\$PATH\""
                ;;
        esac
    fi
}

# ─── Create config directory ─────────────────────────────────────────────────
setup_config() {
    local config_dir="${HOME}/.config/n8n-manager"
    mkdir -p "$config_dir" 2>/dev/null

    if [ ! -f "$config_dir/config" ]; then
        cat > "$config_dir/config" << 'CONF'
# n8n-manager configuration
# Uncomment and set values to use as defaults

# CONF_GITHUB_TOKEN=ghp_your_token_here
# CONF_GITHUB_REPO=username/n8n-backups
# CONF_GITHUB_BRANCH=main
# CONF_CONTAINER=n8n
# CONF_BACKUP_TYPE=all
# CONF_SEPARATE_FILES=false
# CONF_VERBOSE=false
# CONF_RECORD=false
# CONF_RECORD_OUTPUT=/path/to/recordings
CONF
        success "Config template created at $config_dir/config"
    fi
}

# ─── Uninstall ───────────────────────────────────────────────────────────────
uninstall() {
    local install_dir="${XDG_DATA_HOME:-$HOME/.local/share}/n8n-manager"
    local bin_dir="$install_dir/bin"

    info "Uninstalling n8n-manager..."

    # Remove binaries
    rm -f "$bin_dir/n8n-manager" "$bin_dir/gum" 2>/dev/null
    rmdir "$bin_dir" 2>/dev/null || true
    rmdir "$install_dir" 2>/dev/null || true

    # Remove symlinks
    rm -f /usr/local/bin/n8n-manager /usr/local/bin/gum 2>/dev/null || true

    # Remove PATH entry from shell profiles
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rc" ]; then
            sed -i '/n8n-manager/d' "$rc" 2>/dev/null || true
        fi
    done

    success "n8n-manager uninstalled"
    info "Config preserved at ~/.config/n8n-manager/ (delete manually if desired)"
}

# ─── Print banner ────────────────────────────────────────────────────────────
print_banner() {
    printf "\n"
    printf "${BOLD}${CYAN}"
    printf "  +===============================================+\n"
    printf "  |     n8n-manager installer v%-15s|\n" "$N8N_MANAGER_VERSION"
    printf "  +===============================================+\n"
    printf "${NC}\n"
}

print_summary() {
    local install_dir="$1"
    local has_gum="$2"

    printf "\n"
    printf "${BOLD}  Installation Summary${NC}\n"
    printf "  -----------------------------------------\n"
    printf "  ${CYAN}n8n-manager${NC}  -> %s/n8n-manager\n" "$install_dir"
    if [ "$has_gum" = "true" ]; then
        printf "  ${CYAN}gum${NC}          -> %s/gum\n" "$install_dir"
        printf "  ${CYAN}UI mode${NC}      -> ${GREEN}Rich (Lip Gloss + Gum)${NC}\n"
    else
        printf "  ${CYAN}gum${NC}          -> ${YELLOW}not installed${NC}\n"
        printf "  ${CYAN}UI mode${NC}      -> ${YELLOW}Basic (ASCII fallback)${NC}\n"
    fi
    printf "  ${CYAN}Config${NC}       -> ~/.config/n8n-manager/config\n"
    printf "\n"
    printf "  ${BOLD}Quick start:${NC}\n"
    printf "    n8n-manager backup --help\n"
    printf "    n8n-manager restore --help\n"
    printf "\n"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    local mode="user"          # user | system | portable
    local prefix=""            # custom install prefix
    local do_uninstall=false
    local skip_gum=false
    local _yes=false           # required only for the destructive --uninstall path
                               # (running curl|sudo bash IS consent for fresh install)

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --system|-s)     mode="system" ;;
            --user)          mode="user" ;;
            --portable|-p)   mode="portable" ;;
            --prefix)        prefix="$2"; shift ;;
            --prefix=*)      prefix="${1#*=}" ;;
            --yes|-y)        _yes=true ;;
            --uninstall)     do_uninstall=true ;;
            --no-gum)        skip_gum=true ;;
            --help|-h)
                echo "Usage: install.sh [OPTIONS]"
                echo ""
                echo "Modes:"
                echo "  (default)      Install to /usr/local/bin (root) or ~/.local/bin (user)"
                echo "  --system, -s   Force system-wide install (/usr/local/bin)"
                echo "  --user         Force user install (~/.local/bin)"
                echo "  --portable, -p Install to current directory (no PATH changes)"
                echo "  --prefix PATH  Install to custom directory"
                echo ""
                echo "Options:"
                echo "  --yes, -y      Skip confirmation prompts (required for --uninstall over a pipe)"
                echo "  --no-gum       Skip gum installation (basic UI mode)"
                echo "  --uninstall    Remove n8n-manager and gum"
                echo "  --help, -h     Show this help"
                exit 0
                ;;
            *)
                warn "Unknown option: $1"
                ;;
        esac
        shift
    done

    # D-19 (relaxed): the consent guard now only fires for --uninstall,
    # which is the actually-destructive path. Fresh installs proceed
    # without --yes — running `curl … | sudo bash` IS the consent,
    # matching the convention every other installer uses (rustup,
    # oh-my-zsh, get.docker.com, deno, etc.).
    if [ "$do_uninstall" = "true" ]; then
        if [ ! -t 0 ] && [ "$_yes" != "true" ]; then
            printf '\n%s\n' "Uninstall over a pipe needs explicit --yes (destructive operation)." >&2
            printf '%s\n'   "Working one-liner:" >&2
            printf '\n  %s\n\n' "curl -fsSL https://i.nskha.com/install.sh | sudo bash -s -- --uninstall --yes" >&2
            fatal "consent flag required for --uninstall"
        fi
        uninstall
        exit 0
    fi

    print_banner

    # Determine install directory — D-16: $EUID root detection (EUID=0 → /usr/local/bin, else ~/.local/bin)
    local install_dir
    local _effective_uid
    _effective_uid=$(id -u 2>/dev/null || echo 1000)
    if [ -n "$prefix" ]; then
        install_dir="$prefix"
    elif [ "$mode" = "portable" ]; then
        install_dir="$(pwd)"
    elif [ "$mode" = "system" ] || [ "$_effective_uid" -eq 0 ]; then
        install_dir="/usr/local/bin"
    else
        install_dir="${HOME}/.local/bin"
        mkdir -p "$install_dir" 2>/dev/null || true
    fi

    # Prerequisites
    if ! check_command curl; then
        fatal "curl is required. Install it first: apt install curl / yum install curl / apk add curl"
    fi

    local os arch
    os=$(detect_os)
    arch=$(detect_arch)
    local distro
    distro=$(detect_distro)

    info "Detected: ${os}/${arch} (${distro})"

    # Create install directory
    mkdir -p "$install_dir" 2>/dev/null || fatal "Cannot create directory: $install_dir"

    # Install gum
    local has_gum="false"
    if [ "$skip_gum" != "true" ]; then
        if install_gum "$install_dir" "$os" "$arch"; then
            has_gum="true"
        fi
    else
        info "Skipping gum installation (--no-gum)"
    fi

    # Install n8n-manager
    install_n8n_manager "$install_dir"

    # D-18: --user install with v4 in /usr/local/bin — warn but don't block
    if [ "$mode" = "user" ] && [ -f "/usr/local/bin/n8n-manager" ]; then
        local _sys_kind
        _sys_kind=$(_install_detect_v4 "/usr/local/bin/n8n-manager" 2>/dev/null || echo "unknown")
        if [ "$_sys_kind" = "v4" ]; then
            warn "v4 binary remains at /usr/local/bin/n8n-manager. Whichever runs depends on \$PATH ordering."
            info "  Run 'sudo n8n-manager update' to upgrade the system-wide v4 binary in place."
        fi
    fi

    # Setup PATH (skip for portable mode)
    if [ "$mode" != "portable" ]; then
        setup_path "$install_dir" "$mode"
    fi

    # Create config
    setup_config

    # Summary
    print_summary "$install_dir" "$has_gum"

    success "Installation complete!"

    # Patch-34: hand the user straight to the binary's welcome screen so
    # the very first thing they see post-install is "what can I do?".
    # The welcome command prints a static command summary in every mode
    # (works fine over the curl|sudo bash pipe — non-TTY just skips the
    # gum menu and exits 0). For portable installs the binary is in
    # ${install_dir}/n8n-manager, not on PATH yet — invoke it by absolute
    # path so we don't depend on shell rehash.
    local installed_bin="${install_dir}/n8n-manager"
    if [ -x "$installed_bin" ]; then
        echo ""
        "$installed_bin" 2>/dev/null || true
    fi
}

main "$@"

#!/usr/bin/env bash
# n8n-manager.sh — backward-compat shim for scripts hardcoded to 'n8n-manager.sh'
# This file is NOT the v5 binary. It locates and executes 'n8n-manager' from PATH.
# PATH determines which binary runs — secure your PATH environment accordingly.
# See https://i.nskha.com/install.sh for installation instructions.
set -Eeuo pipefail
IFS=$'\n\t'

# ─── One-time deprecation banner ─────────────────────────────────────────────
_sentinel="${XDG_DATA_HOME:-$HOME/.local/share}/n8n-manager/.banner-shown"

_bin_name="n8n-manager"
if [ ! -f "$_sentinel" ]; then
    printf 'i n8n-manager.sh is now a thin compat shim \xe2\x80\x94 switch your scripts to use %s directly.\n' "$_bin_name" >&2
    printf '  This message appears only once. See https://i.nskha.com/install.sh for v5 install info.\n' >&2
    mkdir -p "$(dirname "$_sentinel")" 2>/dev/null || true
    touch "$_sentinel" 2>/dev/null || true
fi

# ─── Locate v5 binary ────────────────────────────────────────────────────────
_v5_bin=$(command -v n8n-manager 2>/dev/null || true)

if [ -z "$_v5_bin" ]; then
    printf 'ERROR: n8n-manager binary not found. Run: curl -sSf https://i.nskha.com/install.sh | bash\n' >&2
    exit 127
fi

# ─── Hand off to the real binary ─────────────────────────────────────────────
exec "$_v5_bin" "$@"

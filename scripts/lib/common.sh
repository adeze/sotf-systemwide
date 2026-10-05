#!/usr/bin/env bash
# Shared helpers for SOTF build / release scripts.
# Source this file from a script in scripts/ to avoid duplicating common
# boilerplate.

# Print the absolute path to the project root.
# Uses the script that sourced this library as the anchor.
sotf_project_root() {
    local caller_script="${BASH_SOURCE[1]}"
    local script_dir
    script_dir="$(cd "$(dirname "$caller_script")" && pwd)"
    echo "$(cd "$script_dir/.." && pwd)"
}

# Extract the workspace version from the root Cargo.toml.
# Optional argument: path to project root (defaults to sotf_project_root).
sotf_version() {
    local root="${1:-$(sotf_project_root)}"
    grep -m1 '^version = ' "$root/Cargo.toml" | sed -E 's/version = "(.*)"/\1/'
}

# Derive the distribution architecture from every required payload executable.
# All payloads must have the same supported slice set; a mixed bundle cannot
# advertise a platform on which one of its required components will not run.
sotf_payload_architecture() {
    if [ "$#" -eq 0 ]; then
        echo "No payload executables supplied for architecture inspection" >&2
        return 1
    fi
    local executable slices normalized architecture expected=""
    for executable in "$@"; do
        if [ ! -x "$executable" ]; then
            echo "Payload executable is missing or not executable: $executable" >&2
            return 1
        fi
        if ! slices=$(/usr/bin/lipo -archs "$executable"); then
            echo "Cannot inspect payload architecture: $executable" >&2
            return 1
        fi
        normalized=$(printf '%s\n' "$slices" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort | paste -sd ' ' -)
        case "$normalized" in
            arm64) architecture="arm64" ;;
            x86_64) architecture="x86_64" ;;
            "arm64 x86_64") architecture="universal" ;;
            *)
                echo "Unsupported payload architecture '$normalized': $executable" >&2
                return 1
                ;;
        esac
        if [ -n "$expected" ] && [ "$expected" != "$architecture" ]; then
            echo "Payload architectures do not match: $executable is $architecture, expected $expected" >&2
            return 1
        fi
        expected="$architecture"
    done
    printf '%s\n' "$expected"
}

# Color codes
SOTF_RED='\033[0;31m'
SOTF_GREEN='\033[0;32m'
SOTF_YELLOW='\033[1;33m'
SOTF_BLUE='\033[0;34m'
SOTF_CYAN='\033[0;36m'
SOTF_BOLD='\033[1m'
SOTF_NC='\033[0m'

sotf_log_info()    { echo -e "${SOTF_BLUE}[INFO]${SOTF_NC} $1"; }
sotf_log_success() { echo -e "${SOTF_GREEN}[OK]${SOTF_NC} $1"; }
sotf_log_warning() { echo -e "${SOTF_YELLOW}[WARN]${SOTF_NC} $1"; }
sotf_log_error()   { echo -e "${SOTF_RED}[ERROR]${SOTF_NC} $1"; }

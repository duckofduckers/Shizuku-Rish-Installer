#!/bin/bash

set -Eeuo pipefail
shopt -s inherit_errexit

exec 3>&1 4>&2

DEBUG=0 # dev purposes only

RED='\033[1;31m'
GREEN='\033[1;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
X='\033[0m'

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOCK_DIR="${TMPDIR:-/tmp}/${SCRIPT_NAME}.lock"
SILENT=0
echo_info()    { if [[ $SILENT -eq 0 ]]; then echo -e "${BLUE}[*] $*${X}" >&3; fi; }
echo_warn()    { if [[ $SILENT -eq 0 ]]; then echo -e "${YELLOW}[-] $*${X}" >&3; fi; }
echo_success() { if [[ $SILENT -eq 0 ]]; then echo -e "${GREEN}[+] $*${X}" >&3; fi; }
echo_error()   { echo -e "${RED}[!] $*${X}" >&4; }

safe_run() {
    local msg="${1:-command failed}"
    shift
    if ! "$@" >/dev/null 2>&1; then
        echo_error "$msg (command: $*)"
        exit 1
    fi
}

_cleanup_common() {
    local exit_code="${1:-0}"
    if [[ -n "${TEMP_DIR:-}" ]] && [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    if [[ -d "$LOCK_DIR" ]]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    exit "$exit_code"
}

cleanup_exit() { _cleanup_common "${?}"; }
cleanup_int()  { _cleanup_common 130; }
cleanup_term() { _cleanup_common 143; }
cleanup_hup()  { _cleanup_common 129; }

trap cleanup_exit EXIT
trap cleanup_int INT
trap cleanup_term TERM
trap cleanup_hup HUP
trap '' TSTP

acquire_lock() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo_error "Another instance is already running."
        exit 1
    fi
}

validate_disk_space() {
    local required_mb=10
    local avail_kb
    if [[ -d "$HOME" ]]; then
        avail_kb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
        if [[ -n "${avail_kb:-}" ]] && (( avail_kb < required_mb * 1024 )); then
            echo_error "Insufficient disk space (need ${required_mb}MB)."
            exit 1
        fi
    fi
}

PackageManager::download_apk() {
    local mode="${1:-}"
    local dest="${2:-}"
    local obtained=false
    local shizuku_path=""
    local api_url=""
    local apk_url=""

    if [[ "$mode" == "online" ]]; then
        echo_warn "Downloading Shizuku APK from GitHub..."
        api_url="https://api.github.com/repos/RikkaApps/Shizuku/releases/latest"
        if [[ $DEBUG -eq 1 ]]; then
            apk_url=$(curl -fsSL "$api_url" | grep -o '"browser_download_url": *"[^"]*\.apk"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/') || true
        else
            apk_url=$(curl -fsSL "$api_url" 2>/dev/null | grep -o '"browser_download_url": *"[^"]*\.apk"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/') || true
        fi
        if [[ -z "${apk_url:-}" ]]; then
            echo_error "Shizuku APK downloaded unsuccessfully"
            exit 1
        fi
        safe_run "Shizuku APK downloaded unsuccessfully" curl -fsSL -o "$dest" "$apk_url"
        obtained=true
    elif [[ "$mode" == "offline" ]]; then
        if command -v cmd >/dev/null 2>&1; then
            shizuku_path=$(cmd package path moe.shizuku.privileged.api --user 0 2>/dev/null | grep -oE 'package:(.*)' | sed 's/package://') || shizuku_path=""
        fi
        if [[ -z "$shizuku_path" || ! -f "$shizuku_path" ]]; then
            echo_error "Shizuku not found locally"
            exit 1
        fi
        echo_warn "Shizuku found locally, copying APK..."
        safe_run "Failed to copy Shizuku APK" cp "$shizuku_path" "$dest"
        obtained=true
    else
        if command -v cmd >/dev/null 2>&1; then
            shizuku_path=$(cmd package path moe.shizuku.privileged.api --user 0 2>/dev/null | grep -oE 'package:(.*)' | sed 's/package://') || shizuku_path=""
        fi
        if [[ -n "$shizuku_path" && -f "$shizuku_path" ]]; then
            echo_warn "Shizuku found locally, copying APK..."
            if cp "$shizuku_path" "$dest" 2>/dev/null; then
                echo_success "Shizuku APK copied from local installation"
                obtained=true
            else
                echo_error "Failed to copy Shizuku APK, falling back to download"
            fi
        fi
        if [[ "$obtained" == false ]]; then
            echo_warn "Downloading Shizuku APK from GitHub..."
            api_url="https://api.github.com/repos/RikkaApps/Shizuku/releases/latest"
            if [[ $DEBUG -eq 1 ]]; then
                apk_url=$(curl -fsSL "$api_url" | grep -o '"browser_download_url": *"[^"]*\.apk"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/') || true
            else
                apk_url=$(curl -fsSL "$api_url" 2>/dev/null | grep -o '"browser_download_url": *"[^"]*\.apk"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/') || true
            fi
            if [[ -z "${apk_url:-}" ]]; then
                echo_error "Shizuku APK downloaded unsuccessfully"
                exit 1
            fi
            safe_run "Shizuku APK downloaded unsuccessfully" curl -fsSL -o "$dest" "$apk_url"
            echo_success "Shizuku APK downloaded successfully"
            obtained=true
        fi
    fi

    if [[ "$obtained" != true ]]; then
        exit 1
    fi
    if [[ ! -s "$dest" ]]; then
        echo_error "Downloaded APK is empty"
        exit 1
    fi
}

PackageManager::install() {
    acquire_lock
    validate_disk_space

    local both_exist=true
    local NAME
    for NAME in rish rish_shizuku.dex; do
        if [[ -f "$BIN/$NAME" ]]; then
            echo_warn "$NAME found"
        else
            both_exist=false
            break
        fi
    done

    if [[ "$both_exist" == true ]]; then
        echo_error "rish files already exist"
        exit 1
    fi

    echo_warn "Creating temporary directory..."
    TEMP_DIR=$(mktemp -d) || { echo_error "Failed to create temporary directory"; exit 1; }
    echo_success "Temporary directory created: $TEMP_DIR"

    for NAME in rish rish_shizuku.dex; do
        if [[ -f "$BIN/$NAME" ]]; then
            echo_warn "Removing existing $NAME..."
            if rm -f "$BIN/$NAME"; then
                echo_success "$NAME removed successfully"
            else
                echo_error "Failed to remove $NAME"
                exit 1
            fi
        fi
    done

    local APK_FILE="$TEMP_DIR/Shizuku.apk"
    PackageManager::download_apk "$SUBFLAG" "$APK_FILE"

    local EXTRACT_FAILED=false
    for NAME in rish rish_shizuku.dex; do
        echo_warn "Extracting $NAME"
        if ! unzip -p "$APK_FILE" "assets/$NAME" > "$TEMP_DIR/$NAME" 2>/dev/null; then
            echo_error "$NAME extracted unsuccessfully"
            EXTRACT_FAILED=true
            break
        else
            echo_success "$NAME extracted successfully"
        fi
    done
    if [[ "$EXTRACT_FAILED" == true ]]; then
        exit 1
    fi

    local PKG_NAME="${BIN#/data/data/}"
    PKG_NAME="${PKG_NAME%%/*}"
    echo_warn "Detected package name: $PKG_NAME"

    echo_warn "Patching rish with package name..."
    if ! sed -i "s/RISH_APPLICATION_ID=\"PKG\"/RISH_APPLICATION_ID=\"${PKG_NAME}\"/" "$TEMP_DIR/rish"; then
        echo_error "rish patched unsuccessfully"
        exit 1
    else
        echo_success "rish patched successfully"
    fi

    echo_warn "Setting executable permissions on rish..."
    safe_run "Failed to set executable permissions on rish" chmod +x "$TEMP_DIR/rish"
    echo_success "Executable permissions set"

    for NAME in rish rish_shizuku.dex; do
        echo_warn "Moving $NAME to $BIN..."
        safe_run "Failed to move $NAME to $BIN" mv "$TEMP_DIR/$NAME" "$BIN/"
        echo_success "$NAME moved successfully"
    done

    echo_warn "Cleaning up temporary directory..."
    rm -rf "$TEMP_DIR"
    echo_success "Temporary directory removed"
}

PackageManager::uninstall() {
    local ANY_DELETED=false
    local NAME
    for NAME in rish rish_shizuku.dex; do
        local FILEPATH="$BIN/$NAME"
        if [[ -f "$FILEPATH" ]]; then
            echo_warn "Uninstalling $NAME..."
            if rm -f "$FILEPATH"; then
                echo_success "$NAME uninstalled successfully"
                ANY_DELETED=true
            else
                echo_error "Failed to remove $NAME"
                exit 1
            fi
        else
            echo_warn "$NAME not found"
        fi
    done
    if [[ "$ANY_DELETED" == false ]]; then
        echo_error "No rish files found"
        exit 1
    fi
}

PackageManager::main() {
    [ -z "${BASH_VERSION:-}" ] && echo_error "This script must be run with bash" && exit 1
    [ -z "${TERMUX_VERSION:-}" ] && echo_error "This script must be ran in Termux" && exit 1

    if [ "$(id -u)" -eq 0 ]; then
        echo_error "This script cannot be run as root"
        exit 1
    fi

    if [[ $# -eq 0 ]]; then
        echo_info "Usage: -install[:online|:offline][:silent]|-reinstall[:online|:offline][:silent]|-uninstall[:silent]"
        exit 1
    elif [[ $# -gt 1 ]]; then
        echo_error "Only one parameter is allowed"
        exit 1
    fi

    local BIN
    if cmd_path=$(command -v sh) && [ -n "$cmd_path" ]; then
        BIN=$(dirname "$cmd_path")
    else
        BIN="${PREFIX}/bin"
        if [ ! -d "$BIN" ]; then
            echo_error "BIN directory could not be found, you have a weird ass environment"
            exit 1
        fi
    fi

    local tool
    for tool in mktemp curl unzip sed chmod mv rm; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo_error "Required tool '$tool' is not available"
            exit 1
        fi
    done

    local ARG="${1:-}"
    ARG="${ARG,,}"
    local MODE=""
    local SUBFLAGS=()
    if [[ "$ARG" =~ ^-(install|reinstall|uninstall)((:[a-z]+)*)$ ]]; then
        MODE="-${BASH_REMATCH[1]}"
        local SUBFLAG_RAW="${BASH_REMATCH[2]}"
        if [[ -n "$SUBFLAG_RAW" ]]; then
            IFS=':' read -ra SUBFLAGS <<< "${SUBFLAG_RAW:1}"
        fi
    else
        echo_error "Invalid parameter"
        exit 1
    fi

    SILENT=0
    local HAS_ONLINE=0
    local HAS_OFFLINE=0
    SUBFLAG=""
    local sf
    for sf in "${SUBFLAGS[@]}"; do
        case "$sf" in
            online) SUBFLAG="online"; HAS_ONLINE=1 ;;
            offline) SUBFLAG="offline"; HAS_OFFLINE=1 ;;
            silent) SILENT=1 ;;
            *) echo_error "Invalid subflag: $sf"; exit 1 ;;
        esac
    done

    if [[ "$MODE" == "-uninstall" && ( $HAS_ONLINE -eq 1 || $HAS_OFFLINE -eq 1 ) ]]; then
        echo_error "Invalid subflag for uninstall mode"
        exit 1
    fi

    if [[ $HAS_ONLINE -eq 1 && $HAS_OFFLINE -eq 1 ]]; then
        echo_error "Cannot use both online and offline subflags together"
        exit 1
    fi

    local ANY_FOUND
    local NAME
    if [[ "$MODE" == "-reinstall" ]]; then
        ANY_FOUND=false
        for NAME in rish rish_shizuku.dex; do
            local FILEPATH="$BIN/$NAME"
            if [[ -f "$FILEPATH" ]]; then
                echo_warn "Uninstalling $NAME..."
                if rm -f "$FILEPATH"; then
                    echo_success "$NAME uninstalled successfully"
                    ANY_FOUND=true
                else
                    echo_error "Failed to uninstall $NAME"
                    exit 1
                fi
            else
                echo_warn "$NAME not found"
            fi
        done
        if [[ "$ANY_FOUND" == false ]]; then
            echo_warn "No rish files found"
        fi
        MODE="-install"
    fi

    if [[ "$MODE" == "-install" ]]; then
        PackageManager::install
    elif [[ "$MODE" == "-uninstall" ]]; then
        PackageManager::uninstall
    fi
}

PackageManager::main "$@"

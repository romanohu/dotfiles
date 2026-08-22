#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DOT_DIR=$(CDPATH= cd -P -- "$SOURCE_DIR" && pwd -P)
if [ "${DOTFILES_TARGET_HOME+x}" = x ]; then
    TARGET_HOME_INPUT="$DOTFILES_TARGET_HOME"
else
    TARGET_HOME_INPUT="$HOME"
fi
TARGET_HOME="$TARGET_HOME_INPUT"
MISE_VERSION="2026.8.9"
MISE_INSTALLER_URL="https://github.com/jdx/mise/releases/download/v2026.8.9/install.sh"
MISE_INSTALLER_SHA256="0947cf3dd1eb5d734676a554b4bb8298f8557ffc706f5ed5637e9e68e1218403"
MISE_BIN="$TARGET_HOME/.local/bin/mise"
TARGET_HOME_RESOLVED=0
VERIFIED_INSTALLER_SOURCE_SUBSHELL="${BASH_SUBSHELL:-0}"

log() { printf '[dotfiles] %s\n' "$1"; }
warn() { printf '[dotfiles][warn] %s\n' "$1" >&2; }
fail() { printf '[dotfiles][error] %s\n' "$1" >&2; exit 1; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

resolve_target_home() {
    local normalized="$TARGET_HOME_INPUT"
    local physical_home

    [ "${TARGET_HOME_RESOLVED:-0}" -eq 0 ] || return 0
    [ -n "$normalized" ] || {
        warn 'Target home must not be empty.'
        return 1
    }
    case "$normalized" in
        /*) ;;
        *)
            warn "Target home must be an absolute path: $normalized"
            return 1
            ;;
    esac
    while [ "$normalized" != / ] && [ "${normalized%/}" != "$normalized" ]; do
        normalized="${normalized%/}"
    done
    if [ -L "$normalized" ]; then
        warn "Target home must not be a symbolic link: $normalized"
        return 1
    fi
    if [ ! -d "$normalized" ]; then
        warn "Target home directory is unavailable: $normalized"
        return 1
    fi
    physical_home=$(CDPATH= cd -P -- "$normalized" 2>/dev/null && pwd -P) || {
        warn "Cannot resolve physical target home: $normalized"
        return 1
    }
    case "$physical_home" in
        /*) ;;
        *)
            warn "Resolved target home is not absolute: $physical_home"
            return 1
            ;;
    esac

    TARGET_HOME="$physical_home"
    MISE_BIN="$TARGET_HOME/.local/bin/mise"
    TARGET_HOME_RESOLVED=1
}

preflight_required_commands() {
    local required
    for required in bash curl git tar zsh; do
        has_cmd "$required" || fail "Required command not found: $required. Install it and rerun."
    done
    if ! has_cmd sha256sum && ! has_cmd shasum; then
        fail 'Required SHA-256 tool not found. Install sha256sum or shasum and rerun.'
    fi
}

sha256_file() {
    local file="$1"
    local output

    case "$file" in
        -*)
            warn "Refusing option-like SHA-256 path: $file"
            return 1
            ;;
    esac
    if [ ! -f "$file" ] || [ -L "$file" ]; then
        warn "Cannot calculate SHA-256 for a non-regular or symlinked file: $file"
        return 1
    fi
    if has_cmd sha256sum; then
        output="$(sha256sum -- "$file")" || return 1
    elif has_cmd shasum; then
        output="$(shasum -a 256 -- "$file")" || return 1
    else
        warn 'Cannot calculate SHA-256: neither sha256sum nor shasum is available.'
        return 1
    fi
    printf '%s\n' "${output%% *}"
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual

    if [ "${#expected}" -ne 64 ]; then
        warn "Invalid expected SHA-256 for $file."
        return 1
    fi
    case "$expected" in
        *[!0-9a-f]*)
            warn "Invalid expected SHA-256 for $file."
            return 1
            ;;
    esac

    actual="$(sha256_file "$file")" || return 1
    if [ "$actual" != "$expected" ]; then
        warn "SHA-256 verification failed for $file."
        return 1
    fi
}

run_verified_installer() {
    if [ "${BASH_SUBSHELL:-0}" -le "$VERIFIED_INSTALLER_SOURCE_SUBSHELL" ]; then
        (run_verified_installer "$@")
        return
    fi

    local url="$1"
    local expected_sha256="$2"
    local temp_dir=''
    local installer_path
    local active_child_pid=''
    local status=0
    local cleanup_status=0

    cleanup_verified_installer() {
        [ -n "$temp_dir" ] || return 0
        rm -rf -- "$temp_dir"
    }

    handle_verified_installer_signal() {
        local signal_name="$1"
        local signal_status="$2"

        if [ -n "$active_child_pid" ]; then
            kill -s "$signal_name" "$active_child_pid" 2>/dev/null || :
            wait "$active_child_pid" 2>/dev/null || :
            active_child_pid=''
        fi
        cleanup_verified_installer || :
        trap - EXIT HUP INT TERM
        exit "$signal_status"
    }

    case "$url" in
        https://*) ;;
        *)
            warn "Refusing non-HTTPS installer URL: $url"
            return 1
            ;;
    esac

    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-mise-installer.XXXXXX")" || return 1
    trap cleanup_verified_installer EXIT
    trap 'handle_verified_installer_signal HUP 129' HUP
    trap 'handle_verified_installer_signal INT 130' INT
    trap 'handle_verified_installer_signal TERM 143' TERM

    installer_path="$temp_dir/install.sh"
    curl --fail --location --silent --show-error --output "$installer_path" "$url" &
    active_child_pid=$!
    if wait "$active_child_pid"; then
        status=0
    else
        status=$?
    fi
    active_child_pid=''
    if [ "$status" -eq 0 ] && { [ ! -f "$installer_path" ] || [ -L "$installer_path" ]; }; then
        warn "Downloaded installer is not a regular file: $installer_path"
        status=1
    fi
    if [ "$status" -eq 0 ]; then
        if verify_sha256 "$installer_path" "$expected_sha256"; then
            status=0
        else
            status=$?
        fi
    fi
    if [ "$status" -eq 0 ]; then
        HOME="$TARGET_HOME" MISE_INSTALL_PATH="$MISE_BIN" bash "$installer_path" &
        active_child_pid=$!
        if wait "$active_child_pid"; then
            status=0
        else
            status=$?
        fi
        active_child_pid=''
    fi

    if cleanup_verified_installer; then
        cleanup_status=0
    else
        cleanup_status=$?
    fi
    trap - EXIT HUP INT TERM
    if [ "$status" -eq 0 ] && [ "$cleanup_status" -ne 0 ]; then
        status="$cleanup_status"
    fi
    return "$status"
}

validate_mise_install_destination() {
    local parent="${MISE_BIN%/*}"

    resolve_target_home || return 1
    parent="${MISE_BIN%/*}"

    case "$MISE_BIN" in
        "$TARGET_HOME"/*) ;;
        *)
            warn "Refusing mise destination outside target home: $MISE_BIN"
            return 1
            ;;
    esac

    while [ "$parent" != "$TARGET_HOME" ]; do
        case "$parent" in
            "$TARGET_HOME"/*) ;;
            *)
                warn "Refusing ambiguous mise destination: $MISE_BIN"
                return 1
                ;;
        esac
        if [ -L "$parent" ]; then
            warn "Refusing mise destination below symlinked parent: $parent"
            return 1
        fi
        if [ -e "$parent" ] && [ ! -d "$parent" ]; then
            warn "Refusing mise destination below non-directory parent: $parent"
            return 1
        fi
        parent="${parent%/*}"
    done
    if [ -L "$MISE_BIN" ]; then
        warn "Refusing symlinked mise destination: $MISE_BIN"
        return 1
    fi
    if [ -e "$MISE_BIN" ] && [ ! -f "$MISE_BIN" ]; then
        warn "Refusing non-file mise destination: $MISE_BIN"
        return 1
    fi
}

install_mise_if_needed() {
    local installed_version=''
    validate_mise_install_destination || return 1
    if [ -x "$MISE_BIN" ]; then
        installed_version=$(HOME="$TARGET_HOME" "$MISE_BIN" --version 2>/dev/null | awk 'NR == 1 { print $1 }')
    fi
    if [ "$installed_version" != "$MISE_VERSION" ]; then
        mkdir -p "$TARGET_HOME/.local/bin" || return 1
        HOME="$TARGET_HOME" MISE_INSTALL_PATH="$MISE_BIN" \
            run_verified_installer "$MISE_INSTALLER_URL" "$MISE_INSTALLER_SHA256" || return 1
    fi
    installed_version=$(HOME="$TARGET_HOME" "$MISE_BIN" --version 2>/dev/null | awk 'NR == 1 { print $1 }')
    [ "$installed_version" = "$MISE_VERSION" ] || \
        fail "mise version mismatch: expected $MISE_VERSION, got ${installed_version:-unknown}."
}

validate_managed_dotfile_target() {
    local target="$1"
    local expected_source="$2"
    local parent="${target%/*}"
    local actual_source

    case "$target" in
        "$TARGET_HOME"/*) ;;
        *)
            warn "Refusing managed target outside target home: $target"
            return 1
            ;;
    esac
    while [ "$parent" != "$TARGET_HOME" ]; do
        case "$parent" in
            "$TARGET_HOME"/*) ;;
            *)
                warn "Refusing ambiguous managed target: $target"
                return 1
                ;;
        esac
        if [ -L "$parent" ]; then
            warn "Refusing managed target below symlinked ancestor: $parent"
            return 1
        fi
        if [ -e "$parent" ] && [ ! -d "$parent" ]; then
            warn "Refusing managed target below non-directory ancestor: $parent"
            return 1
        fi
        parent="${parent%/*}"
    done

    if [ -L "$target" ]; then
        actual_source=$(readlink "$target") || return 1
        if [ "$actual_source" != "$expected_source" ]; then
            warn "Refusing unrelated managed-target symlink: $target"
            return 1
        fi
        return 0
    fi
    if [ -e "$target" ]; then
        warn "Refusing unmanaged managed target: $target"
        return 1
    fi
}

vscode_user_dir_for_platform() {
    local platform="$1"

    case "$platform" in
        Darwin) printf '%s\n' "$TARGET_HOME/Library/Application Support/Code/User" ;;
        Linux) printf '%s\n' "$TARGET_HOME/.config/Code/User" ;;
        *)
            warn "Unsupported VS Code platform: $platform"
            return 1
            ;;
    esac
}

vscode_settings_target_for_platform() {
    local user_dir

    user_dir="$(vscode_user_dir_for_platform "$1")" || return 1
    printf '%s/settings.json\n' "$user_dir"
}

preflight_vscode_settings() {
    local platform="${1:-$(uname -s)}"
    local announce="${2:-announce}"
    local user_dir
    local target

    case "$announce" in
        announce|quiet) ;;
        *)
            warn "Invalid VS Code settings preflight output mode: $announce"
            return 1
            ;;
    esac
    user_dir="$(vscode_user_dir_for_platform "$platform")" || return 1
    target="$user_dir/settings.json"
    validate_managed_dotfile_target \
        "$target" "$DOT_DIR/.config/vscode/settings.json" || return 1
    if [ ! -d "$user_dir" ]; then
        [ ! -e "$user_dir" ] && [ ! -L "$user_dir" ] || {
            warn "Refusing VS Code settings path that is not a directory: $user_dir"
            return 1
        }
        [ "$announce" = quiet ] || \
            log 'VS Code settings: skipped (User directory is absent)'
    fi
}

setup_vscode_settings() {
    local platform="${1:-$(uname -s)}"
    local user_dir
    local target
    local source="$DOT_DIR/.config/vscode/settings.json"

    preflight_vscode_settings "$platform" quiet || return 1
    user_dir="$(vscode_user_dir_for_platform "$platform")" || return 1
    [ -d "$user_dir" ] || return 0
    target="$user_dir/settings.json"
    [ -L "$target" ] && {
        log "VS Code settings: already linked $target"
        return 0
    }
    ln -s "$source" "$target" || return 1
    log "VS Code settings: linked $target"
}

preflight_managed_dotfiles() {
    resolve_target_home || return 1
    validate_managed_dotfile_target \
        "$TARGET_HOME/.config/mise/config.toml" "$DOT_DIR/mise.toml" || return 1
    validate_managed_dotfile_target \
        "$TARGET_HOME/.config/mise/mise.lock" "$DOT_DIR/mise.lock" || return 1
    validate_managed_dotfile_target \
        "$TARGET_HOME/.zshenv" "$DOT_DIR/.zshenv" || return 1
    validate_managed_dotfile_target \
        "$TARGET_HOME/.config/git" "$DOT_DIR/.config/git" || return 1
    validate_managed_dotfile_target \
        "$TARGET_HOME/.config/herdr" "$DOT_DIR/.config/herdr" || return 1
    validate_managed_dotfile_target \
        "$TARGET_HOME/.config/zsh/.zshrc" "$DOT_DIR/.config/zsh/.zshrc" || return 1
    validate_managed_dotfile_target \
        "$TARGET_HOME/.config/zsh/aliases.zsh" "$DOT_DIR/.config/zsh/aliases.zsh" || return 1
    validate_managed_dotfile_target \
        "$TARGET_HOME/.config/wezterm/wezterm.lua" \
        "$DOT_DIR/.config/wezterm/wezterm.lua" || return 1
    validate_managed_dotfile_target \
        "$TARGET_HOME/.config/opencode/opencode.jsonc" \
        "$DOT_DIR/.config/opencode/opencode.jsonc" || return 1
    validate_managed_dotfile_target \
        "$TARGET_HOME/.config/opencode/tui.json" \
        "$DOT_DIR/.config/opencode/tui.json" || return 1
    validate_managed_dotfile_target \
        "$TARGET_HOME/.codex/AGENTS.md" "$DOT_DIR/.codex/AGENTS.md" || return 1
    validate_managed_dotfile_target \
        "$TARGET_HOME/.claude/CLAUDE.md" "$DOT_DIR/.claude/CLAUDE.md" || return 1
    preflight_vscode_settings || return 1
}

remove_exact_managed_link() {
    local link_path="$1"
    local parent
    local actual_target
    local expected_target
    shift

    case "$link_path" in
        "$TARGET_HOME"/*) ;;
        *)
            warn "Refusing legacy link outside target home: $link_path"
            return 1
            ;;
    esac

    parent="${link_path%/*}"
    while [ "$parent" != "$TARGET_HOME" ]; do
        case "$parent" in
            "$TARGET_HOME"/*) ;;
            *)
                warn "Refusing ambiguous legacy link path: $link_path"
                return 1
                ;;
        esac
        if [ -L "$parent" ]; then
            warn "Refusing legacy link below symlinked parent: $parent"
            return 1
        fi
        parent="${parent%/*}"
    done

    [ -L "$link_path" ] || return 0
    actual_target="$(readlink "$link_path")" || return 1
    for expected_target in "$@"; do
        if [ "$actual_target" = "$expected_target" ]; then
            rm -f -- "$link_path" || return 1
            log "Removed legacy managed link: $link_path"
            return 0
        fi
    done
}

cleanup_legacy_managed_links() {
    remove_exact_managed_link \
        "$TARGET_HOME/.local/bin/ha" "$DOT_DIR/bin/ha" || return 1
    remove_exact_managed_link \
        "$TARGET_HOME/.config/devbox" "$DOT_DIR/.config/devbox" || return 1
    remove_exact_managed_link \
        "$TARGET_HOME/.local/share/devbox/global/default" \
        "$TARGET_HOME/.config/devbox/global" \
        "$DOT_DIR/.config/devbox/global" || return 1
    remove_exact_managed_link \
        "$TARGET_HOME/.config/nvim" "$DOT_DIR/.config/nvim" || return 1
    remove_exact_managed_link \
        "$TARGET_HOME/.config/zsh/pet.zsh" \
        "$DOT_DIR/.config/zsh/pet.zsh" || return 1
}

run_mise_bootstrap() {
    resolve_target_home || return 1
    HOME="$TARGET_HOME" MISE_GLOBAL_CONFIG_FILE="$DOT_DIR/mise.toml" \
        "$MISE_BIN" trust --yes "$DOT_DIR/mise.toml"
    HOME="$TARGET_HOME" MISE_GLOBAL_CONFIG_FILE="$DOT_DIR/mise.toml" \
        "$MISE_BIN" -C "$DOT_DIR" --locked bootstrap --yes
}

validate_environment() {
    [ -d "$SOURCE_DIR" ] || fail "Dotfiles source directory is unavailable: $SOURCE_DIR"
    [ -d "$DOT_DIR" ] || fail "Physical dotfiles directory is unavailable: $DOT_DIR"
    [ -f "$DOT_DIR/mise.toml" ] || fail "Root mise configuration is unavailable: $DOT_DIR/mise.toml"
    [ -f "$DOT_DIR/.config/vscode/settings.json" ] || \
        fail "VS Code settings are unavailable: $DOT_DIR/.config/vscode/settings.json"
    resolve_target_home || fail "Invalid target home: $TARGET_HOME_INPUT"

    case "$(uname -s)" in
        Darwin|Linux) ;;
        *) fail 'Only macOS and Linux are supported.' ;;
    esac
}

main() {
    preflight_required_commands
    validate_environment
    preflight_managed_dotfiles || return 1
    install_mise_if_needed || return 1
    cleanup_legacy_managed_links || return 1
    run_mise_bootstrap || return 1
    setup_vscode_settings || return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

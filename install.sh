#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DOT_DIR=$(CDPATH= cd -P -- "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)
DOTFILES_SOURCE_ROOT="${DOTFILES_SOURCE_DIR:-$SCRIPT_DOT_DIR}"
if ! DOT_DIR=$(CDPATH= cd -P -- "$DOTFILES_SOURCE_ROOT" 2>/dev/null && pwd -P); then
    printf '[dotfiles][error] Dotfiles source directory is unavailable: %s\n' \
        "$DOTFILES_SOURCE_ROOT" >&2
    return 1 2>/dev/null || exit 1
fi
TARGET_HOME="${DOTFILES_TARGET_HOME:-$HOME}"
DEVBOX_DATA_DIR="${DEVBOX_DATA_DIR:-$TARGET_HOME/.local/share/devbox}"
DEVBOX_GLOBAL_CONFIG="$TARGET_HOME/.config/devbox/global"
ZSH_HOME_DIR="$TARGET_HOME/.config/zsh"
NIX_DAEMON_PROFILE="/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
NIX_USER_PROFILE="$TARGET_HOME/.nix-profile/etc/profile.d/nix.sh"
BACKUP_DIR="$TARGET_HOME/.dotfiles-backup"
BACKUP_RUN_DIR=""
NIX_INSTALLER_URL="https://install.determinate.systems/nix/tag/v3.21.2/nix-installer.sh"
NIX_INSTALLER_SHA256="4141f93485a16d600b995d02b2bdd296fb69af30ea3665037677b8d56f703b56"
DEVBOX_VERSION="0.17.3"
DEVBOX_FLAKE="github:jetify-com/devbox/0.17.3"
OH_MY_ZSH_COMMIT="677a4592b18c08ddea737f8aca70bac0e9fc9313"
ZSH_AUTOSUGGESTIONS_COMMIT="85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5"
ZSH_SYNTAX_HIGHLIGHTING_COMMIT="1d85c692615a25fe2293bdd44b34c217d5d2bf04"

log() { printf '[dotfiles] %s\n' "$1"; }
warn() { printf '[dotfiles][warn] %s\n' "$1"; }
fail() { printf '[dotfiles][error] %s\n' "$1" >&2; exit 1; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

preflight_required_commands() {
    local required
    local missing=0

    for required in bash curl git; do
        if ! has_cmd "$required"; then
            printf "[dotfiles][error] Required command not found: %s. Install it and rerun.\n" \
                "$required" >&2
            missing=1
        fi
    done
    if ! has_cmd sha256sum && ! has_cmd shasum; then
        printf '%s\n' \
            '[dotfiles][error] Required SHA-256 tool not found. Install sha256sum or shasum and rerun.' >&2
        missing=1
    fi

    [ "$missing" -eq 0 ] || return 1
}

sha256_file() {
    local file="$1"
    local output

    if [ ! -f "$file" ] || [ -L "$file" ]; then
        warn "Cannot calculate SHA-256 for a non-regular or symlinked file: $file"
        return 1
    fi
    if has_cmd sha256sum; then
        output="$(sha256sum -- "$file")" || return 1
    elif has_cmd shasum; then
        output="$(shasum -a 256 -- "$file")" || return 1
    else
        warn "Cannot calculate SHA-256: neither sha256sum nor shasum is available."
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
    if [ "${#actual}" -ne 64 ]; then
        warn "SHA-256 tool returned an invalid digest for $file."
        return 1
    fi
    case "$actual" in
        *[!0-9a-f]*)
            warn "SHA-256 tool returned an invalid digest for $file."
            return 1
            ;;
    esac
    if [ "$actual" != "$expected" ]; then
        warn "SHA-256 verification failed for $file."
        return 1
    fi
}

installer_owner_token_is_valid() {
    local token="$1"
    local token_parent="${token%/*}"
    local token_name="${token##*/}"

    [ -n "$token" ] || return 1
    [ "$token_parent" = "$temp_root" ] || return 1
    case "$token_name" in
        .dotfiles-nix-installer-owner.*) ;;
        *) return 1 ;;
    esac
    [ -f "$token" ] && [ ! -L "$token" ]
}

installer_marker_proves_ownership() {
    local candidate="$1"
    local marker="$candidate/$installer_owner_marker_name"

    installer_owner_token_is_valid "$installer_owner_token" || return 1
    [ -d "$candidate" ] || return 1
    [ ! -L "$candidate" ] || return 1
    [ -f "$marker" ] || return 1
    [ ! -L "$marker" ] || return 1
    [ "$marker" -ef "$installer_owner_token" ]
}

cleanup_verified_installer_dir() {
    local candidate="$1"
    local candidate_parent="${candidate%/*}"
    local candidate_name="${candidate##*/}"

    [ -n "$candidate" ] || return 0
    if [ "$candidate_parent" != "$temp_root" ]; then
        warn "Refusing to clean unvalidated installer temporary directory: $candidate"
        return 1
    fi
    case "$candidate_name" in
        dotfiles-nix-installer.*) ;;
        *)
            warn "Refusing to clean unvalidated installer temporary directory: $candidate"
            return 1
            ;;
    esac
    [ -e "$candidate" ] || [ -L "$candidate" ] || return 0

    if installer_marker_proves_ownership "$candidate"; then
        rm -rf -- "$candidate" || return 1
    fi
}

cleanup_verified_installer_owner_token() {
    [ -n "${installer_owner_token:-}" ] || return 0
    installer_owner_token_is_valid "$installer_owner_token" || return 0
    rm -f -- "$installer_owner_token" || return 1
}

restore_verified_installer_traps() {
    trap - EXIT HUP INT TERM
    [ -z "$saved_installer_exit_trap" ] || eval "$saved_installer_exit_trap"
    [ -z "$saved_installer_hup_trap" ] || eval "$saved_installer_hup_trap"
    [ -z "$saved_installer_int_trap" ] || eval "$saved_installer_int_trap"
    [ -z "$saved_installer_term_trap" ] || eval "$saved_installer_term_trap"
}

finish_verified_installer() {
    local original_status="$1"
    local cleanup_status=0
    local step_status=0

    if [ -n "${temp_dir:-}" ]; then
        cleanup_verified_installer_dir "$temp_dir" || cleanup_status=$?
    fi
    cleanup_verified_installer_owner_token || step_status=$?
    if [ "$step_status" -ne 0 ] && [ "$cleanup_status" -eq 0 ]; then
        cleanup_status="$step_status"
    fi
    restore_verified_installer_traps
    if [ "$original_status" -eq 0 ] && [ "$cleanup_status" -ne 0 ]; then
        original_status="$cleanup_status"
    fi
    return "$original_status"
}

handle_verified_installer_signal() {
    local signal_name="$1"
    local signal_status="$2"
    local final_status

    if finish_verified_installer "$signal_status"; then
        final_status=0
    else
        final_status=$?
    fi
    operation_signal_status="$final_status"
    sh -c 'kill -s "$1" "$PPID"' sh "$signal_name" 2>/dev/null || :
    return 0
}

cleanup_verified_installer_at_exit() {
    local original_status=$?
    local final_status

    if finish_verified_installer "$original_status"; then
        final_status=0
    else
        final_status=$?
    fi
    exit "$final_status"
}

verified_installer_test_after_traps_installed() {
    return 0
}

run_verified_installer_work() {
    local url="$1"
    local expected_sha256="$2"
    shift 2

    local installer_path
    local status

    case "$url" in
        https://*) ;;
        *)
            warn "Refusing non-HTTPS installer URL: $url"
            return 1
            ;;
    esac
    temp_root="${temp_root%/}"
    [ -n "$temp_root" ] || temp_root="/"
    case "$temp_root" in
        /*) ;;
        *)
            warn "Refusing non-absolute temporary root: $temp_root"
            return 1
            ;;
    esac

    installer_owner_token="$(
        mktemp "$temp_root/.dotfiles-nix-installer-owner.XXXXXX"
    )" || return 1
    chmod 600 "$installer_owner_token" || return $?
    installer_owner_token_name="${installer_owner_token##*/}"
    installer_owner_id="${installer_owner_token_name#.dotfiles-nix-installer-owner.}"
    temp_dir="$temp_root/dotfiles-nix-installer.$installer_owner_id"
    mkdir -m 700 "$temp_dir" || return $?
    ln "$installer_owner_token" "$temp_dir/$installer_owner_marker_name" ||
        return $?
    installer_path="$temp_dir/nix-installer.sh"

    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 \
        --output "$installer_path" "$url" || {
        status=$?
        return "$status"
    }
    if [ "${operation_signal_status:-0}" -ne 0 ]; then
        return "$operation_signal_status"
    fi
    verify_sha256 "$installer_path" "$expected_sha256" || {
        status=$?
        return "$status"
    }
    bash "$installer_path" "$@" || {
        status=$?
        return "$status"
    }
}

run_verified_installer() {
    local temp_root="${TMPDIR:-/tmp}"
    local temp_dir=""
    local installer_owner_token="" installer_owner_token_name=""
    local installer_owner_id=""
    local installer_owner_marker_name=".dotfiles-nix-installer-owner"
    local saved_installer_exit_trap saved_installer_hup_trap
    local saved_installer_int_trap saved_installer_term_trap
    local operation_signal_status=0
    local status=0

    saved_installer_exit_trap="$(trap -p EXIT)"
    saved_installer_hup_trap="$(trap -p HUP)"
    saved_installer_int_trap="$(trap -p INT)"
    saved_installer_term_trap="$(trap -p TERM)"
    trap cleanup_verified_installer_at_exit EXIT
    trap 'handle_verified_installer_signal HUP 129' HUP
    trap 'handle_verified_installer_signal INT 130' INT
    trap 'handle_verified_installer_signal TERM 143' TERM

    verified_installer_test_after_traps_installed || status=$?
    if [ "$operation_signal_status" -ne 0 ]; then
        status="$operation_signal_status"
    elif [ "$status" -eq 0 ]; then
        if run_verified_installer_work "$@"; then
            status=0
        else
            status=$?
        fi
    fi
    if [ "$operation_signal_status" -ne 0 ]; then
        status="$operation_signal_status"
    fi
    if finish_verified_installer "$status"; then
        status=0
    else
        status=$?
    fi
    return "$status"
}

is_lexically_within_target_home() {
    case "$1" in
        "$TARGET_HOME"/*) return 0 ;;
        *) warn "Path is outside TARGET_HOME: $1"; return 1 ;;
    esac
}

ensure_safe_target_parent() {
    local path="$1"
    local relative component current

    is_lexically_within_target_home "$path" || return 1
    relative="${path#"$TARGET_HOME"/}"
    current="$TARGET_HOME"
    while [ -n "$relative" ]; do
        component="${relative%%/*}"
        case "$component" in
            ''|.|..)
                warn "Refusing ambiguous target path component: $path"
                return 1
                ;;
        esac

        if [ "$component" = "$relative" ]; then
            return 0
        fi
        current="$current/$component"
        if [ -L "$current" ]; then
            warn "Refusing symlinked target parent: $current"
            return 1
        fi
        relative="${relative#*/}"
    done

    warn "Refusing empty target path: $path"
    return 1
}

detect_platform() {
    case "$(uname -s)" in
        Darwin*) echo "macOS" ;;
        Linux*) echo "Linux" ;;
        MINGW*|MSYS*|CYGWIN*) echo "Windows" ;;
        *) echo "Unknown" ;;
    esac
}

ensure_common_path() {
    case ":$PATH:" in
        *":$TARGET_HOME/.local/bin:"*) ;;
        *) PATH="$TARGET_HOME/.local/bin:$PATH" ;;
    esac
    case ":$PATH:" in
        *":$TARGET_HOME/.nix-profile/bin:"*) ;;
        *) PATH="$TARGET_HOME/.nix-profile/bin:$PATH" ;;
    esac
    case ":$PATH:" in
        *":/nix/var/nix/profiles/default/bin:"*) ;;
        *) PATH="/nix/var/nix/profiles/default/bin:$PATH" ;;
    esac
    export PATH
}

source_nix_env_if_present() {
    if [ -f "$NIX_DAEMON_PROFILE" ]; then
        # shellcheck disable=SC1090
        . "$NIX_DAEMON_PROFILE" || return 1
    elif [ -f "$NIX_USER_PROFILE" ]; then
        # shellcheck disable=SC1090
        . "$NIX_USER_PROFILE" || return 1
    fi
    ensure_common_path || return 1
}

install_nix_if_needed() {
    if has_cmd nix; then
        log "Nix is already installed. Skipping."
        source_nix_env_if_present || return 1
        return
    fi

    local platform
    platform="$(detect_platform)"
    if [ "$platform" = "Windows" ]; then
        fail "Native Windows is not supported for automatic Nix install. Run this script in Linux, macOS, or WSL."
        return 1
    fi
    log "Installing Nix..."
    run_verified_installer "$NIX_INSTALLER_URL" "$NIX_INSTALLER_SHA256" \
        install --no-confirm || return 1
    source_nix_env_if_present || return 1
    has_cmd nix || {
        fail "Nix installation finished, but 'nix' command is still unavailable."
        return 1
    }
}

parse_devbox_version() {
    local output="$1"
    local major remainder minor patch

    case "$output" in
        ''|*[!0-9.]*)
            return 1
            ;;
    esac

    major="${output%%.*}"
    remainder="${output#*.}"
    [ "$remainder" != "$output" ] || return 1
    minor="${remainder%%.*}"
    patch="${remainder#*.}"
    [ "$patch" != "$remainder" ] || return 1
    case "$patch" in
        ''|*.*) return 1 ;;
    esac
    [ -n "$major" ] || return 1
    [ -n "$minor" ] || return 1

    printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

install_devbox_if_needed() {
    local installed_output installed_version

    ensure_common_path || return 1
    source_nix_env_if_present || return 1
    if has_cmd devbox; then
        if installed_output="$(devbox version 2>/dev/null)"; then
            if installed_version="$(parse_devbox_version "$installed_output")"; then
                if [ "$installed_version" = "$DEVBOX_VERSION" ]; then
                    log "devbox $DEVBOX_VERSION is already installed. Skipping."
                    return 0
                fi
            fi
        fi
        warn "Existing devbox is not exactly version $DEVBOX_VERSION; preserving it."
        return 0
    fi

    has_cmd nix || {
        fail "'nix' is required to install devbox."
        return 1
    }
    log "Installing devbox $DEVBOX_VERSION..."
    nix profile install "$DEVBOX_FLAKE" || return 1
    ensure_common_path || return 1
    source_nix_env_if_present || return 1
    has_cmd devbox || {
        fail "devbox installation finished, but 'devbox' command is still unavailable."
        return 1
    }
    installed_output="$(devbox version 2>/dev/null)" || {
        warn "Installed devbox version could not be read; expected $DEVBOX_VERSION."
        return 1
    }
    installed_version="$(parse_devbox_version "$installed_output")" || {
        warn "Installed devbox version output is malformed; expected $DEVBOX_VERSION."
        return 1
    }
    if [ "$installed_version" != "$DEVBOX_VERSION" ]; then
        warn "Installed devbox is $installed_version; expected $DEVBOX_VERSION."
        return 1
    fi
}

ensure_backup_run_dir() {
    if [ -n "$BACKUP_RUN_DIR" ]; then
        [ -d "$BACKUP_RUN_DIR" ] || {
            warn "Backup run directory is unavailable: $BACKUP_RUN_DIR"
            return 1
        }
        return 0
    fi

    mkdir -p "$BACKUP_DIR" || return 1
    BACKUP_RUN_DIR="$(mktemp -d "$BACKUP_DIR/run.XXXXXX")" || return 1
}

backup_target_if_needed() {
    local target="$1"

    local rel backup_path
    ensure_safe_target_parent "$target" || return 1
    [ -e "$target" ] || [ -L "$target" ] || return 0
    if [ -L "$BACKUP_DIR" ]; then
        warn "Refusing symlinked backup root: $BACKUP_DIR"
        return 1
    fi
    ensure_safe_target_parent "$BACKUP_DIR" || return 1
    rel="${target#"$TARGET_HOME"/}"

    ensure_backup_run_dir || return 1

    backup_path="$BACKUP_RUN_DIR/$rel"
    ensure_safe_target_parent "$backup_path" || return 1
    if [ -e "$backup_path" ] || [ -L "$backup_path" ]; then
        warn "Refusing to overwrite existing backup: $backup_path"
        return 1
    fi
    mkdir -p "$(dirname "$backup_path")" || return 1
    mv "$target" "$backup_path" || return 1
    log "Backed up existing path: $target -> $backup_path"
}

safe_link_or_copy() {
    local src="$1"
    local dst="$2"

    if [ ! -e "$src" ] && [ ! -L "$src" ]; then
        fail "Source path does not exist: $src"
        return 1
    fi
    ensure_safe_target_parent "$dst" || return 1
    mkdir -p "$(dirname "$dst")" || return 1

    if [ -L "$dst" ]; then
        local current
        current="$(readlink "$dst")" || return 1
        if [ "$current" = "$src" ]; then
            log "Already linked: $dst"
            return 0
        fi
    fi

    if [ -e "$dst" ] || [ -L "$dst" ]; then
        backup_target_if_needed "$dst" || return 1
    fi

    if ln -s "$src" "$dst" 2>/dev/null; then
        log "Linked: $dst -> $src"
    else
        cp -R "$src" "$dst" || return 1
        warn "Symlink unavailable, copied instead: $src -> $dst"
    fi
}

prepare_zsh_dir() {
    local repo_zsh_dir="$DOT_DIR/.config/zsh"

    ensure_safe_target_parent "$ZSH_HOME_DIR" || return 1
    mkdir -p "$TARGET_HOME/.config" || return 1
    if [ -L "$ZSH_HOME_DIR" ]; then
        local linked_target
        linked_target="$(readlink "$ZSH_HOME_DIR")" || return 1
        backup_target_if_needed "$ZSH_HOME_DIR" || return 1
        mkdir -p "$ZSH_HOME_DIR" || return 1

        if [ "$linked_target" = "$repo_zsh_dir" ]; then
            if [ -L "$repo_zsh_dir/.zsh_history" ]; then
                warn "Skipping symlinked Zsh history: $repo_zsh_dir/.zsh_history"
            elif [ -f "$repo_zsh_dir/.zsh_history" ]; then
                cp -p "$repo_zsh_dir/.zsh_history" "$ZSH_HOME_DIR/.zsh_history" || return 1
            fi
            if [ -L "$repo_zsh_dir/.zsh_sessions" ]; then
                warn "Skipping symlinked Zsh sessions: $repo_zsh_dir/.zsh_sessions"
            elif [ -d "$repo_zsh_dir/.zsh_sessions" ]; then
                cp -pR "$repo_zsh_dir/.zsh_sessions" "$ZSH_HOME_DIR/.zsh_sessions" || return 1
            fi
            for dump_file in "$repo_zsh_dir"/.zcompdump*; do
                [ -e "$dump_file" ] || continue
                if [ -L "$dump_file" ]; then
                    warn "Skipping symlinked Zsh completion dump: $dump_file"
                    continue
                fi
                cp -pR "$dump_file" "$ZSH_HOME_DIR/" || return 1
            done
        fi
    else
        mkdir -p "$ZSH_HOME_DIR" || return 1
    fi
}

prepare_wezterm_dir() {
    local repo_wezterm_dir="$DOT_DIR/.config/wezterm"
    local wezterm_home_dir="$TARGET_HOME/.config/wezterm"
    local linked_target

    ensure_safe_target_parent "$wezterm_home_dir" || return 1
    mkdir -p "$TARGET_HOME/.config" || return 1

    if [ -L "$wezterm_home_dir" ]; then
        linked_target="$(readlink "$wezterm_home_dir")" || return 1
        if [ "$linked_target" != "$repo_wezterm_dir" ]; then
            warn "Refusing unrelated WezTerm directory symlink: $wezterm_home_dir"
            return 1
        fi
        backup_target_if_needed "$wezterm_home_dir" || return 1
        mkdir -p "$wezterm_home_dir" || return 1
    elif [ -e "$wezterm_home_dir" ]; then
        if [ ! -d "$wezterm_home_dir" ]; then
            warn "Refusing non-directory WezTerm path: $wezterm_home_dir"
            return 1
        fi
    else
        mkdir -p "$wezterm_home_dir" || return 1
    fi
}

setup_agent_config_links() {
    local agent_dir

    for agent_dir in "$TARGET_HOME/.codex" "$TARGET_HOME/.claude"; do
        ensure_safe_target_parent "$agent_dir" || return 1
        if [ -L "$agent_dir" ]; then
            warn "Refusing symlinked agent configuration directory: $agent_dir"
            return 1
        fi
        if [ -e "$agent_dir" ] && [ ! -d "$agent_dir" ]; then
            warn "Refusing non-directory agent configuration path: $agent_dir"
            return 1
        fi
    done

    mkdir -p "$TARGET_HOME/.codex" "$TARGET_HOME/.claude" || return 1
    safe_link_or_copy "$DOT_DIR/.codex/AGENTS.md" \
        "$TARGET_HOME/.codex/AGENTS.md" || return 1
    safe_link_or_copy "$DOT_DIR/.claude/CLAUDE.md" \
        "$TARGET_HOME/.claude/CLAUDE.md" || return 1
}

setup_dotfiles_links() {
    safe_link_or_copy "$DOT_DIR/.zshenv" "$TARGET_HOME/.zshenv" || return 1
    safe_link_or_copy "$DOT_DIR/bin/ha" "$TARGET_HOME/.local/bin/ha" || return 1

    for dir_name in devbox git herdr; do
        safe_link_or_copy "$DOT_DIR/.config/$dir_name" "$TARGET_HOME/.config/$dir_name" || return 1
    done

    prepare_zsh_dir || return 1
    for zsh_file in .zshrc aliases.zsh; do
        safe_link_or_copy "$DOT_DIR/.config/zsh/$zsh_file" "$ZSH_HOME_DIR/$zsh_file" || return 1
    done

    prepare_wezterm_dir || return 1
    safe_link_or_copy "$DOT_DIR/.config/wezterm/wezterm.lua" \
        "$TARGET_HOME/.config/wezterm/wezterm.lua" || return 1

    setup_agent_config_links || return 1
}

cleanup_legacy_managed_links() {
    local nvim_link="$TARGET_HOME/.config/nvim"
    local managed_nvim_target="$DOT_DIR/.config/nvim"
    local pet_link="$TARGET_HOME/.config/zsh/pet.zsh"
    local managed_pet_target="$DOT_DIR/.config/zsh/pet.zsh"
    local linked_target

    ensure_safe_target_parent "$nvim_link" || return 1
    if [ -L "$nvim_link" ]; then
        linked_target="$(readlink "$nvim_link")" || return 1
        if [ "$linked_target" = "$managed_nvim_target" ]; then
            rm -f "$nvim_link" || return 1
            log "Removed legacy managed Neovim link: $nvim_link"
        fi
    fi

    if [ -L "$pet_link" ]; then
        ensure_safe_target_parent "$pet_link" || return 1
        linked_target="$(readlink "$pet_link")" || return 1
        if [ "$linked_target" = "$managed_pet_target" ]; then
            rm -f "$pet_link" || return 1
            log "Removed legacy managed Pet link: $pet_link"
        fi
    fi
}

setup_devbox_global() {
    if [ ! -d "$DEVBOX_GLOBAL_CONFIG" ]; then
        warn "Skipping Devbox global setup: $DEVBOX_GLOBAL_CONFIG not found."
        return
    fi
    safe_link_or_copy "$DEVBOX_GLOBAL_CONFIG" "$DEVBOX_DATA_DIR/global/default" || return 1

    if has_cmd devbox; then
        log "Installing packages from devbox global config..."
        devbox global install || return 1
    else
        fail "'devbox' is unavailable after installation step."
    fi
}

checkout_owner_token_is_valid() {
    local token="$1"
    local expected_prefix=".${destination_name}.dotfiles-owner."
    local token_parent="${token%/*}"
    local token_name="${token##*/}"

    [ -n "$token" ] || return 1
    [ "$token_parent" = "$parent_dir" ] || return 1
    case "$token_name" in
        "$expected_prefix"*) ;;
        *) return 1 ;;
    esac
    [ -f "$token" ] && [ ! -L "$token" ]
}

checkout_marker_proves_ownership() {
    local candidate="$1"
    local marker="$candidate/$checkout_owner_marker_name"

    checkout_owner_token_is_valid "$owner_token" || return 1
    [ -f "$marker" ] || return 1
    [ ! -L "$marker" ] || return 1
    [ "$marker" -ef "$owner_token" ]
}

checkout_candidate_is_narrowly_derived() {
    local candidate="$1"

    [ -n "$candidate" ] || return 1
    [ "$candidate" = "$temp_dir" ] ||
        [ "$candidate" = "$nested_temp_dir" ] ||
        [ "$candidate" = "$destination" ]
}

cleanup_owned_checkout_candidate() {
    local candidate="$1"

    checkout_candidate_is_narrowly_derived "$candidate" || {
        warn "Refusing to clean non-derived checkout candidate: $candidate"
        return 1
    }
    [ -e "$candidate" ] || [ -L "$candidate" ] || return 0

    if checkout_marker_proves_ownership "$candidate"; then
        rm -rf -- "$candidate" || return 1
        return 0
    fi

    if [ "$candidate" = "$temp_dir" ] && [ -d "$candidate" ]; then
        if rmdir "$candidate" 2>/dev/null; then
            return 0
        fi
    fi
    return 0
}

cleanup_owned_checkout_lock() {
    local candidate

    [ -n "$lock_dir" ] || return 0
    checkout_owner_token_is_valid "$owner_token" || return 0
    for candidate in "$lock_dir" "$nested_lock_path"; do
        [ -n "$candidate" ] || continue
        [ -f "$candidate" ] || continue
        [ ! -L "$candidate" ] || continue
        if [ "$candidate" -ef "$owner_token" ]; then
            rm -f -- "$candidate" || return 1
        fi
    done
}

cleanup_checkout_owner_token() {
    [ -n "$owner_token" ] || return 0
    checkout_owner_token_is_valid "$owner_token" || return 0
    rm -f -- "$owner_token" || return 1
}

checkout_lock_owner_is_live() {
    local lock_pid

    [ -f "$lock_dir" ] || return 1
    [ ! -L "$lock_dir" ] || return 1
    IFS= read -r lock_pid < "$lock_dir" || return 1
    case "$lock_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$lock_pid" 2>/dev/null
}

restore_pinned_checkout_traps() {
    trap - EXIT HUP INT TERM
    [ -z "$saved_checkout_exit_trap" ] || eval "$saved_checkout_exit_trap"
    [ -z "$saved_checkout_hup_trap" ] || eval "$saved_checkout_hup_trap"
    [ -z "$saved_checkout_int_trap" ] || eval "$saved_checkout_int_trap"
    [ -z "$saved_checkout_term_trap" ] || eval "$saved_checkout_term_trap"
}

finish_pinned_checkout() {
    local original_status="$1"
    local cleanup_status=0
    local step_status=0

    for checkout_cleanup_candidate in \
        "${temp_dir:-}" "${nested_temp_dir:-}" "${destination:-}"; do
        [ -n "$checkout_cleanup_candidate" ] || continue
        step_status=0
        cleanup_owned_checkout_candidate "$checkout_cleanup_candidate" ||
            step_status=$?
        if [ "$step_status" -ne 0 ]; then
            cleanup_status="$step_status"
        fi
    done
    step_status=0
    cleanup_owned_checkout_lock || step_status=$?
    if [ "$step_status" -ne 0 ] && [ "$cleanup_status" -eq 0 ]; then
        cleanup_status="$step_status"
    fi
    step_status=0
    cleanup_checkout_owner_token || step_status=$?
    if [ "$step_status" -ne 0 ] && [ "$cleanup_status" -eq 0 ]; then
        cleanup_status="$step_status"
    fi
    restore_pinned_checkout_traps
    if [ "$original_status" -eq 0 ] && [ "$cleanup_status" -ne 0 ]; then
        original_status="$cleanup_status"
    fi
    return "$original_status"
}

handle_pinned_checkout_signal() {
    local signal_name="$1"
    local signal_status="$2"
    local final_status

    if finish_pinned_checkout "$signal_status"; then
        final_status=0
    else
        final_status=$?
    fi
    operation_signal_status="$final_status"
    sh -c 'kill -s "$1" "$PPID"' sh "$signal_name" 2>/dev/null || :
    return 0
}

cleanup_pinned_checkout_at_exit() {
    local original_status=$?
    local final_status

    if finish_pinned_checkout "$original_status"; then
        final_status=0
    else
        final_status=$?
    fi
    exit "$final_status"
}

pinned_checkout_has_exact_head() {
    local destination="$1"
    local commit="$2"
    local destination_root git_root current_commit

    if [ ! -d "$destination/.git" ] && [ ! -f "$destination/.git" ]; then
        return 1
    fi
    destination_root="$(CDPATH= cd -- "$destination" && pwd -P)" || return 1
    git_root="$(git -C "$destination" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ "$git_root" = "$destination_root" ] || return 1
    current_commit="$(git -C "$destination" rev-parse --verify HEAD 2>/dev/null)" ||
        return 1
    [ "$current_commit" = "$commit" ]
}

pinned_checkout_test_before_finalize() {
    return 0
}

pinned_checkout_test_after_traps_installed() {
    return 0
}

pinned_checkout_test_after_lock_acquired() {
    return 0
}

pinned_checkout_test_after_temp_created() {
    return 0
}

pinned_checkout_test_after_move() {
    return 0
}

return_checkout_signal_if_caught() {
    if [ "${operation_signal_status:-0}" -ne 0 ]; then
        return "$operation_signal_status"
    fi
}

ensure_pinned_checkout_work() {
    if [ "${#commit}" -ne 40 ]; then
        warn "Refusing invalid Git commit for $destination."
        return 1
    fi
    case "$commit" in
        *[!0-9a-f]*)
            warn "Refusing invalid Git commit for $destination."
            return 1
            ;;
    esac
    case "$destination" in
        /*) ;;
        *)
            warn "Refusing non-absolute checkout destination: $destination"
            return 1
            ;;
    esac

    parent_dir="${destination%/*}"
    destination_name="${destination##*/}"
    if [ -z "$parent_dir" ] || [ -z "$destination_name" ] ||
       [ "$destination_name" = "." ] || [ "$destination_name" = ".." ]; then
        warn "Refusing ambiguous checkout destination: $destination"
        return 1
    fi
    [ -d "$parent_dir" ] || {
        warn "Checkout parent directory does not exist: $parent_dir"
        return 1
    }

    if pinned_checkout_has_exact_head "$destination" "$commit"; then
        log "Pinned checkout is already at $commit: $destination"
        return 0
    fi

    lock_dir="$parent_dir/.${destination_name}.dotfiles-checkout.lock"
    owner_token="$(mktemp "$parent_dir/.${destination_name}.dotfiles-owner.XXXXXX")" ||
        return 1
    chmod 600 "$owner_token" || return $?
    sh -c 'printf "%s\n" "$PPID"' > "$owner_token" || return $?
    owner_token_name="${owner_token##*/}"
    owner_token_prefix=".${destination_name}.dotfiles-owner."
    case "$owner_token_name" in
        "$owner_token_prefix"*) ;;
        *)
            warn "Owner token name is invalid: $owner_token"
            return 1
            ;;
    esac
    owner_id="${owner_token_name#"$owner_token_prefix"}"
    temp_name=".${destination_name}.dotfiles-checkout.${owner_id}"
    temp_dir="$parent_dir/$temp_name"
    nested_temp_dir="$destination/$temp_name"
    nested_lock_path="$lock_dir/$owner_token_name"

    while :; do
        if ln "$owner_token" "$lock_dir" 2>/dev/null &&
           [ -f "$lock_dir" ] && [ ! -L "$lock_dir" ] &&
           [ "$lock_dir" -ef "$owner_token" ]; then
            break
        elif [ -f "$nested_lock_path" ] && [ ! -L "$nested_lock_path" ] &&
             [ "$nested_lock_path" -ef "$owner_token" ]; then
            rm -f -- "$nested_lock_path" || return $?
            warn "Cannot verify checkout lock $lock_dir; inspect it and remove it manually only after confirming no installer is using it."
            return 1
        elif pinned_checkout_has_exact_head "$destination" "$commit"; then
            log "Pinned checkout is already at $commit: $destination"
            return 0
        elif checkout_lock_owner_is_live; then
            lock_attempts=$((lock_attempts + 1))
            if [ "$lock_attempts" -ge 300 ]; then
                warn "Checkout lock remains active at $lock_dir; inspect it before any manual removal."
                return 1
            fi
            sleep 0.1 || return $?
        else
            warn "Cannot verify checkout lock $lock_dir; inspect it and remove it manually only after confirming no installer is using it."
            return 1
        fi
    done
    pinned_checkout_test_after_lock_acquired "$lock_dir" "$owner_token" || return $?
    return_checkout_signal_if_caught || return $?

    if [ -e "$destination" ] || [ -L "$destination" ]; then
        if pinned_checkout_has_exact_head "$destination" "$commit"; then
            log "Pinned checkout is already at $commit: $destination"
        elif [ -d "$destination/.git" ] || [ -f "$destination/.git" ]; then
            current_commit="$(git -C "$destination" rev-parse --verify HEAD 2>/dev/null)" || {
                warn "Existing Git destination could not be inspected; preserving it: $destination"
                return 0
            }
            warn "Existing checkout at $current_commit differs from requested $commit; preserving it: $destination"
        else
            warn "Existing non-Git destination preserved: $destination"
        fi
        return 0
    fi

    mkdir "$temp_dir" || return $?
    return_checkout_signal_if_caught || return $?
    ln "$owner_token" "$temp_dir/$checkout_owner_marker_name" || return $?
    return_checkout_signal_if_caught || return $?
    pinned_checkout_test_after_temp_created "$temp_dir" "$owner_token" || return $?
    return_checkout_signal_if_caught || return $?
    git init -q "$temp_dir" || return $?
    return_checkout_signal_if_caught || return $?
    git -C "$temp_dir" remote add origin "$url" || return $?
    return_checkout_signal_if_caught || return $?
    git -C "$temp_dir" fetch -q --depth 1 origin "$commit" || return $?
    return_checkout_signal_if_caught || return $?
    git -C "$temp_dir" checkout -q --detach FETCH_HEAD || return $?
    return_checkout_signal_if_caught || return $?
    current_commit="$(git -C "$temp_dir" rev-parse --verify HEAD)" || return $?
    if [ "$current_commit" != "$commit" ]; then
        warn "Fetched checkout does not match requested commit for $destination."
        return 1
    fi

    pinned_checkout_test_before_finalize "$temp_dir" "$destination" || return $?
    return_checkout_signal_if_caught || return $?
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        warn "Checkout destination appeared during installation; preserving it: $destination"
        return 1
    fi
    mv "$temp_dir" "$destination" || return $?
    return_checkout_signal_if_caught || return $?
    pinned_checkout_test_after_move "$temp_dir" "$destination" "$nested_temp_dir" ||
        return $?
    return_checkout_signal_if_caught || return $?

    if checkout_marker_proves_ownership "$nested_temp_dir"; then
        warn "Checkout was nested under a foreign destination; preserving the destination: $destination"
        return 1
    fi
    if ! checkout_marker_proves_ownership "$destination"; then
        warn "Cannot prove ownership of finalized checkout: $destination"
        return 1
    fi
    if ! pinned_checkout_has_exact_head "$destination" "$commit"; then
        warn "Final checkout verification failed for $destination."
        return 1
    fi
    rm -f -- "$destination/$checkout_owner_marker_name" || return $?
    log "Installed pinned checkout at $commit: $destination"
}

ensure_pinned_checkout() {
    local url="$1"
    local commit="$2"
    local destination="$3"
    local parent_dir="" destination_name="" lock_dir="" nested_lock_path=""
    local owner_token="" owner_token_name="" owner_token_prefix="" owner_id=""
    local checkout_owner_marker_name=".dotfiles-checkout-owner"
    local temp_name="" temp_dir="" nested_temp_dir="" current_commit
    local lock_attempts=0
    local checkout_cleanup_candidate
    local operation_signal_status=0
    local saved_checkout_exit_trap saved_checkout_hup_trap
    local saved_checkout_int_trap saved_checkout_term_trap
    local status=0

    saved_checkout_exit_trap="$(trap -p EXIT)"
    saved_checkout_hup_trap="$(trap -p HUP)"
    saved_checkout_int_trap="$(trap -p INT)"
    saved_checkout_term_trap="$(trap -p TERM)"
    trap cleanup_pinned_checkout_at_exit EXIT
    trap 'handle_pinned_checkout_signal HUP 129' HUP
    trap 'handle_pinned_checkout_signal INT 130' INT
    trap 'handle_pinned_checkout_signal TERM 143' TERM

    pinned_checkout_test_after_traps_installed || status=$?
    if [ "$operation_signal_status" -ne 0 ]; then
        status="$operation_signal_status"
    elif [ "$status" -eq 0 ]; then
        if ensure_pinned_checkout_work; then
            status=0
        else
            status=$?
        fi
    fi
    if [ "$operation_signal_status" -ne 0 ]; then
        status="$operation_signal_status"
    fi
    if finish_pinned_checkout "$status"; then
        status=0
    else
        status=$?
    fi
    return "$status"
}

setup_oh_my_zsh() {
    local omz_dir="$ZSH_HOME_DIR/oh-my-zsh"
    local plugin_dir="$omz_dir/custom/plugins"
    local autosuggestions_dir="$plugin_dir/zsh-autosuggestions"
    local syntax_highlighting_dir="$plugin_dir/zsh-syntax-highlighting"

    ensure_safe_target_parent "$omz_dir" || return 1
    ensure_pinned_checkout "https://github.com/ohmyzsh/ohmyzsh.git" \
        "$OH_MY_ZSH_COMMIT" "$omz_dir" || return 1
    if ! pinned_checkout_has_exact_head "$omz_dir" "$OH_MY_ZSH_COMMIT"; then
        warn "Skipping Zsh plugins because Oh My Zsh is not at the pinned commit: $omz_dir"
        return 0
    fi
    ensure_safe_target_parent "$autosuggestions_dir" || return 1
    ensure_safe_target_parent "$syntax_highlighting_dir" || return 1
    mkdir -p "$plugin_dir" || return 1
    ensure_pinned_checkout "https://github.com/zsh-users/zsh-autosuggestions.git" \
        "$ZSH_AUTOSUGGESTIONS_COMMIT" "$autosuggestions_dir" || return 1
    ensure_pinned_checkout "https://github.com/zsh-users/zsh-syntax-highlighting.git" \
        "$ZSH_SYNTAX_HIGHLIGHTING_COMMIT" "$syntax_highlighting_dir" || return 1
}

main() {
    preflight_required_commands || return 1
    log "Starting dotfiles setup..."
    log "Detected platform: $(detect_platform)"

    install_nix_if_needed || return 1
    install_devbox_if_needed || return 1
    cleanup_legacy_managed_links || return 1
    setup_dotfiles_links || return 1
    setup_devbox_global || return 1
    setup_oh_my_zsh || return 1

    log "Setup completed in one run."
    log "If this was your first install of Nix/devbox, restart your shell once."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

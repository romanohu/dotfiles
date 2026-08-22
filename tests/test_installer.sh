#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$TEST_DIR/.." && pwd)
INSTALLER_RUNTIME_PATH="${DOTFILES_TEST_INSTALLER_PATH:-$REPO_DIR/install.sh}"

# shellcheck source=test_helpers.sh
. "$TEST_DIR/test_helpers.sh"

TEST_ROOT=$(make_test_dir)
TEST_SHELL_BASHPID="${BASHPID:-$$}"

cleanup() {
    [ "${BASHPID:-$$}" = "$TEST_SHELL_BASHPID" ] || return 0
    rm -rf "$TEST_ROOT"
}

trap cleanup EXIT

fixture_sha256() {
    local path="$1"
    local output

    if command -v sha256sum >/dev/null 2>&1; then
        output="$(sha256sum -- "$path")" || return 1
    else
        output="$(shasum -a 256 -- "$path")" || return 1
    fi
    printf '%s\n' "${output%% *}"
}

wait_for_path() {
    local path="$1"
    local attempts=0

    while [ ! -e "$path" ] && [ "$attempts" -lt 100 ]; do
        sleep 0.1
        attempts=$((attempts + 1))
    done
    [ -e "$path" ] || fail "timed out waiting for path: $path"
}

assert_no_installer_temp_dirs() {
    local temp_root="$1"
    local path

    for path in "$temp_root"/dotfiles-mise-installer.*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        fail "installer temporary path was not cleaned: $path"
    done
}

assert_link_points_to() {
    local link_path="$1"
    local expected="$2"

    [ -L "$link_path" ] || fail "expected symbolic link: $link_path"
    assert_eq "$expected" "$(readlink "$link_path")" \
        "unexpected target for $link_path"
}

test_install_script_has_source_guard() {
    assert_file_contains "$REPO_DIR/install.sh" 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]'
}

test_verify_sha256_accepts_match_and_rejects_mismatch() {
    local fixture="$TEST_ROOT/sha-fixture"
    local actual_sha

    printf 'verified fixture\n' > "$fixture"
    actual_sha="$(fixture_sha256 "$fixture")"

    (
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        verify_sha256 "$fixture" "$actual_sha"
        if verify_sha256 "$fixture" \
            '0000000000000000000000000000000000000000000000000000000000000000'; then
            fail 'verify_sha256 must reject a mismatched digest'
        fi
        if verify_sha256 "$fixture" 'not-a-sha256'; then
            fail 'verify_sha256 must reject a malformed digest'
        fi
    )
}

test_sha256_file_rejects_symlinks_and_option_like_paths() {
    local fixture="$TEST_ROOT/sha-regular-file"
    local symlink="$TEST_ROOT/sha-symlink"

    printf 'regular\n' > "$fixture"
    ln -s "$fixture" "$symlink"

    (
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        if sha256_file "$symlink"; then
            fail 'sha256_file must reject symlinks'
        fi
        cd "$TEST_ROOT"
        printf 'option-like\n' > ./--binary
        if sha256_file --binary < /dev/null; then
            fail 'sha256_file must reject option-like paths'
        fi
    )
}

test_verified_installer_executes_only_after_hash_match() {
    local fixture="$TEST_ROOT/harmless-installer.sh"
    local marker="$TEST_ROOT/verified-installer-executed"
    local installer_home_marker="$TEST_ROOT/verified-installer-home"
    local temp_root="$TEST_ROOT/verified-installer-tmp"
    local target_home="$TEST_ROOT/verified-installer-target-home"
    local ambient_home="$TEST_ROOT/verified-installer-ambient-home"
    local physical_target_home
    local actual_sha

    mkdir -p "$temp_root" "$target_home" "$ambient_home"
    physical_target_home=$(CDPATH= cd -P -- "$target_home" && pwd -P)
    printf '%s\n' '#!/usr/bin/env bash' \
        ': > "$EXECUTED_MARKER"' \
        'printf "%s\n" "$HOME" > "$EXECUTED_HOME_MARKER"' > "$fixture"
    actual_sha="$(fixture_sha256 "$fixture")"

    (
        export EXECUTED_MARKER="$marker"
        export EXECUTED_HOME_MARKER="$installer_home_marker"
        export TEST_CURL_SOURCE="$fixture"
        export TMPDIR="$temp_root"
        export HOME="$ambient_home"
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        curl() {
            local output_path=''

            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --output)
                        output_path="$2"
                        shift 2
                        ;;
                    *) shift ;;
                esac
            done
            [ -n "$output_path" ] || return 91
            cp "$TEST_CURL_SOURCE" "$output_path"
        }

        resolve_target_home

        if run_verified_installer 'https://example.invalid/installer.sh' \
            '0000000000000000000000000000000000000000000000000000000000000000'; then
            fail 'verified installer must reject a mismatched digest'
        fi
        assert_path_missing "$EXECUTED_MARKER"

        run_verified_installer 'https://example.invalid/installer.sh' "$actual_sha"
        assert_path_exists "$EXECUTED_MARKER"
        assert_eq "$physical_target_home" "$(cat "$EXECUTED_HOME_MARKER")" \
            'verified installer did not receive the physical target HOME'
    )
}

test_verified_installer_cleans_temporary_directory_on_failure() {
    local fixture="$TEST_ROOT/failing-installer.sh"
    local temp_root="$TEST_ROOT/failing-installer-tmp"
    local actual_sha

    mkdir -p "$temp_root"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 23' > "$fixture"
    actual_sha="$(fixture_sha256 "$fixture")"

    (
        export TEST_CURL_SOURCE="$fixture"
        export TMPDIR="$temp_root"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        curl() {
            local output_path=''

            while [ "$#" -gt 0 ]; do
                if [ "$1" = '--output' ]; then
                    output_path="$2"
                    shift 2
                else
                    shift
                fi
            done
            cp "$TEST_CURL_SOURCE" "$output_path"
        }

        if run_verified_installer 'https://example.invalid/installer.sh' "$actual_sha"; then
            fail 'failing installer unexpectedly succeeded'
        fi
        assert_no_installer_temp_dirs "$TMPDIR"
    )
}

test_verified_installer_cleans_temporary_directory_on_signal() {
    local temp_root="$TEST_ROOT/signal-installer-tmp"
    local ready="$TEST_ROOT/signal-installer-ready"
    local curl_pid_file="$TEST_ROOT/signal-curl-pid"
    local fake_bin="$TEST_ROOT/signal-bin"
    local installer_pid signal_status curl_pid
    local attempts

    mkdir -p "$temp_root" "$fake_bin"
    printf '%s\n' '#!/usr/bin/env bash' \
        'trap "exit 98" TERM' \
        'printf "%s\n" "$$" > "$TEST_SIGNAL_CURL_PID_FILE"' \
        ': > "$TEST_SIGNAL_READY"' \
        'while :; do' \
        '    sleep 0.1' \
        'done' > "$fake_bin/curl"
    chmod +x "$fake_bin/curl"
    (
        export TMPDIR="$temp_root"
        export TEST_SIGNAL_READY="$ready"
        export TEST_SIGNAL_CURL_PID_FILE="$curl_pid_file"
        export PATH="$fake_bin:$PATH"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"

        run_verified_installer 'https://example.invalid/installer.sh' \
            '0000000000000000000000000000000000000000000000000000000000000000' &
        installer_pid=$!
        wait_for_path "$TEST_SIGNAL_READY"
        kill -TERM "$installer_pid"
        attempts=0
        while kill -0 "$installer_pid" 2>/dev/null && [ "$attempts" -lt 20 ]; do
            sleep 0.1
            attempts=$((attempts + 1))
        done
        if kill -0 "$installer_pid" 2>/dev/null; then
            curl_pid="$(cat "$TEST_SIGNAL_CURL_PID_FILE")"
            kill -TERM "$curl_pid" 2>/dev/null || :
            wait "$installer_pid" 2>/dev/null || :
            fail 'TERM did not stop a blocked installer download'
        fi
        if wait "$installer_pid"; then
            fail 'TERM-interrupted installer unexpectedly succeeded'
        else
            signal_status=$?
        fi
        assert_eq '143' "$signal_status" 'installer did not preserve TERM status'
        curl_pid="$(cat "$TEST_SIGNAL_CURL_PID_FILE")"
        if kill -0 "$curl_pid" 2>/dev/null; then
            kill -TERM "$curl_pid" 2>/dev/null || :
            fail 'TERM left the installer download process running'
        fi
        assert_no_installer_temp_dirs "$TMPDIR"
    )
}

test_preflight_failure_prevents_main_mutations() {
    local target_home="$TEST_ROOT/preflight-target"
    local mutations="$TEST_ROOT/preflight-mutations"

    mkdir -p "$target_home"
    if (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        has_cmd() {
            [ "$1" != 'tar' ]
        }
        install_mise_if_needed() { : > "$mutations"; }
        cleanup_legacy_managed_links() { : > "$mutations"; }
        run_mise_bootstrap() { : > "$mutations"; }

        main
    ); then
        fail 'main unexpectedly passed without tar'
    fi
    assert_path_missing "$mutations"
}

test_mise_install_passes_exact_url_hash_and_destination() {
    local target_home="$TEST_ROOT/mise-install-target"
    local ambient_home="$TEST_ROOT/mise-install-ambient-home"
    local calls="$TEST_ROOT/mise-install-calls"
    local home_calls="$TEST_ROOT/mise-install-home-calls"
    local physical_target_home

    mkdir -p "$target_home" "$ambient_home"
    physical_target_home=$(CDPATH= cd -P -- "$target_home" && pwd -P)
    mkdir -p "$physical_target_home/.local/bin"
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf "probe|%s\n" "$HOME" >> "$MISE_TEST_HOME_CALLS"' \
        'printf "%s\n" "2026.8.8 macos-arm64 (2026-08-18)"' \
        > "$physical_target_home/.local/bin/mise"
    chmod +x "$physical_target_home/.local/bin/mise"
    (
        export HOME="$ambient_home"
        export DOTFILES_TARGET_HOME="$target_home"
        export MISE_TEST_HOME_CALLS="$home_calls"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        run_verified_installer() {
            printf '%s|%s|%s\n' "$1" "$2" "$MISE_INSTALL_PATH" >> "$calls"
            printf 'installer|%s\n' "$HOME" >> "$MISE_TEST_HOME_CALLS"
            printf '%s\n' '#!/usr/bin/env bash' \
                'if [ "${1:-}" = "--version" ]; then' \
                '    printf "probe|%s\n" "$HOME" >> "$MISE_TEST_HOME_CALLS"' \
                '    printf "%s\n" "2026.8.9 macos-arm64 (2026-08-19)"' \
                'fi' > "$MISE_INSTALL_PATH"
            chmod +x "$MISE_INSTALL_PATH"
        }
        nix() { fail 'Nix must not be called'; }
        devbox() { fail 'Devbox must not be called'; }

        install_mise_if_needed
    )

    assert_file_contains "$calls" \
        "https://github.com/jdx/mise/releases/download/v2026.8.9/install.sh|0947cf3dd1eb5d734676a554b4bb8298f8557ffc706f5ed5637e9e68e1218403|$physical_target_home/.local/bin/mise"
    assert_file_contains "$home_calls" "installer|$physical_target_home"
    assert_file_contains "$home_calls" "probe|$physical_target_home"
    assert_eq '2' "$(grep -F -x -c -- "probe|$physical_target_home" "$home_calls")" \
        'both mise version probes must use the physical target home'
    assert_file_not_contains "$home_calls" "$ambient_home"
}

test_mise_install_requires_exact_version_after_install() {
    local target_home="$TEST_ROOT/mise-version-target"

    mkdir -p "$target_home"
    if (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        run_verified_installer() {
            printf '%s\n' '#!/usr/bin/env bash' \
                'printf "%s\n" "2026.8.8 macos-arm64 (2026-08-18)"' \
                > "$MISE_INSTALL_PATH"
            chmod +x "$MISE_INSTALL_PATH"
        }

        install_mise_if_needed
    ); then
        fail 'mise installation accepted the wrong installed version'
    fi
}

test_mise_install_rejects_symlinked_destination_paths() {
    local layout target_home external linked_path

    for layout in local bin; do
        target_home="$TEST_ROOT/mise-symlinked-$layout-target"
        external="$TEST_ROOT/mise-symlinked-$layout-external"
        mkdir -p "$target_home" "$external"
        if [ "$layout" = 'local' ]; then
            ln -s "$external" "$target_home/.local"
            linked_path="$target_home/.local"
        else
            mkdir -p "$target_home/.local"
            ln -s "$external" "$target_home/.local/bin"
            linked_path="$target_home/.local/bin"
        fi

        if (
            export DOTFILES_TARGET_HOME="$target_home"
            # shellcheck source=/dev/null
            . "$INSTALLER_RUNTIME_PATH"
            run_verified_installer() {
                mkdir -p "$external/installer-was-called"
                return 91
            }

            install_mise_if_needed
        ); then
            fail "mise installation accepted a symlinked $layout destination parent"
        fi
        assert_link_points_to "$linked_path" "$external"
        if find "$external" -mindepth 1 -print -quit | grep -q .; then
            fail "mise installation wrote through symlinked $layout destination parent"
        fi
    done

    target_home="$TEST_ROOT/mise-symlinked-binary-target"
    external="$TEST_ROOT/mise-symlinked-binary-external"
    mkdir -p "$target_home/.local/bin" "$external"
    printf '%s\n' '#!/usr/bin/env bash' \
        ': > "$MISE_SYMLINK_PROBE_MARKER"' \
        'printf "%s\n" "2026.8.9 macos-arm64 (2026-08-19)"' \
        > "$external/mise"
    chmod +x "$external/mise"
    ln -s "$external/mise" "$target_home/.local/bin/mise"

    if (
        export DOTFILES_TARGET_HOME="$target_home"
        export MISE_SYMLINK_PROBE_MARKER="$TEST_ROOT/mise-symlink-probe-marker"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        run_verified_installer() {
            printf 'mutated\n' > "$MISE_INSTALL_PATH"
            return 92
        }

        install_mise_if_needed
    ); then
        fail 'mise installation accepted a symlinked binary destination'
    fi
    assert_link_points_to "$target_home/.local/bin/mise" "$external/mise"
    assert_file_contains "$external/mise" '2026.8.9 macos-arm64'
    assert_file_not_contains "$external/mise" 'mutated'
    assert_path_missing "$TEST_ROOT/mise-symlink-probe-marker"
}

test_target_home_is_absolute_physical_and_never_traverses_symlink_input() {
    local physical_home="$TEST_ROOT/physical-target-home"
    local linked_home="$TEST_ROOT/linked-target-home"
    local expected_physical_home
    local invalid

    mkdir -p "$physical_home/child" "$TEST_ROOT/relative-target-home" \
        "$TEST_ROOT/--option-target-home"
    expected_physical_home=$(CDPATH= cd -P -- "$physical_home" && pwd -P)
    ln -s "$physical_home" "$linked_home"

    for invalid in relative-target-home --option-target-home; do
        if (
            cd "$TEST_ROOT"
            export DOTFILES_TARGET_HOME="$invalid"
            # shellcheck source=/dev/null
            . "$INSTALLER_RUNTIME_PATH"
            validate_environment
        ); then
            fail "installer accepted non-absolute target home: $invalid"
        fi
    done

    if (
        export DOTFILES_TARGET_HOME="$linked_home/"
        export TARGET_HOME_RESOLVED=1
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        validate_environment
    ); then
        fail 'installer traversed a symlinked target-home input'
    fi
    assert_link_points_to "$linked_home" "$physical_home"

    (
        export DOTFILES_TARGET_HOME="$physical_home/child/.."
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        validate_environment
        assert_eq "$expected_physical_home" "$TARGET_HOME" \
            'target home was not resolved to its physical absolute directory'
        assert_eq "$expected_physical_home/.local/bin/mise" "$MISE_BIN" \
            'mise destination did not use the physical target home'
    )
}

test_managed_dotfile_conflict_blocks_every_mutation_and_bootstrap() {
    local target_home="$TEST_ROOT/managed-conflict-target"
    local calls="$TEST_ROOT/managed-conflict-calls"
    local target="$target_home/.zshenv"

    mkdir -p "$target_home"
    printf 'preserve unmanaged bytes\n' > "$target"

    if (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        preflight_required_commands() { return 0; }
        install_mise_if_needed() { printf 'install\n' >> "$calls"; }
        cleanup_legacy_managed_links() { printf 'cleanup\n' >> "$calls"; }
        run_mise_bootstrap() { printf 'bootstrap\n' >> "$calls"; }

        main
    ); then
        fail 'installer accepted an unmanaged managed-target file'
    fi

    assert_eq 'preserve unmanaged bytes' "$(cat "$target")" \
        'managed-target preflight changed rejected file bytes'
    assert_path_missing "$calls"
}

test_managed_dotfile_symlinked_ancestor_preserves_external_state() {
    local target_home="$TEST_ROOT/managed-ancestor-target"
    local external="$TEST_ROOT/managed-ancestor-external"
    local calls="$TEST_ROOT/managed-ancestor-calls"

    mkdir -p "$target_home" "$external/mise"
    printf 'preserve external bytes\n' > "$external/mise/config.toml"
    ln -s "$external" "$target_home/.config"

    if (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        preflight_required_commands() { return 0; }
        install_mise_if_needed() { printf 'install\n' >> "$calls"; }
        cleanup_legacy_managed_links() { printf 'cleanup\n' >> "$calls"; }
        run_mise_bootstrap() { printf 'bootstrap\n' >> "$calls"; }

        main
    ); then
        fail 'installer accepted a managed target below a symlinked ancestor'
    fi

    assert_link_points_to "$target_home/.config" "$external"
    assert_eq 'preserve external bytes' "$(cat "$external/mise/config.toml")" \
        'managed-target preflight changed external bytes'
    assert_path_missing "$calls"
}

test_unrelated_managed_target_symlink_and_directory_are_preserved() {
    local directory_home="$TEST_ROOT/managed-directory-target"
    local symlink_home="$TEST_ROOT/managed-symlink-target"
    local external="$TEST_ROOT/managed-symlink-external"

    mkdir -p "$directory_home/.config/git" "$symlink_home" "$external"
    printf 'preserve directory bytes\n' > "$directory_home/.config/git/sentinel"
    printf 'preserve symlink bytes\n' > "$external/sentinel"
    ln -s "$external" "$symlink_home/.zshenv"

    if (
        export DOTFILES_TARGET_HOME="$directory_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        preflight_managed_dotfiles
    ); then
        fail 'managed-target preflight accepted a real target directory'
    fi
    assert_eq 'preserve directory bytes' \
        "$(cat "$directory_home/.config/git/sentinel")" \
        'managed-target preflight changed a rejected directory'

    if (
        export DOTFILES_TARGET_HOME="$symlink_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        preflight_managed_dotfiles
    ); then
        fail 'managed-target preflight accepted an unrelated target symlink'
    fi
    assert_link_points_to "$symlink_home/.zshenv" "$external"
    assert_eq 'preserve symlink bytes' "$(cat "$external/sentinel")" \
        'managed-target preflight changed unrelated symlink state'
}

test_exact_managed_dotfile_links_are_idempotent() {
    local target_home="$TEST_ROOT/exact-managed-links-target"
    local target source

    mkdir -p "$target_home"
    set -- \
        '.config/mise/config.toml' 'mise.toml' \
        '.config/mise/mise.lock' 'mise.lock' \
        '.zshenv' '.zshenv' \
        '.config/git' '.config/git' \
        '.config/herdr' '.config/herdr' \
        '.config/zsh/.zshrc' '.config/zsh/.zshrc' \
        '.config/zsh/aliases.zsh' '.config/zsh/aliases.zsh' \
        '.config/wezterm/wezterm.lua' '.config/wezterm/wezterm.lua' \
        '.config/opencode/opencode.jsonc' '.config/opencode/opencode.jsonc' \
        '.config/opencode/tui.json' '.config/opencode/tui.json' \
        '.codex/AGENTS.md' '.codex/AGENTS.md' \
        '.claude/CLAUDE.md' '.claude/CLAUDE.md'
    while [ "$#" -gt 0 ]; do
        target="$target_home/$1"
        source="$REPO_DIR/$2"
        mkdir -p "${target%/*}"
        ln -s "$source" "$target"
        shift 2
    done

    (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        preflight_managed_dotfiles
        preflight_managed_dotfiles
    )

    assert_eq '12' "$(find "$target_home" -type l | wc -l | tr -d ' ')" \
        'correct managed links changed during repeated preflight'
    assert_link_points_to "$target_home/.config/mise/config.toml" "$REPO_DIR/mise.toml"
    assert_link_points_to "$target_home/.claude/CLAUDE.md" "$REPO_DIR/.claude/CLAUDE.md"
}

test_each_managed_dotfile_target_is_preflighted() {
    local relative target_home target
    local index=0

    for relative in \
        '.config/mise/config.toml' \
        '.config/mise/mise.lock' \
        '.zshenv' \
        '.config/git' \
        '.config/herdr' \
        '.config/zsh/.zshrc' \
        '.config/zsh/aliases.zsh' \
        '.config/wezterm/wezterm.lua' \
        '.config/opencode/opencode.jsonc' \
        '.config/opencode/tui.json' \
        '.codex/AGENTS.md' \
        '.claude/CLAUDE.md'; do
        index=$((index + 1))
        target_home="$TEST_ROOT/managed-target-$index"
        target="$target_home/$relative"
        mkdir -p "${target%/*}"
        printf 'preserve target %s\n' "$index" > "$target"

        if (
            export DOTFILES_TARGET_HOME="$target_home"
            # shellcheck source=/dev/null
            . "$INSTALLER_RUNTIME_PATH"
            preflight_managed_dotfiles
        ); then
            fail "managed target was omitted from preflight: $relative"
        fi
        assert_eq "preserve target $index" "$(cat "$target")" \
            "preflight changed rejected managed target: $relative"
    done
    assert_eq '12' "$index" 'managed-target preflight fixture count changed'
}

test_bootstrap_uses_exact_binary_target_home_and_root_config() {
    local source_link="$TEST_ROOT/bootstrap-source-link"
    local target_home="$TEST_ROOT/bootstrap-target"
    local calls="$TEST_ROOT/bootstrap-calls"
    local physical_repo
    local physical_target_home

    ln -s "$REPO_DIR" "$source_link"
    mkdir -p "$target_home"
    physical_repo=$(CDPATH= cd -P -- "$source_link" && pwd -P)
    physical_target_home=$(CDPATH= cd -P -- "$target_home" && pwd -P)

    (
        export DOTFILES_SOURCE_DIR="$source_link"
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        mkdir -p "$(dirname "$MISE_BIN")"
        printf '%s\n' '#!/usr/bin/env bash' \
            'printf "%s|%s|%s\n" "$HOME" "$MISE_GLOBAL_CONFIG_FILE" "$*" >> "$MISE_CALLS"' \
            > "$MISE_BIN"
        chmod +x "$MISE_BIN"

        MISE_CALLS="$calls" run_mise_bootstrap
    )

    assert_file_contains "$calls" \
        "$physical_target_home|$physical_repo/mise.toml|trust --yes $physical_repo/mise.toml"
    assert_file_contains "$calls" \
        "$physical_target_home|$physical_repo/mise.toml|-C $physical_repo --locked bootstrap --yes"
}

test_only_exact_legacy_links_are_removed() {
    local source_link="$TEST_ROOT/cleanup-source-link"
    local target_home="$TEST_ROOT/cleanup-target"
    local physical_repo

    ln -s "$REPO_DIR" "$source_link"
    mkdir -p "$target_home/.local/bin" \
        "$target_home/.local/share/devbox/global" \
        "$target_home/.config/zsh"
    physical_repo=$(CDPATH= cd -P -- "$source_link" && pwd -P)
    ln -s "$physical_repo/bin/ha" "$target_home/.local/bin/ha"
    ln -s "$physical_repo/.config/devbox" "$target_home/.config/devbox"
    ln -s "$target_home/.config/devbox/global" \
        "$target_home/.local/share/devbox/global/default"
    ln -s "$physical_repo/.config/nvim" "$target_home/.config/nvim"
    ln -s "$physical_repo/.config/zsh/pet.zsh" "$target_home/.config/zsh/pet.zsh"

    (
        export DOTFILES_SOURCE_DIR="$source_link"
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        cleanup_legacy_managed_links
    )

    assert_path_missing "$target_home/.local/bin/ha"
    assert_path_missing "$target_home/.config/devbox"
    assert_path_missing "$target_home/.local/share/devbox/global/default"
    assert_path_missing "$target_home/.config/nvim"
    assert_path_missing "$target_home/.config/zsh/pet.zsh"

    ln -s "$physical_repo/.config/devbox/global" \
        "$target_home/.local/share/devbox/global/default"
    (
        export DOTFILES_SOURCE_DIR="$source_link"
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        cleanup_legacy_managed_links
    )
    assert_path_missing "$target_home/.local/share/devbox/global/default"
}

test_legacy_cleanup_propagates_unlink_failure() {
    local target_home="$TEST_ROOT/unlink-failure-target"
    local managed_link="$target_home/.local/bin/ha"

    mkdir -p "$target_home/.local/bin"
    ln -s "$REPO_DIR/bin/ha" "$managed_link"

    if (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        rm() { return 73; }

        cleanup_legacy_managed_links
    ); then
        fail 'legacy cleanup ignored an unlink failure'
    fi
    assert_link_points_to "$managed_link" "$REPO_DIR/bin/ha"
}

test_cleanup_preserves_links_below_symlinked_target_parents() {
    local target_home="$TEST_ROOT/symlinked-cleanup-target"
    local external="$TEST_ROOT/symlinked-cleanup-external"
    local managed_link="$external/bin/ha"

    mkdir -p "$target_home" "$external/bin"
    printf 'keep external data\n' > "$external/sentinel"
    ln -s "$external" "$target_home/.local"
    ln -s "$REPO_DIR/bin/ha" "$managed_link"

    if (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"

        cleanup_legacy_managed_links
    ); then
        fail 'legacy cleanup accepted a symlinked target parent'
    fi
    assert_link_points_to "$target_home/.local" "$external"
    assert_link_points_to "$managed_link" "$REPO_DIR/bin/ha"
    assert_eq 'keep external data' "$(cat "$external/sentinel")" \
        'cleanup changed data below a symlinked target parent'
}

test_regular_files_and_unrelated_links_are_preserved() {
    local target_home="$TEST_ROOT/preserve-target"
    local unrelated="$TEST_ROOT/unrelated"

    mkdir -p "$target_home/.local/bin" \
        "$target_home/.local/share/devbox/global" \
        "$target_home/.config/devbox" \
        "$target_home/.config/zsh" \
        "$unrelated"
    printf 'keep ha\n' > "$target_home/.local/bin/ha"
    printf 'keep devbox\n' > "$target_home/.config/devbox/config"
    ln -s "$unrelated" "$target_home/.local/share/devbox/global/default"
    ln -s "$unrelated" "$target_home/.config/nvim"
    ln -s "$unrelated" "$target_home/.config/zsh/pet.zsh"

    (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        cleanup_legacy_managed_links
    )

    assert_eq 'keep ha' "$(cat "$target_home/.local/bin/ha")" \
        'regular ha file was changed'
    assert_eq 'keep devbox' "$(cat "$target_home/.config/devbox/config")" \
        'real Devbox directory was changed'
    assert_link_points_to "$target_home/.local/share/devbox/global/default" "$unrelated"
    assert_link_points_to "$target_home/.config/nvim" "$unrelated"
    assert_link_points_to "$target_home/.config/zsh/pet.zsh" "$unrelated"
}

test_invalid_source_or_target_home_fails_before_mutation() {
    local missing_source="$TEST_ROOT/missing-source"
    local missing_home="$TEST_ROOT/missing-home"
    local valid_home="$TEST_ROOT/valid-home"
    local mutations="$TEST_ROOT/validation-mutations"

    mkdir -p "$valid_home"
    if DOTFILES_SOURCE_DIR="$missing_source" DOTFILES_TARGET_HOME="$valid_home" \
        bash "$INSTALLER_RUNTIME_PATH" >/dev/null 2>&1; then
        fail 'installer unexpectedly accepted a missing source directory'
    fi
    if find "$valid_home" -mindepth 1 -print -quit | grep -q .; then
        fail 'invalid source mutated the target home'
    fi

    if (
        export DOTFILES_TARGET_HOME="$missing_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        preflight_required_commands() { return 0; }
        install_mise_if_needed() { : > "$mutations"; }
        cleanup_legacy_managed_links() { : > "$mutations"; }
        run_mise_bootstrap() { : > "$mutations"; }

        main
    ); then
        fail 'installer unexpectedly accepted a missing target home'
    fi
    assert_path_missing "$missing_home"
    assert_path_missing "$mutations"
}

test_vscode_settings_target_supports_only_macos_and_linux() {
    local target_home="$TEST_ROOT/vscode-target-home"

    mkdir -p "$target_home"
    (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"

        assert_eq "$target_home/Library/Application Support/Code/User" \
            "$(vscode_user_dir_for_platform Darwin)"
        assert_eq "$target_home/.config/Code/User" \
            "$(vscode_user_dir_for_platform Linux)"
        assert_eq "$target_home/Library/Application Support/Code/User/settings.json" \
            "$(vscode_settings_target_for_platform Darwin)"
        assert_eq "$target_home/.config/Code/User/settings.json" \
            "$(vscode_settings_target_for_platform Linux)"
        if vscode_user_dir_for_platform Windows; then
            fail 'VS Code target calculation must reject Windows'
        fi
    )
}

test_vscode_settings_skip_without_user_directory() {
    local target_home="$TEST_ROOT/vscode-skip-home"
    local logs="$TEST_ROOT/vscode-skip-logs"

    mkdir -p "$target_home"
    (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        log() { printf '%s\n' "$1" >> "$logs"; }
        preflight_vscode_settings Darwin
        setup_vscode_settings Darwin
    )
    assert_path_missing "$target_home/Library"
    assert_eq 'VS Code settings: skipped (User directory is absent)' "$(cat "$logs")" \
        'missing VS Code User directory must be announced only once'
}

test_vscode_settings_conflicts_are_preserved() {
    local target_home="$TEST_ROOT/vscode-conflict-home"
    local user_dir="$target_home/.config/Code/User"
    local target="$user_dir/settings.json"
    local external="$TEST_ROOT/vscode-conflict-external"

    mkdir -p "$user_dir" "$external"
    printf 'keep settings\n' > "$target"
    (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        if setup_vscode_settings Linux; then
            fail 'VS Code settings conflict was accepted'
        fi
    )
    assert_eq 'keep settings' "$(cat "$target")" \
        'VS Code settings conflict was overwritten'

    rm -f "$target"
    ln -s "$external" "$target"
    if (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        setup_vscode_settings Linux
    ); then
        fail 'unrelated VS Code settings symlink was accepted'
    fi
    assert_link_points_to "$target" "$external"
}

test_vscode_settings_rejects_symlinked_ancestor() {
    local target_home="$TEST_ROOT/vscode-ancestor-home"
    local external="$TEST_ROOT/vscode-ancestor-external"

    mkdir -p "$target_home" "$external/Code/User"
    ln -s "$external" "$target_home/.config"
    if (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        setup_vscode_settings Linux
    ); then
        fail 'VS Code settings below a symlinked ancestor were accepted'
    fi
    assert_link_points_to "$target_home/.config" "$external"
}

test_vscode_settings_link_is_idempotent() {
    local target_home="$TEST_ROOT/vscode-idempotent-home"
    local user_dir="$target_home/Library/Application Support/Code/User"
    local target="$user_dir/settings.json"

    mkdir -p "$user_dir"
    (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        setup_vscode_settings Darwin
        setup_vscode_settings Darwin
    )
    assert_link_points_to "$target" "$REPO_DIR/.config/vscode/settings.json"
}

test_main_sets_up_vscode_after_mise_bootstrap() {
    local target_home="$TEST_ROOT/vscode-main-order-home"
    local calls="$TEST_ROOT/vscode-main-order-calls"

    mkdir -p "$target_home"
    (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        preflight_required_commands() { printf 'preflight\n' >> "$calls"; }
        validate_environment() { printf 'environment\n' >> "$calls"; }
        preflight_managed_dotfiles() { printf 'managed\n' >> "$calls"; }
        install_mise_if_needed() { printf 'mise\n' >> "$calls"; }
        cleanup_legacy_managed_links() { printf 'cleanup\n' >> "$calls"; }
        run_mise_bootstrap() { printf 'bootstrap\n' >> "$calls"; }
        setup_vscode_settings() { printf 'vscode\n' >> "$calls"; }
        main
    )
    assert_eq "$(printf '%s\n' preflight environment managed mise cleanup bootstrap vscode)" \
        "$(cat "$calls")" \
        'main must set up VS Code only after mise bootstrap'
}

test_install_script_has_source_guard
test_verify_sha256_accepts_match_and_rejects_mismatch
test_sha256_file_rejects_symlinks_and_option_like_paths
test_verified_installer_executes_only_after_hash_match
test_verified_installer_cleans_temporary_directory_on_failure
test_verified_installer_cleans_temporary_directory_on_signal
test_preflight_failure_prevents_main_mutations
test_mise_install_passes_exact_url_hash_and_destination
test_mise_install_requires_exact_version_after_install
test_mise_install_rejects_symlinked_destination_paths
test_target_home_is_absolute_physical_and_never_traverses_symlink_input
test_managed_dotfile_conflict_blocks_every_mutation_and_bootstrap
test_managed_dotfile_symlinked_ancestor_preserves_external_state
test_unrelated_managed_target_symlink_and_directory_are_preserved
test_exact_managed_dotfile_links_are_idempotent
test_each_managed_dotfile_target_is_preflighted
test_bootstrap_uses_exact_binary_target_home_and_root_config
test_only_exact_legacy_links_are_removed
test_legacy_cleanup_propagates_unlink_failure
test_cleanup_preserves_links_below_symlinked_target_parents
test_regular_files_and_unrelated_links_are_preserved
test_invalid_source_or_target_home_fails_before_mutation
test_vscode_settings_target_supports_only_macos_and_linux
test_vscode_settings_skip_without_user_directory
test_vscode_settings_conflicts_are_preserved
test_vscode_settings_rejects_symlinked_ancestor
test_vscode_settings_link_is_idempotent
test_main_sets_up_vscode_after_mise_bootstrap
printf 'PASS: %s\n' "$(basename "$0")"

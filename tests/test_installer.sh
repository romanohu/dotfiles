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

test_install_script_has_source_guard() {
    assert_file_contains "$REPO_DIR/install.sh" 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]'
}

fixture_sha256() {
    local path="$1"
    local output

    if command -v sha256sum >/dev/null 2>&1; then
        output="$(sha256sum "$path")" || return 1
    else
        output="$(shasum -a 256 "$path")" || return 1
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

    for path in \
        "$temp_root"/dotfiles-nix-installer.* \
        "$temp_root"/.dotfiles-nix-installer-owner.*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        fail "installer temporary path was not cleaned: $path"
    done
}

assert_no_checkout_artifacts() {
    local parent_dir="$1"
    local destination_name="$2"
    local path

    for path in \
        "$parent_dir"/."$destination_name".dotfiles-checkout.* \
        "$parent_dir"/."$destination_name".dotfiles-owner.*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        fail "checkout temporary or lock path was not cleaned: $path"
    done
}

create_local_git_origin() {
    local origin="$1"

    mkdir -p "$origin"
    git -C "$origin" init -q
    git -C "$origin" config user.name 'Dotfiles Tests'
    git -C "$origin" config user.email 'dotfiles-tests@example.invalid'
    printf 'fixture\n' > "$origin/content"
    git -C "$origin" add content
    git -C "$origin" commit -q -m fixture
    git -C "$origin" rev-parse HEAD
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
        if verify_sha256 "$fixture" \
            'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; then
            fail 'verify_sha256 must reject uppercase expected digests'
        fi
        if verify_sha256 "$fixture" 'not-a-sha256'; then
            fail 'verify_sha256 must reject malformed expected digests'
        fi
    )
}

test_sha256_file_rejects_symlinks_and_missing_option_like_paths() {
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
        if sha256_file --binary < /dev/null; then
            fail 'missing option-like filename must not hash standard input'
        fi
    )
}

test_sha256_file_uses_safe_arguments_for_both_backends() {
    local fixture="$TEST_ROOT/sha-backend-file"
    local expected='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

    printf 'backend\n' > "$fixture"

    (
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        has_cmd() {
            [ "$1" = 'sha256sum' ]
        }
        sha256sum() {
            assert_eq '2' "$#" 'sha256sum received an unexpected argument count'
            assert_eq '--' "$1" 'sha256sum did not receive an option terminator'
            assert_eq "$fixture" "$2" 'sha256sum received the wrong file'
            printf '%s  %s\n' "$expected" "$2"
        }

        assert_eq "$expected" "$(sha256_file "$fixture")" \
            'sha256sum backend returned the wrong digest'
    )

    (
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        has_cmd() {
            [ "$1" = 'shasum' ]
        }
        shasum() {
            assert_eq '4' "$#" 'shasum received an unexpected argument count'
            assert_eq '-a' "$1" 'shasum algorithm option missing'
            assert_eq '256' "$2" 'shasum algorithm value changed'
            assert_eq '--' "$3" 'shasum did not receive an option terminator'
            assert_eq "$fixture" "$4" 'shasum received the wrong file'
            printf '%s  %s\n' "$expected" "$4"
        }

        assert_eq "$expected" "$(sha256_file "$fixture")" \
            'shasum backend returned the wrong digest'
    )
}

test_verified_installer_executes_only_after_hash_match() {
    local fixture="$TEST_ROOT/harmless-installer.sh"
    local marker="$TEST_ROOT/verified-installer-executed"
    local temp_root="$TEST_ROOT/verified-installer-tmp"
    local actual_sha

    mkdir -p "$temp_root"
    printf '%s\n' '#!/usr/bin/env bash' ': > "$EXECUTED_MARKER"' > "$fixture"
    actual_sha="$(fixture_sha256 "$fixture")"

    (
        export EXECUTED_MARKER="$marker"
        export TEST_CURL_SOURCE="$fixture"
        export TMPDIR="$temp_root"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        curl() {
            local output_path=""

            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --output|-o)
                        output_path="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            [ -n "$output_path" ] || return 91
            cp "$TEST_CURL_SOURCE" "$output_path"
        }

        if run_verified_installer 'https://example.invalid/installer.sh' \
            '0000000000000000000000000000000000000000000000000000000000000000'; then
            fail 'verified installer must reject a mismatched digest'
        fi
        assert_path_missing "$EXECUTED_MARKER"
        assert_no_installer_temp_dirs "$TMPDIR"

        run_verified_installer 'https://example.invalid/installer.sh' "$actual_sha"
        assert_path_exists "$EXECUTED_MARKER"
        assert_no_installer_temp_dirs "$TMPDIR"
    )
}

test_verified_installer_cleans_transport_failure() {
    local temp_root="$TEST_ROOT/verified-installer-transport-tmp"

    mkdir -p "$temp_root"
    (
        export TMPDIR="$temp_root"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        curl() {
            return 92
        }

        if run_verified_installer 'https://example.invalid/installer.sh' \
            '0000000000000000000000000000000000000000000000000000000000000000'; then
            fail 'verified installer must propagate transport failure'
        fi
        assert_no_installer_temp_dirs "$TMPDIR"
    )
}

test_verified_installer_preserves_foreign_replacement_at_owned_path() {
    local temp_root="$TEST_ROOT/verified-installer-replacement-tmp"
    local moved_owned="$TEST_ROOT/verified-installer-moved-owned"

    mkdir -p "$temp_root"
    (
        export TMPDIR="$temp_root"
        export TEST_MOVED_INSTALLER_DIR="$moved_owned"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        curl() {
            local output_path=""

            while [ "$#" -gt 0 ]; do
                if [ "$1" = '--output' ]; then
                    shift
                    output_path="$1"
                fi
                shift
            done
            [ -n "$output_path" ] || return 90
            command mv "${output_path%/*}" "$TEST_MOVED_INSTALLER_DIR" || return 91
            mkdir "${output_path%/*}" || return 92
            printf 'foreign\n' > "${output_path%/*}/sentinel"
            return 93
        }

        if run_verified_installer 'https://example.invalid/installer.sh' \
            '0000000000000000000000000000000000000000000000000000000000000000'; then
            fail 'verified installer must propagate replacement transport failure'
        fi
        assert_eq 'foreign' "$(cat "$temp_root"/dotfiles-nix-installer.*/sentinel)" \
            'foreign installer directory was deleted or changed'
        assert_path_exists "$TEST_MOVED_INSTALLER_DIR"
        if find "$temp_root" -mindepth 1 -maxdepth 1 \
            -name '.dotfiles-nix-installer-owner.*' -print -quit | grep -q .; then
            fail 'installer owner token was not cleaned after foreign replacement'
        fi
    )
}

test_verified_installer_signal_cleans_temporary_directory() {
    local temp_root="$TEST_ROOT/verified-installer-signal-tmp"
    local ready="$TEST_ROOT/verified-installer-signal-ready"
    local installer_pid signal_status

    mkdir -p "$temp_root"
    (
        export TMPDIR="$temp_root"
        export TEST_SIGNAL_READY="$ready"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        curl() {
            : > "$TEST_SIGNAL_READY"
            while :; do
                sleep 1
            done
        }

        run_verified_installer 'https://example.invalid/installer.sh' \
            '0000000000000000000000000000000000000000000000000000000000000000' &
        installer_pid=$!
        wait_for_path "$TEST_SIGNAL_READY"
        kill -TERM "$installer_pid"
        if wait "$installer_pid"; then
            fail 'TERM-interrupted installer unexpectedly succeeded'
        else
            signal_status=$?
        fi
        assert_eq '143' "$signal_status" 'installer did not preserve TERM status'
        assert_no_installer_temp_dirs "$TMPDIR"
    )
}

test_verified_installer_chains_existing_term_handler() {
    local temp_root="$TEST_ROOT/verified-installer-chain-tmp"
    local ready="$TEST_ROOT/verified-installer-chain-ready"
    local handler_marker="$TEST_ROOT/verified-installer-chain-handler"
    local installer_pid signal_status handler_count

    mkdir -p "$temp_root"
    (
        export TMPDIR="$temp_root"
        export TEST_SIGNAL_READY="$ready"
        export TEST_SIGNAL_HANDLER_MARKER="$handler_marker"
        trap 'printf "handled\n" >> "$TEST_SIGNAL_HANDLER_MARKER"; exit 77' TERM
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        curl() {
            : > "$TEST_SIGNAL_READY"
            while :; do
                sleep 1
            done
        }

        run_verified_installer 'https://example.invalid/installer.sh' \
            '0000000000000000000000000000000000000000000000000000000000000000'
    ) &
    installer_pid=$!

    wait_for_path "$ready"
    kill -TERM "$installer_pid"
    if wait "$installer_pid"; then
        fail 'TERM handler chain unexpectedly succeeded'
    else
        signal_status=$?
    fi
    assert_eq '77' "$signal_status" 'existing TERM handler exit status was not preserved'
    handler_count="$(wc -l < "$handler_marker" | tr -d ' ')"
    assert_eq '1' "$handler_count" \
        "existing TERM handler ran $handler_count times instead of once"
    assert_no_installer_temp_dirs "$temp_root"
}

run_verified_installer_signal_after_trap_install() {
    local handler_kind="$1"
    local expected_status="$2"
    local temp_root="$TEST_ROOT/verified-installer-trap-$handler_kind-tmp"
    local ready="$TEST_ROOT/verified-installer-trap-$handler_kind-ready"
    local handler_marker="$TEST_ROOT/verified-installer-trap-$handler_kind-handler"
    local installer_pid signal_status handler_count

    mkdir -p "$temp_root"
    (
        export TMPDIR="$temp_root"
        export TEST_SIGNAL_READY="$ready"
        export TEST_SIGNAL_HANDLER_MARKER="$handler_marker"
        if [ "$handler_kind" = 'exit' ]; then
            trap 'printf "handled\n" >> "$TEST_SIGNAL_HANDLER_MARKER"; exit 77' TERM
        else
            trap 'printf "handled\n" >> "$TEST_SIGNAL_HANDLER_MARKER"' TERM
        fi
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        verified_installer_test_after_traps_installed() {
            : > "$TEST_SIGNAL_READY"
            if [ "$handler_kind" = 'exit' ]; then
                while :; do
                    sleep 1
                done
            else
                while [ ! -e "$TEST_SIGNAL_HANDLER_MARKER" ]; do
                    sleep 0.1
                done
            fi
        }
        mktemp() {
            local created_path

            created_path="$(command mktemp "$@")" || return $?
            : > "$TEST_SIGNAL_READY"
            command sleep 1
            printf '%s\n' "$created_path"
        }
        curl() {
            return 92
        }

        run_verified_installer 'https://example.invalid/installer.sh' \
            '0000000000000000000000000000000000000000000000000000000000000000'
    ) &
    installer_pid=$!

    wait_for_path "$ready"
    assert_no_installer_temp_dirs "$temp_root"
    kill -TERM "$installer_pid"
    if wait "$installer_pid"; then
        fail "TERM after installer trap installation unexpectedly succeeded ($handler_kind)"
    else
        signal_status=$?
    fi
    assert_eq "$expected_status" "$signal_status" \
        "installer trap-install signal status was wrong ($handler_kind)"
    handler_count="$(wc -l < "$handler_marker" | tr -d ' ')"
    assert_eq '1' "$handler_count" \
        "installer trap-install handler ran $handler_count times ($handler_kind)"
    assert_no_installer_temp_dirs "$temp_root"
}

test_verified_installer_signal_after_trap_install_chains_callers() {
    run_verified_installer_signal_after_trap_install 'exit' '77'
    run_verified_installer_signal_after_trap_install 'return' '143'
}

test_preflight_failure_prevents_all_main_mutations() {
    local target_home="$TEST_ROOT/preflight-target"
    local mutation_marker="$TEST_ROOT/preflight-mutation"

    mkdir -p "$TEST_ROOT/preflight-source"
    (
        export DOTFILES_TARGET_HOME="$target_home"
        export DOTFILES_SOURCE_DIR="$TEST_ROOT/preflight-source"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        has_cmd() {
            [ "$1" != 'git' ]
        }
        mark_mutation() {
            : > "$mutation_marker"
        }
        install_nix_if_needed() { mark_mutation; }
        install_devbox_if_needed() { mark_mutation; }
        cleanup_legacy_managed_links() { mark_mutation; }
        setup_dotfiles_links() { mark_mutation; }
        setup_devbox_global() { mark_mutation; }
        setup_oh_my_zsh() { mark_mutation; }
        setup_npm_prefix() { mark_mutation; }

        if main; then
            fail 'main must fail when a required command is unavailable'
        fi
        assert_path_missing "$mutation_marker"
        assert_path_missing "$target_home"
    )
}

test_existing_exact_devbox_version_skips_install() {
    local install_marker="$TEST_ROOT/devbox-exact-install"
    local output

    (
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        ensure_common_path() { return 0; }
        source_nix_env_if_present() { return 0; }
        has_cmd() {
            case "$1" in
                devbox|nix) return 0 ;;
                *) return 1 ;;
            esac
        }
        devbox() {
            assert_eq 'version' "$1" 'unexpected devbox command'
            printf '0.17.3\n'
        }
        nix() {
            : > "$install_marker"
        }

        output="$(install_devbox_if_needed 2>&1)"
        assert_path_missing "$install_marker"
        case "$output" in
            *'devbox 0.17.3 is already installed. Skipping.'*) ;;
            *) fail "exact Devbox version was not recognized: $output" ;;
        esac
    )
}

test_existing_different_devbox_version_is_warned_and_preserved() {
    local install_marker="$TEST_ROOT/devbox-different-install"
    local output

    (
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        ensure_common_path() { return 0; }
        source_nix_env_if_present() { return 0; }
        has_cmd() {
            case "$1" in
                devbox|nix) return 0 ;;
                *) return 1 ;;
            esac
        }
        devbox() {
            assert_eq 'version' "$1" 'unexpected devbox command'
            printf '0.17.2\n'
        }
        nix() {
            : > "$install_marker"
        }

        output="$(install_devbox_if_needed 2>&1)"
        assert_path_missing "$install_marker"
        case "$output" in
            *'[dotfiles][warn]'*'preserving it'*) ;;
            *) fail "different Devbox version did not warn: $output" ;;
        esac
    )
}

test_malformed_devbox_version_ending_in_pin_is_warned_and_preserved() {
    local install_marker="$TEST_ROOT/devbox-malformed-install"
    local output

    (
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        ensure_common_path() { return 0; }
        source_nix_env_if_present() { return 0; }
        has_cmd() {
            case "$1" in
                devbox|nix) return 0 ;;
                *) return 1 ;;
            esac
        }
        devbox() {
            assert_eq 'version' "$1" 'unexpected devbox command'
            printf 'not-a-version record 0.17.3\n'
        }
        nix() {
            : > "$install_marker"
        }

        output="$(install_devbox_if_needed 2>&1)"
        assert_path_missing "$install_marker"
        case "$output" in
            *'[dotfiles][warn]'*'preserving it'*) ;;
            *) fail "malformed Devbox version did not warn: $output" ;;
        esac
    )
}

test_nix_setup_passes_active_pinned_installer_arguments() {
    local installed_marker="$TEST_ROOT/nix-active-pin-installed"
    local argument_capture="$TEST_ROOT/nix-active-pin-arguments"
    local expected_arguments

    expected_arguments=$(printf '%s\n' \
        'https://install.determinate.systems/nix/tag/v3.21.2/nix-installer.sh' \
        '4141f93485a16d600b995d02b2bdd296fb69af30ea3665037677b8d56f703b56' \
        'install' \
        '--no-confirm')

    (
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        has_cmd() {
            case "$1" in
                nix) [ -e "$installed_marker" ] ;;
                *) return 0 ;;
            esac
        }
        source_nix_env_if_present() { return 0; }
        run_verified_installer() {
            printf '%s\n' "$@" > "$argument_capture"
            : > "$installed_marker"
        }

        install_nix_if_needed
        assert_eq "$expected_arguments" "$(cat "$argument_capture")" \
            'Nix setup did not pass the active pinned installer arguments'
    )
}

test_devbox_setup_passes_active_pinned_flake() {
    local installed_marker="$TEST_ROOT/devbox-active-pin-installed"
    local argument_capture="$TEST_ROOT/devbox-active-pin-arguments"
    local expected_arguments

    expected_arguments=$(printf '%s\n' \
        'profile' \
        'install' \
        'github:jetify-com/devbox/0.17.3')

    (
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        ensure_common_path() { return 0; }
        source_nix_env_if_present() { return 0; }
        has_cmd() {
            case "$1" in
                devbox) [ -e "$installed_marker" ] ;;
                nix) return 0 ;;
                *) return 1 ;;
            esac
        }
        nix() {
            printf '%s\n' "$@" > "$argument_capture"
            : > "$installed_marker"
        }
        devbox() {
            assert_eq 'version' "$1" 'unexpected post-install devbox command'
            printf '0.17.3\n'
        }

        install_devbox_if_needed
        assert_eq "$expected_arguments" "$(cat "$argument_capture")" \
            'Devbox setup did not pass the active pinned flake'
    )
}

test_devbox_post_install_requires_exact_version() {
    local exact_marker="$TEST_ROOT/devbox-post-exact"
    local rejected_output

    (
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        ensure_common_path() { return 0; }
        source_nix_env_if_present() { return 0; }
        has_cmd() {
            case "$1" in
                devbox) [ -e "$exact_marker" ] ;;
                nix) return 0 ;;
                *) return 1 ;;
            esac
        }
        nix() {
            : > "$exact_marker"
        }
        devbox() {
            printf '0.17.3\n'
        }

        install_devbox_if_needed
    )

    for rejected_output in '0.17.2' 'malformed output 0.17.3'; do
        local rejected_marker="$TEST_ROOT/devbox-post-rejected-${rejected_output%% *}"

        if (
            # shellcheck source=/dev/null
            . "$INSTALLER_RUNTIME_PATH"
            ensure_common_path() { return 0; }
            source_nix_env_if_present() { return 0; }
            has_cmd() {
                case "$1" in
                    devbox) [ -e "$rejected_marker" ] ;;
                    nix) return 0 ;;
                    *) return 1 ;;
                esac
            }
            nix() {
                : > "$rejected_marker"
            }
            devbox() {
                printf '%s\n' "$rejected_output"
            }

            install_devbox_if_needed
        ); then
            fail "post-install Devbox version must be rejected: $rejected_output"
        fi
    done
}

test_zsh_setup_passes_active_pinned_checkout_arguments() {
    local target_home="$TEST_ROOT/zsh-active-pins-target"
    local argument_capture="$TEST_ROOT/zsh-active-pins-arguments"
    local omz_dir="$target_home/.config/zsh/oh-my-zsh"
    local plugin_dir="$omz_dir/custom/plugins"
    local expected_arguments

    expected_arguments=$(printf '%s\n' \
        "https://github.com/ohmyzsh/ohmyzsh.git|677a4592b18c08ddea737f8aca70bac0e9fc9313|$omz_dir" \
        "https://github.com/zsh-users/zsh-autosuggestions.git|85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5|$plugin_dir/zsh-autosuggestions" \
        "https://github.com/zsh-users/zsh-syntax-highlighting.git|1d85c692615a25fe2293bdd44b34c217d5d2bf04|$plugin_dir/zsh-syntax-highlighting")

    (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        ensure_safe_target_parent() { return 0; }
        pinned_checkout_has_exact_head() { return 0; }
        ensure_pinned_checkout() {
            printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$argument_capture"
            case "$3" in
                */oh-my-zsh)
                    mkdir -p "$3/.git" || return 1
                    ;;
            esac
        }

        setup_oh_my_zsh
        assert_eq "$expected_arguments" "$(cat "$argument_capture")" \
            'Zsh setup did not pass all active pinned checkout arguments'
    )
}

test_mismatched_oh_my_zsh_checkout_is_fully_preserved() {
    local target_home="$TEST_ROOT/omz-mismatch-target"
    local omz_dir="$target_home/.config/zsh/oh-my-zsh"
    local output_file="$TEST_ROOT/omz-mismatch-output"
    local before after output

    mkdir -p "$omz_dir"
    git -C "$omz_dir" init -q
    git -C "$omz_dir" config user.name 'Dotfiles Tests'
    git -C "$omz_dir" config user.email 'dotfiles-tests@example.invalid'
    printf 'existing\n' > "$omz_dir/existing"
    git -C "$omz_dir" add existing
    git -C "$omz_dir" commit -q -m existing
    before="$(snapshot_tree "$omz_dir")"

    (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        ensure_pinned_checkout() { return 0; }

        setup_oh_my_zsh > "$output_file" 2>&1
    )

    after="$(snapshot_tree "$omz_dir")"
    assert_eq "$before" "$after" 'mismatched Oh My Zsh checkout was mutated'
    output="$(cat "$output_file")"
    case "$output" in
        *'[dotfiles][warn]'*) ;;
        *) fail "mismatched Oh My Zsh checkout did not warn: $output" ;;
    esac
}

test_uninspectable_oh_my_zsh_checkout_is_fully_preserved() {
    local target_home="$TEST_ROOT/omz-uninspectable-target"
    local omz_dir="$target_home/.config/zsh/oh-my-zsh"
    local output_file="$TEST_ROOT/omz-uninspectable-output"
    local before after output

    mkdir -p "$omz_dir"
    printf 'not git metadata\n' > "$omz_dir/.git"
    printf 'existing\n' > "$omz_dir/existing"
    before="$(snapshot_tree "$omz_dir")"

    (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        ensure_pinned_checkout() { return 0; }

        setup_oh_my_zsh > "$output_file" 2>&1
    )

    after="$(snapshot_tree "$omz_dir")"
    assert_eq "$before" "$after" 'uninspectable Oh My Zsh checkout was mutated'
    output="$(cat "$output_file")"
    case "$output" in
        *'[dotfiles][warn]'*) ;;
        *) fail "uninspectable Oh My Zsh checkout did not warn: $output" ;;
    esac
}

test_concurrent_pinned_checkouts_serialize_to_one_root() {
    local origin="$TEST_ROOT/concurrent-origin"
    local destination="$TEST_ROOT/concurrent-destination"
    local first_locked="$TEST_ROOT/concurrent-first-locked"
    local release_first="$TEST_ROOT/concurrent-release-first"
    local second_waiting="$TEST_ROOT/concurrent-second-waiting"
    local second_done="$TEST_ROOT/concurrent-second-done"
    local commit destination_root first_pid second_pid first_status second_status

    commit="$(create_local_git_origin "$origin")"

    (
        export TEST_FIRST_LOCKED="$first_locked"
        export TEST_RELEASE_FIRST="$release_first"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        pinned_checkout_test_after_lock_acquired() {
            : > "$TEST_FIRST_LOCKED"
            while [ ! -e "$TEST_RELEASE_FIRST" ]; do
                command sleep 0.1
            done
        }

        ensure_pinned_checkout "$origin" "$commit" "$destination"
    ) &
    first_pid=$!
    wait_for_path "$first_locked"

    (
        export TEST_SECOND_WAITING="$second_waiting"
        export TEST_SECOND_DONE="$second_done"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        sleep() {
            : > "$TEST_SECOND_WAITING"
            command sleep "$@"
        }

        if ensure_pinned_checkout "$origin" "$commit" "$destination"; then
            printf '0\n' > "$TEST_SECOND_DONE"
            exit 0
        else
            second_checkout_status=$?
            printf '%s\n' "$second_checkout_status" > "$TEST_SECOND_DONE"
            exit "$second_checkout_status"
        fi
    ) &
    second_pid=$!
    wait_for_path "$second_waiting"

    assert_path_missing "$destination"
    assert_path_missing "$second_done"
    : > "$release_first"

    if wait "$first_pid"; then first_status=0; else first_status=$?; fi
    if wait "$second_pid"; then second_status=0; else second_status=$?; fi
    assert_eq '0' "$first_status" 'first concurrent checkout failed'
    assert_eq '0' "$second_status" 'second concurrent checkout failed'
    destination_root="$(CDPATH= cd -- "$destination" && pwd -P)"
    assert_eq "$destination_root" "$(git -C "$destination" rev-parse --show-toplevel)" \
        'concurrent checkout is not rooted at the destination'
    assert_eq "$commit" "$(git -C "$destination" rev-parse HEAD)" \
        'concurrent checkout resolved to the wrong commit'
    if find "$destination" -mindepth 1 \
        \( -name '.concurrent-destination.dotfiles-checkout.*' \
        -o -name '.concurrent-destination.dotfiles-owner.*' \) \
        -print -quit | grep -q .; then
        fail 'concurrent checkout left a nested temporary, lock, or owner token'
    fi
    assert_no_checkout_artifacts "$TEST_ROOT" 'concurrent-destination'
}

test_checkout_restores_subshell_local_exit_trap() {
    local origin="$TEST_ROOT/subshell-exit-origin"
    local destination="$TEST_ROOT/subshell-exit-destination"
    local handler_marker="$TEST_ROOT/subshell-exit-handler"
    local commit handler_count

    commit="$(create_local_git_origin "$origin")"
    (
        export TEST_CHECKOUT_HANDLER_MARKER="$handler_marker"
        trap 'printf "handled\n" >> "$TEST_CHECKOUT_HANDLER_MARKER"' EXIT
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"

        ensure_pinned_checkout "$origin" "$commit" "$destination"
    )

    handler_count="$(wc -l < "$handler_marker" | tr -d ' ')"
    assert_eq '1' "$handler_count" \
        'subshell-local EXIT handler was not restored exactly once'
}

test_checkout_collision_before_finalize_is_preserved_without_nesting() {
    local origin="$TEST_ROOT/collision-origin"
    local destination="$TEST_ROOT/collision-destination"
    local commit

    commit="$(create_local_git_origin "$origin")"
    (
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        pinned_checkout_test_before_finalize() {
            mkdir "$2" || return 1
            printf 'collision\n' > "$2/sentinel"
        }

        if ensure_pinned_checkout "$origin" "$commit" "$destination"; then
            fail 'checkout must fail when destination appears before finalization'
        fi
        assert_eq 'collision' "$(cat "$destination/sentinel")" \
            'injected collision destination was changed'
        if find "$destination" -mindepth 1 -maxdepth 1 \
            -name '.collision-destination.dotfiles-checkout.*' -print -quit |
            grep -q .; then
            fail 'temporary checkout was nested under collision destination'
        fi
        assert_no_checkout_artifacts "$TEST_ROOT" 'collision-destination'
    )
}

test_checkout_collision_inside_mv_preserves_foreign_destination() {
    local origin="$TEST_ROOT/mv-collision-origin"
    local destination="$TEST_ROOT/mv-collision-destination"
    local commit

    commit="$(create_local_git_origin "$origin")"
    (
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        mv() {
            mkdir "$2" || return 1
            printf 'foreign\n' > "$2/sentinel"
            command mv "$1" "$2"
        }

        if ensure_pinned_checkout "$origin" "$commit" "$destination"; then
            fail 'checkout must fail when destination appears inside mv'
        fi
        assert_eq 'foreign' "$(cat "$destination/sentinel")" \
            'foreign destination was deleted or changed after mv collision'
        if find "$destination" -mindepth 1 -maxdepth 1 \
            -name '.mv-collision-destination.dotfiles-checkout.*' -print -quit |
            grep -q .; then
            fail 'owned temporary checkout remained nested under foreign destination'
        fi
        assert_no_checkout_artifacts "$TEST_ROOT" 'mv-collision-destination'
    )
}

test_checkout_post_move_verification_rejects_corruption() {
    local origin="$TEST_ROOT/post-move-origin"
    local destination="$TEST_ROOT/post-move-destination"
    local commit

    commit="$(create_local_git_origin "$origin")"
    (
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        pinned_checkout_test_before_finalize() {
            rm -rf -- "$1/.git"
        }

        if ensure_pinned_checkout "$origin" "$commit" "$destination"; then
            fail 'checkout must fail when final root verification cannot succeed'
        fi
        assert_path_missing "$destination"
        assert_no_checkout_artifacts "$TEST_ROOT" 'post-move-destination'
    )
}

run_checkout_signal_at_acquisition_seam() {
    local seam="$1"
    local origin="$TEST_ROOT/signal-${seam}-origin"
    local destination="$TEST_ROOT/signal-${seam}-destination"
    local ready="$TEST_ROOT/signal-${seam}-ready"
    local commit checkout_pid signal_status

    commit="$(create_local_git_origin "$origin")"
    (
        export TEST_CHECKOUT_SIGNAL_READY="$ready"
        export TEST_CHECKOUT_SIGNAL_SEAM="$seam"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        block_checkout_for_signal() {
            : > "$TEST_CHECKOUT_SIGNAL_READY"
            while :; do
                sleep 1
            done
        }
        pinned_checkout_test_after_lock_acquired() {
            [ "$TEST_CHECKOUT_SIGNAL_SEAM" != 'after-lock' ] ||
                block_checkout_for_signal
        }
        pinned_checkout_test_after_temp_created() {
            [ "$TEST_CHECKOUT_SIGNAL_SEAM" != 'after-temp' ] ||
                block_checkout_for_signal
        }
        pinned_checkout_test_after_move() {
            [ "$TEST_CHECKOUT_SIGNAL_SEAM" != 'after-move' ] ||
                block_checkout_for_signal
        }

        ensure_pinned_checkout "$origin" "$commit" "$destination"
    ) &
    checkout_pid=$!

    wait_for_path "$ready"
    kill -TERM "$checkout_pid"
    if wait "$checkout_pid"; then
        fail "TERM-interrupted checkout unexpectedly succeeded at $seam"
    else
        signal_status=$?
    fi
    assert_eq '143' "$signal_status" "checkout did not preserve TERM status at $seam"
    assert_path_missing "$destination"
    assert_no_checkout_artifacts "$TEST_ROOT" "signal-${seam}-destination"
}

test_checkout_signals_clean_each_acquisition_seam() {
    run_checkout_signal_at_acquisition_seam 'after-lock'
    run_checkout_signal_at_acquisition_seam 'after-temp'
    run_checkout_signal_at_acquisition_seam 'after-move'
}

test_checkout_signal_cleans_temporary_directory_and_lock() {
    local origin="$TEST_ROOT/signal-origin"
    local destination="$TEST_ROOT/signal-destination"
    local ready="$TEST_ROOT/signal-checkout-ready"
    local commit checkout_pid signal_status

    commit="$(create_local_git_origin "$origin")"
    (
        export TEST_CHECKOUT_SIGNAL_READY="$ready"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        pinned_checkout_test_before_finalize() {
            : > "$TEST_CHECKOUT_SIGNAL_READY"
            while :; do
                sleep 1
            done
        }

        ensure_pinned_checkout "$origin" "$commit" "$destination"
    ) &
    checkout_pid=$!

    wait_for_path "$ready"
    kill -HUP "$checkout_pid"
    if wait "$checkout_pid"; then
        fail 'HUP-interrupted checkout unexpectedly succeeded'
    else
        signal_status=$?
    fi
    assert_eq '129' "$signal_status" 'checkout did not preserve HUP status'
    assert_path_missing "$destination"
    assert_no_checkout_artifacts "$TEST_ROOT" 'signal-destination'
}

test_checkout_chains_existing_hup_handler() {
    local origin="$TEST_ROOT/signal-chain-origin"
    local destination="$TEST_ROOT/signal-chain-destination"
    local ready="$TEST_ROOT/signal-chain-ready"
    local handler_marker="$TEST_ROOT/signal-chain-handler"
    local commit checkout_pid signal_status handler_count

    commit="$(create_local_git_origin "$origin")"
    (
        export TEST_CHECKOUT_SIGNAL_READY="$ready"
        export TEST_CHECKOUT_HANDLER_MARKER="$handler_marker"
        trap 'printf "handled\n" >> "$TEST_CHECKOUT_HANDLER_MARKER"; exit 77' HUP
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        pinned_checkout_test_after_lock_acquired() {
            : > "$TEST_CHECKOUT_SIGNAL_READY"
            while :; do
                sleep 1
            done
        }

        ensure_pinned_checkout "$origin" "$commit" "$destination"
    ) &
    checkout_pid=$!

    wait_for_path "$ready"
    kill -HUP "$checkout_pid"
    if wait "$checkout_pid"; then
        fail 'HUP handler chain unexpectedly succeeded'
    else
        signal_status=$?
    fi
    assert_eq '77' "$signal_status" 'existing HUP handler exit status was not preserved'
    handler_count="$(wc -l < "$handler_marker" | tr -d ' ')"
    assert_eq '1' "$handler_count" \
        "existing HUP handler ran $handler_count times instead of once"
    assert_path_missing "$destination"
    assert_no_checkout_artifacts "$TEST_ROOT" 'signal-chain-destination'
}

test_checkout_returning_term_handler_falls_back_to_signal_status() {
    local origin="$TEST_ROOT/signal-return-origin"
    local destination="$TEST_ROOT/signal-return-destination"
    local ready="$TEST_ROOT/signal-return-ready"
    local handler_marker="$TEST_ROOT/signal-return-handler"
    local commit checkout_pid signal_status handler_count

    commit="$(create_local_git_origin "$origin")"
    (
        export TEST_CHECKOUT_SIGNAL_READY="$ready"
        export TEST_CHECKOUT_HANDLER_MARKER="$handler_marker"
        trap 'printf "handled\n" >> "$TEST_CHECKOUT_HANDLER_MARKER"' TERM
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        pinned_checkout_test_after_lock_acquired() {
            : > "$TEST_CHECKOUT_SIGNAL_READY"
            while [ ! -e "$TEST_CHECKOUT_HANDLER_MARKER" ]; do
                sleep 0.1
            done
        }

        ensure_pinned_checkout "$origin" "$commit" "$destination"
    ) &
    checkout_pid=$!

    wait_for_path "$ready"
    kill -TERM "$checkout_pid"
    if wait "$checkout_pid"; then
        fail 'returning TERM handler unexpectedly allowed checkout to succeed'
    else
        signal_status=$?
    fi
    assert_eq '143' "$signal_status" \
        'returning TERM handler did not fall back to the conventional signal status'
    handler_count="$(wc -l < "$handler_marker" | tr -d ' ')"
    assert_eq '1' "$handler_count" \
        "returning TERM handler ran $handler_count times instead of once"
    assert_path_missing "$destination"
    assert_no_checkout_artifacts "$TEST_ROOT" 'signal-return-destination'
}

test_checkout_ignored_term_falls_back_to_signal_status() {
    local origin="$TEST_ROOT/signal-ignore-origin"
    local destination="$TEST_ROOT/signal-ignore-destination"
    local ready="$TEST_ROOT/signal-ignore-ready"
    local commit checkout_pid signal_status

    commit="$(create_local_git_origin "$origin")"
    (
        export TEST_CHECKOUT_SIGNAL_READY="$ready"
        trap '' TERM
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        pinned_checkout_test_after_lock_acquired() {
            : > "$TEST_CHECKOUT_SIGNAL_READY"
            sleep 1
        }

        ensure_pinned_checkout "$origin" "$commit" "$destination"
    ) &
    checkout_pid=$!

    wait_for_path "$ready"
    kill -TERM "$checkout_pid"
    if wait "$checkout_pid"; then
        fail 'ignored TERM unexpectedly allowed checkout to succeed'
    else
        signal_status=$?
    fi
    assert_eq '143' "$signal_status" \
        'ignored TERM did not fall back to the conventional signal status'
    assert_path_missing "$destination"
    assert_no_checkout_artifacts "$TEST_ROOT" 'signal-ignore-destination'
}

run_checkout_signal_after_trap_install() {
    local handler_kind="$1"
    local expected_status="$2"
    local origin="$TEST_ROOT/checkout-trap-$handler_kind-origin"
    local destination="$TEST_ROOT/checkout-trap-$handler_kind-destination"
    local ready="$TEST_ROOT/checkout-trap-$handler_kind-ready"
    local handler_marker="$TEST_ROOT/checkout-trap-$handler_kind-handler"
    local commit checkout_pid signal_status handler_count

    commit="$(create_local_git_origin "$origin")"
    (
        export TEST_CHECKOUT_SIGNAL_READY="$ready"
        export TEST_CHECKOUT_HANDLER_MARKER="$handler_marker"
        if [ "$handler_kind" = 'exit' ]; then
            trap 'printf "handled\n" >> "$TEST_CHECKOUT_HANDLER_MARKER"; exit 77' TERM
        else
            trap 'printf "handled\n" >> "$TEST_CHECKOUT_HANDLER_MARKER"' TERM
        fi
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        pinned_checkout_test_after_traps_installed() {
            : > "$TEST_CHECKOUT_SIGNAL_READY"
            if [ "$handler_kind" = 'exit' ]; then
                while :; do
                    sleep 1
                done
            else
                while [ ! -e "$TEST_CHECKOUT_HANDLER_MARKER" ]; do
                    sleep 0.1
                done
            fi
        }
        mktemp() {
            local created_path

            created_path="$(command mktemp "$@")" || return $?
            : > "$TEST_CHECKOUT_SIGNAL_READY"
            command sleep 1
            printf '%s\n' "$created_path"
        }

        ensure_pinned_checkout "$origin" "$commit" "$destination"
    ) &
    checkout_pid=$!

    wait_for_path "$ready"
    assert_path_missing "$destination"
    assert_no_checkout_artifacts "$TEST_ROOT" \
        "checkout-trap-$handler_kind-destination"
    kill -TERM "$checkout_pid"
    if wait "$checkout_pid"; then
        fail "TERM after checkout trap installation unexpectedly succeeded ($handler_kind)"
    else
        signal_status=$?
    fi
    assert_eq "$expected_status" "$signal_status" \
        "checkout trap-install signal status was wrong ($handler_kind)"
    handler_count="$(wc -l < "$handler_marker" | tr -d ' ')"
    assert_eq '1' "$handler_count" \
        "checkout trap-install handler ran $handler_count times ($handler_kind)"
    assert_path_missing "$destination"
    assert_no_checkout_artifacts "$TEST_ROOT" "checkout-trap-$handler_kind-destination"
}

test_checkout_signal_after_trap_install_chains_callers() {
    run_checkout_signal_after_trap_install 'exit' '77'
    run_checkout_signal_after_trap_install 'return' '143'
}

test_exact_checkout_ignores_foreign_stale_lock() {
    local origin="$TEST_ROOT/stale-exact-origin"
    local destination="$TEST_ROOT/stale-exact-destination"
    local lock_path="$TEST_ROOT/.stale-exact-destination.dotfiles-checkout.lock"
    local commit

    commit="$(create_local_git_origin "$origin")"
    (
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        ensure_pinned_checkout "$origin" "$commit" "$destination"
        mkdir "$lock_path"
        sleep() { return 99; }
        ensure_pinned_checkout "$origin" "$commit" "$destination"
        assert_path_exists "$lock_path"
    )
}

test_absent_checkout_reports_and_preserves_unverifiable_stale_lock() {
    local origin="$TEST_ROOT/stale-absent-origin"
    local destination="$TEST_ROOT/stale-absent-destination"
    local lock_path="$TEST_ROOT/.stale-absent-destination.dotfiles-checkout.lock"
    local commit output

    commit="$(create_local_git_origin "$origin")"
    mkdir "$lock_path"
    (
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        sleep() { return 99; }

        if output="$(ensure_pinned_checkout "$origin" "$commit" "$destination" 2>&1)"; then
            fail 'checkout must fail for an unverifiable stale lock'
        fi
        case "$output" in
            *"$lock_path"*'inspect'*'remove'*) ;;
            *) fail "stale lock diagnostic is not actionable: $output" ;;
        esac
        assert_path_exists "$lock_path"
        assert_path_missing "$destination"
    )
}

test_ensure_pinned_checkout_fetches_exact_commit_and_preserves_existing_checkout() {
    local origin="$TEST_ROOT/pinned-origin"
    local first_destination="$TEST_ROOT/pinned-first"
    local existing_destination="$TEST_ROOT/pinned-existing"
    local first_commit second_commit output

    mkdir -p "$origin"
    git -C "$origin" init -q
    git -C "$origin" config user.name 'Dotfiles Tests'
    git -C "$origin" config user.email 'dotfiles-tests@example.invalid'
    printf 'first\n' > "$origin/content"
    git -C "$origin" add content
    git -C "$origin" commit -q -m first
    first_commit="$(git -C "$origin" rev-parse HEAD)"
    printf 'second\n' > "$origin/content"
    git -C "$origin" commit -q -am second
    second_commit="$(git -C "$origin" rev-parse HEAD)"

    (
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        ensure_pinned_checkout "$origin" "$first_commit" "$first_destination"
        assert_eq "$first_commit" "$(git -C "$first_destination" rev-parse HEAD)" \
            'fresh checkout did not resolve to the requested commit'
        if git -C "$first_destination" symbolic-ref -q HEAD >/dev/null 2>&1; then
            fail 'fresh pinned checkout must have detached HEAD'
        fi
        assert_eq 'first' "$(cat "$first_destination/content")" \
            'fresh pinned checkout contains the wrong revision'

        ensure_pinned_checkout "$origin" "$second_commit" "$existing_destination"
        output="$(ensure_pinned_checkout "$origin" "$first_commit" "$existing_destination" 2>&1)"
        assert_eq "$second_commit" "$(git -C "$existing_destination" rev-parse HEAD)" \
            'existing checkout was changed when a different commit was requested'
        case "$output" in
            *'[dotfiles][warn]'*"$second_commit"*) ;;
            *) fail "different existing commit did not emit a warning: $output" ;;
        esac
    )
}

capture_path_state() {
    local path="$1"

    if [ -L "$path" ]; then
        printf 'link:%s\n' "$(readlink "$path")"
    elif [ -f "$path" ]; then
        cksum "$path" | awk '{ print "file:" $1 ":" $2 }'
    elif [ -d "$path" ]; then
        printf 'directory\n'
    elif [ -e "$path" ]; then
        printf 'other\n'
    else
        printf 'missing\n'
    fi
}

assert_path_within_target() {
    local path="$1"
    local target="$2"

    case "$path" in
        "$target"|"$target"/*) ;;
        *) fail "expected path below temporary target $target: $path" ;;
    esac
}

assert_link_points_to() {
    local link_path="$1"
    local expected_target="$2"

    [ -L "$link_path" ] || fail "expected symlink: $link_path"
    assert_eq "$expected_target" "$(readlink "$link_path")" "unexpected link target for $link_path"
}

path_mode_and_mtime() {
    local path="$1"

    if stat -c '%a:%Y' "$path" >/dev/null 2>&1; then
        stat -c '%a:%Y' "$path"
    else
        stat -f '%Lp:%m' "$path"
    fi
}

assert_preserved_copy() {
    local source_path="$1"
    local copied_path="$2"

    assert_path_exists "$copied_path"
    if [ -f "$source_path" ]; then
        cmp -s "$source_path" "$copied_path" || fail "copied content differs: $copied_path"
    fi
    assert_eq "$(path_mode_and_mtime "$source_path")" "$(path_mode_and_mtime "$copied_path")" \
        "copied mode or modification time differs: $copied_path"
}

assert_directory_empty() {
    local path="$1"

    if find "$path" -mindepth 1 -print -quit | grep -q .; then
        fail "expected directory to remain empty: $path"
    fi
}

snapshot_tree() {
    local path="$1"

    (
        cd "$path"
        find . -print | LC_ALL=C sort | while IFS= read -r entry; do
            if [ -L "$entry" ]; then
                printf 'link %s %s\n' "$entry" "$(readlink "$entry")"
            elif [ -f "$entry" ]; then
                printf 'file %s ' "$entry"
                cksum "$entry"
                ls -ld "$entry"
            elif [ -d "$entry" ]; then
                printf 'dir %s ' "$entry"
                ls -ld "$entry"
            fi
        done
    )
}

test_zsh_symlink_is_backed_up_without_mutating_target() {
    local source_dir="$TEST_ROOT/zsh-source"
    local target_home="$TEST_ROOT/zsh-target"
    local source_zsh_dir="$source_dir/.config/zsh"
    local physical_source_zsh_dir
    local before after run_dir_count sole_run_dir source_dump_file

    mkdir -p "$source_zsh_dir/.zsh_sessions" "$source_zsh_dir/oh-my-zsh"
    physical_source_zsh_dir=$(CDPATH= cd -P -- "$source_zsh_dir" && pwd -P)
    printf 'zshrc\n' > "$source_zsh_dir/.zshrc"
    printf 'aliases\n' > "$source_zsh_dir/aliases.zsh"
    printf 'pet\n' > "$source_zsh_dir/pet.zsh"
    printf 'history\n' > "$source_zsh_dir/.zsh_history"
    printf 'session\n' > "$source_zsh_dir/.zsh_sessions/session"
    printf 'dump one\n' > "$source_zsh_dir/.zcompdump-test"
    printf 'dump two\n' > "$source_zsh_dir/.zcompdump-test.zwc"
    printf 'must not migrate\n' > "$source_zsh_dir/oh-my-zsh/README"
    chmod 640 "$source_zsh_dir/.zsh_history"
    chmod 751 "$source_zsh_dir/.zsh_sessions"
    chmod 640 "$source_zsh_dir/.zsh_sessions/session"
    chmod 600 "$source_zsh_dir/.zcompdump-test"
    chmod 641 "$source_zsh_dir/.zcompdump-test.zwc"
    touch -t 202001020304.05 "$source_zsh_dir/.zsh_history" \
                           "$source_zsh_dir/.zsh_sessions/session" \
                           "$source_zsh_dir/.zcompdump-test" \
                           "$source_zsh_dir/.zcompdump-test.zwc"
    touch -t 202001020305.06 "$source_zsh_dir/.zsh_sessions"
    before="$(snapshot_tree "$source_zsh_dir")"

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        mkdir -p "$target_home/.config"
        ln -s "$physical_source_zsh_dir" "$target_home/.config/zsh"

        prepare_zsh_dir

        assert_preserved_copy "$source_zsh_dir/.zsh_history" "$target_home/.config/zsh/.zsh_history"
        assert_preserved_copy "$source_zsh_dir/.zsh_sessions" "$target_home/.config/zsh/.zsh_sessions"
        assert_preserved_copy "$source_zsh_dir/.zsh_sessions/session" "$target_home/.config/zsh/.zsh_sessions/session"
        for source_dump_file in "$source_zsh_dir"/.zcompdump*; do
            assert_preserved_copy "$source_dump_file" "$target_home/.config/zsh/$(basename "$source_dump_file")"
        done
        assert_path_missing "$target_home/.config/zsh/oh-my-zsh"

        run_dir_count=0
        for sole_run_dir in "$target_home/.dotfiles-backup"/run.*; do
            [ -d "$sole_run_dir" ] || continue
            run_dir_count=$((run_dir_count + 1))
        done
        assert_eq '1' "$run_dir_count" 'expected exactly one backup run directory'
        assert_link_points_to "$sole_run_dir/.config/zsh" "$physical_source_zsh_dir"
    )

    after="$(snapshot_tree "$source_zsh_dir")"
    assert_eq "$before" "$after" 'Zsh source fixtures or metadata changed during migration'
}

test_wezterm_managed_directory_symlink_migrates_to_local_directory() {
    local source_dir="$TEST_ROOT/wezterm-source"
    local target_home="$TEST_ROOT/wezterm-target"
    local source_wezterm_dir="$source_dir/.config/wezterm"
    local physical_source_wezterm_dir run_dir

    mkdir -p "$source_wezterm_dir" "$target_home/.config"
    printf 'return {}\n' > "$source_wezterm_dir/wezterm.lua"
    physical_source_wezterm_dir=$(CDPATH= cd -P -- "$source_wezterm_dir" && pwd -P)

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        ln -s "$physical_source_wezterm_dir" "$target_home/.config/wezterm"

        prepare_wezterm_dir
        printf 'private host\n' > "$target_home/.config/wezterm/local.lua"
        safe_link_or_copy "$DOT_DIR/.config/wezterm/wezterm.lua" \
            "$target_home/.config/wezterm/wezterm.lua"

        [ -d "$target_home/.config/wezterm" ] && [ ! -L "$target_home/.config/wezterm" ] ||
            fail 'managed WezTerm directory symlink must migrate to a real directory'
        assert_link_points_to "$target_home/.config/wezterm/wezterm.lua" \
            "$physical_source_wezterm_dir/wezterm.lua"
        assert_eq 'private host' "$(cat "$target_home/.config/wezterm/local.lua")" \
            'WezTerm migration must preserve unrelated local files'
        for run_dir in "$target_home/.dotfiles-backup"/run.*; do
            [ -d "$run_dir" ] || continue
            assert_link_points_to "$run_dir/.config/wezterm" "$physical_source_wezterm_dir"
            return 0
        done
        fail 'WezTerm migration must back up the exact legacy managed directory link'
    )
}

test_wezterm_setup_rejects_unrelated_symlinked_parent() {
    local source_dir="$TEST_ROOT/wezterm-parent-source"
    local target_home="$TEST_ROOT/wezterm-parent-target"
    local external_dir="$TEST_ROOT/wezterm-parent-external"

    mkdir -p "$source_dir/.config/wezterm" "$external_dir" "$target_home"
    printf 'return {}\n' > "$source_dir/.config/wezterm/wezterm.lua"
    ln -s "$external_dir" "$target_home/.config"

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        if prepare_wezterm_dir; then
            fail 'WezTerm setup must reject an unrelated symlinked parent'
        fi
        assert_path_missing "$external_dir/wezterm"
    )
}

test_zsh_runtime_symlinks_are_not_dereferenced() {
    local source_dir="$TEST_ROOT/runtime-symlink-source"
    local target_home="$TEST_ROOT/runtime-symlink-target"
    local source_zsh_dir="$source_dir/.config/zsh"
    local physical_source_zsh_dir
    local external_dir="$TEST_ROOT/runtime-symlink-external"
    local internal_link="$target_home/.config/zsh/.zsh_sessions/external-link"
    local source_before source_after external_before external_after

    mkdir -p "$source_zsh_dir" "$external_dir/sessions"
    physical_source_zsh_dir=$(CDPATH= cd -P -- "$source_zsh_dir" && pwd -P)
    printf 'external history\n' > "$external_dir/history"
    printf 'external session\n' > "$external_dir/sessions/session"
    printf 'external dump\n' > "$external_dir/dump"
    printf 'local dump\n' > "$source_zsh_dir/.zcompdump-local"
    ln -s "$external_dir/history" "$source_zsh_dir/.zsh_history"
    ln -s "$external_dir/sessions" "$source_zsh_dir/.zsh_sessions"
    ln -s "$external_dir/dump" "$source_zsh_dir/.zcompdump-external"
    source_before="$(snapshot_tree "$source_zsh_dir")"
    external_before="$(snapshot_tree "$external_dir")"

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        mkdir -p "$target_home/.config"
        ln -s "$physical_source_zsh_dir" "$target_home/.config/zsh"

        prepare_zsh_dir

        assert_path_missing "$target_home/.config/zsh/.zsh_history"
        assert_path_missing "$target_home/.config/zsh/.zsh_sessions"
        assert_path_missing "$target_home/.config/zsh/.zcompdump-external"
        assert_preserved_copy "$source_zsh_dir/.zcompdump-local" "$target_home/.config/zsh/.zcompdump-local"
        if [ -e "$internal_link" ] && [ ! -L "$internal_link" ]; then
            fail 'internal Zsh session symlink was dereferenced into a regular path'
        fi
    )

    source_after="$(snapshot_tree "$source_zsh_dir")"
    external_after="$(snapshot_tree "$external_dir")"
    assert_eq "$source_before" "$source_after" 'Zsh runtime symlink fixtures changed'
    assert_eq "$external_before" "$external_after" 'external runtime referents changed'
}

test_zsh_session_internal_symlink_is_not_dereferenced() {
    local source_dir="$TEST_ROOT/session-internal-source"
    local target_home="$TEST_ROOT/session-internal-target"
    local source_zsh_dir="$source_dir/.config/zsh"
    local physical_source_zsh_dir
    local external_dir="$TEST_ROOT/session-internal-external"
    local target_link="$target_home/.config/zsh/.zsh_sessions/external-link"
    local external_before external_after

    mkdir -p "$source_zsh_dir/.zsh_sessions" "$external_dir"
    physical_source_zsh_dir=$(CDPATH= cd -P -- "$source_zsh_dir" && pwd -P)
    printf 'local session\n' > "$source_zsh_dir/.zsh_sessions/local-session"
    printf 'external session\n' > "$external_dir/session"
    ln -s "$external_dir/session" "$source_zsh_dir/.zsh_sessions/external-link"
    external_before="$(snapshot_tree "$external_dir")"

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        mkdir -p "$target_home/.config"
        ln -s "$physical_source_zsh_dir" "$target_home/.config/zsh"

        prepare_zsh_dir

        assert_preserved_copy "$source_zsh_dir/.zsh_sessions/local-session" "$target_home/.config/zsh/.zsh_sessions/local-session"
        [ -L "$target_link" ] || fail 'internal Zsh session symlink was not preserved'
        assert_eq "$external_dir/session" "$(readlink "$target_link")" 'internal Zsh session link target changed'
    )

    external_after="$(snapshot_tree "$external_dir")"
    assert_eq "$external_before" "$external_after" 'external session referent changed'
}

test_backup_rejects_symlinked_backup_root() {
    local source_dir="$TEST_ROOT/backup-root-source"
    local target_home="$TEST_ROOT/backup-root-target"
    local external_dir="$TEST_ROOT/backup-root-external"
    local target_file="$target_home/config"

    mkdir -p "$source_dir" "$target_home" "$external_dir"
    printf 'current\n' > "$target_file"
    ln -s "$external_dir" "$target_home/.dotfiles-backup"

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        if backup_target_if_needed "$target_file"; then
            fail 'backup must reject a symlinked backup root'
        fi
        assert_eq 'current' "$(cat "$target_file")" 'target changed after rejected backup root'
        assert_directory_empty "$external_dir"
        assert_eq '' "$BACKUP_RUN_DIR" 'rejected backup created a run directory'
    )
}

test_link_rejects_symlinked_managed_parent() {
    local source_dir="$TEST_ROOT/symlink-parent-source"
    local target_home="$TEST_ROOT/symlink-parent-target"
    local external_dir="$TEST_ROOT/symlink-parent-external"
    local source_file="$source_dir/config"
    local target_file="$target_home/.config/config"

    mkdir -p "$source_dir" "$target_home" "$external_dir"
    printf 'source\n' > "$source_file"
    ln -s "$external_dir" "$target_home/.config"

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        if safe_link_or_copy "$source_file" "$target_file"; then
            fail 'linking must reject a symlinked managed parent'
        fi
        assert_link_points_to "$target_home/.config" "$external_dir"
        assert_directory_empty "$external_dir"
        assert_path_missing "$target_file"
    )
}

test_backup_uses_literal_target_home_prefix() {
    local source_dir="$TEST_ROOT/glob-source"
    local target_home="$TEST_ROOT/home [y]*"
    local target_file="$target_home/.config/config"
    local run_dir run_dir_count

    mkdir -p "$source_dir" "$target_home/.config"
    printf 'literal path\n' > "$target_file"

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        backup_target_if_needed "$target_file"
        run_dir_count=0
        for run_dir in "$target_home/.dotfiles-backup"/run.*; do
            [ -d "$run_dir" ] || continue
            run_dir_count=$((run_dir_count + 1))
        done
        assert_eq '1' "$run_dir_count" 'expected one backup run directory for literal target home'
        assert_eq 'literal path' "$(cat "$run_dir/.config/config")" 'backup layout used a pattern-expanded target home'
    )
}

test_backup_refuses_to_overwrite_existing_backup() {
    local source_dir="$TEST_ROOT/repeated-backup-source"
    local target_home="$TEST_ROOT/repeated-backup-target"
    local target_file="$target_home/config"
    local run_dir run_dir_count

    mkdir -p "$source_dir" "$target_home"
    printf 'first\n' > "$target_file"

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        backup_target_if_needed "$target_file"
        run_dir_count=0
        for run_dir in "$target_home/.dotfiles-backup"/run.*; do
            [ -d "$run_dir" ] || continue
            run_dir_count=$((run_dir_count + 1))
        done
        assert_eq '1' "$run_dir_count" 'expected one backup run directory before repeated backup'
        printf 'second\n' > "$target_file"
        if backup_target_if_needed "$target_file"; then
            fail 'backup must refuse to overwrite an existing backup path'
        fi
        assert_eq 'first' "$(cat "$run_dir/config")" 'first backup was overwritten'
        assert_eq 'second' "$(cat "$target_file")" 'current target changed after rejected backup'
    )
}

test_backup_refuses_broken_symlink_collision() {
    local source_dir="$TEST_ROOT/broken-backup-source"
    local target_home="$TEST_ROOT/broken-backup-target"
    local target_file="$target_home/config"
    local run_dir="$target_home/.dotfiles-backup/run.fixture"
    local broken_backup="$run_dir/config"

    mkdir -p "$source_dir" "$run_dir"
    printf 'current\n' > "$target_file"
    ln -s 'missing-backup' "$broken_backup"

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        BACKUP_RUN_DIR="$run_dir"

        if backup_target_if_needed "$target_file"; then
            fail 'backup must reject a broken symlink collision'
        fi
        [ -L "$broken_backup" ] || fail 'broken backup symlink was replaced'
        assert_eq 'missing-backup' "$(readlink "$broken_backup")" 'broken backup symlink changed'
        assert_eq 'current' "$(cat "$target_file")" 'current target changed after broken backup collision'
    )
}

test_backup_rejects_path_traversal() {
    local source_dir="$TEST_ROOT/traversal-source"
    local target_home="$TEST_ROOT/traversal-target"
    local external_dir="$TEST_ROOT/outside"
    local external_file="$external_dir/config"
    local traversing_target="$target_home/../outside/config"

    mkdir -p "$source_dir" "$target_home" "$external_dir"
    printf 'outside\n' > "$external_file"

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        if backup_target_if_needed "$traversing_target"; then
            fail 'backup must reject a traversal target'
        fi
        assert_eq 'outside' "$(cat "$external_file")" 'external traversal target changed'
        assert_path_missing "$target_home/.dotfiles-backup"
        assert_eq '' "$BACKUP_RUN_DIR" 'traversal backup created a run directory'
    )
}

test_devbox_data_dir_rejects_path_traversal() {
    local source_dir="$TEST_ROOT/devbox-traversal-source"
    local target_home="$TEST_ROOT/devbox-traversal-target"
    local external_dir="$TEST_ROOT/devbox-outside"
    local data_dir="$target_home/../devbox-outside"

    mkdir -p "$source_dir" "$target_home/.config/devbox/global" "$external_dir"
    printf 'outside\n' > "$external_dir/sentinel"

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        export DEVBOX_DATA_DIR="$data_dir"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        if setup_devbox_global; then
            fail 'Devbox setup must reject a traversal data directory'
        fi
        assert_eq 'outside' "$(cat "$external_dir/sentinel")" 'external Devbox traversal directory changed'
        assert_path_missing "$target_home/.dotfiles-backup"
    )
}

test_devbox_setup_rejects_symlinked_local_parent() {
    local source_dir="$TEST_ROOT/devbox-parent-source"
    local target_home="$TEST_ROOT/devbox-parent-target"
    local external_dir="$TEST_ROOT/devbox-parent-external"
    local external_before external_after

    mkdir -p "$source_dir" "$target_home/.config/devbox/global" "$external_dir"
    printf 'external\n' > "$external_dir/sentinel"
    ln -s "$external_dir" "$target_home/.local"
    external_before="$(snapshot_tree "$external_dir")"

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        if setup_devbox_global; then
            fail 'Devbox setup must reject a symlinked .local parent'
        fi
    )

    external_after="$(snapshot_tree "$external_dir")"
    assert_eq "$external_before" "$external_after" 'symlinked Devbox parent changed external data'
}

test_devbox_setup_propagates_backup_failure_in_conditional_context() {
    local source_dir="$TEST_ROOT/devbox-backup-failure-source"
    local target_home="$TEST_ROOT/devbox-backup-failure-target"
    local destination="$target_home/.local/share/devbox/global/default"
    local external_backup="$TEST_ROOT/devbox-backup-failure-external"
    local destination_before destination_after backup_before backup_after

    mkdir -p "$source_dir" "$target_home/.config/devbox/global" "$destination" "$external_backup"
    printf 'destination data\n' > "$destination/sentinel"
    printf 'backup data\n' > "$external_backup/sentinel"
    ln -s "$external_backup" "$target_home/.dotfiles-backup"
    destination_before="$(snapshot_tree "$destination")"
    backup_before="$(snapshot_tree "$external_backup")"

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"
        has_cmd() { return 0; }
        devbox() { return 0; }

        if setup_devbox_global; then
            fail 'Devbox setup must propagate a backup failure from conditional context'
        fi
    )

    destination_after="$(snapshot_tree "$destination")"
    backup_after="$(snapshot_tree "$external_backup")"
    assert_eq "$destination_before" "$destination_after" 'Devbox destination changed after rejected backup'
    assert_eq "$backup_before" "$backup_after" 'external backup referent changed'
    assert_path_missing "$destination/global"
}

test_correct_link_is_idempotent() {
    local source_dir="$TEST_ROOT/idempotent-source"
    local target_home="$TEST_ROOT/idempotent-target"

    mkdir -p "$source_dir" "$target_home"
    : > "$source_dir/config"

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        safe_link_or_copy "$source_dir/config" "$target_home/config"
        safe_link_or_copy "$source_dir/config" "$target_home/config"

        assert_path_missing "$target_home/.dotfiles-backup"
    )
}

test_only_exact_legacy_managed_links_are_removed() {
    local source_dir="$TEST_ROOT/legacy-source"
    local physical_source_dir
    local managed_home="$TEST_ROOT/nvim-managed"
    local other_link_home="$TEST_ROOT/nvim-other-link"
    local broken_other_link_home="$TEST_ROOT/nvim-broken-other-link"
    local relative_link_home="$TEST_ROOT/nvim-relative-link"
    local directory_home="$TEST_ROOT/nvim-directory"
    local file_home="$TEST_ROOT/nvim-file"
    local pet_managed_home="$TEST_ROOT/pet-managed"
    local pet_other_link_home="$TEST_ROOT/pet-other-link"
    local pet_relative_link_home="$TEST_ROOT/pet-relative-link"
    local pet_file_home="$TEST_ROOT/pet-file"
    local managed_link="$managed_home/.config/nvim"
    local other_link="$other_link_home/.config/nvim"
    local broken_other_link="$broken_other_link_home/.config/nvim"
    local relative_link="$relative_link_home/.config/nvim"
    local regular_dir="$directory_home/.config/nvim"
    local regular_file="$file_home/.config/nvim"
    local managed_pet_link="$pet_managed_home/.config/zsh/pet.zsh"
    local other_pet_link="$pet_other_link_home/.config/zsh/pet.zsh"
    local relative_pet_link="$pet_relative_link_home/.config/zsh/pet.zsh"
    local regular_pet_file="$pet_file_home/.config/zsh/pet.zsh"

    mkdir -p "$source_dir/.config/zsh" "$source_dir/other-nvim" \
             "$managed_home/.config" \
             "$other_link_home/.config" "$broken_other_link_home/.config" \
             "$relative_link_home/.config" \
             "$regular_dir" "$file_home/.config" \
             "$pet_managed_home/.config/zsh" \
             "$pet_other_link_home/.config/zsh" \
             "$pet_relative_link_home/.config/zsh" \
             "$pet_file_home/.config/zsh"
    physical_source_dir=$(CDPATH= cd -P -- "$source_dir" && pwd -P)
    printf 'directory data\n' > "$regular_dir/data"
    printf 'file data\n' > "$regular_file"
    printf 'legacy Pet source\n' > "$source_dir/.config/zsh/pet.zsh"
    printf 'unrelated Pet source\n' > "$source_dir/other-pet.zsh"
    printf 'regular Pet data\n' > "$regular_pet_file"
    ln -s "$physical_source_dir/.config/nvim" "$managed_link"
    ln -s "$source_dir/other-nvim" "$other_link"
    ln -s "$source_dir/missing-other-nvim" "$broken_other_link"
    ln -s '../relative-nvim' "$relative_link"
    ln -s "$physical_source_dir/.config/zsh/pet.zsh" "$managed_pet_link"
    ln -s "$source_dir/other-pet.zsh" "$other_pet_link"
    ln -s '../../../legacy-source/.config/zsh/pet.zsh' "$relative_pet_link"

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$managed_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        cleanup_legacy_managed_links

        assert_path_missing "$managed_link"
    )

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$other_link_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        cleanup_legacy_managed_links

        assert_path_exists "$other_link"
        assert_eq "$source_dir/other-nvim" "$(readlink "$other_link")" 'unmanaged Neovim link changed'
    )

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$broken_other_link_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        cleanup_legacy_managed_links

        assert_path_exists "$broken_other_link"
        assert_eq "$source_dir/missing-other-nvim" "$(readlink "$broken_other_link")" 'broken unmanaged Neovim link changed'
    )

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$relative_link_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        cleanup_legacy_managed_links

        assert_path_exists "$relative_link"
        assert_eq '../relative-nvim' "$(readlink "$relative_link")" 'relative Neovim link changed'
    )

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$directory_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        cleanup_legacy_managed_links

        assert_path_exists "$regular_dir"
        assert_eq 'directory data' "$(cat "$regular_dir/data")" 'Neovim directory changed'
    )

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$file_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        cleanup_legacy_managed_links

        assert_path_exists "$regular_file"
        assert_eq 'file data' "$(cat "$regular_file")" 'Neovim file changed'
    )

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$pet_managed_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        cleanup_legacy_managed_links

        assert_path_missing "$managed_pet_link"
    )

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$pet_other_link_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        cleanup_legacy_managed_links

        assert_path_exists "$other_pet_link"
        assert_eq "$source_dir/other-pet.zsh" "$(readlink "$other_pet_link")" \
            'unmanaged Pet link changed'
    )

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$pet_relative_link_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        cleanup_legacy_managed_links

        assert_path_exists "$relative_pet_link"
        assert_eq '../../../legacy-source/.config/zsh/pet.zsh' \
            "$(readlink "$relative_pet_link")" 'relative Pet link changed'
    )

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$pet_file_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        cleanup_legacy_managed_links

        assert_path_exists "$regular_pet_file"
        assert_eq 'regular Pet data' "$(cat "$regular_pet_file")" \
            'regular Pet file changed'
    )
}

test_legacy_pet_cleanup_requires_canonical_absolute_source_link() {
    local relative_parent="$TEST_ROOT/relative-source-parent"
    local relative_source="$relative_parent/legacy-source"
    local relative_work="$relative_parent/work"
    local relative_home="$TEST_ROOT/relative-source-home"
    local relative_pet_link="$relative_home/.config/zsh/pet.zsh"
    local relative_physical_source
    local ambiguous_parent="$TEST_ROOT/ambiguous-source-parent"
    local ambiguous_source="$ambiguous_parent/source"
    local ambiguous_segment="$ambiguous_parent/segment"
    local ambiguous_spelling="$ambiguous_segment/../source"
    local ambiguous_home="$TEST_ROOT/ambiguous-source-home"
    local ambiguous_pet_link="$ambiguous_home/.config/zsh/pet.zsh"
    local ambiguous_physical_source
    local exact_source="$TEST_ROOT/exact-source"
    local exact_home="$TEST_ROOT/exact-source-home"
    local exact_pet_link="$exact_home/.config/zsh/pet.zsh"
    local exact_sibling="$exact_home/.config/zsh/keep.zsh"
    local exact_physical_source

    mkdir -p "$relative_source/.config/zsh" "$relative_work" \
             "$relative_home/.config/zsh"
    relative_physical_source=$(CDPATH= cd -P -- "$relative_source" && pwd -P)
    printf 'legacy relative source\n' > "$relative_source/.config/zsh/pet.zsh"
    ln -s '../legacy-source/.config/zsh/pet.zsh' "$relative_pet_link"

    (
        cd "$relative_work"
        export DOTFILES_SOURCE_DIR='../legacy-source'
        export DOTFILES_TARGET_HOME="$relative_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        cleanup_legacy_managed_links

        assert_path_exists "$relative_pet_link"
        assert_eq '../legacy-source/.config/zsh/pet.zsh' \
            "$(readlink "$relative_pet_link")" \
            'relative legacy Pet link changed'
        assert_eq "$relative_physical_source" "$DOT_DIR" \
            'relative DOTFILES_SOURCE_DIR was not normalized physically'
    )

    mkdir -p "$ambiguous_source/.config/zsh" "$ambiguous_segment" \
             "$ambiguous_home/.config/zsh"
    ambiguous_physical_source=$(CDPATH= cd -P -- "$ambiguous_source" && pwd -P)
    printf 'legacy ambiguous source\n' > "$ambiguous_source/.config/zsh/pet.zsh"
    ln -s "$ambiguous_spelling/.config/zsh/pet.zsh" "$ambiguous_pet_link"

    (
        export DOTFILES_SOURCE_DIR="$ambiguous_spelling"
        export DOTFILES_TARGET_HOME="$ambiguous_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        cleanup_legacy_managed_links

        assert_path_exists "$ambiguous_pet_link"
        assert_eq "$ambiguous_spelling/.config/zsh/pet.zsh" \
            "$(readlink "$ambiguous_pet_link")" \
            'noncanonical absolute legacy Pet link changed'
        assert_eq "$ambiguous_physical_source" "$DOT_DIR" \
            'ambiguous DOTFILES_SOURCE_DIR was not normalized physically'
    )

    mkdir -p "$exact_source/.config/zsh" "$exact_home/.config/zsh"
    exact_physical_source=$(CDPATH= cd -P -- "$exact_source" && pwd -P)
    printf 'legacy exact source\n' > "$exact_source/.config/zsh/pet.zsh"
    printf 'keep\n' > "$exact_sibling"
    ln -s "$exact_physical_source/.config/zsh/pet.zsh" "$exact_pet_link"

    (
        export DOTFILES_SOURCE_DIR="$exact_source"
        export DOTFILES_TARGET_HOME="$exact_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        cleanup_legacy_managed_links
        cleanup_legacy_managed_links

        assert_path_missing "$exact_pet_link"
        assert_path_exists "$exact_sibling"
        assert_eq 'keep' "$(cat "$exact_sibling")" \
            'idempotent legacy cleanup changed another Zsh file'
    )
}

test_invalid_dotfiles_source_dir_fails_explicitly() {
    local missing_source="$TEST_ROOT/missing-dotfiles-source"
    local target_home="$TEST_ROOT/missing-source-home"
    local diagnostic="$TEST_ROOT/missing-source-diagnostic"

    if (
        export DOTFILES_SOURCE_DIR="$missing_source"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
    ) 2> "$diagnostic"; then
        fail 'missing DOTFILES_SOURCE_DIR must fail while loading the installer'
    fi

    assert_file_contains "$diagnostic" \
        'Dotfiles source directory is unavailable'
    assert_path_missing "$target_home"
}

test_setup_dotfiles_links_isolated_to_target_home() {
    local real_home="$HOME"
    local source_dir="$TEST_ROOT/source"
    local target_home="$TEST_ROOT/target"
    local physical_source_dir
    local real_state_before="$TEST_ROOT/real-state-before"
    local real_state_after="$TEST_ROOT/real-state-after"
    local path link_path link_target
    local -a real_managed_paths

    real_managed_paths=(
        "$real_home/.zshenv"
        "$real_home/.config"
        "$real_home/.config/devbox"
        "$real_home/.config/devbox/global"
        "$real_home/.config/git"
        "$real_home/.config/herdr"
        "$real_home/.config/wezterm"
        "$real_home/.config/zsh"
        "$real_home/.config/zsh/.zshrc"
        "$real_home/.config/zsh/aliases.zsh"
        "$real_home/.codex"
        "$real_home/.claude"
        "$real_home/.local/share/devbox"
        "$real_home/.nix-profile/etc/profile.d/nix.sh"
        "$real_home/.dotfiles-backup"
    )
    mkdir -p "$source_dir" "$target_home" "$real_state_before" "$real_state_after"
    for path in "${real_managed_paths[@]}"; do
        capture_path_state "$path" >> "$real_state_before/states"
    done

    mkdir -p "$source_dir/.config/devbox" \
             "$source_dir/.config/git" \
             "$source_dir/.config/herdr" \
             "$source_dir/.config/wezterm" \
             "$source_dir/.config/zsh" \
             "$source_dir/.codex" \
             "$source_dir/.claude" \
             "$source_dir/bin"
    physical_source_dir=$(CDPATH= cd -P -- "$source_dir" && pwd -P)
    : > "$source_dir/.zshenv"
    : > "$source_dir/.config/zsh/.zshrc"
    : > "$source_dir/.config/zsh/aliases.zsh"
    : > "$source_dir/.config/wezterm/wezterm.lua"
    : > "$source_dir/.codex/AGENTS.md"
    : > "$source_dir/.claude/CLAUDE.md"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$source_dir/bin/ha"
    chmod +x "$source_dir/bin/ha"

    export DOTFILES_SOURCE_DIR="$source_dir"
    export DOTFILES_TARGET_HOME="$target_home"
    unset DEVBOX_DATA_DIR
    # shellcheck source=/dev/null
    . "$INSTALLER_RUNTIME_PATH"
    # The installer defines fail(); restore the test assertion helper after sourcing.
    . "$TEST_DIR/test_helpers.sh"

    assert_eq "$target_home" "${TARGET_HOME:-}" "TARGET_HOME must use DOTFILES_TARGET_HOME"
    assert_eq "$physical_source_dir" "${DOT_DIR:-}" \
        'DOT_DIR must use the physical absolute source path'
    assert_path_within_target "$TARGET_HOME" "$target_home"
    assert_path_within_target "${DEVBOX_DATA_DIR:-}" "$target_home"
    assert_path_within_target "${DEVBOX_GLOBAL_CONFIG:-}" "$target_home"
    assert_path_within_target "${ZSH_HOME_DIR:-}" "$target_home"
    assert_path_within_target "${NIX_USER_PROFILE:-}" "$target_home"
    assert_path_within_target "${BACKUP_DIR:-}" "$target_home"

    assert_eq 'TARGET_HOME="${DOTFILES_TARGET_HOME:-$HOME}"' "$(grep -F '$HOME' "$REPO_DIR/install.sh")" \
        'direct $HOME expansion must only be the TARGET_HOME default'
    assert_file_contains "$REPO_DIR/install.sh" 'DEVBOX_DATA_DIR="${DEVBOX_DATA_DIR:-$TARGET_HOME/.local/share/devbox}"'
    assert_file_contains "$REPO_DIR/install.sh" 'DEVBOX_GLOBAL_CONFIG="$TARGET_HOME/.config/devbox/global"'
    assert_file_contains "$REPO_DIR/install.sh" 'ZSH_HOME_DIR="$TARGET_HOME/.config/zsh"'
    assert_file_contains "$REPO_DIR/install.sh" 'NIX_USER_PROFILE="$TARGET_HOME/.nix-profile/etc/profile.d/nix.sh"'
    assert_file_contains "$REPO_DIR/install.sh" 'BACKUP_DIR="$TARGET_HOME/.dotfiles-backup"'

    if find "$target_home" -mindepth 1 -print -quit | grep -q .; then
        fail 'sourcing install.sh must not create managed links or directories'
    fi

    setup_dotfiles_links

    assert_link_points_to "$target_home/.zshenv" "$physical_source_dir/.zshenv"
    for path in devbox git herdr; do
        assert_link_points_to "$target_home/.config/$path" "$physical_source_dir/.config/$path"
    done
    [ -d "$target_home/.config/wezterm" ] && [ ! -L "$target_home/.config/wezterm" ] ||
        fail 'installer must create a real WezTerm directory'
    assert_link_points_to "$target_home/.config/wezterm/wezterm.lua" \
        "$physical_source_dir/.config/wezterm/wezterm.lua"
    for path in .zshrc aliases.zsh; do
        assert_link_points_to "$target_home/.config/zsh/$path" \
            "$physical_source_dir/.config/zsh/$path"
    done
    assert_link_points_to "$target_home/.local/bin/ha" "$physical_source_dir/bin/ha"
    assert_link_points_to "$target_home/.codex/AGENTS.md" \
        "$physical_source_dir/.codex/AGENTS.md"
    assert_link_points_to "$target_home/.claude/CLAUDE.md" \
        "$physical_source_dir/.claude/CLAUDE.md"

    while IFS= read -r link_path; do
        assert_path_within_target "$link_path" "$target_home"
        link_target=$(readlink "$link_path")
        case "$link_target" in
            "$physical_source_dir"|"$physical_source_dir"/*) ;;
            *) fail "expected link to point into temporary source: $link_path -> $link_target" ;;
        esac
    done < <(find "$target_home" -type l -print)

    for path in "${real_managed_paths[@]}"; do
        capture_path_state "$path" >> "$real_state_after/states"
    done
    cmp -s "$real_state_before/states" "$real_state_after/states" || fail 'real managed destinations changed during isolated test'
}

test_setup_dotfiles_links_backs_up_existing_ha() {
    local source_dir="$TEST_ROOT/ha-source"
    local target_home="$TEST_ROOT/ha-target"
    local physical_source_dir run_dir

    mkdir -p "$source_dir/.config/devbox" \
             "$source_dir/.config/git" \
             "$source_dir/.config/herdr" \
             "$source_dir/.config/wezterm" \
             "$source_dir/.config/zsh" \
             "$source_dir/.codex" \
             "$source_dir/.claude" \
             "$source_dir/bin" \
             "$target_home/.local/bin"
    : > "$source_dir/.zshenv"
    : > "$source_dir/.config/zsh/.zshrc"
    : > "$source_dir/.config/zsh/aliases.zsh"
    : > "$source_dir/.config/wezterm/wezterm.lua"
    : > "$source_dir/.codex/AGENTS.md"
    : > "$source_dir/.claude/CLAUDE.md"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$source_dir/bin/ha"
    chmod +x "$source_dir/bin/ha"
    printf 'user-owned launcher\n' > "$target_home/.local/bin/ha"
    physical_source_dir=$(CDPATH= cd -P -- "$source_dir" && pwd -P)

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        setup_dotfiles_links

        assert_link_points_to "$target_home/.local/bin/ha" "$physical_source_dir/bin/ha"
        for run_dir in "$target_home/.dotfiles-backup"/run.*; do
            [ -d "$run_dir" ] || continue
            assert_eq 'user-owned launcher' "$(cat "$run_dir/.local/bin/ha")" \
                'installer must back up an unrelated existing ha file'
            return 0
        done
        fail 'installer did not create a backup for an existing ha file'
    )
}

test_setup_agent_config_links_manages_only_public_guidance() {
    local source_dir="$TEST_ROOT/agent-guidance-source"
    local target_home="$TEST_ROOT/agent-guidance-target"
    local physical_source_dir run_dir_count

    mkdir -p "$source_dir/.codex" "$source_dir/.claude" \
             "$target_home/.codex/session-data" "$target_home/.claude"
    printf 'public Codex guidance\n' > "$source_dir/.codex/AGENTS.md"
    printf 'public Claude guidance\n' > "$source_dir/.claude/CLAUDE.md"
    printf 'user public Codex guidance\n' > "$target_home/.codex/AGENTS.md"
    printf 'user public Claude guidance\n' > "$target_home/.claude/CLAUDE.md"
    printf 'auth-looking state\n' > "$target_home/.codex/auth.json"
    printf 'session state\n' > "$target_home/.codex/session-data/current"
    printf 'unrelated settings\n' > "$target_home/.claude/settings.json"
    physical_source_dir=$(CDPATH= cd -P -- "$source_dir" && pwd -P)

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        setup_agent_config_links

        assert_link_points_to "$target_home/.codex/AGENTS.md" \
            "$physical_source_dir/.codex/AGENTS.md"
        assert_link_points_to "$target_home/.claude/CLAUDE.md" \
            "$physical_source_dir/.claude/CLAUDE.md"
        assert_eq 'auth-looking state' "$(cat "$target_home/.codex/auth.json")" \
            'installer changed existing auth-looking state'
        assert_eq 'session state' "$(cat "$target_home/.codex/session-data/current")" \
            'installer changed an existing session directory'
        assert_eq 'unrelated settings' "$(cat "$target_home/.claude/settings.json")" \
            'installer changed unrelated agent settings'

        run_dir_count=$(find "$target_home/.dotfiles-backup" -mindepth 1 -maxdepth 1 -type d -name 'run.*' | wc -l | tr -d ' ')
        assert_eq '1' "$run_dir_count" 'first public guidance replacement must create one backup run'
        assert_eq 'user public Codex guidance' \
            "$(cat "$target_home/.dotfiles-backup"/run.*/.codex/AGENTS.md)" \
            'installer must back up existing Codex guidance'
        assert_eq 'user public Claude guidance' \
            "$(cat "$target_home/.dotfiles-backup"/run.*/.claude/CLAUDE.md)" \
            'installer must back up existing Claude guidance'

        setup_agent_config_links
        run_dir_count=$(find "$target_home/.dotfiles-backup" -mindepth 1 -maxdepth 1 -type d -name 'run.*' | wc -l | tr -d ' ')
        assert_eq '1' "$run_dir_count" 'repeated setup must not create another backup run'
    )
}

test_setup_agent_config_links_rejects_symlinked_target_parent() {
    local source_dir="$TEST_ROOT/agent-parent-source"
    local target_home="$TEST_ROOT/agent-parent-target"
    local external_dir="$TEST_ROOT/agent-parent-external"

    mkdir -p "$source_dir/.codex" "$source_dir/.claude" "$target_home" "$external_dir"
    printf 'public Codex guidance\n' > "$source_dir/.codex/AGENTS.md"
    printf 'public Claude guidance\n' > "$source_dir/.claude/CLAUDE.md"
    ln -s "$external_dir" "$target_home/.codex"

    (
        export DOTFILES_SOURCE_DIR="$source_dir"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        . "$TEST_DIR/test_helpers.sh"

        if setup_agent_config_links; then
            fail 'agent guidance setup must reject a symlinked target parent'
        fi
        assert_link_points_to "$target_home/.codex" "$external_dir"
        assert_directory_empty "$external_dir"
        assert_path_missing "$target_home/.claude"
    )
}

test_install_script_has_source_guard
test_verify_sha256_accepts_match_and_rejects_mismatch
test_sha256_file_rejects_symlinks_and_missing_option_like_paths
test_sha256_file_uses_safe_arguments_for_both_backends
test_verified_installer_executes_only_after_hash_match
test_verified_installer_cleans_transport_failure
test_verified_installer_preserves_foreign_replacement_at_owned_path
test_verified_installer_signal_cleans_temporary_directory
test_verified_installer_chains_existing_term_handler
test_verified_installer_signal_after_trap_install_chains_callers
test_preflight_failure_prevents_all_main_mutations
test_existing_exact_devbox_version_skips_install
test_existing_different_devbox_version_is_warned_and_preserved
test_malformed_devbox_version_ending_in_pin_is_warned_and_preserved
test_nix_setup_passes_active_pinned_installer_arguments
test_devbox_setup_passes_active_pinned_flake
test_devbox_post_install_requires_exact_version
test_zsh_setup_passes_active_pinned_checkout_arguments
test_mismatched_oh_my_zsh_checkout_is_fully_preserved
test_uninspectable_oh_my_zsh_checkout_is_fully_preserved
test_concurrent_pinned_checkouts_serialize_to_one_root
test_checkout_restores_subshell_local_exit_trap
test_checkout_collision_before_finalize_is_preserved_without_nesting
test_checkout_collision_inside_mv_preserves_foreign_destination
test_checkout_post_move_verification_rejects_corruption
test_checkout_signals_clean_each_acquisition_seam
test_checkout_signal_cleans_temporary_directory_and_lock
test_checkout_chains_existing_hup_handler
test_checkout_returning_term_handler_falls_back_to_signal_status
test_checkout_ignored_term_falls_back_to_signal_status
test_checkout_signal_after_trap_install_chains_callers
test_exact_checkout_ignores_foreign_stale_lock
test_absent_checkout_reports_and_preserves_unverifiable_stale_lock
test_ensure_pinned_checkout_fetches_exact_commit_and_preserves_existing_checkout
test_setup_dotfiles_links_isolated_to_target_home
test_setup_dotfiles_links_backs_up_existing_ha
test_setup_agent_config_links_manages_only_public_guidance
test_setup_agent_config_links_rejects_symlinked_target_parent
test_zsh_symlink_is_backed_up_without_mutating_target
test_wezterm_managed_directory_symlink_migrates_to_local_directory
test_wezterm_setup_rejects_unrelated_symlinked_parent
test_zsh_runtime_symlinks_are_not_dereferenced
test_zsh_session_internal_symlink_is_not_dereferenced
test_backup_rejects_symlinked_backup_root
test_link_rejects_symlinked_managed_parent
test_backup_uses_literal_target_home_prefix
test_backup_refuses_to_overwrite_existing_backup
test_backup_refuses_broken_symlink_collision
test_backup_rejects_path_traversal
test_devbox_data_dir_rejects_path_traversal
test_devbox_setup_rejects_symlinked_local_parent
test_devbox_setup_propagates_backup_failure_in_conditional_context
test_correct_link_is_idempotent
test_only_exact_legacy_managed_links_are_removed
test_legacy_pet_cleanup_requires_canonical_absolute_source_link
test_invalid_dotfiles_source_dir_fails_explicitly
printf 'PASS: %s\n' "$(basename "$0")"

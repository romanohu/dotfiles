#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$TEST_DIR/.." && pwd)

# shellcheck source=test_helpers.sh
. "$TEST_DIR/test_helpers.sh"

jq_assert() {
    local expression="$1"
    local message="$2"
    local path="${3:-$REPO_DIR/.config/devbox/global/devbox.json}"

    jq -e "$expression" "$path" >/dev/null || fail "$message"
}

devbox_manifest_has_exact_packages() {
    local manifest="$1"

    jq -e '
        {
            "starship": {"version": "1.24.2"},
            "fzf": {"version": "0.71.0"},
            "ripgrep": {"version": "15.1.0"},
            "eza": {"version": "0.23.4"},
            "bat": {"version": "0.26.1"},
            "fd": {"version": "10.4.2"},
            "gh": {"version": "2.89.0"},
            "uv": {"version": "0.11.6"},
            "tmux": {"version": "3.6"},
            "pueue": {"version": "4.0.4"},
            "htop": {"version": "3.5.0"},
            "hwloc": {"version": "2.13.0"},
            "git-lfs": {"version": "3.7.1"},
            "tree": {"version": "2.3.1"},
            "navi": {"version": "2.24.0"},
            "dua": {"version": "2.34.0"},
            "viddy": {"version": "1.3.0"},
            "xclip": {"version": "0.13"},
            "jq": {"version": "1.7.1"},
            "git": {"version": "2.50.1"},
            "nodejs": {"version": "24.12.0"},
            "zsh": {"version": "5.9"},
            "zoxide": {"version": "0.9.8"},
            "github:ogulcancelik/herdr/v0.7.5": {},
            "nvtopPackages.apple": {
                "version": "3.3.2",
                "platforms": ["aarch64-darwin"]
            },
            "nvtopPackages.full": {
                "version": "3.3.2",
                "platforms": ["x86_64-linux", "aarch64-linux"]
            }
        } as $expected
        | .packages == $expected
    ' "$manifest" >/dev/null
}

devbox_lock_matches_manifest() {
    local manifest="$1"
    local lock="$2"

    # Lock versions are resolved Nix package versions and can be more specific
    # than the manifest query encoded in the lock key (for example, tmux 3.6a).
    jq -e --slurpfile manifest "$manifest" '
        {
            "starship@1.24.2": {"version": "1.24.2", "attr": "starship"},
            "fzf@0.71.0": {"version": "0.71.0", "attr": "fzf"},
            "ripgrep@15.1.0": {"version": "15.1.0", "attr": "ripgrep"},
            "eza@0.23.4": {"version": "0.23.4", "attr": "eza"},
            "bat@0.26.1": {"version": "0.26.1", "attr": "bat"},
            "fd@10.4.2": {"version": "10.4.2", "attr": "fd"},
            "gh@2.89.0": {"version": "2.89.0", "attr": "gh"},
            "uv@0.11.6": {"version": "0.11.6", "attr": "uv"},
            "tmux@3.6": {"version": "3.6a", "attr": "tmux"},
            "pueue@4.0.4": {"version": "4.0.4", "attr": "pueue"},
            "htop@3.5.0": {"version": "3.5.0", "attr": "htop"},
            "hwloc@2.13.0": {"version": "2.13.0", "attr": "hwloc"},
            "git-lfs@3.7.1": {"version": "3.7.1", "attr": "git-lfs"},
            "tree@2.3.1": {"version": "2.3.1", "attr": "tree"},
            "navi@2.24.0": {"version": "2.24.0", "attr": "navi"},
            "dua@2.34.0": {"version": "2.34.0", "attr": "dua"},
            "viddy@1.3.0": {"version": "1.3.0", "attr": "viddy"},
            "xclip@0.13": {"version": "0.13", "attr": "xclip"},
            "jq@1.7.1": {"version": "1.7.1", "attr": "jq"},
            "git@2.50.1": {"version": "2.50.1", "attr": "git"},
            "nodejs@24.12.0": {"version": "24.12.0", "attr": "nodejs_24"},
            "zsh@5.9": {"version": "5.9.2", "attr": "zsh"},
            "zoxide@0.9.8": {"version": "0.9.8", "attr": "zoxide"},
            "nvtopPackages.apple@3.3.2": {
                "version": "3.3.2",
                "attr": "nvtopPackages.apple"
            },
            "nvtopPackages.full@3.3.2": {
                "version": "3.3.2",
                "attr": "nvtopPackages.full"
            }
        } as $expected
        | "github:NixOS/nixpkgs/nixpkgs-unstable" as $internal_key
        | "github:ogulcancelik/herdr/v0.7.5" as $herdr_key
        | "^github:NixOS/nixpkgs/(?<sha>[0-9a-f]{40})(?<query>\\?[^#]+)?#(?<attr>[^#?]+)$" as $package_pattern
        | "^github:NixOS/nixpkgs/[0-9a-f]{40}(\\?[^#]+)?$" as $internal_pattern
        | . as $lock
        | ($lock.packages | type == "object")
        and (
            ($manifest[0].packages
                | del(.[$herdr_key])
                | to_entries
                | map("\(.key)@\(.value.version)")
                | sort)
            == ($expected | keys | sort)
        )
        and ($manifest[0].packages[$herdr_key] == {})
        and (
            ($lock.packages | keys | sort)
            == (($expected | keys) + [$internal_key, $herdr_key] | sort)
        )
        and all(
            $expected | to_entries[];
            . as $expected_entry
            | ($lock.packages[$expected_entry.key]) as $entry
            | ($expected_entry.key | split("@")[0]) as $package_name
            | (
                $manifest[0].packages[$package_name].platforms
                // ["aarch64-darwin", "x86_64-linux", "aarch64-linux"]
            ) as $platforms
            | ($entry | type == "object")
            and ($entry.source == "devbox-search")
            and ($entry.version == $expected_entry.value.version)
            and ($entry.resolved | type == "string")
            and ($entry.resolved | test($package_pattern))
            and (
                $entry.resolved
                | endswith("#" + $expected_entry.value.attr)
            )
            and ($entry.systems | type == "object")
            and all(
                $platforms[];
                . as $platform
                | ($entry.systems[$platform]) as $system
                | ($system | type == "object")
                and (
                    ($system.store_path | type == "string")
                    and ($system.store_path | test("^/nix/store/[^/]+"))
                )
                and (
                    ($system.outputs | type == "array")
                    and ($system.outputs | length > 0)
                )
            )
        )
        and (
            ($lock.packages[$internal_key]) as $internal
            | ($internal | type == "object")
            and ($internal.resolved | type == "string")
            and ($internal.resolved | test($internal_pattern))
        )
        and (
            ($lock.packages[$herdr_key]) as $herdr
            | ($herdr | type == "object")
            and (($herdr | keys | sort) == ["last_modified", "resolved"])
            and ($herdr.last_modified == "2026-07-21T18:04:32Z")
            and (
                $herdr.resolved
                == "github:ogulcancelik/herdr/ef4c23f5775bb8cfec05f05d0844226ff959a07a?lastModified=1784657072"
            )
        )
    ' "$lock" >/dev/null
}

test_neovim_configuration_is_not_tracked() {
    assert_path_missing "$REPO_DIR/.config/nvim"
    assert_path_missing "$REPO_DIR/nvim.log"
}

test_public_agent_guidance_excludes_runtime_state() {
    local guidance tracked_path

    for guidance in "$REPO_DIR/.codex/AGENTS.md" "$REPO_DIR/.claude/CLAUDE.md"; do
        assert_path_exists "$guidance"
        assert_file_contains "$guidance" 'Preserve user intent'
        assert_file_contains "$guidance" 'Keep changes scoped'
        assert_file_contains "$guidance" 'host-independent tests'
        assert_file_not_contains "$guidance" 'https://'
        assert_file_not_contains "$guidance" '/Users/'
    done

    while IFS= read -r tracked_path; do
        case "$tracked_path" in
            *auth*|*session*|*history*|*transcript*|*cache*|*projects*)
                fail "agent runtime state must not be tracked: $tracked_path"
                ;;
        esac
    done < <(git -C "$REPO_DIR" ls-files -- .codex .claude)

    assert_file_contains "$REPO_DIR/.gitignore" '.codex/*'
    assert_file_contains "$REPO_DIR/.gitignore" '!.codex/AGENTS.md'
    assert_file_contains "$REPO_DIR/.gitignore" '.claude/*'
    assert_file_contains "$REPO_DIR/.gitignore" '!.claude/CLAUDE.md'
}

test_installer_does_not_delete_neovim_runtime_data() {
    assert_file_not_contains "$REPO_DIR/install.sh" '.local/state/nvim'
    assert_file_not_contains "$REPO_DIR/install.sh" '.local/share/nvim'
    assert_file_not_contains "$REPO_DIR/install.sh" '.cache/nvim'
}

test_bootstrap_dependencies_are_exactly_pinned() {
    assert_file_contains "$REPO_DIR/install.sh" \
        'https://install.determinate.systems/nix/tag/v3.21.2/nix-installer.sh'
    assert_file_contains "$REPO_DIR/install.sh" \
        '4141f93485a16d600b995d02b2bdd296fb69af30ea3665037677b8d56f703b56'
    assert_file_contains "$REPO_DIR/install.sh" 'github:jetify-com/devbox/0.17.3'
    assert_file_contains "$REPO_DIR/install.sh" '677a4592b18c08ddea737f8aca70bac0e9fc9313'
    assert_file_contains "$REPO_DIR/install.sh" '85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5'
    assert_file_contains "$REPO_DIR/install.sh" '1d85c692615a25fe2293bdd44b34c217d5d2bf04'
}

test_installer_has_no_unverified_or_floating_bootstrap_commands() {
    if grep -E 'curl[[:space:]][^|]*\|[[:space:]]*(sh|bash)' "$REPO_DIR/install.sh" >/dev/null; then
        fail 'installer must not pipe curl output to a shell'
    fi
    if grep -E '^[[:space:]]*git[[:space:]]+clone([[:space:]]|$)' "$REPO_DIR/install.sh" >/dev/null; then
        fail 'installer must not use floating git clone commands'
    fi
    assert_file_not_contains "$REPO_DIR/install.sh" 'npm config set prefix'
}

test_zsh_configuration_has_no_custom_npm_prefix_path() {
    assert_file_not_contains "$REPO_DIR/.config/zsh/.zshrc" '.npm-global/bin'
}

test_daily_shell_and_git_defaults_are_safe_and_pinned() {
    local zshrc="$REPO_DIR/.config/zsh/.zshrc"
    local aliases="$REPO_DIR/.config/zsh/aliases.zsh"
    local git_config="$REPO_DIR/.config/git/config"

    jq_assert '.packages.zoxide == {"version":"0.9.8"}' \
        'zoxide must use an exact object-form package pin'
    jq_assert '
        .packages["zoxide@0.9.8"]
        | type == "object"
        and .version == "0.9.8"
        and .source == "devbox-search"
        and (.resolved | type == "string")
        and (.systems | type == "object")
    ' 'zoxide lock entry must be complete and immutable' \
        "$REPO_DIR/.config/devbox/global/devbox.lock"
    assert_file_contains "$zshrc" 'command -v zoxide > /dev/null 2>&1'
    assert_file_contains "$zshrc" '[ -n "${ZSH_VERSION:-}" ]'
    assert_file_contains "$zshrc" 'eval "$(zoxide init zsh)"'
    assert_file_contains "$aliases" 'gcof()'
    assert_file_contains "$aliases" 'git for-each-ref'
    assert_file_contains "$aliases" 'git switch -- "$branch"'
    assert_file_contains "$aliases" 'glogf()'
    assert_file_contains "$aliases" 'git log --oneline'
    assert_file_contains "$aliases" 'git show -- "${commit%% *}"'
    assert_file_contains "$aliases" '[ -t 0 ] && [ -t 1 ] || return 0'
    assert_file_not_contains "$aliases" 'eval'
    assert_file_contains "$git_config" '[fetch]'
    assert_file_contains "$git_config" 'name = romanohu'
    assert_file_contains "$git_config" 'email = 158289679+romanohu@users.noreply.github.com'
    assert_file_not_contains "$git_config" '@gmail.com'
    assert_file_contains "$git_config" 'prune = true'
    assert_file_contains "$git_config" '[rerere]'
    assert_file_contains "$git_config" 'enabled = true'
    assert_file_contains "$git_config" 'autoSetupRemote = true'
}

test_pet_is_absent_from_active_configuration() {
    assert_path_missing "$REPO_DIR/.config/zsh/pet.zsh"
    if sed -n '/^setup_dotfiles_links()/,/^}/p' "$REPO_DIR/install.sh" |
        grep -F -q -- 'pet.zsh'; then
        fail 'installer must not manage pet.zsh'
    fi
    assert_file_not_contains "$REPO_DIR/.config/zsh/.zshrc" 'pet.zsh'
    assert_file_not_contains "$REPO_DIR/.config/devbox/global/devbox.json" '"pet"'
    assert_file_not_contains "$REPO_DIR/.gitignore" 'pet.zsh'
    if jq -e '.packages | has("pet@1.0.1")' \
        "$REPO_DIR/.config/devbox/global/devbox.lock" >/dev/null; then
        fail 'devbox lock must not contain Pet'
    fi
}

test_herdr_is_pinned_and_minimally_configured() {
    local config="$REPO_DIR/.config/herdr/config.toml"
    local expected actual

    expected=$(printf '%s\n' \
        '[terminal]' \
        'default_shell = "zsh"' \
        'new_cwd = "follow"' \
        '' \
        '[[keys.command]]' \
        'key = "prefix+a"' \
        'command = "ha"' \
        'description = "add one generic agent pane"')
    actual=$(cat "$config" 2>/dev/null || true)
    assert_eq "$expected" "$actual" \
        'Herdr config must define the generic ha command and follow the current directory'
    assert_file_not_contains "$config" 'codex'
    assert_file_not_contains "$config" 'claude'
    assert_file_not_contains "$config" 'reviewer'
    assert_file_not_contains "$config" 'planner'
    assert_file_not_contains "$config" 'onboarding'
    assert_file_not_contains "$config" 'update_channel'
    jq_assert '
        .packages["github:ogulcancelik/herdr/v0.7.5"] == {}
    ' 'Herdr must use the exact v0.7.5 flake tag in object-form packages'
    assert_file_contains "$REPO_DIR/install.sh" \
        'for dir_name in devbox git herdr; do'
}

test_installer_links_herdr_to_the_physical_source() {
    local target_home physical_repo

    target_home=$(make_test_dir)
    physical_repo=$(CDPATH= cd -P -- "$REPO_DIR" && pwd -P)

    (
        export DOTFILES_SOURCE_DIR="$REPO_DIR"
        export DOTFILES_TARGET_HOME="$target_home"
        unset DEVBOX_DATA_DIR
        # shellcheck source=/dev/null
        . "$REPO_DIR/install.sh"
        # The installer defines fail(); restore the test helper.
        . "$TEST_DIR/test_helpers.sh"

        setup_dotfiles_links

        [ -L "$target_home/.config/herdr" ] ||
            fail 'installer must create the managed Herdr symlink'
        assert_eq "$physical_repo/.config/herdr" \
            "$(readlink "$target_home/.config/herdr")" \
            'Herdr link must target the absolute physical source directory'
    )

    rm -rf "$target_home"
}

test_devbox_lock_is_tracked() {
    (
        cd "$REPO_DIR"
        git ls-files --error-unmatch .config/devbox/global/devbox.lock >/dev/null
    ) || fail 'devbox.lock must be tracked'
}

test_devbox_packages_are_exact_object_pins() {
    jq_assert '."$schema" == "https://raw.githubusercontent.com/jetify-com/devbox/0.17.3/.schema/devbox.schema.json"' \
        'devbox schema must match the pinned 0.17.3 bootstrap version'
    devbox_manifest_has_exact_packages \
        "$REPO_DIR/.config/devbox/global/devbox.json" ||
        fail 'devbox package names and versions must exactly match the supported set'
    jq_assert '.packages.nodejs.version == "24.12.0"' \
        'Node.js must be pinned to 24.12.0'
    jq_assert '.packages.jq.version == "1.7.1"' \
        'jq must be pinned to 1.7.1 for repository tests'
    jq_assert '.packages.git.version == "2.50.1"' \
        'Git must be pinned to 2.50.1 for pure repository tests'
    jq_assert '.packages | has("neovim") | not' \
        'Neovim must not be managed by devbox'
    jq_assert '.packages | has("tree-sitter") | not' \
        'Tree-sitter must not be managed by devbox'
    jq_assert '.packages.zsh.version == "5.9"' \
        'Zsh must be pinned to 5.9'
}

test_devbox_package_validation_rejects_inexact_or_changed_sets() {
    local manifest="$REPO_DIR/.config/devbox/global/devbox.json"
    local fixture_root mutated mutation

    fixture_root=$(make_test_dir)
    mutated="$fixture_root/devbox.json"

    for mutation in \
        '.packages.starship.version = "*"' \
        '.packages.starship.version = ""' \
        '.packages.starship.version = ">=1.0"' \
        '.packages.starship.platforms = ["aarch64-darwin"]' \
        '.packages.zoxide.version = "*"' \
        '.packages["github:ogulcancelik/herdr/master"] = .packages["github:ogulcancelik/herdr/v0.7.5"] | del(.packages["github:ogulcancelik/herdr/v0.7.5"])' \
        '.packages["github:ogulcancelik/herdr"] = .packages["github:ogulcancelik/herdr/v0.7.5"] | del(.packages["github:ogulcancelik/herdr/v0.7.5"])' \
        '.packages["github:ogulcancelik/herdr/v0.7.5"] = {"version":"latest"}' \
        '.packages.unexpected = {"version":"1.0.0"}' \
        'del(.packages.starship)'
    do
        jq "$mutation" "$manifest" > "$mutated"
        if devbox_manifest_has_exact_packages "$mutated"; then
            fail "devbox manifest validator accepted mutation: $mutation"
        fi
    done

    rm -rf "$fixture_root"
}

test_devbox_nvtop_packages_are_platform_specific() {
    jq_assert '
        .packages["nvtopPackages.apple"]
        == {"version":"3.3.2","platforms":["aarch64-darwin"]}
    ' 'Apple nvtop must be pinned to 3.3.2 for aarch64-darwin only'
    jq_assert '
        .packages["nvtopPackages.full"]
        == {
            "version":"3.3.2",
            "platforms":["x86_64-linux","aarch64-linux"]
        }
    ' 'Linux nvtop must be pinned to 3.3.2 for both supported architectures'
}

test_devbox_manifest_packages_are_locked() {
    local manifest="$REPO_DIR/.config/devbox/global/devbox.json"
    local lock="$REPO_DIR/.config/devbox/global/devbox.lock"

    devbox_lock_matches_manifest "$manifest" "$lock" ||
        fail 'devbox lock must contain only complete, immutable entries for the manifest'
}

test_devbox_lock_validation_rejects_incomplete_or_floating_entries() {
    local manifest="$REPO_DIR/.config/devbox/global/devbox.json"
    local lock="$REPO_DIR/.config/devbox/global/devbox.lock"
    local fixture_root mutated mutation

    fixture_root=$(make_test_dir)
    mutated="$fixture_root/devbox.lock"

    for mutation in \
        '.packages["bat@0.26.1"] = null' \
        '.packages["bat@0.26.1"].version = "0.0.0"' \
        '.packages["bat@0.26.1"].resolved = "github:NixOS/nixpkgs/nixpkgs-unstable#bat"' \
        '.packages["bat@0.26.1"].resolved = "github:NixOS/nixpkgs/389ed85304b281ca7f306cf8a1eb4378651ca44e#cowsay"' \
        'del(.packages["bat@0.26.1"].systems["aarch64-linux"])' \
        'del(.packages["nvtopPackages.full@3.3.2"].systems["x86_64-linux"])' \
        '.packages["nvtopPackages.full@3.3.2"].systems["x86_64-linux"].store_path = ""' \
        '.packages["nvtopPackages.full@3.3.2"].systems["x86_64-linux"].outputs = []' \
        '.packages["bat@0.25.0"] = .packages["bat@0.26.1"]' \
        '.packages["github:NixOS/nixpkgs/nixpkgs-unstable"].resolved = "github:NixOS/nixpkgs/nixpkgs-unstable"' \
        '.packages["github:ogulcancelik/herdr/v0.7.5"] = null' \
        'del(.packages["github:ogulcancelik/herdr/v0.7.5"].last_modified)' \
        'del(.packages["github:ogulcancelik/herdr/v0.7.5"].resolved)' \
        '.packages["github:ogulcancelik/herdr/v0.7.5"].unexpected = true' \
        '.packages["github:ogulcancelik/herdr/v0.7.5"].last_modified = "2026-07-21T18:04:33Z"' \
        '.packages["github:ogulcancelik/herdr/v0.7.5"].last_modified = "2026-07-21 18:04:32"' \
        '.packages["github:ogulcancelik/herdr/v0.7.5"].resolved = "github:ogulcancelik/herdr/v0.7.5"' \
        '.packages["github:ogulcancelik/herdr/v0.7.5"].resolved = "github:ogulcancelik/herdr/master"' \
        '.packages["github:ogulcancelik/herdr/v0.7.5"].resolved = "github:other/herdr/0000000000000000000000000000000000000000"' \
        '.packages["github:ogulcancelik/herdr/v0.7.5"].resolved = "github:ogulcancelik/herdr/0000000000000000000000000000000000000000?lastModified=1784657072"' \
        '.packages["github:ogulcancelik/herdr/v0.7.5"].resolved = "github:ogulcancelik/herdr/ef4c23f5775bb8cfec05f05d0844226ff959a07a"' \
        '.packages["github:ogulcancelik/herdr/v0.7.5"].resolved = "github:ogulcancelik/herdr/ef4c23f5775bb8cfec05f05d0844226ff959a07a?lastModified=1784657073"' \
        '.packages["github:ogulcancelik/herdr/v0.7.5"].resolved += "&narHash=sha256-example"'
    do
        jq "$mutation" "$lock" > "$mutated"
        if devbox_lock_matches_manifest "$manifest" "$mutated"; then
            fail "devbox lock validator accepted mutation: $mutation"
        fi
    done

    jq '
        .packages["bat@0.26.1"].resolved
        = "github:NixOS/nixpkgs/389ed85304b281ca7f306cf8a1eb4378651ca44e?lastModified=1784555310#bat"
    ' "$lock" > "$mutated"
    devbox_lock_matches_manifest "$manifest" "$mutated" ||
        fail 'devbox lock validator rejected a fixed revision with a query and exact attribute'

    jq '
        .packages["github:ogulcancelik/herdr/v0.7.6"]
        = .packages["github:ogulcancelik/herdr/v0.7.5"]
        | del(.packages["github:ogulcancelik/herdr/v0.7.5"])
    ' "$manifest" > "$fixture_root/stale-manifest.json"
    if devbox_lock_matches_manifest "$fixture_root/stale-manifest.json" "$lock"; then
        fail 'devbox lock validator accepted a stale Herdr lock after a tag change'
    fi

    rm -rf "$fixture_root"
}

test_devbox_test_runs_repository_suite() {
    jq_assert '
        .shell.scripts.test
        == "bash \"$DEVBOX_PROJECT_ROOT/run-tests.sh\""
    ' 'devbox test must be the exact scalar repository test entrypoint'

    local runner="$REPO_DIR/.config/devbox/global/run-tests.sh"
    assert_path_exists "$runner"
    [ -x "$runner" ] || fail "expected executable test entrypoint: $runner"
    assert_file_contains "$runner" \
        'SCRIPT_DIR=$(CDPATH= cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)'
    assert_file_contains "$runner" \
        'REPO_ROOT=$(CDPATH= cd -P -- "$SCRIPT_DIR/../../.." && pwd)'
    assert_file_contains "$runner" 'exec bash "$REPO_ROOT/tests/run.sh"'
}

test_devbox_test_runner_resolves_symlinked_repository_path() {
    local fixture_root fake_repo linked_global marker runner
    local marker_count marker_path

    fixture_root=$(make_test_dir)
    fixture_root=$(CDPATH= cd -P -- "$fixture_root" && pwd)
    fake_repo="$fixture_root/repository"
    linked_global="$fixture_root/global-link"
    marker="$fixture_root/runner-marker"
    runner="$REPO_DIR/.config/devbox/global/run-tests.sh"

    mkdir -p "$fake_repo/.config/devbox/global" "$fake_repo/tests"
    cp "$runner" "$fake_repo/.config/devbox/global/run-tests.sh"
    chmod +x "$fake_repo/.config/devbox/global/run-tests.sh"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "%s\n" "${BASH_SOURCE[0]}" >> "$RUNNER_MARKER"' \
        > "$fake_repo/tests/run.sh"
    chmod +x "$fake_repo/tests/run.sh"
    ln -s "$fake_repo/.config/devbox/global" "$linked_global"

    RUNNER_MARKER="$marker" "$linked_global/run-tests.sh"

    marker_count=$(wc -l < "$marker" | tr -d ' ')
    marker_path=$(sed -n '1p' "$marker")
    assert_eq '1' "$marker_count" \
        'symlinked test runner must execute the repository suite exactly once'
    assert_eq "$fake_repo/tests/run.sh" "$marker_path" \
        'symlinked test runner must execute the physical repository suite'

    rm -rf "$fixture_root"
}

test_wezterm_has_portable_fonts_without_monitoring_layout() {
    local config="$REPO_DIR/.config/wezterm/wezterm.lua"

    assert_file_not_contains "$config" 'setup_monitoring_layout'
    assert_file_not_contains "$config" "{ key = 's', mods = 'LEADER'"
    assert_file_contains "$config" 'wezterm.font_with_fallback'
    assert_file_contains "$config" "'JetBrains Mono'"
    assert_file_contains "$config" "'Menlo'"
    assert_file_contains "$config" "'monospace'"
}

test_unused_shell_shortcuts_are_absent() {
    local aliases="$REPO_DIR/.config/zsh/aliases.zsh"

    assert_file_not_contains "$aliases" "alias memo_on="
}

test_wezterm_has_portable_herdr_shortcut() {
    local config="$REPO_DIR/.config/wezterm/wezterm.lua"

    assert_file_contains "$config" "{ key = 'N', mods = 'LEADER|SHIFT', action = act.SpawnCommandInNewTab { args = { 'herdr' } } }"
}

test_wezterm_loads_private_ssh_bindings_from_local_config() {
    local config="$REPO_DIR/.config/wezterm/wezterm.lua"
    local example="$REPO_DIR/.config/wezterm/local.lua.example"

    assert_file_not_contains "$config" 'SSH:popssh'
    assert_file_not_contains "$config" 'SSH:duffy'
    assert_file_not_contains "$config" 'SSH:hibana'
    assert_file_not_contains "$config" 'SSH:omokage'
    assert_file_not_contains "$config" 'SSH:roko'
    assert_file_contains "$config" 'pcall(dofile'
    assert_file_contains "$config" '.config/wezterm/local.lua'
    assert_file_contains "$config" 'local_config.ssh_hosts'
    assert_file_contains "$config" "'SSH:' .. host.domain"
    assert_file_contains "$example" 'ssh_hosts'
    assert_file_contains "$example" 'example.invalid'
    assert_file_contains "$example" 'key ='
    assert_file_contains "$example" 'domain ='
    assert_file_contains "$example" 'label ='
    assert_file_not_contains "$example" 'popssh'
    assert_file_not_contains "$example" 'duffy'
    assert_file_not_contains "$example" 'hibana'
    assert_file_not_contains "$example" 'omokage'
    assert_file_not_contains "$example" 'roko'
}

test_readme_documents_setup_boundaries_and_maintenance() {
    local readme="$REPO_DIR/README.md"

    assert_file_contains "$readme" 'bash, curl, and git'
    assert_file_contains "$readme" 'sha256sum or shasum'
    assert_file_contains "$readme" 'WezTerm'
    assert_file_contains "$readme" 'JetBrains Mono'
    assert_file_contains "$readme" 'preferred'
    assert_file_contains "$readme" 'macOS'
    assert_file_contains "$readme" 'Linux'
    assert_file_contains "$readme" 'WSL'
    assert_file_contains "$readme" 'Windows-hosted WezTerm configuration is not installed from WSL'
    assert_file_contains "$readme" 'backup'
    assert_file_contains "$readme" 'never deletes editor state'
    assert_file_contains "$readme" 'devbox run --config .config/devbox/global test'
    assert_file_contains "$readme" 'devbox run --pure --config .config/devbox/global test'
    assert_file_contains "$readme" 'devbox install --config .config/devbox/global'
    assert_file_contains "$readme" "NIX_CONFIG='system = x86_64-linux'"
    assert_file_contains "$readme" 'devbox update nvtopPackages.full --no-install'
    assert_file_contains "$readme" 'NIX_INSTALLER_URL'
    assert_file_contains "$readme" 'NIX_INSTALLER_SHA256'
    assert_file_contains "$readme" 'sha256sum'
    assert_file_contains "$readme" 'shasum -a 256'
    assert_file_contains "$readme" 'DEVBOX_VERSION'
    assert_file_contains "$readme" 'DEVBOX_FLAKE'
    assert_file_contains "$readme" 'OH_MY_ZSH_COMMIT'
    assert_file_contains "$readme" 'ZSH_AUTOSUGGESTIONS_COMMIT'
    assert_file_contains "$readme" 'ZSH_SYNTAX_HIGHLIGHTING_COMMIT'
    assert_file_contains "$readme" 'bash tests/run.sh'
    assert_file_contains "$readme" 're-clone'
    assert_file_contains "$readme" 'reset to the rewritten `main`'
    assert_file_contains "$readme" 'forks, mirrors, pull request refs, and hosting-provider caches'
    assert_file_contains "$readme" 'Local WezTerm settings'
    assert_file_contains "$readme" 'cp /path/to/dotfiles/.config/wezterm/local.lua.example ~/.config/wezterm/local.lua'
    assert_file_contains "$readme" 'Keep real hostnames in this local file'
    assert_file_contains "$readme" '$HOME/.dotfiles-backup/<run-id>/.config/wezterm'
}

test_readme_documents_herdr_use_and_package_managed_updates() {
    local readme="$REPO_DIR/README.md"

    assert_file_contains "$readme" 'herdr'
    assert_file_contains "$readme" 'Press `Ctrl+B`, then `q` to detach'
    assert_file_not_contains "$readme" 'then `Q`'
    assert_file_contains "$readme" 'Ctrl+A`, then `Shift+N` in WezTerm'
    assert_file_contains "$readme" 'Ctrl+B`, then `Shift+N` in Herdr to create a workspace'
    assert_file_contains "$readme" 'Ctrl+B`, then `W` in Herdr to switch or list workspaces'
    assert_file_contains "$readme" 'Ctrl+B`, then `a` in Herdr to run `ha`'
    assert_file_contains "$readme" 'github:ogulcancelik/herdr/v0.7.5'
    assert_file_contains "$readme" 'platform-independent revision'
    assert_file_contains "$readme" '`aarch64-darwin`, `x86_64-linux`, or `aarch64-linux`'
    assert_file_contains "$readme" \
        "devbox update 'github:ogulcancelik/herdr/vX.Y.Z' --no-install --config .config/devbox/global"
    assert_file_contains "$readme" 'Do not run `herdr update`'
}

test_ci_workflow_runs_only_host_independent_checks() {
    local workflow="$REPO_DIR/.github/workflows/validate.yml"

    assert_path_exists "$workflow"
    assert_file_contains "$workflow" 'actions/checkout@v4.2.2'
    assert_file_contains "$workflow" 'bash tests/run.sh'
    assert_file_contains "$workflow" 'bash -n install.sh bin/ha tests/test_helpers.sh tests/test_installer.sh tests/test_configuration.sh tests/test_agent.sh tests/run.sh .config/devbox/global/run-tests.sh'
    assert_file_contains "$workflow" 'zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh'
    assert_file_contains "$workflow" 'jq empty .config/devbox/global/devbox.json .config/devbox/global/devbox.lock'
    assert_file_contains "$workflow" 'git diff --check'
    assert_file_not_contains "$workflow" 'devbox install'
    assert_file_not_contains "$workflow" 'devbox run'
    assert_file_not_contains "$workflow" 'herdr'
    assert_file_not_contains "$workflow" 'nix build'
    assert_file_not_contains "$workflow" 'codex'
    assert_file_not_contains "$workflow" 'claude'
}

test_tracked_private_state_and_historical_wezterm_hosts_are_absent() {
    local tracked_path

    while IFS= read -r tracked_path; do
        case "$tracked_path" in
            *auth*|*session*|*history*|*transcript*|*cache*|*projects*)
                fail "agent runtime state must not be tracked: $tracked_path"
                ;;
        esac
    done < <(git -C "$REPO_DIR" ls-files -- .codex .claude)

    if git -C "$REPO_DIR" grep -n -E 'SSH:(popssh|duffy|hibana|omokage|roko)' -- .config/wezterm; then
        fail 'tracked WezTerm configuration must not contain historical host bindings'
    fi
}

test_neovim_configuration_is_not_tracked
test_public_agent_guidance_excludes_runtime_state
test_installer_does_not_delete_neovim_runtime_data
test_bootstrap_dependencies_are_exactly_pinned
test_installer_has_no_unverified_or_floating_bootstrap_commands
test_zsh_configuration_has_no_custom_npm_prefix_path
test_daily_shell_and_git_defaults_are_safe_and_pinned
test_pet_is_absent_from_active_configuration
test_herdr_is_pinned_and_minimally_configured
test_installer_links_herdr_to_the_physical_source
test_devbox_packages_are_exact_object_pins
test_devbox_package_validation_rejects_inexact_or_changed_sets
test_devbox_nvtop_packages_are_platform_specific
test_devbox_manifest_packages_are_locked
test_devbox_lock_validation_rejects_incomplete_or_floating_entries
test_devbox_test_runs_repository_suite
test_devbox_test_runner_resolves_symlinked_repository_path
test_wezterm_has_portable_fonts_without_monitoring_layout
test_unused_shell_shortcuts_are_absent
test_wezterm_has_portable_herdr_shortcut
test_wezterm_loads_private_ssh_bindings_from_local_config
test_readme_documents_setup_boundaries_and_maintenance
test_readme_documents_herdr_use_and_package_managed_updates
test_ci_workflow_runs_only_host_independent_checks
test_tracked_private_state_and_historical_wezterm_hosts_are_absent
test_devbox_lock_is_tracked
printf 'PASS: %s\n' "$(basename "$0")"

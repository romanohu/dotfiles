# Task 1 Report: Add failing OpenCode configuration and mapping assertions

## Files changed

- `tests/test_configuration.sh`
  - Added `test_opencode_default_permission_is_shared` with the exact expected OpenCode JSONC content.
  - Added the test to the test-call list.
- `tests/test_mise_configuration.sh`
  - Added the exact OpenCode entry to the complete `[dotfiles]` mapping expectation.
- `tests/test_installer.sh`
  - Added the OpenCode target/source pair to the exact managed-link fixture.
  - Updated the expected idempotent link count from 10 to 11.
  - Added the OpenCode target to the preflight fixture loop.
  - Updated the expected preflight fixture count from 10 to 11.

The pre-existing user modification to `.config/zsh/.zshrc` was preserved and not changed or staged.

## Focused test runs and outputs

Commands:

```sh
bash tests/test_configuration.sh
bash tests/test_mise_configuration.sh
bash tests/test_installer.sh
```

All three commands exited with status 1 as expected for the RED state:

- `tests/test_configuration.sh`: `FAIL: expected path to exist: /Users/suzuki_f/dotfiles/.config/opencode/opencode.jsonc`
- `tests/test_mise_configuration.sh`: `FAIL: [dotfiles] must contain exactly the approved mappings`
- `tests/test_installer.sh`: existing fixture warnings were emitted, then the new assertion failed with `FAIL: managed target was omitted from preflight: .config/opencode/opencode.jsonc`

## Scope

Only the three requested test files were modified. No production configuration, mise mapping, installer preflight list, Codex state, or runtime dependency was changed.

## Concerns

The RED failures are expected until the production OpenCode file, mise mapping, and installer preflight target are implemented in the next task. The installer output includes pre-existing warning-path test diagnostics before reaching the intended new failure.

# Security updates and local mise migration implementation plan

> **For agentic workers:** Use inline execution for the coupled pin update and local deployment. Use the requesting-code-review skill for an independent review before integration.

**Goal:** Reproduce the verified security fixes in dotfiles and activate its existing mise setup on this PC.

**Architecture:** Start from GitHub main `0fa9f559b107820c7e76486999108576888b0d11`, which already implements mise. Change only security-related pins and their lock/test/documentation references, then deploy to the user's older checkout while preserving local state.

**Tech Stack:** Bash, Zsh, mise, TOML, OS packages.

## Global constraints

- Node.js `24.22.1`; uv `0.13.4`; mise `2026.10.18`.
- mise installer SHA-256 `5c5d50685ad52c26a7fd691bda5505f6908a7953b2766fc5bd61d2ae3c4a2df1`.
- Lock `macos-arm64`, `linux-x64`, and `linux-arm64`; retain other tool versions.
- Preserve local Herdr settings, legacy Devbox customizations and untracked editor/runtime state outside published changes.
- Do not uninstall Nix, change credentials or start/stop user services.

### Task 1: Update the reproducible security pins

Files: `mise.toml`, `mise.lock`, `install.sh`, `README.md`, `tests/test_configuration.sh`, `tests/test_mise_configuration.sh`, `tests/test_installer.sh`.

- [x] Run `bash tests/run.sh` on unmodified GitHub main; confirm all four test files pass.
- [ ] Update the existing expected versions and installer hash in the offline tests first; run the suite and confirm the old configuration fails those assertions.
- [ ] Replace the production pins and README versions with the exact values above. Keep bootstrap behavior and the supported tool set unchanged.
- [ ] Use the checksum-verified release installer to stage mise outside the user's active configuration, then run its CLI help for the supported selective lock command.
- [ ] Regenerate Node and uv lock entries with `mise lock --platform macos-arm64,linux-x64,linux-arm64 node uv`; use `--locked=false` if required while generating the replacement lock. Verify with a TOML comparison that all other tool records are unchanged.
- [ ] Run `bash tests/run.sh`, Bash/Zsh syntax checks, and `git diff --check`. Run the mise test task with managed-tool auto-installation disabled as already specified by the repository.
- [ ] Commit the reviewed pin update and request an independent code review; resolve actionable findings and rerun covering checks.

### Task 2: Activate the reviewed mise configuration on this PC

- [ ] Back up the existing tracked Devbox manifest/lock and Herdr configuration outside the repository and save a file-hash inventory. Verify the updated branch descends from the local main commit.
- [ ] Compare old, new and local Herdr configuration; preserve the local customization without committing runtime data. Restore only backed-up tracked files temporarily if needed to permit a fast-forward to the reviewed commit.
- [ ] Fast-forward the local checkout; restore its local Herdr customization. Preserve untracked files. Run the updated installer using its existing conflict checks; investigate any conflict before changing the target.
- [ ] Install locked tools and verify `mise which node`, `mise which uv`, and their versions. Remove only the temporary override symlinks created by this investigation once the mise replacements work.
- [ ] Check a fresh interactive Zsh, Brotli round-trip and malformed-input rejection, HTTPS connectivity, and rejection of both eMudhra demonstration chains.
- [ ] Record remaining OS/app findings and the test results in the user-facing audit report. Keep the code branch and local backup available for review and recovery.

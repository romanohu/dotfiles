# Add the Pueue daemon to the mise-managed toolset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or superpowers:subagent-driven-development) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install the exact-pinned Pueue client and daemon through mise, while leaving daemon startup manual and side-effect free.

**Architecture:** Replace the single direct GitHub tool entry with two mise aliases, `pueue` and `pueued`, that resolve the same `4.0.4` release using anchored asset selectors. Regenerate the tracked multi-platform lockfile, update the repository’s offline assertions and README, and do not add any service or shell-startup integration.

**Tech Stack:** TOML (`mise.toml`), generated mise lockfile (`mise.lock`), Bash tests, Markdown documentation, mise 2026.8.9.

## Global Constraints

- The managed Pueue version is exactly `4.0.4` for both binaries.
- `pueue` selects `^pueue-`; `pueued` selects `^pueued-` via `matching_regex`.
- The lockfile platforms remain `macos-arm64`, `linux-x64`, and `linux-arm64`.
- `install.sh` and mise bootstrap must not start, stop, or configure a Pueue daemon.
- Existing daemons and sockets outside the repository are not modified.
- Git/Zsh and the existing mise bootstrap path remain unchanged.
- Preserve the unrelated uncommitted `.config/zsh/.zshrc` change.

---

### Task 1: Add failing configuration and documentation assertions

**Files:**
- Modify: `tests/test_mise_configuration.sh:74-130,216-219`
- Modify: `tests/test_configuration.sh:70-108`

**Interfaces:**
- The tests consume `mise.toml`, `mise.lock`, and `README.md` and must remain
  offline and host-independent.
- Later tasks must satisfy the exact strings and counts asserted here.

- [ ] **Step 1: Replace the old single-tool expectations.**

  In `test_mise_tools_are_exact_and_complete`, remove the line
  `"github:Nukesor/pueue" = "4.0.4"` from the flat `[tools]` expectation; the
  two new entries are nested TOML tables and are checked separately. Add an
  exact `[tool_alias]` assertion:

  ```text
  pueue = "github:Nukesor/pueue"
  pueued = "github:Nukesor/pueue"
  ```

  Use `mise_section_entries` so the test rejects missing, reordered, or extra
  aliases. Add two more exact section assertions:

  ```text
  mise_section_entries "$REPO_DIR/mise.toml" '[tools.pueue]' \
      == $'version = "4.0.4"\nmatching_regex = "^pueue-"'
  mise_section_entries "$REPO_DIR/mise.toml" '[tools.pueued]' \
      == $'version = "4.0.4"\nmatching_regex = "^pueued-"'
  ```

  The existing flat-entry helper must continue to assert every other managed
  tool exactly; do not make it silently accept an extra flat tool.

- [ ] **Step 2: Update lock expectations for two Pueue entries.**

  In `test_mise_lock_has_supported_platform_artifacts`, replace the one
  `github:Nukesor/pueue` expected row with `pueue` and `pueued`, change the lock
  entry count from 17 to 18, and require both names in `mise_lock_tool_entries`.
  Keep the ordinary URL/checksum totals unchanged until the generated lock is
  inspected; if the GitHub backend adds one platform asset per alias, assert
  the resulting exact URL and checksum totals rather than allowing a range.
  Add checks that the lock contains URLs beginning with both
  `.../pueue-` and `.../pueued-`, and that no URL used by `pueue` contains the
  `pueued-` asset prefix.

- [ ] **Step 3: Add README behavior assertions.**

  In `test_readme_documents_mise_setup_and_boundaries`, require the exact
  manual flow and version parity strings:

  ```text
  pueue 4.0.4
  pueued 4.0.4
  pueued -d
  pueue status
  ```

  Also require text that bootstrap does not start the daemon. Keep the existing
  assertions that prevent service-side effects or obsolete Devbox/Nix paths.

- [ ] **Step 4: Run focused tests and verify RED.**

  Run:

  ```sh
  bash tests/test_mise_configuration.sh
  bash tests/test_configuration.sh
  ```

  Expected: failure because the current manifest still has one direct Pueue
  entry, the lock has no daemon entry, and the README has no manual daemon
  flow. Do not weaken the assertions to make the current files pass.

### Task 2: Replace the manifest entry and regenerate the locked assets

**Files:**
- Modify: `mise.toml:10-25`
- Modify: `mise.lock` (generated; do not hand-edit individual checksums)

**Interfaces:**
- Produces the `pueue` and `pueued` tool names and exact versions consumed by
  the tests and README.
- Consumes the existing `mise.min_version`, lockfile platform list, and all
  other tool entries without changing them.

- [ ] **Step 1: Add the two aliases and exact tool tables.**

  Add this table before `[tools]`:

  ```toml
  [tool_alias]
  pueue = "github:Nukesor/pueue"
  pueued = "github:Nukesor/pueue"
  ```

  Remove the existing line:

  ```toml
  "github:Nukesor/pueue" = "4.0.4"
  ```

  Add the following entries in its position:

  ```toml
  [tools.pueue]
  version = "4.0.4"
  matching_regex = "^pueue-"

  [tools.pueued]
  version = "4.0.4"
  matching_regex = "^pueued-"
  ```

- [ ] **Step 2: Regenerate the lockfile for all supported platforms.**

  Run from the repository root:

  ```sh
  mise lock --platform macos-arm64,linux-x64,linux-arm64
  ```

  If mise reports an asset-selection ambiguity, inspect the v4.0.4 release
  asset names and tighten only the two anchored regular expressions; do not
  remove the platform entries or fall back to a floating version. The result
  must include separate `[[tools.pueue]]` and `[[tools.pueued]]` sections with
  the three supported platform URLs and backend checksums where published.

- [ ] **Step 3: Run the focused configuration tests.**

  Run:

  ```sh
  bash tests/test_mise_configuration.sh
  ```

  Expected: PASS, including exact entry counts, distinct asset prefixes, and
  lock checksums. If the generated lock changes unrelated tools, restore only
  those unrelated generated sections before continuing and investigate the
  mise version or platform command that caused the drift.

### Task 3: Document manual daemon operation

**Files:**
- Modify: `README.md:31-49,75-96`

**Interfaces:**
- Documents the commands tested by `test_configuration.sh`.
- Must not claim that `install.sh` or mise starts a daemon.

- [ ] **Step 1: Update the managed-tool inventory.**

  Change the inventory text so it names both `pueue 4.0.4` and
  `pueued 4.0.4`, without changing the versions of the other tools.

- [ ] **Step 2: Add the explicit manual flow.**

  Add a short subsection after the tool inventory or before shell usage:

  ```markdown
  ### Pueue client and daemon

  The bootstrap installs the matching Pueue client and daemon but does not
  start a background service. Start the daemon manually when needed, then
  verify the client connection:

  ```sh
  pueued -d
  pueue status
  ```

  Keep both binaries at the same pinned version (`4.0.4`). Existing daemons
  and sockets are not stopped or removed by this repository.
  ```

  Use the repository’s existing prose style and do not add launchd/systemd
  instructions.

- [ ] **Step 3: Run documentation assertions.**

  Run:

  ```sh
  bash tests/test_configuration.sh
  ```

  Expected: PASS, including the exact removed-tool and unmanaged-htop lines
  already protected by this test.

### Task 4: Run the full verification gate and record the change

**Files:**
- Include: `docs/superpowers/specs/2026-08-22-pueued-mise-design.md`
- Include: `docs/superpowers/plans/2026-08-22-pueued-mise.md`
- Include: `mise.toml`, `mise.lock`, `README.md`, and the two test files above

- [ ] **Step 1: Run the complete repository checks.**

  Run:

  ```sh
  bash tests/run.sh
  bash -n install.sh tests/test_helpers.sh tests/test_installer.sh tests/test_configuration.sh tests/test_mise_configuration.sh tests/test_runner.sh tests/run.sh
  zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
  git diff --check
  ```

  Expected: all commands exit 0. Confirm `git status --short` still shows the
  pre-existing `.config/zsh/.zshrc` modification and no generated temporary
  files.

- [ ] **Step 2: Verify the pinned binaries on the current host.**

  Run:

  ```sh
  mise install --locked
  pueue --version
  pueued --version
  ```

  Expected: both commands report `4.0.4`. Start the daemon only for the manual
  smoke check, then stop it explicitly after checking status:

  ```sh
  pueued -d
  pueue status
  pueue shutdown
  ```

  Do not add any daemon process or socket to the repository.

- [ ] **Step 3: Review the diff and commit.**

  Run:

  ```sh
  git diff --stat
  git diff -- mise.toml README.md tests/test_mise_configuration.sh tests/test_configuration.sh
  git status --short
  ```

  Confirm `.config/zsh/.zshrc` is not staged or altered by this task, then
  commit only the Pueue changes and the approved spec/plan documents:

  ```sh
  git add mise.toml mise.lock README.md tests/test_mise_configuration.sh tests/test_configuration.sh docs/superpowers/specs/2026-08-22-pueued-mise-design.md docs/superpowers/plans/2026-08-22-pueued-mise.md
  git commit -m "feat: install pueue daemon with mise"
  ```

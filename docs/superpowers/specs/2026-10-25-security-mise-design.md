# Security updates and local mise migration

The user approved using mise with OS packages, preserving existing settings and uncommitted work. GitHub main already implements the mise migration; this PC is still running its older Devbox checkout. Reuse that implementation rather than rebuilding it.

Update Node.js from 24.12.0 to the security release 24.22.1 and uv from 0.11.6 to 0.13.4. Update the pinned mise bootstrap from 2026.8.9 to 2026.10.18, verifying its release installer against SHA-256 `5c5d50685ad52c26a7fd691bda5505f6908a7953b2766fc5bd61d2ae3c4a2df1`. Retain all other approved tools and versions from current main. Regenerate only the affected tool lock entries for macos-arm64, linux-x64 and linux-arm64.

Run the host-independent tests before and after the change. Preserve bootstrap checksum verification, conflict checks and user-owned runtime files. Do not add credentials, logs or session data to the repository.

Before applying current main and the security changes to this PC, save the three existing tracked local modifications outside the public repository. Retain the user's Herdr configuration and preserve legacy Devbox customizations in the backup. Install mise and its locked tools, switch the existing repository symlinks to the updated checkout, and retire the temporary Node/uv override links created during the vulnerability investigation after verifying mise's replacements. Keep Nix installed for unrelated projects; stop loading Devbox in Zsh. OS-dependent software stays with the OS package manager.

Verify an interactive Zsh resolves Node.js and uv through mise, Node's Brotli patch is present, ordinary HTTPS works and compromised eMudhra chains are rejected. Review the branch before publishing or integrating. App-bundled runtimes and the unpatched distribution Brotli library remain separate audit findings.

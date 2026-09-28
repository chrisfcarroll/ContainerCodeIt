# 06 — `code-it-add-tool-chain`: code-it adds a new tool chain

See 00-conventions.md. Depends on 01. Shares plumbing with 05.

## Goal
`code-it-add-tool-chain NAME [--url URL]` runs code-it headless on this repo with a built-in prompt that adds tool chain NAME, and optionally its package cache.

## Behaviour
Same as 05: new branch `add-tool-chain/NAME`, refuse if the repo is dirty, never push, `--dry-run` prints the prompt and command, print the branch and a diff summary at the end.

## Built-in prompt (for the in-container agent)
1. Gate first. Proceed only if NAME is a reasonably well-known language/runtime AND its tool chain installs securely:
   - from Alpine's own repos, or from the vendor's official HTTPS distribution, with checksum or signature verification where published;
   - ships musl builds for x86_64 and aarch64, or fails the build clearly on unsupported arches;
   - actively maintained with security updates.
   Otherwise stop, print the reason, make no changes, exit non-zero.
2. Follow how `bun` was added (commit 49b3ee7) as the template:
   - Dockerfile: `ARG NAME=false`, normalise into `/etc/code-it-tech.env`, an install layer guarded by it, a minimal `doas` permit.
   - Known names and any aliases in the shared lib from 01, so `code-it-build`, `code-it` and image naming all pick it up.
   - Completions (bash, zsh, PowerShell) and the README tables and "Tool chains" section.
3. If the tool chain has a package manager with a well-known global cache, add it to `--package-caches`: find the host cache (env var, then config, then default path, as NuGet does), mount it read-only at `~/.<name>-host`, and seed the container's writable cache from it (as npm/bun do in `go.sh`) or register it as a read-only fallback (as NuGet does). Never let the container write to the host cache.
4. Add tests to both suites mirroring the bun ones. Build the image and run the tool chain's `--version` headlessly. Commit.

## Done when
- Tests (stub agent) cover: dirty-repo refusal, branch creation, the prompt includes the security gate, and a gate refusal gives a non-zero exit code.

# 07 — `code-it-first-run`: interactive setup

See 00-conventions.md. Depends on 01 and 04.

## Goal
One interactive command that takes a new user from nothing to a built image with their agent logins carried over.

## Flow
1. Check for git.
2. Invoke `code-it-build` interactively; it owns runtime detection, host toolchain/agent detection and selection, build confirmation, and image building. Forward explicit toolchains, agents, runtime, image, Dockerfile directory, `--yes`, and `--dry-run`.
3. For each selected agent whose host config/state paths exist (from its definition, e.g. `~/.claude`, `~/.claude.json`, `~/.config/opencode`, `~/.local/share/opencode`), offer to copy them into `--save-dir` (default `~/.config/code-it`), preserving layout.
   - Copy, never move or symlink. Never overwrite existing files without asking.
   - Say plainly that credentials will be copied and will be readable by the agent in the container.
   - On Windows, resolve the equivalent host paths (`%USERPROFILE%`, `%APPDATA%`).
4. Print the `code-it` command to start.

## Testability
- `--dry-run`: do everything except build and copy; print what would happen.
- Read answers from stdin so tests can script them; `--yes` accepts all defaults.
- Tests: build selection/detection with stubbed PATH/HOME, first-run delegation, no-overwrite on copy, dry-run makes no changes.

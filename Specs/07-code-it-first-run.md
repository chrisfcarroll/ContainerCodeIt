# 07 — `code-it-first-run`: interactive setup

See 00-conventions.md. Depends on 01 and 04.

## Goal
One interactive command that takes a new user from nothing to a built image with their agent logins carried over.

## Flow
1. Check for a container runtime and git (reuse code-it's detection and advice).
2. Detect host toolchains (each stack definition supplies its own detect command, e.g. `dotnet --version`, `node --version`, `volta --version`, `python3 --version`, `uv --version`) and host agents (from agent definitions: binary on PATH or config dir present).
3. Ask which stacks and which agents to include. Pre-select what was detected; show every available one. Plain numbered prompts; no TUI dependency.
4. Show the resulting `code-it-build` command; confirm; run it.
5. For each chosen agent whose host config/state paths exist (from its definition, e.g. `~/.claude`, `~/.claude.json`, `~/.config/opencode`, `~/.local/share/opencode`), offer to copy them into `--save-dir` (default `~/.config/code-it`), preserving layout.
   - Copy, never move or symlink. Never overwrite existing files without asking.
   - Say plainly that credentials will be copied and will be readable by the agent in the container.
   - On Windows, resolve the equivalent host paths (`%USERPROFILE%`, `%APPDATA%`).
6. Print the `code-it` command to start.

## Testability
- `--dry-run`: do everything except build and copy; print what would happen.
- Read answers from stdin so tests can script them; `--yes` accepts all defaults.
- Tests: detection with stubbed PATH/HOME, answer parsing, no-overwrite on copy, dry-run makes no changes.

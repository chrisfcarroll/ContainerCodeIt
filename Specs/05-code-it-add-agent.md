# 05 — `code-it-add-agent`: code-it adds a new agent

See 00-conventions.md. Depends on 04.

## Goal
`code-it-add-agent NAME [--url URL]` runs code-it headless on this repo with a built-in prompt that adds an agent definition (04 format) for NAME.

## Behaviour
- Runs `code-it --headless --work-dir <this repo>` with the prompt below, using the user's current default agent.
- Works on a new branch `add-agent/NAME`. Never commits to the current branch, never pushes. Prints the branch and a diff summary at the end.
- Refuses if the repo has uncommitted changes.
- `--dry-run` prints the prompt and code-it command only.

## Built-in prompt (for the in-container agent)
1. Gate first. Proceed only if NAME is a reasonably well-known coding agent: an established vendor or a widely used open-source project, actively maintained, with official docs and an official install channel. Otherwise stop, write the reason to stdout, make no changes, exit non-zero.
2. Read the agent's official docs: install, binary path, config/state/auth locations, CLI flags for opening prompt and non-interactive mode.
3. Add `agents/NAME/` per the 04 format. Install from the official channel only; pin versions where possible.
4. Add tests, README row, completions. Run the tests. Commit.

## Done when
- Tests cover: dirty-repo refusal, branch creation, prompt contents, and propagating a non-zero gate refusal as the tool's exit code (using a stub agent).

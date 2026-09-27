# Conventions for every prompt in this folder

- Read HumansAndAgents.md first. They apply.
- Every script ships as a bash + PowerShell pair (`code-it-x.sh`, `Code-It-X.ps1`) with the same logical parameters. Works on macOS, Linux, Windows; docker and Apple `container`.
- Tests are mandatory: extend `tests/test-code-it.sh` and `tests/Test-CodeIt.ps1` (or add sibling files wired into `tests/run-all-tests.sh`). Prefer `--dry-run` assertions over real builds.
- Update `README.md` option tables and `completions/` (bash, zsh, PowerShell) for any new parameter.
- Keep the defaults working: `code-it.sh` with no arguments should behave as it does today
- One conventional commit per logical change.

# 11 — Pass environment variables and other arguments to the container runtime

See 00-conventions.md.

## Goal
Let users pass arguments to `docker run` / `container run`, chiefly environment
variables (e.g. a proxy), without editing the scripts. Arguments go to three places:
code-it's own options; the container runtime; and the coding agent (after `--` in bash,
unrecognised arguments in PowerShell). Keep those three separate.

## Options on `code-it`
Each repeatable, one argument each (like `gcc -Xlinker`), so nothing is word-split and
quoting works the same in bash and PowerShell:
- `--env`, `-e NAME[=VALUE]` (PowerShell `-environment`, aliases `-env`, `-e`; array).
  A bare `NAME` passes the host's value, if set. Reject anything that is not a valid
  `NAME` or `NAME=VALUE`.
- `--env-file FILE` (PowerShell `-envFile`; array). Error if FILE does not exist.
- `--run-arg ARG`, alias `--docker-arg` (PowerShell `-runArgs`, alias `-dockerArgs`;
  array). Passed verbatim: an option and its value are two `--run-arg`s, or one if
  joined with `=`.

## `<save dir>/run-args`
For settings every run needs. If it exists, read it as devcontainer.json's `runArgs`:
one argument per line, not quoted, whitespace trimmed, blank lines and `#` comments
skipped. Say when it is used (`Using run arguments from …`).

## Order and runtimes
- After code-it's own arguments and before the image: the file's arguments first, then
  `--env`, `--env-file` and `--run-arg` in command-line order. So with docker a later
  `-e` of the same name wins.
- Docker reads a bare `-e NAME` from the host itself. Apple `container` does not, so
  code-it fills in `NAME=value` (dropping it if unset). Either way, the printed command
  shows only the bare name, never the value.
- `--run-arg` is not portable between docker and `container`; say so in help and README.
- The printed command puts each option on its own line, its value on the same line.

## Docs
- Help text in both scripts, README option table, a "Passing arguments to the container
  runtime" section with bash, PowerShell and `run-args` examples, and a pointer to
  Docker's own proxy config (`~/.docker/config.json`) as an alternative.
- Completions: `--env` completes environment variable names, `--env-file` files,
  `--run-arg` nothing.
- Shared helpers in the lib files (`ci_read_run_args`, `ci_valid_env_spec` and twins).

## Done when
Tests in both suites, using `--dry-run` and stub runtimes, cover: each option printed;
order relative to code-it's own args, the image and agent args; invalid `--env` and
missing `--env-file` fail; the `run-args` file is read, reported, comments skipped,
values with spaces quoted, and comes first; no file means no extra args; docker gets a
bare `-e NAME` without its value; `container` gets the host value but the printout
does not; help documents the options and the file; PowerShell options bind under
`pwsh -File`; completions.

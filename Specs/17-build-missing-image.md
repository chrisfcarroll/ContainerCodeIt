# 17 — Build the image when no existing image will do

See 00-conventions.md. Amends 08-superset-image.md.

## Goal
When `code-it` needs `code-it-alpine-<chains>`, the image does not exist, and no
existing image contains every requested toolchain, it used to warn and exit, telling
the user to run code-it-build. Instead, warn and then build it, and run it.

## Behaviour
- The warning still says the image does not exist, and names the build it starts:
  `Warning: docker image 'code-it-alpine-python' does not exist; building it with
  code-it-build.sh --toolchain python --agent opencode,claude`.
- The build gets the run's resolved toolchains and package caches, its `--locale`, its
  runtime and the image name, with `--yes` so it does not ask. Its agents are the
  build's defaults (opencode, claude) plus the agent about to run; `--no-agent` adds
  none.
- `--dry-run` passes `--dry-run` to the build, which prints its build command, and
  then prints the run command as usual.
- A failed build stops code-it with the build's exit code, before anything runs.
- An explicit `--image` is still never substituted or built: a missing one is an error.
- `CODE_IT_BUILD` overrides the build script's path, as `CODE_IT_FIRST_RUN` does for
  first-run, so tests can stub it.

## Docs
`--image` help in both scripts; the README.

## Done when
Tests in both suites, using `--dry-run` and stub runtimes and a stub build, cover: the
warning, then a dry-run build of the missing image followed by the run; the arguments
passed to the build, including the agent list with a chosen agent, an agent already in
the defaults, and `--no-agent`; a failed build exits with its code and does not run;
an explicit `--image` is not built.

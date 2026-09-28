# 10 — Default: an existing code-it image, or first-run

See 00-conventions.md. Supersedes the weighted default in 09 (the history file stays,
and now orders the choice).

When `code-it` runs with no `--tool-chains` and no `--image`:

1. If `--save-dir` does not exist, run `code-it-first-run` and exit: there is no setup
   yet.
2. Otherwise choose an existing image whose repository starts with `code-it-`,
   preferring the most recently used remembered image that still exists, then the most
   recently built. Use that image and its tool chains.
3. Otherwise there is no code-it image at all: run `code-it-first-run` and exit.

So the default is always first-run until an image exists, and thereafter the most
recent existing code-it image. Explicit `--tool-chains` or `--image` bypasses all of
this. Under `--dry-run`, first-run is not run: print what would happen and exit 0.

A `CODE_IT_FIRST_RUN` environment variable (PowerShell: `$env:CODE_IT_FIRST_RUN`)
overrides the first-run launcher path, for testing.

# 10 — Default when the memory does not choose: an existing code-it image, or first-run

See 00-conventions.md. **Spec 09 still applies in full**: when `code-it` runs with no
`--tool-chains` and no `--image`, the 70% weighted rule chooses the remembered image.

This spec amends only the final paragraph of Spec 09. Where 09 says

> If nothing is remembered, or no remembered image covers 70%, keep today's default
> tool chains.

read instead:

1. If `--save-dir` does not exist, run `code-it-first-run` and exit: there is no setup
   yet.
2. Otherwise, if `image-history` exists, use the 70% weighted rule of Spec 09. If it
   selects an existing image, use that image.
3. Otherwise (no image history, or the weighted rule selected nothing), if any
   `code-it-*` image exists, use the most recently used remembered one that still
   exists, else the most recently built. Use that image and its tool chains.
4. Otherwise there is no code-it image at all: run `code-it-first-run` and exit.

Explicit `--tool-chains` or `--image` bypasses all of this, and the image used is still
recorded per Spec 09. Under `--dry-run`, first-run is not run: print what would happen
and exit 0.

A `CODE_IT_FIRST_RUN` environment variable (PowerShell: `$env:CODE_IT_FIRST_RUN`)
overrides the first-run launcher path, for testing.

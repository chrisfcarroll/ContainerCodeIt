# 01 — Extract image building into `code-it-build`; rename `--tech` to `--tool-chains`

See 00-conventions.md.

## Goal
Move `--build-image` / `--rebuild-image` (`-buildImage` / `-rebuildImage`) out of `code-it.sh` / `Code-It.ps1` into new `code-it-build.sh` / `Code-It-Build.ps1`. Keep the Dockerfile's `ARG`-switch design as is. (Superseded by Spec 11: tool chains and package caches are now fragments assembled at build time, with no ARG switches.)

## `code-it-build` parameters
- `--tool-chains LIST`, `--package-caches LIST`: same names, aliases, defaults (`dotnet,node`; caches implied by tool chains) and unknown-name errors as code-it today. Emits the same `--build-arg`s (`DOTNET`, `NODE`, `BUN`, `NUGET`, `NPM`).
- `--rebuild`: bump `# last changed` dates first (existing logic).
- `--image` (default derived from tool chains, `code-it-alpine-<chains>`), `--dockerfile-dir`, `--runtime`, `--dry-run`, `--help`.
- Label the image with its tool chains and package caches (e.g. `--label code-it.tool-chains=dotnet,node`).

## `code-it` changes
- No building. Keep `--build-image` / `--rebuild-image` as thin shims that call `code-it-build` with the same tool chains, package caches, image, runtime and dockerfile dir, then run. Print a one-line deprecation note.
- Still takes `--tool-chains` / `--package-caches`: it needs them for the default image name and for which host caches to mount.
- Replace the image-name mismatch guess with a read of the image label, where the runtime supports it. Fall back to today's name-based warning.
- Put shared logic (runtime detection, list/alias resolution, image naming) in one sourced file per shell (e.g. `lib/code-it-common.sh`, `lib/CodeItCommon.ps1`) used by both scripts. No copies.

## Done when
- `code-it-build --dry-run` prints the same build command code-it prints today for every existing `--tech`/`--package-caches` test case.
- Existing tests pass after being moved to the new script or the shims; new tests cover the `--tech` alias, `--rebuild`, the label, and the shims.

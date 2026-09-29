# 01 — Extract image building into `code-it-build`; rename `--tech` to `--tool-chains`

See 00-conventions.md.

Amended 2026-10-17: `code-it-build` prompts when no toolchain is supplied; `code-it` keeps no build shims. See "Amendment" at the end.

## Goal
Move `--build-image` / `--rebuild-image` (`-buildImage` / `-rebuildImage`) out of `code-it.sh` / `Code-It.ps1` into new `code-it-build.sh` / `Code-It-Build.ps1`. Keep the Dockerfile's `ARG`-switch design as is. (Superseded by Spec 13: toolchains and package caches are now fragments assembled at build time, with no ARG switches.)

## `code-it-build` parameters
- `--tool-chains LIST` (now `--toolchain`): with none, enter interactive setup, preselecting detected host toolchains. An explicitly empty list remains an error.
- With no toolchain, ask which agents to include, preselecting detected agents. `--yes` accepts detected/default selections without asking; parameterized builds with an explicit toolchain retain the `opencode,claude` default agents.
- `--interactive`: ask for any omitted toolchain/agent selection. First-run uses this when invoking build.
- `--package-caches LIST`: same name, aliases, default (caches implied by toolchains) and unknown-name errors as code-it today.
- Emits the same `--build-arg`s (`DOTNET`, `NODE`, `BUN`, `NUGET`, `NPM`).
- `--rebuild`: bump `# last changed` dates first (existing logic).
- `--image` (default derived from toolchains, `code-it-alpine-<chains>`), `--dockerfile-dir`, `--runtime`, `--dry-run`, `--help`.
- Label the image with its toolchains and package caches (e.g. `--label code-it.tool-chains=dotnet,node`).

## `code-it` changes
- No building. Remove `--build-image` / `--rebuild-image` / `--dockerfile-dir` (`-buildImage` / `-rebuildImage` / `-dockerfileDir`). Passing one fails with a message pointing to `code-it-build`; in PowerShell, check for them explicitly, as they would otherwise reach the agent as pass-through arguments.
- Messages that advise a rebuild name a complete `code-it-build --toolchain <chains> --agent <agents>` command.
- Still takes `--tool-chains` / `--package-caches`: it needs them for the default image name and for which host caches to mount.
- Replace the image-name mismatch guess with a read of the image label, where the runtime supports it. Fall back to today's name-based warning.
- Put shared logic (runtime detection, list/alias resolution, image naming) in one sourced file per shell (e.g. `lib/code-it-common.sh`, `lib/CodeItCommon.ps1`) used by both scripts. No copies.

## Done when
- `code-it-build --dry-run` prints the same build command code-it printed for every existing `--tech`/`--package-caches` test case.
- Existing build tests pass after being moved to the new script; tests cover interactive selection without a toolchain, the `--tech` alias, `--rebuild`, labels, and the removed `code-it` options failing without building.

## Amendment (2026-10-16)
The first version kept `--build-image` / `--rebuild-image` as deprecated shims, and gave `code-it-build` the default toolchains `dotnet,node`. Both are gone:
- `code-it` chooses one agent to run; an image holds a set. The shim passed only the agent being run, so rebuilding an image through it dropped its other agents.
- The shim did not pass `--dry-run`, so `code-it --dry-run --build-image` really built.
- A default toolchain builds an image nobody asked for. Without one, the shim would have had to invent one for `code-it --build-image --image X`.

Passing all of `code-it-build`'s parameters through `code-it` would duplicate its interface, so images are built only by `code-it-build` (directly, or from first run).

## Amendment (2026-10-17)
`code-it-build` is interactive when no toolchain is supplied. First-run delegates runtime detection, toolchain/agent selection, build confirmation, and image building to it. First-run remains responsible for offering to copy host agent configuration into the save directory without overwriting existing files, then printing the run command.

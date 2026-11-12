# 20 — A saved default container runtime, asked for at first run

See 00-conventions.md. Amends Specs 07 (first-run) and 15 (code-it-defaults).

## Goal

The container runtime is a saved default, like the agent and toolchain, so a machine
with both docker and wslc (or docker and Apple's container) uses the one you chose
without `--runtime` every time.

## Storage

`default-runtime=docker|container|wslc` in `<save-dir>/defaults`.

## Which runtimes a platform can have

docker everywhere; Apple's `container` only on macOS; wslc on Windows, and wherever it
is found. WSL installs its container CLI on Windows as both `wslc.exe` and
`container.exe`, identical binaries, so a `container` off macOS is never Apple's: it
is not detected, not offered, and `--runtime container` (or saving it) is refused
there, on Windows with a pointer to wslc. PowerShell tests set `CODE_IT_PLATFORM`
(macos, windows, linux) to stand in for the platform, as `$IsMacOS` cannot be faked;
bash tests stub `uname`.

## Who reads it

`code-it`, `code-it-build` and `code-it-doctor`, when `--runtime` is not given, say
`Using saved default runtime: NAME` and use it. A saved runtime that is not installed
is an error, as an explicit `--runtime` would be. With nothing saved, auto-detection
is as before (macOS: container, then docker; elsewhere docker, then wslc), except
that `container` is no longer a last resort off macOS. `code-it-build` gains `--save-dir` (`-saveDir`) to find the defaults; code-it
and first-run pass theirs.

## first-run

Unless `--runtime` is given, first-run lists the platform's runtimes, marking those
found with `*`, and asks, by number or name. The suggested
answer is the platform's own runtime — container on macOS, wslc on Windows, docker
elsewhere (WSL's Linux included) — when it is found, else the auto-detected one.
`--yes` takes the suggestion. The answer, or the `--runtime` given, is saved through
`code-it-defaults --runtime`; `--dry-run` only says what it would save. With no
runtime found, nothing is asked and the build reports it as before.

code-it passes `--runtime` to first-run only when it was given or saved: an
auto-detected runtime is first-run's to ask about.

## code-it-defaults

`--runtime, -r NAME` (`-runtime`, `-r`): docker, container, wslc, or none to clear.
A runtime not installed here is saved with a warning; one the platform cannot have
is refused. The interactive run asks it
last, as first-run does; `--show` prints it.

## Done when

- Tests in both suites: the helpers; code-it, build and doctor using the saved
  runtime and `--runtime` beating it; first-run asking, suggesting, saving, `--yes`,
  `--runtime`, `--dry-run`; code-it-defaults `--runtime`, `--show`, the question.
- README, help and completions updated.

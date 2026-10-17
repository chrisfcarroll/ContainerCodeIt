# 16 — `--no-agent`: a plain zsh shell instead of a coding agent

See 00-conventions.md.

## Goal
Sometimes you want a code-it container's toolchains, mounts and locale without any
coding agent: `--no-agent` (alias `--zsh`; PowerShell `-noAgent`, alias `-zsh`) runs
the container's tmux with a plain interactive zsh.

## Behaviour
- The run passes `-e CODE_AGENT_SHELL=1` instead of `-e CODE_AGENT=...`, and appends
  nothing after the image. In go.sh, that variable selects zsh before any agent lookup.
- The run stays interactive (`-it`). A prompt (`--prompt` or a bare argument) or
  `--headless` has no agent to run it and is an error, as is combining `--no-agent`
  with `-claude`, `-opencode` or `-agent` (PowerShell, where they are parameters).
- No agent definition is loaded: no agent state is mounted, no default agent config is
  written, no exclusive-state lock is taken, and the image's agent checks (which agents
  and binaries it records) are skipped. A saved default agent is not applied.
- Everything else is unchanged: toolchain and package-cache selection, remembered
  image, port, locale, run-args, git identity, image-history recording.

## Docs
Help text in both scripts, the README option table, bash and zsh completions
(PowerShell completes parameters from the param block).

## Done when
Tests in both suites, using `--dry-run` and stub runtimes, cover: `CODE_AGENT_SHELL=1`
sent and no `CODE_AGENT`; nothing appended after the image; a TTY allocated; no agent
state mounts; the `--zsh`/`-zsh` alias; a prompt, `--headless`, or a combined agent
selection fails; go.sh runs zsh in tmux under `CODE_AGENT_SHELL=1` and never an
installed agent; PowerShell parameter binding; completions.

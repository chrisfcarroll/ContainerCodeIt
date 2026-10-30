# ContainerCodeIt XS

Extra small, extra secure. Sandbox your coding agent in a container that can see one
directory, from a Dockerfile you maintain yourself and two short scripts you can read
in a few minutes.

- `Dockerfile`: Alpine, zsh, git, tmux, Claude Code and OpenCode. No toolchains.
- `snippets/`: lines to paste into the Dockerfile, for Python with uv
  (`python-uv.dockerfile`) and for the Codex agent (`codex.dockerfile`).
- `code-it.sh` and `Code-It.ps1`: build the image if it is missing, then run an agent.

For toolchain and agent selection, defaults, a doctor, and more, use the
[full version](../README.md).

## Prerequisites

- Docker, or Apple's container on macOS
- bash or PowerShell

## Quick start

```bash
./code-it.sh        # OpenCode, in the current directory
./code-it.sh -c     # Claude Code
.\Code-It.ps1 -c    # PowerShell
```

The first run builds the image `code-it-xs` from the Dockerfile. After you edit the
Dockerfile, rebuild with `--build` (`-build`).

The agent runs in tmux, next to a zsh session: `Ctrl-B S` switches between them.
To exit, quit the agent (`Ctrl-D` twice in Claude Code, `Ctrl-C` in OpenCode) and the shell.

## First run

When the save dir (`~/.config/code-it-xs`) does not exist yet, code-it asks one question:

> Shall I copy your existing Claude and OpenCode config so that your containerised agents can use your current logins?

Answer `y` to copy `~/.claude`, `~/.claude.json`, `~/.config/opencode`,
`~/.local/share/opencode` and `~/.local/state/opencode`, where they exist, into the
save dir. The copies include credentials, which the agent in the container can read.
Each agent sees only its own state.

## Options

| bash | PowerShell | Default | Description |
|---|---|---|---|
| `--opencode`, `-o` | `-opencode`, `-o` | on | Run OpenCode |
| `--claude`, `-c` | `-claude`, `-c` | off | Run Claude Code |
| `--agent`, `-a NAME` | `-agent`, `-a NAME` | `opencode` | Run agent NAME, e.g. `codex` once its snippet is in the Dockerfile |
| `--zsh` | `-zsh` | off | Run zsh instead of an agent |
| `--work-dir`, `-w DIR` | `-workDir`, `-w DIR` | `.` | The one host directory the agent can see, mounted at `/work/<parent>/<name>` so it keeps its name |
| `--save-dir`, `-s DIR` | `-saveDir`, `-s DIR` | `~/.config/code-it-xs` | Where agent logins and state are kept |
| `--image`, `-i NAME` | `-image`, `-i NAME` | `code-it-xs` | The image to run, built from the Dockerfile if missing |
| `--build`, `-b` | `-build`, `-b` | off | Build the image even if it exists |
| `--runtime`, `-r NAME` | `-runtime`, `-r NAME` | `container` on macOS if installed, else `docker` | `docker` or `container` |
| `--locale`, `-l LOCALE` | `-locale`, `-l LOCALE` | the host's | The container's `LANG`, e.g. `en_GB.UTF-8` or `en-GB` |
| `-D:ARG`, `--D:ARG` (repeatable) | `-D ARG,ARG…`, or `--D:ARG` | none | Pass ARG to `docker run` / `container run`, e.g. `-D:-p -D:8080:3000` |
| `--dry-run`, `-d` | `-dryRun` | off | Print the commands without running them |
| `--help`, `-h` | `-help`, `-h` | | Show help |
| `-- ARGS…` | `ARGS…` or `-- ARGS…` | none | Pass ARGS to the agent |

No ports are mapped: add them with `-D:-p -D:HOST:CONTAINER`. Agents ask for
permissions as usual; turn that off with their own flags, for instance
`./code-it.sh -c -- --dangerously-skip-permissions`.

In PowerShell, the `--` and repeated `--D:` forms work when the script is run from a
PowerShell prompt; `pwsh -File` reads them as its own parameters.

## Adding toolchains and agents

Paste a snippet into the Dockerfile where it says `--- Toolchains` or `--- Agents`,
then run with `--build`. A new agent also needs a line in the scripts saying which
of its state directories to mount; `codex` already has one.

## Tests

From the repository root:

```bash
./tests/xs/test-code-it-xs.sh
pwsh -NoProfile -File tests/xs/Test-CodeItXS.ps1
```

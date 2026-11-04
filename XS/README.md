# ContainerCodeIt XS

Sandbox your agentic AI properly: in a container, with access to a single 
working directory, where it can work free of permissions interruption.

Your agents get work done by having a _single mounted directory_, typically 
containing a git repo or repos, so they can work and commit.

This is the XS version, for devs who are appropriately paranoid and also comfortable with editing their own Dockerfile.

- `Dockerfile`: Alpine, zsh, git, tmux, Claude Code and OpenCode. Add your own toolchains.
- `snippets/`: Example lines to paste into the Dockerfile, for Python with uv
  (`python-uv.dockerfile`) and for the Codex agent (`codex.dockerfile`).
- `code-it.sh` and `Code-It.ps1`: build the image if it is missing, then run an agent.

For a full fat version with toolchain and agent selection, defaults, a doctor, and more, see
the [full version README.md](../README.md).

## Prerequisites

- Docker, or Apple's container on macOS
- bash or PowerShell

## Quick start

```bash
./code-it.sh        # OpenCode, in the current directory
./code-it.sh -c     # Claude Code
.\Code-It.ps1 -c    # PowerShell
./code-it.sh 'add a README'   # OpenCode, with an opening prompt
```

The first run builds the image `code-it-xs` from the Dockerfile. After you edit the
Dockerfile, rebuild with `--build` (`-build`).

The agent runs in tmux, next to a zsh session: `Ctrl-B S` switches between them.
To exit, quit the agent (`Ctrl-D` twice in Claude Code, `Ctrl-C` in OpenCode) and the shell.
If the agent fails, its error stays on screen until you press Enter.

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
| `PROMPT` | `PROMPT` | none | Open the agent with PROMPT as its first prompt. OpenCode gets `mini --prompt PROMPT` |
| `-- ARGS…` | `ARGS…` or `-- ARGS…` | none | Pass ARGS to the agent |

No ports are mapped: add them with `-D:-p -D:HOST:CONTAINER`. The container is
the sandbox, so Claude Code always runs with `--dangerously-skip-permissions`, and
OpenCode with `--auto` (its TUI and `opencode run`; `mini`, which a `PROMPT` opens,
does not take it). Other agents ask for permissions as usual; turn that off with their
own flags.

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

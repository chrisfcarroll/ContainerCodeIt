# ContainerCodeIt XS

Sandbox your agentic AI properly: in a container, with access to a single 
working directory, where it can work free of permissions interruption.

Your agents get work done by having a _single mounted directory_, typically 
containing a git repo or repos, so they can work and commit.

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

To exit, `Ctrl-C` twice currently works in both Claude Code and OpenCode.

## Maintenance and Change.

This is the XS version, for devs who are comfortable maintaining their own Dockerfile.

- `Dockerfile`: Alpine, zsh, git, tmux, Claude Code and OpenCode. Add your own toolchains or other agents.
- `code-it.sh` and `Code-It.ps1`: build the image if it is missing, then run an agent
- `snippets/`: Example lines to paste into a Dockerfile for other agents and toochains.

For a full-fat version including UI for toolchain and agent selection see 
the [full version README.md](../README.md).

## Prerequisites

- Docker, or Apple's container on macOS, or WSL's `wslc` on Windows
- bash or PowerShell

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
| `--runtime`, `-r NAME` | `-runtime`, `-r NAME` | `container` on macOS if installed, else `docker`, else `wslc` on Windows | `docker`, `container` or `wslc` |
| `--locale`, `-l LOCALE` | `-locale`, `-l LOCALE` | the host's | The container's `LANG`, e.g. `en_GB.UTF-8` or `en-GB` |
| `-D:ARG`, `--D:ARG` (repeatable) | `-D ARG,ARG…`, or `--D:ARG` | none | Pass ARG to `docker run` / `container run`, e.g. `-D:-p -D:8080:3000` |
| `--no-wait` | `-noWait` | off | If the agent fails, close at once instead of keeping its error on screen until Enter |
| `--dry-run`, `-d` | `-dryRun` | off | Print the commands without running them |
| `--help`, `-h` | `-help`, `-h` | | Show help |
| `PROMPT` | `PROMPT` | none | Open the agent with PROMPT as its first prompt. OpenCode gets `--prompt PROMPT` |
| `-- ARGS…` | `ARGS…` or `-- ARGS…` | none | Pass ARGS to the agent |

The container is the sandbox, so Claude Code always runs with `--dangerously-skip-permissions`, 
and OpenCode with `--auto`.

In PowerShell, the `--` and repeated `--D:` forms work when the script is run from a
PowerShell prompt.

## Adding toolchains and agents

Paste a snippet into the Dockerfile where it says `--- Toolchains` or `--- Agents`,
then run with `--build`. A new agent also needs a line in the scripts saying which
of its state directories to mount; `codex` already has one.

For a TLS-intercepting proxy, paste `snippets/ca-certificates.dockerfile` immediately
after `FROM`. Put the CA certificate files in the repository's top-level
`ca-certificates/` folder; the XS launchers include it in the build context.

## Rough Edges

see [full version README.md](../README.md).

## Tests

From the repository root:

```bash
./tests/xs/test-code-it-xs.sh
pwsh -NoProfile -File tests/xs/Test-CodeItXS.ps1
```

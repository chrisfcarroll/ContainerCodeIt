# ContainerCodeIt

A sandbox to safely set your agentic AI to work on a single directory, free of permissions interruption. The default Dockerfile includes **OpenCode** and **Claude Code**.

```bash
code-it.sh     # or -o or --opencode (this is the default)
code-it.sh -c  # or -claude
```

```powershell
Code-It.ps1      # or -o or -opencode (this is the default)
Code-It.ps1 -c   # or -claude 
```

The agent gets work done by having a single mounted directory, typically one containing a git repo or repos, so it can get, commit and push.

## Runtime detection

`code-it.sh` and `Code-It.ps1` pick a container runtime automatically:

1. On **macOS**, uses the **Apple container CLI** (`container`) if installed
2. Otherwise uses **Docker** if installed
3. Otherwise it exits with a suggestion for the best runtime to install on your platform

Or specify `--runtime docker` or `--runtime container` (`-runtime` in PowerShell).

## What's in the image

Edit the **Dockerfile** to taste. The default version includes:

- **Alpine Linux 3.23** with **.NET SDK 8.0 and 10, and Mono**, **Node.js** and **npm**, **PowerShell 7**
- **Claude Code CLI** and **OpenCode CLI**
- A **non-root user `agent1`** with passwordless `doas` for installations: `apk`, `dotnet`, `npm`, and `node`

On startup, the container launches a **tmux** session running the chosen agent, and a `zsh` terminal available via the tmux switch hotkey sequence, `Ctrl-B S`.

## Prerequisites

- Docker or Apple Containers.

## Quick start

```bash
# Build and run with the included Dockerfile
./code-it.sh --build-image

# Thereafter, run the built image
./code-it.sh [-o] [-c] [--work-dir path ]
```

```powershell
.\Code-It.ps1 -buildImage
.\Code-It.ps1 -o [[-WorkDirToMount] <string>]
```

### What does the shell script do?

Something like this:

```bash
# docker build . -t code-it-alpine-dotnet:latest

docker run -it --rm \
    -p 3000:3000 -p 3001:3001 \
    -e CODE_AGENT=opencode \
    -e GIT_AUTHOR_NAME="Agent1 for $(git config --get user.name)" \
    -e GIT_AUTHOR_EMAIL="$(git config --get user.email)" \
    -v ~/my-repos:/repos \
    -v ~/.config/code-it/.claude:/home/agent1/.claude \
    -v ~/.config/code-it/.claude.json:/home/agent1/.claude.json \
    -v ~/.config/code-it/.local/share/opencode:/home/agent1/.local/share/opencode \
    code-it-alpine-dotnet:latest
```

## Volume mounts

The launcher scripts keep all agent state under one save dir (default `~/.config/code-it`, created on first run), so you can destroy the container and create a new one without logging in again:

| Mount point | Purpose |
|---|---|
| `/repos` | Host directory containing git repos for the agent to work on |
| `/home/agent1/.claude` | Persists Claude credentials, settings, permissions, and memory |
| `/home/agent1/.claude.json` | Persists Claude OAuth session data, MCP configs, and preferences |
| `/home/agent1/.local/share/opencode` | Persists OpenCode data and auth |

Alternatively, pass `-e ANTHROPIC_API_KEY=sk-...` (claude) or a provider API key env var (opencode) instead of mounting state.

## Launcher script options

`code-it.sh` and `Code-It.ps1` accept the same logical parameters:

| bash | PowerShell | Default | Description |
|---|---|---|---|
| `--claude`, `-c` | `-claude`, `-c` | off | Run Claude Code |
| `--opencode`, `-o` | `-opencode`, `-o` | on (default) | Run OpenCode |
| `--work-dir` | `-WorkDirToMount` | `.` | Host path mounted at `/repos` |
| `--save-dir` | `-saveDir` | `~/.config/code-it` | Host path for agent state persistence |
| `--image` | `-image` | `code-it-alpine-dotnet` | Image name |
| `--build-image` | `-buildImage` | off | Build the image before running |
| `--dockerfile-dir` | `-dockerfileDir` | script's directory | Directory containing the Dockerfile |
| `--runtime` | `-runtime` | auto-detect | `docker` or `container` |
| `--ports` | `-portsMap` | `0:3000` `0:3001` (docker); `3000:3000` `3001:3001` (container) | Port mappings (max 2); host port 0 auto-assigns |
| `--agent-name` | `-agentName` | `Agent1` | Agent name, used for git attribution; must match the Dockerfile USER |
| `--dry-run` | `-dryRun` | off | Print the run command without executing |

The scripts automatically derive the git author name and email from your environment or git config, prefixed with the agent name (e.g. `Agent1 for Your Name`).

## Isolating your agent from upstream origin repos.

For complete isolation, git clone your working tree locally. It works easiest if you give the agent its own branch (to avoid git error, 'updating the current branch in a non-bare repository is denied').

```bash
mkdir ~/ReposForAgents
cd ~/ReposForAgents
git clone ~/MyRepos/Project1 # git can locally clone a working tree
cd Project1
git checkout -b agent1
git push --set-upstream origin agent1 # 
```

Now the agent can only push to your own local working tree. You can only push upstream outside the container.

```
cd ~/MyRepos/Project1
git merge agent1
git push
```

## Tests

No container runtime needed — the tests stub `docker`/`container`/`uname` on the PATH and assert on `--dry-run` output, so they run on any machine, not just inside a container:

```bash
# Linux / macOS (runs the bash suite, then the pwsh suite if pwsh is installed)
./tests/run-all-tests.sh
```

```powershell
# Windows (or anywhere with pwsh) — the PowerShell suite alone
pwsh -NoProfile -File tests/Test-CodeIt.ps1
```

- **macOS**: `./tests/run-all-tests.sh` works with the stock bash 3.2; the Apple-container detection paths are exercised via stubs, so neither Docker nor the `container` CLI needs to be installed.
- **Windows**: run the PowerShell suite; the bash suite additionally works under Git Bash or WSL. The suite stubs docker with a `.cmd` shim and only needs `git` and PowerShell 7+.

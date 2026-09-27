# ContainerCodeIt

Sandbox your agentic AI properly, in a container, with access to a single working directory, where it can work free of permissions interruption. 

The default Dockerfile includes **OpenCode** and **Claude Code** agents.

```bash
code-it.sh     # or -o or --opencode (this is the default)
code-it.sh -c  # or -claude
```

```powershell
Code-It.ps1      # or -o or -opencode (this is the default)
Code-It.ps1 -c   # or -claude 
```

The agent gets work done by having a single mounted directory, typically one containing a git repo or repos, so it can get, commit and push.

## Prerequisites

- Docker or Apple Containers.
- Tested on MacOs and Windows 11, not tested by me Linux

In principal either powershell or bash scripts should work on any O/S.

## Quick start

```bash
# Build and run with the included Dockerfile
./code-it.sh --build-image

# Thereafter, no need to rebuild the image, except to get agent harness updates.
./code-it.sh [-o] [-c] [--work-dir path ]
```

```powershell
.\Code-It.ps1 -buildImage
.\Code-It.ps1 -o [[-WorkDirToMount] <string>]
```

## Code-It options

`code-it.sh` and `Code-It.ps1` accept the same logical parameters:

| bash | PowerShell | Default | Description |
|---|---|---|---|
| `--claude`, `-c` | `-claude`, `-c` | off | Run Claude Code |
| `--opencode`, `-o` | `-opencode`, `-o` | on (default) | Run OpenCode |
| `--prompt`, or a bare argument | `-prompt`, or a bare argument | none | Opening prompt for the agent |
| `--headless` | `-headless` | off | Run the agent one-shot in the foreground instead of in tmux: no TTY, and the container exits with the agent's exit code |
| `--` *agent-args* | *agent-args* (no separator) | none | Arguments passed to the coding agent verbatim |
| `--work-dir` | `-WorkDirToMount` | `.` | Host path mounted at `/work` |
| `--save-dir` | `-saveDir` | `~/.config/code-it` | Host path for agent state persistence |
| `--image` | `-image` | `code-it-alpine-<tech>` | Image name; derived from `--tech` (e.g. `code-it-alpine-node-bun`) |
| `--build-image` | `-buildImage` | off | Build the image before running |
| `--rebuild-image` | `-rebuildImage` | off | Build the image, first bumping the Dockerfile's `# last changed` dates to today so the agents are updated |
| `--dockerfile-dir` | `-dockerfileDir` | script's directory | Directory containing the Dockerfile |
| `--runtime` | `-runtime` | auto-detect | `docker` or `container` |
| `--ports` | `-portsMap` | `0:3000` `0:3001` (docker); `3000:3000` `3001:3001` (container) | Port mappings (max 2); host port 0 auto-assigns |
| `--agent-name` | `-agentName` | `Agent1` | Agent name, used for git attribution; must match the Dockerfile USER |
| `--tech LIST` | `-tech LIST` | `dotnet,node` | Comma-separated tech stacks: `dotnet`, `node`, `bun` (aliases `js-node`/`ts-node` for `node`, `js-bun`/`ts-bun` for `bun`) |
| `--package-caches LIST` | `-packageCaches LIST` | implied by `tech` | Comma-separated package repos to mount read-only: `nuget`, `npm`, `bun` |
| `--dry-run` | `-dryRun` | off | Print the run command without executing |

## Tech stacks

The Dockerfile takes build-time switches for the tech stacks to include, and the
launchers expose them as two comma-separated lists, passed to `docker build` as
`--build-arg`s:

- `--tech` / `-tech` — tech stacks to build: `dotnet`, `node`, `bun`. Default `dotnet,node`.
  `js-node` and `ts-node` are aliases for `node`; `js-bun` and `ts-bun` are aliases for
  `bun`. Aliases resolve to the canonical name, so `--tech ts-node` is `--tech node` and
  produces the same image name.
- `--package-caches` / `-packageCaches` — package repos whose host cache is mounted
  read-only: `nuget`, `npm`, `bun`. Default: the repos implied by `--tech`
  (`dotnet`->`nuget`, `node`->`npm`).

A list *replaces* the default set rather than toggling it, so there is no per-tech
on/off flag to clash with future tech names as the list grows. Each tech left out skips
its layers entirely.

```bash
# Match the original image: .NET + Node.js (nuget + npm implied)
./code-it.sh --build-image

# A Bun-only sandbox with a read-only host Bun cache
./code-it.sh --build-image --tech bun --package-caches bun

# Node.js and Bun, but npm only (e.g. you drive Bun through npm)
./code-it.sh --build-image --tech node,bun --package-caches npm
```

```powershell
.\Code-It.ps1 -buildImage -tech 'node,bun' -packageCaches npm
```

Each enabled tech also adds a passwordless `doas` rule, so the agent can install more
tools itself (`doas dotnet`, `doas node`, `doas npm`, `doas bun`).

Each enabled tech also adds a passwordless `doas` rule, so the agent can install more
tools itself (`doas dotnet`, `doas node`, `doas npm`, `doas bun`).

## Prompts and agent flags

Anything you want the coding agent itself to see can be passed through the launcher.

```bash
./code-it.sh -c "explain this repo"        # opens Claude Code with that first prompt
./claude-it.sh "explain this repo"         # the same, via the alias script

# One-shot: the agent answers the prompt, exits, and the container shuts down
./code-it.sh -c --headless "run the tests and fix any failures"
./code-it.sh -o --headless "summarise the last 10 commits" > summary.txt

# Everything after -- goes to the agent verbatim
./claude-it.sh -- --continue --model opus
./claude-it.sh --headless "tidy the imports" -- --max-turns 5
```

```powershell
.\Code-It.ps1 -c "explain this repo"
.\Code-It.ps1 -c -headless "run the tests and fix any failures"

# PowerShell has no usable `--` for scripts, so agent flags need no separator:
# anything Code-It.ps1 does not recognise is passed to the agent
.\Claude-It.ps1 --continue --model opus
.\Claude-It.ps1 -headless -prompt "tidy the imports" --max-turns 5
```

In PowerShell a bare argument is now the prompt, so `-WorkDirToMount` is no longer bound
positionally: pass it by name, `.\Code-It.ps1 -WorkDirToMount ~/my-repos`. And a short
agent flag that PowerShell reads as one of the script's own parameters (`-p` matches both
`-portsMap` and `-prompt`) is rejected before the script runs: spell it in full, `--print`,
or pass it as `-agentArgs '-p','...'`. `code-it.sh` has no such problem: use `--`.

The launcher translates the prompt into each agent's own command line
([Claude Code](https://code.claude.com/docs/en/cli-reference),
[OpenCode](https://opencode.ai/docs/cli/)):

| | interactive | `--headless` |
|---|---|---|
| Claude Code | `claude PROMPT` | `claude -p PROMPT` |
| OpenCode | `opencode --prompt PROMPT` | `opencode run PROMPT` |

Interactively the agent still runs inside tmux. With `--headless` it runs in the
foreground with no TTY allocated (`docker run -i`), so output can be piped or redirected
and the container's exit code is the agent's.

## Tab completion

The `completions/` directory completes the launchers' own options, and, after `--`, the
flags of whichever agent is selected — `claude-it.sh` completes Claude Code flags,
`opencode-it.sh` completes OpenCode flags. Edit the flag lists in those files to add your
own favourites.

```bash
# bash: in ~/.bashrc
source /path/to/ContainerCodeIt/completions/code-it.bash
```

```zsh
# zsh: in ~/.zshrc, before compinit
fpath=(/path/to/ContainerCodeIt/completions $fpath)
autoload -Uz compinit && compinit
```

```powershell
# PowerShell: in $PROFILE. Parameters such as -claude, -prompt, -headless and -runtime
# complete without this; it adds the agent's own flags after -agentArgs.
. /path/to/ContainerCodeIt/completions/CodeItCompletion.ps1
```

### What does the script do?

Something like this:

```bash
# docker build . -t code-it-alpine-dotnet-node:latest

docker run -it --rm \
    -p 3000:3000 -p 3001:3001 \
    -e CODE_AGENT=opencode \
    -e GIT_AUTHOR_NAME="Agent1 for $(git config --get user.name)" \
    -e GIT_AUTHOR_EMAIL="$(git config --get user.email)" \
    -v ~/my-repos:/work \
    -v ~/.config/code-it/.claude:/home/agent1/.claude \
    -v ~/.config/code-it/.claude.json:/home/agent1/.claude.json \
    -v ~/.config/code-it/.config/opencode:/home/agent1/.config/opencode \
    -v ~/.config/code-it/.local/share/opencode:/home/agent1/.local/share/opencode \
    code-it-alpine-dotnet-node:latest
```

## What's in the image

Edit the **Dockerfile** to taste. The default build includes:

- **Alpine Linux 3.24** with **.NET SDK 8.0 and 10, and Mono**, **Node.js** and **npm**, **PowerShell 7**
- **Claude Code CLI** and **OpenCode CLI**
- A **non-root user `agent1`** with passwordless `doas` for installations: `apk`, plus
  `dotnet`, `node`, `npm` and/or `bun` for whichever techs/packages are enabled

Use the [tech lists](#tech-stacks) to build an image with a different mix, for example
Bun instead of .NET + Node.js.

On startup, the container launches a **tmux** session running the chosen agent, and a `zsh` terminal available via the tmux switch hotkey sequence, `Ctrl-B S`.

Arguments given to the container after the image name are passed straight to the agent, and
with `-e CODE_AGENT_HEADLESS=1` the agent runs in the foreground instead of in tmux, so the
container exits when the agent does. That is what `--headless` uses.

## Rough Edges

- One Dockerfile now supports build-time tech-stack lists (`dotnet`, `node`, `bun`, and
  the package repos `nuget`, `npm`), so combinations do not need separate files. Python
  and Java are the obvious next techs to add.
- The image still ships both coding agents; making the agents build-time switches too is
  the next step.
- Updating the agent harnesses claude code/open code is done by rebuilding the image (`code-it --rebuild-image` / `code-it.ps1 -rebuildImage`)
- Putting .sh on the bash scripts is surely a dubious design choice.

## Runtime detection

`code-it.sh` and `Code-It.ps1` choose a container runtime automatically:

1. On **macOS**, they use the **Apple container CLI** (`container`) if installed
2. Otherwise they use **Docker** if installed
3. Otherwise they exits with a suggestion for the best runtime to install on your platform

Or on MacOs, specify `--runtime docker` or `--runtime container` (`-runtime` in PowerShell).

## Volume mounts

The launcher scripts keep all agent state under one save dir (default `~/.config/code-it`, created on first run), so your sessions and logins are saved.

| Mount point | Purpose |
|---|---|
| `/work` | Host directory containing git repos for the agent to work on |
| `/home/agent1/.claude` | Persists Claude credentials, settings, permissions, and memory |
| `/home/agent1/.claude.json` | Persists Claude OAuth session data, MCP configs, and preferences |
| `/home/agent1/.config/opencode` | Persists OpenCode configuration, including `opencode.json` |
| `/home/agent1/.local/share/opencode` | Persists OpenCode data and auth |
| `/home/agent1/.nuget/packages-host` | **Read-only.** Host NuGet package cache (a `fallbackPackageFolder`), if `nuget` is enabled and a cache is found |
| `/home/agent1/.npm-host` | **Read-only.** Host npm cache, if `npm` is enabled and a cache is found; seeded into `~/.npm` at startup |
| `/home/agent1/.bun-host` | **Read-only.** Host Bun cache, if `bun` is enabled and a cache is found; seeded into `~/.bun/install/cache` at startup |

Alternatively, pass `-e ANTHROPIC_API_KEY=sk-...` (claude) or a provider API key env var (opencode) instead of mounting state.

# Isolating your agent from upstream origin repos.

To isolate your upstream repo from your agents, git clone your working tree locally. Git works fine with origin repos on the local filesystem. 

This works easiest if you give the agent its own branch (to avoid git error, 'updating the current branch in a non-bare repository is denied') as well as its own cloned repo.

```bash
mkdir ~/ReposForAgents
cd ~/ReposForAgents
git clone ~/MyRepos/Project1 # local clone of your working tree
cd Project1
git checkout -b agent1
git push --set-upstream origin agent1
```
Now the agent can only push to your own local working tree. To push upstream, you have to be in your original repo, outside the container.
```
cd ~/MyRepos/Project1
git merge agent1
git push
```

## UseIsolatedAgentRepos.ps1

`UseIsolatedAgentRepos.ps1` caters to this workflow, using a mostly-one-way dataflow.

```
. UseIsolatedAgentRepos.ps1 -originBranch <defaults to main> -agentBranch <defaults to agent1>
cd ~/ReposForAgents/Project1
updateAgentFromOrigin
cd ~/Repos/Project1
mergeFromAgent
```
“Mostly” one-way because there's also:
```
cd ~/Repos/Project1
updateAgentAndDiff
```
which helps if you want to review agent changes in your repo before merging to main. The alternative is to review agent changes in the agent's repo.


## Package caches

To avoid giving agents access to your non-public package sources, and also to avoid a myriad duplicate downloads, we can give the container read-only access to your package caches. The read-only flag prevents this becoming a way to leak out of the sandbox.

### NuGet

If you use NuGet, the launcher scripts mounts your NuGet package cache at `/home/agent1/.nuget/packages-host`, where `dotnet restore` etc can use it. NuGet downloads added in the container will go in `~/.nuget/packages` and will disappear when the container exits. (See [Managing the global packages and cache folders](https://learn.microsoft.com/en-us/nuget/consume-packages/managing-the-global-packages-and-cache-folders) to understand nuget package cache locations).

### npm

`npm` (in `--package-caches`, implied by `--tech node`) mounts your npm cache read-only at
`/home/agent1/.npm-host`. The container's `go.sh` seeds its own writable `~/.npm` from
that mount at startup, so packages already downloaded on the host are reused and the
host cache is never written to.

### Bun

`bun` (in `--package-caches`) mounts your Bun cache read-only at `/home/agent1/.bun-host`,
seeded at startup into `~/.bun/install/cache` in the same way.

### PyPi, etc.

To do.

## Tests

No container runtime needed. The tests stub `docker`/`container`/`uname` on the PATH and assert on `--dry-run` output, so they run on any machine, not just inside a container.

```bash
# Linux / macOS (runs the bash suite, then the pwsh suite if pwsh is installed)
./tests/run-all-tests.sh
```

```powershell
pwsh -NoProfile -File tests/Test-CodeIt.ps1
```

- **macOS**: `./tests/run-all-tests.sh` works with the stock bash 3.2; the Apple-container detection paths are exercised via stubs, so neither Docker nor the `container` CLI needs to be installed.
- **Windows**: run the PowerShell suite; the bash suite additionally works under Git Bash or WSL. The suite stubs docker with a `.cmd` shim and only needs `git` and PowerShell 7+.

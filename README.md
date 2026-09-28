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
| `--agent`, `-a` | `-agent`, `-a` | `opencode` | Run the agent defined in `agents/NAME`; only its state is mounted |
| `--list-agents` | `-listAgents` | - | List the available agents and exit |
| `--claude`, `-c` | `-claude`, `-c` | off | Shortcut for `--agent claude` |
| `--opencode`, `-o` | `-opencode`, `-o` | on (default) | Shortcut for `--agent opencode` |
| `--prompt`, `-p`, or a bare argument | `-prompt`, or a bare argument | none | Opening prompt for the agent |
| `--headless` | `-headless` | off | Run the agent one-shot in the foreground instead of in tmux: no TTY, and the container exits with the agent's exit code |
| `--` *agent-args* | *agent-args* (no separator) | none | Arguments passed to the coding agent verbatim |
| `--work-dir`, `-w` | `-WorkDirToMount` | `.` | Host path mounted at `/work` |
| `--save-dir`, `-s` | `-saveDir` | `~/.config/code-it` | Host path for agent state persistence |
| `--image`, `-i` | `-image` | `code-it-alpine-<tech>` | Image name; derived from `--tool-chains` (e.g. `code-it-alpine-node-bun`) |
| `--build-image`, `-b` | `-buildImage` | off | Build the image before running |
| `--rebuild-image`, `-B` | `-rebuildImage` | off | Build the image, first bumping the Dockerfile's `# last changed` dates to today so the agents are updated |
| `--dockerfile-dir` | `-dockerfileDir` | script's directory | Directory containing the Dockerfile |
| `--runtime`, `-r` | `-runtime` | auto-detect | `docker` or `container` |
| `--port` | `-port` | `0` | Host port mapped to the container's port 3000. `0` auto-assigns (docker) or finds a free port starting at 3000 (Apple `container`) |
| `--agent-name` | `-agentName` | `Agent1` | Agent name, used for git attribution; must match the Dockerfile USER |
| `--tool-chains LIST`, `-t` | `-toolChains LIST` | `dotnet,node` | Comma-separated tech stacks: `dotnet`, `node`, `bun` (aliases `js-node`/`ts-node` for `node`, `js-bun`/`ts-bun` for `bun`) |
| `--package-caches LIST` | `-packageCaches LIST` | implied by `tool-chains` | Comma-separated package repos to mount read-only: `nuget`, `npm`, `bun` |
| `--dry-run`, `-d` | `-dryRun` | off | Print the run command without executing |

`--build-image` and `--rebuild-image` are now thin shims: they print a deprecation
note and delegate to `code-it-build` with the same tool chains, package caches, image,
runtime and Dockerfile directory, then run the container. Prefer calling
`code-it-build` directly.

## code-it-build options

`code-it-build.sh` and `Code-It-Build.ps1` build the image (and label it with its tool
chains and package caches). They accept the same logical parameters:

| bash | PowerShell | Default | Description |
|---|---|---|---|
| `--tool-chains LIST`, `-t` | `-toolChains LIST` | `dotnet,node` | Tool chains to build (aliases as above) |
| `--package-caches LIST` | `-packageCaches LIST` | implied by `tool-chains` | Package repos to support; an explicit empty list means none |
| `--agent, -a LIST` | `-agent LIST` | `opencode,claude` | Agents to install |
| `--list-agents` | `-listAgents` | - | List the available agents and exit |
| `--rebuild` | `-rebuild` | off | Bump the Dockerfile's `# last changed` dates to today first |
| `--image`, `-i` | `-image` | `code-it-alpine-<chains>` | Image name to build |
| `--dockerfile-dir` | `-dockerfileDir` | script's directory | Directory containing the Dockerfile |
| `--runtime`, `-r` | `-runtime` | auto-detect | `docker` or `container` |
| `--dry-run`, `-d` | `-dryRun` | off | Print the build command without executing it |

The image is labelled `code-it.tool-chains=<chains>` and
`code-it.package-caches=<caches>`; `code-it` reads that label to warn if the image was
built for a different tool-chain set, falling back to the image-name guess for images
that predate the label.

## Tech stacks

The Dockerfile takes build-time switches for the tech stacks to include, and the
launchers expose them as two comma-separated lists, passed to `docker build` as
`--build-arg`s:

- `--tool-chains` / `-toolChains` (alias `--stack` / `-stack`) — tech stacks to build:
  `dotnet`, `node`, `bun`, `python`. Default `dotnet,node`.
  `js-node` and `ts-node` are aliases for `node`; `js-bun` and `ts-bun` are aliases for
  `bun`; `uv` is an alias for `python`. Aliases resolve to the canonical name, so
  `--tool-chains ts-node` is `--tool-chains node` and produces the same image name.
- `--package-caches` / `-packageCaches` — package repos whose host cache is mounted
  read-only: `nuget`, `npm`, `bun`. Default: the repos implied by `--tool-chains`
  (`dotnet`->`nuget`, `node`->`npm`). Python has no host cache mount: uv must write its
  own cache, so the container keeps it in the agent's home (`UV_CACHE_DIR`).

A list *replaces* the default set rather than toggling it, so there is no per-tech
on/off flag to clash with future tech names as the list grows. Each tech left out skips
its layers entirely.

```bash
# Match the original image: .NET + Node.js (nuget + npm implied)
./code-it.sh --build-image

# A Bun-only sandbox with a read-only host Bun cache
./code-it.sh --build-image --tool-chains bun --package-caches bun

# Node.js and Bun, but npm only (e.g. you drive Bun through npm)
./code-it.sh --build-image --tool-chains node,bun --package-caches npm

# Python 3 with uv (uv is in every image): --stack is an alias for --tool-chains
./code-it-build.sh --stack python
```

```powershell
.\Code-It.ps1 -buildImage -toolChains 'node,bun' -packageCaches npm
```

Each enabled tech also adds a passwordless `doas` rule, so the agent can install more
tools itself (`doas dotnet`, `doas node`, `doas npm`, `doas bun`, `doas python3`).

### Python

`--tool-chains python` (or `--stack python`, or the old alias `uv`) adds Python 3 from
Alpine's repos. `uv` and `uvx` are installed for every image, including the default.
The system Python is externally managed, so use `uv venv` / `uv tool` rather than
`pip install` into it; uv keeps its cache in the agent's home via `UV_CACHE_DIR` and
fetches musl CPython builds for x86_64 and aarch64.

## Agents

Coding agents are data, not `if claude / else opencode` branches. Each agent is one
directory, `agents/<name>/`:

| File | Purpose |
|---|---|
| `config` | `key=value` (readable by bash and PowerShell): the container binary path, host command, state dirs/files, prompt-translation templates, config label, short flag |
| `install.dockerfile` | the install layer, run as `agent1`, with a `# last changed YYYY-MM-DD` cache-bust line |
| `default-config/` | configuration copied into `--save-dir` on first run, preserving layout |

`code-it-build --agent NAME[,NAME...]` assembles the selected install fragments into
the Dockerfile and writes `/etc/code-it-agents` (a `name=binary` map) that the
container's `go.sh` reads, so no agent names are hardcoded in script logic. The
default is `opencode,claude`. `code-it --agent NAME` runs one of them and mounts only
that agent's state.

```bash
./code-it-build.sh --agent opencode          # a leaner image, OpenCode only
./code-it.sh --agent opencode                # run it
./code-it.sh --list-agents                   # what is available
```

Adding an agent means adding one `agents/<name>/` directory; no script edits.

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
`-port` and `-prompt`) is rejected before the script runs: spell it in full, `--print`,
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
source /path/to/ContainerCodeIt/completions/code-it-build.bash
source /path/to/ContainerCodeIt/completions/code-it-add-agent.bash
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
    -p 0:3000 \
    -e CODE_AGENT=opencode \
    -e GIT_AUTHOR_NAME="Agent1 for $(git config --get user.name)" \
    -e GIT_AUTHOR_EMAIL="$(git config --get user.email)" \
    -v ~/my-repos:/work \
    -v ~/.config/code-it/.config/opencode:/home/agent1/.config/opencode \
    -v ~/.config/code-it/.local/share/opencode:/home/agent1/.local/share/opencode \
    code-it-alpine-dotnet-node:latest
```

## What's in the image

Edit the **Dockerfile** to taste. The default build includes:

- **Alpine Linux 3.24** with **.NET SDK 8.0 and 10, and Mono**, **Node.js** and **npm**, **PowerShell 7**
- The agents you select with `--agent` (default **Claude Code CLI** and **OpenCode CLI**), and **uv/uvx** (in every image)
- A **non-root user `agent1`** with passwordless `doas` for installations: `apk`, plus
  `dotnet`, `node`, `npm`, `bun` and/or `python3` for whichever techs/packages are enabled

Use the [tech lists](#tech-stacks) to build an image with a different mix, for example
Bun instead of .NET + Node.js, or add Python with `--stack python`.

On startup, the container launches a **tmux** session running the chosen agent, and a `zsh` terminal available via the tmux switch hotkey sequence, `Ctrl-B S`.

Arguments given to the container after the image name are passed straight to the agent, and
with `-e CODE_AGENT_HEADLESS=1` the agent runs in the foreground instead of in tmux, so the
container exits when the agent does. That is what `--headless` uses.

## Rough Edges

- One Dockerfile now supports build-time tech-stack lists (`dotnet`, `node`, `bun`,
  `python`, and the package repos `nuget`, `npm`), so combinations do not need separate
  files. Java is the obvious next tech to add.
- Updating the agent harnesses claude code/open code is done by rebuilding the image (`code-it-build --rebuild` / `Code-It-Build.ps1 -rebuild`)
- Putting .sh on the bash scripts is surely a dubious design choice.

## Runtime detection

`code-it.sh` and `Code-It.ps1` choose a container runtime automatically:

1. On **macOS**, they use the **Apple container CLI** (`container`) if installed
2. Otherwise they use **Docker** if installed
3. Otherwise they exits with a suggestion for the best runtime to install on your platform

Or on MacOs, specify `--runtime docker` or `--runtime container` (`-runtime` in PowerShell).

## Volume mounts

The launcher scripts keep the chosen agent's state under one save dir (default `~/.config/code-it`, created on first run), so your sessions and logins are saved. Only the selected agent's paths (from its `agents/<name>/config`) are mounted.

| Mount point | Purpose |
|---|---|
| `/work` | Host directory containing git repos for the agent to work on |
| `/home/agent1/.claude` | Claude only: credentials, settings, permissions, memory |
| `/home/agent1/.claude.json` | Claude only: OAuth session data, MCP configs, preferences |
| `/home/agent1/.config/opencode` | OpenCode only: configuration, including `opencode.json` |
| `/home/agent1/.local/share/opencode` | OpenCode only: data and auth |
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

`npm` (in `--package-caches`, implied by `--tool-chains node`) mounts your npm cache read-only at
`/home/agent1/.npm-host`. The container's `go.sh` seeds its own writable `~/.npm` from
that mount at startup, so packages already downloaded on the host are reused and the
host cache is never written to.

### Bun

`bun` (in `--package-caches`) mounts your Bun cache read-only at `/home/agent1/.bun-host`,
seeded at startup into `~/.bun/install/cache` in the same way.

### PyPi, etc.

To do.

## Adding an agent

`code-it-add-agent NAME [--url URL]` runs code-it headless with a built-in prompt that
adds a new `agents/NAME/` definition. The in-container agent first applies a gate
(is NAME a well-known, maintained agent with official docs and an official install
channel?), and if it passes, reads its docs, adds the definition, tests, README row and
completions, runs the tests, and commits.

The tool refuses to run on a dirty repository, works on a new branch
`add-agent/NAME` (never committing to your current branch, never pushing), and prints
the branch and a diff summary when it finishes. A gate refusal leaves the repo
unchanged and is propagated as the tool's non-zero exit code.

```bash
./code-it-add-agent.sh cursor --url https://docs.cursor.com/cli
./code-it-add-agent.sh cursor --dry-run     # show the prompt and command only
```

```powershell
.\Code-It-Add-Agent.ps1 cursor -url https://docs.cursor.com/cli
```

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

# ContainerCodeIt

Sandbox your agentic AI properly: in a container, with access to a single working directory, where it can work free of permissions interruption.

The default Dockerfile offers **OpenCode** and **Claude Code** agents, but you can add others.

The agent gets work done by having a _single mounted directory_, typically one containing a git repo or repos, so it can work and commit.

## Prerequisites

- Docker or Apple Containers.
- Tested on MacOs and Windows 11, minimal testing on Linux.
- Runs on both bash and PowerShell on any O/S.

## Quick start

```bash
./code-it.sh #bash or zsh
./Code-It.ps1 # powershell
```

## Exiting a container

Press `Ctrl-D` to exit a container. In Claude code, press `Ctrl-D` twice in succession.

## First run

`code-it` first run does interactive setup. it checks the container runtime
and git, attempts to detect if you have at least one toolchain and agent already, asks which to
include (pre-selecting what it found), shows the resulting `code-it-build` command and
runs it, offering to re-use your existing agent session state. Existing state is copied, not moved 
or symlinked or changed. Copied state will include your agent login in the container.
The script waits for you to confirm y/n before doing anything.

## Adding a new agent

`code-it-add-agent NAME [--url URL]` will use code-it to attempt to add agent NAME 
to your setup. The agent doing the install will first attempt to check 
“is NAME a well-known, maintained agent with official docs and an official install
channel?”.
If it passes, it will read its docs, adds the definition, add tests, extend the README, 
add completions, run the tests, then commit.

It will refuse to run on a dirty repository, works on a new branch
`add-agent/NAME` (never committing to your current branch, never pushing), and prints
the branch and a diff summary when it finishes. A gate refusal leaves the repo
unchanged and is propagated as the tool's non-zero exit code.

```bash
./code-it-add-agent.sh cursor --url https://docs.cursor.com/cli
./code-it-add-agent.sh cursor --dry-run     # show the prompt and command only

.\Code-It-Add-Agent.ps1 cursor -url https://docs.cursor.com/cli
```

## Adding a toolchain

`code-it-add-tool-chain NAME [--url URL]` will use code-it to attempt to add a new
supported toolchain to your repo and image.
The in-container agent gates on: NAME being a well-known language/runtime whose 
toolchain installs securely (Alpine repos or the vendor's HTTPS distribution with checksum
or signature verification where published, musl builds for x86_64 and aarch64, actively
maintained).
It generates an `ARG`-guarded Dockerfile layer, the name and aliases in the shared library, completions and README, an optional read-only
package cache, tests, and a commit.

```bash
./code-it-add-tool-chain.sh java --url https://openjdk.org/install/
./code-it-add-tool-chain.sh java --dry-run

.\Code-It-Add-Tool-Chain.ps1 java -url https://openjdk.org/install/
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
| `--image`, `-i` | `-image` | `code-it-alpine-<tech>` | Image name; derived from `--toolchain` (e.g. `code-it-alpine-node-bun`). If the derived image is missing, the most-recently built existing image whose label *contains* the requested chains is used instead; an explicit `--image` is used as-is |
| `--build-image`, `-b` | `-buildImage` | off | Build the image before running |
| `--rebuild-image`, `-B` | `-rebuildImage` | off | Build the image, first bumping the Dockerfile's `# last changed` dates to today so the agents are updated |
| `--dockerfile-dir` | `-dockerfileDir` | script's directory | Directory containing the Dockerfile |
| `--runtime`, `-r` | `-runtime` | auto-detect | `docker` or `container` |
| `--port` | `-port` | `0` | Host port mapped to the container's port 3000. `0` auto-assigns (docker) or finds a free port starting at 3000 (Apple `container`) |
| `--locale`, `-l` | `-locale` | `like-host` | The container's locale (`LANG`), e.g. `en_GB.UTF-8` or `en-GB`. See [Locale](#locale) |
| `--agent-name` | `-agentName` | `Agent1` | Agent name, used for git attribution; must match the Dockerfile USER |
| `--toolchain LIST`, `-t` | `-toolchain LIST` | remembered/existing code-it image, else first-run | Comma-separated toolchains: `dotnet`, `node`, `bun`, `python` (aliases `js-node`/`ts-node` for `node`, `js-bun`/`ts-bun` for `bun`, `uv` for `python`) |
| `--package-caches LIST` | `-packageCaches LIST` | implied by `toolchain` | Comma-separated package repos to mount read-only: `nuget`, `npm`, `bun` |
| `--dry-run`, `-d` | `-dryRun` | off | Print the run command without executing |

When the image derived from `--toolchain` (e.g. `code-it-alpine-dotnet`) does not
exist, `code-it` uses the most-recently built existing image whose
`code-it.tool-chains` label contains every requested chain (e.g.
`code-it-alpine-dotnet-bun` for `dotnet`), and says which image it chose. An explicit
`--image` is used as-is and is an error if missing.

## code-it-build options

`code-it-build.sh` and `Code-It-Build.ps1` build the image (and label it with its tool
chains and package caches). They accept the same logical parameters:

| bash | PowerShell | Default | Description |
|---|---|---|---|
| `--toolchain LIST`, `-t` | `-toolchain LIST` |   | Toolchains to build (aliases as above) |
| `--package-caches LIST` | `-packageCaches LIST` | implied by `toolchain` | Package repos to support; an explicit empty list means none |
| `--agent, -a LIST` | `-agent LIST` | `opencode,claude` | Agents to install |
| `--list-agents` | `-listAgents` | - | List the available agents and exit |
| `--rebuild` | `-rebuild` | off | Bump the Dockerfile's `# last changed` dates to today, to force agent curl-install refreshes. |
| `--locale`, `-l` | `-locale` | `like-host` | The image's locale (`LANG`). See [Locale](#locale) |
| `--image`, `-i` | `-image` | `code-it-alpine-<chains>` | Image name to build |
| `--dockerfile-dir` | `-dockerfileDir` | script's directory | Directory containing the Dockerfile |
| `--runtime`, `-r` | `-runtime` | auto-detect | `docker` or `container` |
| `--dry-run`, `-d` | `-dryRun` | off | Print the build command without executing it |

The image is labelled `code-it.tool-chains=<chains>` and
`code-it.package-caches=<caches>`; `code-it` reads that label to warn if the image was
built for a different tool-chain set, falling back to the image-name guess for images
that predate the label.
It is also labelled `code-it.agents=<agents>` and
`code-it.agent-binaries=<agent>=<path>,...`. `code-it` refuses to run an agent the image
lacks, or one the image installed at a different path from the one its
`agents/<name>/config` now names, because the image is out of date and would run the
wrong binary. Images that predate the binaries label get a warning instead.

The included Dockerfile is based on alpine3.24, which uses musl, and the architecture (amd64 or aarch64)
of your host machine.

### Locale

By default the container gets the host's locale, so .NET, Node.js and other tools
that read `LANG` format dates and numbers the way they do on your host.
`--locale like-host` (the default) reads, in order:

1. `LC_ALL`, then `LANG`, unless they are only `C` or `POSIX`
2. macOS: `defaults read -g AppleLocale`
3. Windows: the user's culture. PowerShell uses `Get-Culture`; Git Bash, MSYS2,
   Cygwin and WSL (whose distro `LANG` is often only `C.UTF-8`) read
   `HKCU\Control Panel\International\LocaleName` with `reg.exe`

Windows and macOS spell locales differently from Linux, so the name is translated as
best it can be, and the codeset is always UTF-8: `en-GB` becomes `en_GB.UTF-8`,
`sr-Latn-RS` becomes `sr_RS.UTF-8@latin`, `zh-Hans-CN` becomes `zh_CN.UTF-8`, and
macOS's `en_GB@rg=gbzzzz` becomes `en_GB.UTF-8`. If nothing can be told, it is
`C.UTF-8`. Pass `--locale` / `-locale` with any of those spellings to choose one.

`code-it-build` bakes the locale into the image as `LANG` (and labels the image
`code-it.locale=<locale>`); `code-it` also passes it to each run as `-e LANG=...`, so
a different `--locale` takes effect without a rebuild. Alpine's `musl-locales`
supplies the translated messages it has; musl itself has no locale-specific
collation.

## Toolchains

The Dockerfile takes build-time switches for the toolchains to include, and the
launchers expose them as two comma-separated lists, passed to `docker build` as
`--build-arg`s:

- `--toolchain` / `-toolchain` (alias `--stack` / `-stack`) — toolchains to build:
  `dotnet`, `node`, `bun`, `python`. Default: the remembered image, else an existing
  code-it image, else the first-run setup (see below).
  `js-node` and `ts-node` are aliases for `node`; `js-bun` and `ts-bun` are aliases for
  `bun`; `uv` is an alias for `python`. Aliases resolve to the canonical name, so
  `--toolchain ts-node` is `--toolchain node` and produces the same image name.
- `--package-caches` / `-packageCaches` — package repos whose host cache is mounted
  read-only: `nuget`, `npm`, `bun`. Default: the repos implied by `--toolchain`
  (`dotnet`->`nuget`, `node`->`npm`). Python has no host cache mount: uv must write its
  own cache, so the container keeps it in the agent's home (`UV_CACHE_DIR`).

Each enabled toolchain also adds a passwordless `doas` rule to the container, so you (or your
agent) can install further related tools.

Subsequent calls to `code-it` with no --toolchain specified will reuse your most-used recent toolchain.

```bash

# A Bun-only sandbox with a read-only host Bun cache
./code-it.sh --build-image --toolchain bun --package-caches bun

# Node.js and Bun, but npm only (e.g. you drive Bun through npm)
./code-it.sh --build-image --toolchain node,bun --package-caches npm

# Python 3 with uv ( --stack is an alias for --toolchain )
./code-it-build.sh --stack python
```

```powershell
.\Code-It.ps1 -buildImage -toolchain 'node,bun' -packageCaches npm
```

### Included toolchains

`--toolchain dotnet` installs dotnet10 and dotnet8 from Alpine repos.
`--toolchain python` adds Python 3, uv and uvx from Alpine's repos.


## Agents

```bash
./code-it-build.sh --agent opencode          # a leaner image, OpenCode only
./code-it.sh --agent opencode                # run it
./code-it-build.sh --agent opencode-v2       # OpenCode v2, pinned separately
./code-it.sh --agent opencode-v2 --headless "summarise this repo"
./code-it.sh --list-agents                   # what is available
```

OpenCode v1 and v2 can be built into the same image: v2's binary is moved to
`~/.opencode-v2/bin` so it does not overwrite v1's. They read the same config and
data paths, and v1 exits at once on v2's `opencode.json`, so v2 sets
`AGENT_SAVE_SUBDIR=opencode-v2` in its config and keeps its state under
`<save dir>/opencode-v2/` instead of the save dir itself.

## Agent-specific Prompts, parameters and flags

Anything you want the coding agent itself to see can be passed through the launcher.

```bash
./code-it.sh -c "explain this repo"        # opens Claude Code with that first prompt
./claude-it.sh "explain this repo"         # the same, using the claude-it alias script

# One-shot: the agent answers the prompt, exits, and the container shuts down
./code-it.sh -c --headless "run the tests and fix any failures"
./code-it.sh -o --headless "summarise the last 10 commits" > summary.txt

# Everything after -- goes to the agent verbatim
./claude-it.sh -- --continue --model opus
./claude-it.sh --headless "tidy the imports" -- --max-turns 5
```
⚠️ Note! --headless provides no feedback. You may be looking at a blank screen until the agent finishes the prompt.

```powershell
.\Code-It.ps1 -c "explain this repo"
.\Code-It.ps1 -c -headless "run the tests and fix any failures"

# PowerShell has no usable `--` for scripts, so agent flags need no separator:
# anything Code-It.ps1 does not recognise is passed to the agent
.\Claude-It.ps1 --continue --model opus
.\Claude-It.ps1 -headless -prompt "tidy the imports" --max-turns 5
```

The launcher translates the prompt into each agent's own command line
([Claude Code](https://code.claude.com/docs/en/cli-reference),
[OpenCode v1](https://opencode.ai/docs/cli/),
[OpenCode v2](https://opencode.ai/v2/docs/cli/)):

| | interactive | `--headless` |
|---|---|---|
| Claude Code | `claude PROMPT` | `claude -p PROMPT` |
| OpenCode | `opencode --prompt PROMPT` | `opencode run PROMPT` |
| OpenCode v2 | `opencode mini --prompt PROMPT` | `opencode run --standalone PROMPT` |

Interactively the agent still runs inside tmux. With `--headless` it runs in the
foreground with no TTY allocated (`docker run -i`), so output can be piped or redirected
and the container's exit code is the agent's.

## tmux

The container includes tmux and starts a shell as well as your agent inside the container.
Press `Ctrl-B S` then use the up/down arrow keys to switch between the agent session and the shell.
Press `Ctrl-B S` again to switch back.

The shell is zsh, and some common abbreviations for git (`gco`, `glog`, `gs`, …)

## tab completion in bash, zsh, powershell

The `completions/` directory completes the launchers' own options, and, after `--`, the
flags of whichever agent is selected — `claude-it.sh` completes Claude Code flags,
`opencode-it.sh` completes OpenCode flags. Edit the flag lists in those files to add your
own favourites.

```bash
# bash: in ~/.bashrc
source /path/to/ContainerCodeIt/completions/code-it.bash
source /path/to/ContainerCodeIt/completions/code-it-build.bash
source /path/to/ContainerCodeIt/completions/code-it-add-agent.bash
source /path/to/ContainerCodeIt/completions/code-it-add-tool-chain.bash
source /path/to/ContainerCodeIt/completions/code-it-first-run.bash
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

## Rough Edges

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
| `/home/agent1/.config/opencode` | OpenCode v1/v2: configuration, including `opencode.json` and `cli.json` (v2's from `<save dir>/opencode-v2/`) |
| `/home/agent1/.local/share/opencode` | OpenCode v1/v2: session data and provider auth database |
| `/home/agent1/.local/state/opencode` | OpenCode v2 only: shared-service state |
| `/home/agent1/.nuget/packages-host` | **Read-only.** Host NuGet package cache (a `fallbackPackageFolder`), if `nuget` is enabled and a cache is found |
| `/home/agent1/.npm-host` | **Read-only.** Host npm cache, if `npm` is enabled and a cache is found; seeded into `~/.npm` at startup |
| `/home/agent1/.bun-host` | **Read-only.** Host Bun cache, if `bun` is enabled and a cache is found; seeded into `~/.bun/install/cache` at startup |

Alternatively, pass `-e ANTHROPIC_API_KEY=sk-...` (claude) or a provider API key env var (opencode) instead of mounting state.

# Isolating your agent from upstream origin repos.

You don't need to do this if your upstream repos need credentials, because your credentials won't be available inside the container. But to isolate your upstream repo from your agents, git clone your working tree locally. Git works fine with origin repos on the local filesystem. 

This works easiest if you give the agent its own branch (to avoid the git error, 'updating the current branch in a non-bare repository is denied') as well as its own cloned repo.

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

`npm` (in `--package-caches`, implied by `--toolchain node`) mounts your npm cache read-only at
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

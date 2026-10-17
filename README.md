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

`code-it` first run checks for Git, then delegates runtime detection, toolchain/agent
selection, and image building to `code-it-build`. It offers to copy existing host
agent configuration into the save directory without overwriting existing files, then
prints the command to start an agent. Existing state is copied, not moved or symlinked;
copied state will include your agent login in the container. With no toolchain detected,
choose at least one; PowerShell is preselected on Windows and when running the
PowerShell first-run script.
The image build waits for your confirmation; copying existing host state is separately opt-in.

You can also run it yourself, e.g. to add another image later:

```bash
./code-it-first-run.sh                      # interactive
./code-it-first-run.sh --toolchain python --agents claude --yes   # no questions
./code-it-first-run.sh --dry-run            # show what it would do
```

```powershell
.\Code-It-FirstRun.ps1 -toolchain python -agents claude -yes
```

It takes `--save-dir`/`-saveDir`, `--work-dir`/`-workDir`, `--toolchain`, `--agents`,
`--image`, `--dockerfile-dir`, `--runtime`, `--yes` and `--dry-run`; see `--help`.

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
It adds a `toolchains/NAME/` definition (`config` and `install.dockerfile`) exactly like
the existing ones, an optional `package-caches/NAME/` read-only cache, completions and
README, tests, and a commit. No Dockerfile or script edits: definitions are discovered
from their directories.

```bash
./code-it-add-tool-chain.sh java --url https://openjdk.org/install/
./code-it-add-tool-chain.sh java --dry-run

.\Code-It-Add-Tool-Chain.ps1 java -url https://openjdk.org/install/
```

## Code-It options

`code-it.sh` and `Code-It.ps1` accept the same logical parameters:

| bash | PowerShell | Default | Description |
|---|---|---|---|
| `--agent`, `-a` | `-agent`, `-a` | `opencode`, or the saved default agent (`code-it-defaults`) | Run the agent defined in `agents/NAME`; only its state is mounted |
| `--list-agents` | `-listAgents` | - | List the available agents and exit |
| `--claude`, `-c` | `-claude`, `-c` | off | Shortcut for `--agent claude` |
| `--opencode`, `-o` | `-opencode`, `-o` | on (default) | Shortcut for `--agent opencode` |
| `--no-agent`, `--zsh` | `-noAgent`, `-zsh` | off | Run a plain interactive zsh in the container instead of a coding agent: no agent state is mounted and no login is needed. A prompt, `--headless`, or combining it with an agent selection is an error |
| `--prompt`, `-p`, or a bare argument | `-prompt`, or a bare argument | none | Opening prompt for the agent |
| `--headless` | `-headless` | off | Run the agent one-shot in the foreground instead of in tmux: no TTY, and the container exits with the agent's exit code |
| `--` *agent-args* | *agent-args* (no separator) | none | Arguments passed to the coding agent verbatim |
| `--env`, `-e NAME[=VALUE]` (repeatable) | `-environment`, `-env`, `-e` *array* | none | Environment variable for the container; a bare `NAME` passes the host's value. See [Passing arguments to the container runtime](#passing-arguments-to-the-container-runtime) |
| `--env-file FILE` (repeatable) | `-envFile` *array* | none | File of `KEY=VALUE` environment variables for the container |
| `--run-arg ARG`, `--docker-arg ARG` (repeatable) | `-runArgs`, `-dockerArgs` *array* | none, plus `<save dir>/run-args` | One argument passed verbatim to `docker run` / `container run` |
| `--work-dir`, `-w` | `-WorkDirToMount` | `.` | Host path mounted at `/work` |
| `--save-dir`, `-s` | `-saveDir` | `~/.config/code-it` | Host path for agent state persistence |
| `--image`, `-i` | `-image` | `code-it-alpine-<toolchains>` | Image name; derived from `--toolchain` (e.g. `code-it-alpine-node-bun`). If the derived image is missing, the most-recently built existing image whose label *contains* the requested chains is used instead; an explicit `--image` is used as-is |
| `--runtime`, `-r` | `-runtime` | auto-detect | `docker` or `container` |
| `--port` | `-port` | `0` | Host port mapped to the container's port 3000. `0` auto-assigns (docker) or finds a free port starting at 3000 (Apple `container`) |
| `--locale`, `-l` | `-locale` | `like-host` | The container's locale (`LANG`), e.g. `en_GB.UTF-8` or `en-GB`. See [Locale](#locale) |
| `--agent-name` | `-agentName` | `Agent1` | Agent name, used for git attribution; must match the Dockerfile USER |
| `--toolchain LIST`, `-t`, `--stack` | `-toolchain LIST`, `-stack` | none: those of `--image`, else of the saved default toolchain (`code-it-defaults`), else of the remembered/existing code-it image, else first-run | Comma-separated toolchains: `dotnet`, `node`, `bun`, `python`, `powershell` (aliases `js-node`/`ts-node` for `node`, `js-bun`/`ts-bun` for `bun`, `uv` for `python`, `pwsh` for `powershell`; see `code-it-build --list-toolchains`) |
| `--package-caches LIST` | `-packageCaches LIST` | implied by `toolchain` | Comma-separated package repos to mount read-only: `nuget`, `npm`, `bun` |
| `--dry-run`, `-d` | `-dryRun` | off | Print the run command without executing |

When the image derived from `--toolchain` (e.g. `code-it-alpine-dotnet`) does not
exist, `code-it` uses the most-recently built existing image whose
`code-it.tool-chains` label contains every requested chain (e.g.
`code-it-alpine-dotnet-bun` for `dotnet`), and says which image it chose. An explicit
`--image` is used as-is and is an error if missing.

`code-it` runs images; it does not build them. Build with `code-it-build`, or let
first run do it. (The old `--build-image`, `--rebuild-image` and `--dockerfile-dir`
options are gone: `code-it` chooses one agent to run, while an image holds a set, so
building from `code-it` rebuilt images without their other agents.)

## code-it-build options

`code-it-build.sh` and `Code-It-Build.ps1` build the image (and label it with its
toolchains and package caches). They accept the same logical parameters:

| bash | PowerShell | Default | Description |
|---|---|---|---|
| `--toolchain LIST`, `-t`, `--stack` | `-toolchain LIST`, `-stack` | interactive if omitted | Toolchains to build (aliases as above). With none, `code-it-build` detects host toolchains and asks which to include |
| `--package-caches LIST` | `-packageCaches LIST` | implied by `toolchain` | Package repos to support; an explicit empty list means none |
| `--agent`, `--agents`, `-a LIST` | `-agent`, `-agents LIST` | `opencode,claude` for parameterized builds | Agents to install; interactive setup preselects detected agents |
| `--list-agents` | `-listAgents` | - | List the available agents and exit |
| `--list-toolchains` | `-listToolchains` | - | List the available toolchains and their aliases, then exit |
| `--list-package-caches` | `-listPackageCaches` | - | List the available package caches and exit |
| `--rebuild` | `-rebuild` | off | Bump the Dockerfile's `# last changed` dates to today, to force the agent and toolchain install layers to refresh. |
| `--locale`, `-l` | `-locale` | `like-host` | The image's locale (`LANG`). See [Locale](#locale) |
| `--image`, `-i` | `-image` | `code-it-alpine-<chains>` | Image name to build |
| `--dockerfile-dir` | `-dockerfileDir` | script's directory | Directory containing the Dockerfile |
| `--runtime`, `-r` | `-runtime` | auto-detect | `docker` or `container` |
| `--dry-run`, `-d` | `-dryRun` | off | Print the build command without executing it |
| `--yes`, `-y` | `-yes` | off | Accept detected/default interactive selections and build without asking |
| `--interactive` | `-interactive` | off | Prompt for any omitted selections; used by first-run |

With no parameters, `code-it-build` runs the same toolchain and agent selection used by first-run, confirms, and builds the image. `--yes` accepts the detected toolchains and agents without prompting. `code-it-build --toolchain node --dry-run` remains a non-interactive build.

The image is labelled `code-it.tool-chains=<chains>` and
`code-it.package-caches=<caches>`; `code-it` reads that label to warn if the image was
built for a different toolchain set, falling back to the image-name guess for images
that predate the label.
It is also labelled `code-it.agents=<agents>` and
`code-it.agent-binaries=<agent>=<path>,...`. `code-it` refuses to run an agent the image
lacks, or one the image installed at a different path from the one its
`agents/<name>/config` now names, because the image is out of date and would run the
wrong binary. Images that predate the binaries label get a warning instead.

The included Dockerfile is based on alpine3.24, which uses musl, and the architecture (amd64 or aarch64)
of your host machine.

### code-it-defaults options

`code-it-defaults.sh` and `Code-It-Defaults.ps1` save your usual choices in
`<save dir>/defaults` (default `~/.config/code-it/defaults`), and each agent's default
model in the agent's own configuration under the save dir, where every run picks it up:

```bash
./code-it-defaults.sh                 # interactive: agent, models, toolchain
./code-it-defaults.sh --agent claude --toolchain node,bun
./code-it-defaults.sh --model 'opencode=anthropic/claude-sonnet-4-5' --model 'claude=opus'
./code-it-defaults.sh --show          # print the saved defaults
./code-it-defaults.sh --refresh-models   # update the model list from https://models.dev
```

```powershell
.\Code-It-Defaults.ps1                # interactive
.\Code-It-Defaults.ps1 -agent claude -toolchain node,bun
.\Code-It-Defaults.ps1 -model 'claude=opus'
.\Code-It-Defaults.ps1 -show
.\Code-It-Defaults.ps1 -refreshModels
```

They accept `--agent/-agent`, `--model/-model AGENT=MODEL` (an empty MODEL clears it),
`--toolchain/-toolchain`, `--show/-show`, `--refresh-models/-refreshModels`,
`--save-dir/-saveDir` and `--dry-run/-dryRun`; see `--help`.

With no parameters code-it-defaults asks, reading answers from stdin (so they can be
scripted); a blank answer keeps the current value. With any of `--agent`, `--model`,
`--toolchain`, it asks nothing and sets exactly those.

`code-it` uses the saved defaults only when its own options do not say:
`--agent`/`-c`/`-o` beats the saved agent, and `--toolchain` and `--image` beat the
saved toolchain — which in turn beats the remembered-image heuristic of
[Specs 09/10](Specs/10-default-first-run-or-existing-image.md). When it launches the
saved agent it says so (`Using saved default agent: …`), because the agent brings its
own state with it: each agent's state, and its login, live in its own directory under
the save dir, so switching the default agent switches those too — opencode-v2 keeps
its login in its own state directory, and its first run there can ask you to log in
again. Models are data: the catalog offered by the interactive picker (from
`lib/models.txt`, or `<save dir>/model-catalog.txt` after `--refresh-models`) is best
effort and always incomplete, and any model string is accepted. `--show` names the
file each agent's model was set in.

## Locale

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

Toolchains, package caches and agents are **data, not branches**. Each toolchain is
one directory, `toolchains/<name>/`:

| File | Purpose |
|---|---|
| `config` | `key=value`: the install fragment name, host detect command(s), aliases, and any package cache it implies |
| `install.dockerfile` | a root-run, self-contained install layer (its packages, its `doas` permits) with a `# last changed YYYY-MM-DD` cache-bust line |

Package caches are the same, in `package-caches/<name>/`. `code-it-build` assembles
only the selected fragments into the Dockerfile, replacing the
`@@CODE_IT_TOOLCHAIN_INSTALLS@@` / `@@CODE_IT_PACKAGE_CACHE_INSTALLS@@` markers.
Unselected toolchains cost **nothing** in the assembled Dockerfile, which matters
because Apple's `container` builder sends it in a gRPC header and fails above ~16 KB
(`apple/container#735`): adding a toolchain does not grow every build.
`code-it-build --list-toolchains` and `--list-package-caches` show what is defined.

The launchers expose them as two comma-separated lists:

- `--toolchain` / `-toolchain` (alias `--stack` / `-stack`) — toolchains to build:
  `dotnet`, `node`, `bun`, `python`, `powershell`. There is no default list: without it,
  `code-it` uses those of `--image`, else of the remembered image, else of an existing
  code-it image, else runs the first-run setup (see below), and `code-it-build` stops.
  `js-node` and `ts-node` are aliases for `node`; `js-bun` and `ts-bun` are aliases for
  `bun`; `uv` is an alias for `python`; `pwsh` is an alias for `powershell`. Aliases resolve to the canonical name, so
  `--toolchain ts-node` is `--toolchain node` and produces the same image name.
- `--package-caches` / `-packageCaches` — package repos whose host cache is mounted
  read-only: `nuget`, `npm`, `bun` (`package-caches/<name>/`). Default: the repos
  implied by `--toolchain`, from each toolchain's `config`
  (`dotnet`->`nuget`, `node`->`npm`). Python has no host cache mount: uv must write
  its own cache, so the container keeps it in the agent's home (`UV_CACHE_DIR`).

Each enabled toolchain also adds a passwordless `doas` rule to the container, so you (or your
agent) can install further related tools.

Adding a toolchain means adding one `toolchains/<name>/` directory (and optionally a
`package-caches/<name>/` one): no script edits. Versioned variants (`dotnet8`,
`node22`, ...) can be added the same way later.

Subsequent calls to `code-it` with no --toolchain specified will reuse your most-used recent toolchain.

```bash

# A Bun-only sandbox with a read-only host Bun cache
./code-it-build.sh --toolchain bun --package-caches bun
./code-it.sh --toolchain bun

# Node.js and Bun, but npm only (e.g. you drive Bun through npm)
./code-it-build.sh --toolchain node,bun --package-caches npm

# Python 3 with uv ( --stack is an alias for --toolchain )
./code-it-build.sh --stack python
```

```powershell
.\Code-It-Build.ps1 -toolchain 'node,bun' -packageCaches npm
.\Code-It.ps1 -toolchain 'node,bun'
```

### Included toolchains

`--toolchain dotnet` installs dotnet10 and dotnet8 SDKs and Mono from Alpine repos.
`--toolchain node` installs Node.js from Alpine repos, and npm when `npm` is a package cache.
`--toolchain bun` installs Bun with its official installer.
`--toolchain python` adds Python 3, uv and uvx from Alpine's repos.
`--toolchain powershell` adds PowerShell 7 (`pwsh`): on x86_64 from Microsoft's musl
build; on aarch64 as a dotnet tool, since Microsoft ships no musl build for it, so it
also installs the .NET 10 SDK if `dotnet` is not selected.


## Agents

```bash
./code-it-build.sh -t node --agent opencode              # a leaner image, OpenCode only
./code-it.sh -t node --agent opencode                    # run it
./code-it-build.sh -t node --agent opencode,opencode-v2  # v1 and v2 side by side
./code-it.sh -t node --agent opencode-v2 --headless "summarise this repo"
./code-it.sh --list-agents                               # what is available
```

OpenCode v1 and v2 can be built into the same image: v2's binary is moved to
`~/.opencode-v2/bin` so it does not overwrite v1's. They read the same config and
data paths, and v1 exits at once on v2's `opencode.json`, so v2 sets
`AGENT_SAVE_SUBDIR=opencode-v2` in its config and keeps its state under
`<save dir>/opencode-v2/` instead of the save dir itself.

### Several containers at once

OpenCode keeps its sessions in a SQLite database in `~/.local/share/opencode`. Two
containers writing it at once corrupt it ("can't create session", `database disk
image is malformed`), especially with Apple `container`, which runs each container in
its own VM. So code-it locks that directory while a container uses it. A second
opencode run started while the first is still going gets a warning and its own copy,
`<save dir>/.code-it-instances/opencode/2/.local/share/opencode`, with `auth.json`
copied in so it needs no new login. Sessions made in a copy stay in that copy, and a
later run that gets the same copy carries on with them. A lock left by a run that
crashed is ignored. opencode-v2 does the same, under `<save dir>/opencode-v2/`, for
both `.local/share/opencode` and `.local/state/opencode` (the record of its shared
background service, which another container cannot reach). v2 keeps its login inside
its database rather than in `auth.json`, so a new v2 copy starts logged out: log in
once in it, and later runs that get the same copy keep that login. Agents opt in with
`AGENT_EXCLUSIVE_DIRS` (below).

### Agent definitions

Each agent is a directory, `agents/<name>/`, so adding one needs no script changes
(`code-it-add-agent` writes one for you):

- `config`: `KEY=value` lines, sourced by bash and parsed by PowerShell, one per line:

  | Key | Meaning |
  |---|---|
  | `AGENT_NAME` | The agent's name, the same as its directory |
  | `AGENT_SHORT` | Its shortcut letter, shown by `--list-agents` (may be empty) |
  | `AGENT_COMMAND` | Its command on the host, used by first-run to detect it |
  | `AGENT_BINARY` | Its absolute path in the image |
  | `AGENT_INSTALL` | The Dockerfile fragment that installs it, usually `install.dockerfile` |
  | `AGENT_CONFIG_LABEL` | How messages name its config, e.g. `'Claude Code settings'` |
  | `AGENT_STATE_DIRS`, `AGENT_STATE_FILES` | `:`-separated paths, relative to home, kept under the save dir and mounted into the container |
  | `AGENT_SAVE_SUBDIR` | Optional subdirectory of the save dir for its state, when it would clash with another agent's |
  | `AGENT_MODEL_FILE` | Optional `path:key`: the JSON file, under the agent's save dir, whose top-level `key` holds its default model; how `code-it-defaults` sets the model. Claude: `.claude/settings.json:model`; opencode: `.config/opencode/config.json:model`; opencode-v2: `.config/opencode/opencode.json:model` (v1 exits on v2's `opencode.json`, so each keeps its own file) |
  | `AGENT_EXCLUSIVE_DIRS` | Optional `:`-separated directories, from `AGENT_STATE_DIRS`, that only one container at a time may use. See [Several containers at once](#several-containers-at-once) |
  | `AGENT_EXCLUSIVE_CARRY` | Optional `:`-separated files, relative to home, inside those directories (credentials), copied into a run's own copy |
  | `AGENT_CMD_INTERACTIVE_PROMPT`, `AGENT_CMD_INTERACTIVE_NO_PROMPT`, `AGENT_CMD_HEADLESS_PROMPT`, `AGENT_CMD_HEADLESS_NO_PROMPT` | Its command line in each mode, where `{args}` is the arguments after `--` and `{prompt}` the opening prompt |

- `install.dockerfile`: the layers that install it, run as `agent1`. `code-it-build`
  splices the selected agents' fragments into the Dockerfile. Keep a `# last changed
  yyyy-mm-dd` comment on the install line, so `--rebuild` can bump it.

  The base Dockerfile carries the default agent (opencode) in a region marked
  `@@CODE_IT_AGENTS_BEGIN@@` ... `@@CODE_IT_AGENTS_END@@`, so building it directly,
  with no args, gives a working image with no toolchains. `code-it-build` replaces that
  whole region, so an assembled image contains exactly the agents it was asked for, and
  pre-creates each selected agent's state directories agent1-owned, so the bind mounts
  have a writable parent.
- `default-config/` (optional): files copied into the agent's save dir on first run,
  if not already there, keeping their layout.

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

### Passing arguments to the container runtime

Arguments go to three places: code-it's own options; the container runtime; and the
coding agent, after `--` (bash) or as unrecognised arguments (PowerShell). Runtime
arguments get their own repeatable options, one argument each, like `gcc -Xlinker`, so
nothing is word-split and quoting works the same in bash and PowerShell:

```bash
# Environment variables: a bare NAME passes the host's value, if it is set
./code-it.sh -c --env HTTPS_PROXY --env NO_PROXY=localhost,127.0.0.1
./code-it.sh -c --env-file ~/proxy.env

# Anything else docker run accepts: an option and its value are two --run-args,
# or one if joined with =
./code-it.sh -c --run-arg --network=host --run-arg --dns --run-arg 10.0.0.2 -- --continue
```

```powershell
.\Code-It.ps1 -c -env 'HTTPS_PROXY','NO_PROXY=localhost,127.0.0.1'
.\Code-It.ps1 -c -runArgs '--network=host','--dns','10.0.0.2' --continue
```

For settings every run needs, such as a proxy, put them in `<save dir>/run-args`
(default `~/.config/code-it/run-args`), as devcontainer.json's `runArgs`: one argument
per line, not quoted, `#` comments and blank lines ignored:

```text
# Behind the office proxy
-e
HTTPS_PROXY
-e
NO_PROXY
--dns=10.0.0.2
```

The file's arguments come first, then `--env`, `--env-file` and `--run-arg` in the order
given, all after code-it's own, so with docker a later `-e` of the same name wins. The
runtime arguments are passed verbatim, and docker and Apple `container` take different
flags, so check them against your runtime. `--env` and `--env-file` work with both:
Docker reads a bare `-e NAME` from the host itself, and for Apple `container` code-it
fills in the host's value. Either way the printed command does not show the value.

If the network problem is an HTTP proxy, Docker can also inject one into every
container from `~/.docker/config.json`
([docs](https://docs.docker.com/engine/cli/proxy/)), with no code-it options at all.

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
source /path/to/ContainerCodeIt/completions/code-it-doctor.bash
source /path/to/ContainerCodeIt/completions/code-it-defaults.bash
```

```zsh
# zsh: in ~/.zshrc, before compinit
fpath=(/path/to/ContainerCodeIt/completions $fpath)
autoload -Uz compinit && compinit
```

```powershell
# PowerShell: in $PROFILE. Parameters such as -claude, -prompt, -headless and -runtime
# complete without this; it adds the agent's own flags after -agentArgs, and the agent
# names of -agent / AGENT= prefixes of -model in Code-It-Defaults.ps1.
. /path/to/ContainerCodeIt/completions/CodeItCompletion.ps1
```

### What does the script do?

Something like this:

```bash
# docker build . -t code-it-alpine-dotnet-node:latest

docker run -it --rm \
    -p 0:3000 \
    -e CODE_AGENT=opencode \
    -e LANG=en_GB.UTF-8 \
    -e GIT_AUTHOR_NAME="Agent1 for $(git config --get user.name)" \
    -e GIT_AUTHOR_EMAIL="$(git config --get user.email)" \
    -e GIT_COMMITTER_NAME="Agent1 for $(git config --get user.name)" \
    -e GIT_COMMITTER_EMAIL="$(git config --get user.email)" \
    -v ~/my-repos:/work \
    -v ~/.config/code-it/.config/opencode:/home/agent1/.config/opencode \
    -v ~/.config/code-it/.local/share/opencode:/home/agent1/.local/share/opencode \
    -v ~/.nuget/packages:/home/agent1/.nuget/packages-host:ro \
    -v ~/.npm:/home/agent1/.npm-host:ro \
    code-it-alpine-dotnet-node:latest
```

`--dry-run` prints the exact command.

## Rough Edges

- Updating the agent harnesses claude code/open code is done by rebuilding the image (`code-it-build --toolchain <chains> --rebuild` / `Code-It-Build.ps1 -toolchain <chains> -rebuild`)
- Putting .sh on the bash scripts is surely a dubious design choice.
- Git configuration and indexing on Windows
  - When Git alternates between Windows and the Linux container on a bind-mounted
    working tree, the two filesystems can report different file metadata. Git then
    rechecks files whose cached stat information no longer matches, which can make
    `git status` appear to re-index the whole repository after each switch. This 
    becomes noticeable in large repositories. 
    The image enables Git's built-in filesystem monitor and `feature.manyFiles`, and
    upgrades mounted repository indexes to index format 4 when the container starts.
    On Windows, use a recent Git for Windows (2.37 or newer) and enable the same optimizations:
    ```powershell
    git config --global core.fsmonitor true
    git config --global feature.manyFiles true
    ```

## Runtime detection

`code-it.sh` and `Code-It.ps1` choose a container runtime automatically:

1. On **macOS**, they use the **Apple container CLI** (`container`) if installed
2. Otherwise they use **Docker** if installed
3. Otherwise they exit with a suggestion for the best runtime to install on your platform

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

Alternatively, pass `--env ANTHROPIC_API_KEY` (claude) or a provider API key env var (opencode) instead of mounting state.

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
. UseIsolatedAgentRepos.ps1 -defaultOriginalBranchName <defaults to main> -defaultAgentBranchName <defaults to agent1>
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

## Copying to the clipboard

Nothing in the container can reach your clipboard directly: there is no `pbcopy` in
there, and no display. A copy travels as an escape sequence, OSC 52, along this path:

```
agent (Claude Code /copy, opencode's select) or tmux mouse selection
  -> tmux in the container (set-clipboard on: passes OSC 52 on)
  -> docker / Apple container (a plain terminal stream)
  -> tmux on your host, if any (needs set -s set-clipboard on; the default drops it)
  -> your terminal, which must accept OSC 52
```

The image already does its part. When copying fails, the cause is almost always the
host end:

| Terminal | OSC 52 | To copy from the container |
|---|---|---|
| macOS Terminal.app | **not supported** | turn mouse reporting off with View > Allow Mouse Reporting (⌘R), drag, ⌘C, ⌘R again; or `Ctrl-B :set mouse off` in the container; or use another terminal |
| iTerm2 | off by default | Settings > General > Selection > *Applications in terminal may access clipboard*, or `defaults write com.googlecode.iterm2 AllowClipboardAccess -bool true` and restart iTerm2 |
| Ghostty, WezTerm, kitty, Alacritty, VS Code, Windows Terminal | on | select with the mouse: tmux copies on release, no ⌘C needed |
| mintty (Git Bash) | off by default | `AllowSetSelection=yes` in `~/.minttyrc` |

`code-it-doctor` checks all of this for you, and can try the round trip itself.

## code-it-doctor

`code-it-doctor` checks your setup and says how to fix each problem it finds: the
container runtime and its service, the image (and its tmux settings), the save dir
(including opencode's database), your git identity, and the clipboard path above: which
terminal you use and whether it accepts OSC 52, and tmux or screen on the host.

The clipboard round trip (asked for first, or `--yes`) puts a marker on your clipboard
with OSC 52, from the shell and then from tmux inside the image, and reads it back with
`pbpaste`, `wl-paste`, `xclip`, `xsel` or PowerShell; text that was on the clipboard is
restored. It is skipped over ssh, where this host's clipboard is not yours.

It exits 0 if it found no problem and 1 if it did.

```bash
./code-it-doctor.sh
./code-it-doctor.sh --yes                          # run the clipboard round trip without asking
./code-it-doctor.sh "opencode can't create a session"   # then have an agent fix it
./code-it-doctor.sh --fix --dry-run               # show the prompt and command only
```

```powershell
.\Code-It-Doctor.ps1
.\Code-It-Doctor.ps1 "opencode can't create a session"
```

With `--fix`, or a problem described in words, it then runs code-it headless on this
repository, like `code-it-add-agent`, handing the agent the problem and the report (the
agent cannot see your host). The agent investigates inside a code-it container, and
either fixes the repository, with tests and a commit, on a new branch
`doctor/<timestamp>`, or tells you exactly what to change on the host. It refuses a
dirty repository, never commits to your current branch and never pushes.

| bash | PowerShell | Default | Description |
|---|---|---|---|
| *PROBLEM* | *Problem* | none | The problem, in words; implies `--fix` |
| `--runtime`, `-r` | `-runtime` | auto-detect | `docker` or `container` |
| `--image`, `-i` | `-image` | the most recently used code-it image | Image to check |
| `--save-dir`, `-s` | `-saveDir` | `~/.config/code-it` | code-it's save dir |
| `--no-live-test` | `-noLiveTest` | off | Skip the clipboard round trip |
| `--yes`, `-y` | `-yes` | off | Run the clipboard round trip without asking |
| `--fix` | `-fix` | off | Have code-it investigate and fix what was found |
| `--repo` | `-repo` | script's directory | Repository for `--fix` |
| `--code-it` | `-codeIt` | `code-it.sh` / `Code-It.ps1` | Launcher for `--fix` |
| `--branch` | `-branch` | `doctor/<yyyymmdd-HHMMSS>` | Branch for `--fix` |
| `--dry-run`, `-d` | `-dryRun` | off | With `--fix`, print the prompt and command only |

## Tests

No container runtime needed. The tests stub `docker`/`container`/`uname` on the PATH and assert on `--dry-run` output, so they run on any machine, not just inside a container.

```bash
# Linux / macOS (runs the bash suite, then the pwsh suite if pwsh is installed)
./tests/run-all-tests.sh
```

```powershell
pwsh -NoProfile -File tests/Test-CodeIt.ps1
pwsh -NoProfile -File tests/Test-CodeItDoctor.ps1
```

- **macOS**: `./tests/run-all-tests.sh` works with the stock bash 3.2; the Apple-container detection paths are exercised via stubs, so neither Docker nor the `container` CLI needs to be installed.
- **Windows**: run the PowerShell suite; the bash suite additionally works under Git Bash or WSL. The suite stubs docker with a `.cmd` shim and only needs `git` and PowerShell 7+.

#! /usr/bin/env pwsh

<#
.SYNOPSIS
    Launches an Alpine Linux container with OpenCode, Claude Code, and a parameterisable set of toolchains.

.DESCRIPTION
    Creates and runs a container for development using OpenCode or Claude Code as an agent.

    Picks a container runtime automatically:
    - On macOS, uses the Apple container CLI (container) if installed
    - Otherwise uses Docker if installed
    - Otherwise suggests the best runtime to install for the current platform
    Use -runtime to force one.

    The script recognises:
    - Volume mounts for code repositories and agent configuration
    - Git author environment variables or config settings (name and email)
    - Paths to preserve agent credentials, settings, and session data across container runs
    - A parameterisable set of toolchains (dotnet, node, bun, python, powershell) and package
      caches (nuget, npm, bun), chosen with -toolchain and -packageCaches
    - The enabled host package caches, mounted read-only
    - Port mappings

    The script supports optional image building and port mappings. Only the chosen
    agent's state (from agents/<name>/config) is mounted, so sessions and logins persist.

.PARAMETER environment
    Environment variables to set in the container, each NAME=VALUE or a bare NAME, which
    passes the host's value of NAME if it is set. Aliases: -env, -e
    e.g. -env 'HTTPS_PROXY','NO_PROXY=localhost'

.PARAMETER envFile
    Files of environment variables, in the runtime's KEY=VALUE format.

.PARAMETER runArgs
    Arguments passed to `docker run` (or `container run`) verbatim, one array element
    each, so nothing is word-split: an option and its value are two elements, or one
    if joined with =, e.g. -runArgs '--network=host','--dns','10.0.0.2'
    The runtime's own flags differ, so these are not portable between docker and
    container. Arguments in <saveDir>/run-args (see Notes) come first. Alias: -dockerArgs

.PARAMETER WorkDirToMount
    Host directory path to mount as /work in the container. Defaults to the current directory.

.PARAMETER agent
    Run the agent defined in agents/<name>. Only that agent's state is mounted.
    Default: opencode. Alias: -a

.PARAMETER listAgents
    List the available agents and exit.

.PARAMETER opencode
    Shortcut for -agent opencode (the default). Alias: -o

.PARAMETER claude
    Shortcut for -agent claude. Alias: -c

.PARAMETER saveDir
    Host directory for storing agent configuration and state volumes. Created if missing.
    Default: ~/.config/code-it

.PARAMETER image
    Image name to run. Default: "code-it-alpine-<toolchains>", a slug of the resolved -toolchain
    list, e.g. code-it-alpine-dotnet or code-it-alpine-node-bun. When that image does not
    exist, the most-recently built existing image whose code-it.tool-chains label contains
    every requested toolchain is used instead. Set it explicitly to force a particular
    image (an error if it does not exist).

.PARAMETER runtime
    Container runtime to use: "docker" or "container".
    Default: auto-detected as described above.

.PARAMETER port
    Host port to map to the container's port 3000 (so it takes a single "host" value,
    not a "host:container" pair). Default: 0. With docker, 0 lets the runtime auto-assign
    a free host port, so multiple containers can run at once without port collisions.
    The Apple container CLI cannot, so on macOS 0 is resolved to a free port, starting
    at 3000, then a random high port if 3000-3010 are all taken.

.PARAMETER prompt
    Opens the agent with this text as its first prompt. A leading bare argument means the
    same thing, so `.\Code-It.ps1 -c "explain this repo"` is equivalent.

.PARAMETER headless
    Runs the agent in the foreground rather than in tmux, with no TTY allocated. With
    -prompt the agent answers, exits, and the container shuts down, exiting with the
    agent's exit code.

.PARAMETER agentArgs
    Any arguments this script does not recognise are passed to the coding agent verbatim,
    e.g. `.\Code-It.ps1 -c --continue --model opus`. PowerShell has no usable `--`
    end-of-parameters token for scripts, so unlike code-it.sh no separator is needed -
    and none works. A short agent flag that PowerShell reads as one of this script's own
    parameters (`-p` matches both -port and -prompt) is rejected before the script
    runs: spell it in full, `--print`, or pass it as `-agentArgs '-p','...'`.
    See https://code.claude.com/docs/en/cli-reference and https://opencode.ai/docs/cli/

.PARAMETER locale
    The container's locale (its LANG), e.g. en_GB.UTF-8 or en-GB. Passed to the
    container when it runs, so it need not be the image's. Default: like-host, the
    host's own locale (see Code-It-Build.ps1 -help); C.UTF-8 if it cannot be told.

.PARAMETER agentName
    Name of the agent running in the container. Used for Git author attribution and home
    directory naming. This must match the USER set in the Dockerfile for your image.
    Default: "Agent1"

.PARAMETER toolchain
    Comma-separated toolchains. Known: dotnet, node (aliases js-node, ts-node), bun
    (aliases js-bun, ts-bun), python (alias uv), powershell (alias pwsh). Alias: -stack.
    There is no default list. Without -toolchain, they are those of the -image given;
    else of the remembered image, the most recent in <saveDir>/image-history whose
    toolchains cover 70% of your recent runs; else of the most recently used, or else
    built, code-it image. With no <saveDir> or no code-it image, Code-It-FirstRun.ps1
    runs instead.

.PARAMETER packageCaches
    Comma-separated package repos whose host cache is mounted read-only. 
    Known: nuget, npm, bun. 
    Default: the repos implied by -toolchain (dotnet->nuget, node->npm), so not specifying 
    this parameter is the simplest choice.
    If the given package manager has a well-known global cache directory; and if that
    directory exists on the host when the script runs; then that directory will be 
    mounted read-only in the virtual machine at the package manager's default location 
    on Alpine Linux.

.PARAMETER dryRun
    Print the run command without executing it.

.EXAMPLE
    .\Code-It.ps1 -claude -WorkDirToMount ~/my-repos
    Runs Claude Code in the default container with a custom work directory.

.EXAMPLE
    .\Code-It.ps1 -o
    Runs OpenCode in the default container mounting the current directory.

.EXAMPLE
    .\Code-It.ps1 -toolchain python
    Runs the code-it-alpine-python image, built by Code-It-Build.ps1 -toolchain python.

.EXAMPLE
    .\Code-It.ps1 -port 8000
    Maps host port 8000 to the container's port 3000.

.EXAMPLE
    .\Code-It.ps1 -c "explain this repo"
    Opens Claude Code with that opening prompt, and stays interactive.

.EXAMPLE
    .\Code-It.ps1 -c -headless "run the tests and fix any failures"
    Runs Claude Code headlessly: the agent works, prints its answer, and the container
    shuts down.

.EXAMPLE
    .\Code-It.ps1 -env HTTPS_PROXY -runArgs '--dns','10.0.0.2' -c --continue
    Passes the host's HTTPS_PROXY and a DNS server to the container, and --continue to
    Claude Code.

.EXAMPLE
    .\Code-It.ps1 -c --continue --model opus
    Passes those flags straight through to Claude Code.

.NOTES
    - The prompt and any pass-through arguments are translated into each agent's own
      command line, from the AGENT_CMD_* templates in agents/<name>/config: -prompt
      becomes `claude PROMPT` or `opencode --prompt PROMPT`, and with -headless it
      becomes `claude -p PROMPT` or `opencode run PROMPT`
    - <saveDir>/run-args (default ~/.config/code-it/run-args), if it exists, holds run
      arguments for every run, like devcontainer.json's runArgs: one argument per line,
      not quoted; blank lines and lines starting with # are ignored. e.g.
          # Behind the office proxy
          -e
          HTTPS_PROXY
          --dns=10.0.0.2
      They come before -environment, -envFile and -runArgs, which come after Code-It's
      own, so with docker a later -e of the same name wins.
    - Git author name and email are automatically captured from environment or git config
    - Volume mounts preserve the selected agent's state between container runs, so you
      can destroy the container and create a new one without logging in again. Only
      the paths in AGENT_STATE_DIRS and AGENT_STATE_FILES of agents/<name>/config are
      mounted, under <saveDir> (or <saveDir>/AGENT_SAVE_SUBDIR, e.g. for opencode-v2)
    - Only one container at a time may use an agent's AGENT_EXCLUSIVE_DIRS (opencode's
      session database, ~/.local/share/opencode, is corrupted if two share it). When
      another Code-It run is using them, Code-It warns and mounts a copy of its own,
      <saveDir>/.code-it-instances/<agent>/<n>/..., with the agent's credentials
      (AGENT_EXCLUSIVE_CARRY) copied in. Sessions made there stay in that copy.
    - Alternatively, use ANTHROPIC_API_KEY (claude) or a provider API key env var (opencode)
      to avoid volume mounts for credentials
    - Host package caches are mounted read-only (never written) for the package
      repos in -packageCaches when a cache is found, so downloads are reused:
        NuGet: ~/.nuget/packages-host (a fallbackPackageFolder). Looked up, in order,
               from the NUGET_PACKAGES env var, the globalPackagesFolder setting in
               the user-level NuGet.Config, and the default ~/.nuget/packages
        npm:   ~/.npm-host, seeded into the container's own ~/.npm at startup
        Bun:   ~/.bun-host, seeded into ~/.bun/install/cache at startup

.LINK
    https://docs.docker.com/engine/reference/commandline/run/
#>

#   What each mount preserves:
#   ┌──────────────────────────┬────────────────────────────────────────────────────────────────┐
#   │          Mount           │                            Contains                            │
#   ├──────────────────────────┼────────────────────────────────────────────────────────────────┤
#   │ ~/.claude/               │ Credentials (.credentials.json), settings, permissions, memory │
#   ├──────────────────────────┼────────────────────────────────────────────────────────────────┤
#   │ ~/.claude.json           │ OAuth session data, MCP configs, theme/editor preferences      │
#   ├──────────────────────────┼────────────────────────────────────────────────────────────────┤
#   │ ~/.config/opencode/      │ OpenCode configuration (opencode.json, etc.)                  │
#   │ ~/.local/share/opencode/ │ OpenCode data and auth (auth.json, etc.)                       │
#   └──────────────────────────┴────────────────────────────────────────────────────────────────┘

# PositionalBinding is off so that arguments meant for the coding agent, which often
# look like parameters (e.g. --continue), all land in $agentArgs instead of being bound
# positionally. -WorkDirToMount therefore has to be named.
[CmdletBinding(PositionalBinding = $false)]
param (
    [string]$WorkDirToMount = (Resolve-Path '.').Path,
    [Alias('c')]
    [switch]$claude         = $false,
    [Alias('o')]
    [switch]$opencode       = $false,
    [Alias('a')]
    [string]$agent          = "",
    [switch]$listAgents     = $false,
    [string]$saveDir        = "$HOME/.config/code-it",
    [string]$image          = "",
    [ArgumentCompleter({ param($c, $p, $wordToComplete) @('docker', 'container') | Where-Object { $_ -like "$wordToComplete*" } })]
    [string]$runtime        = "",
    [int]$port              = 0,
    [ArgumentCompleter({ param($c, $p, $wordToComplete) @('like-host', 'C.UTF-8') | Where-Object { $_ -like "$wordToComplete*" } })]
    [string]$locale         = 'like-host',
    [string]$agentName      = "Agent1",
    [Alias('tech', 'stack')]
    [string]$toolchain     = "",
    [string]$packageCaches  = "",
    [string]$prompt         = "",
    [switch]$headless       = $false,
    # Not $env, which is PowerShell's environment drive
    [Alias('env', 'e')]
    [string[]]$environment  = @(),
    [string[]]$envFile      = @(),
    [Alias('dockerArgs')]
    [string[]]$runArgs      = @(),
    [Alias('h')]
    [switch]$help           = $false,
    [switch]$dryRun         = $false,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$agentArgs    = @()
)

# Handle help request
if ($help) {
    Get-Help $PSCommandPath -Full
    exit 0
}

. "$PSScriptRoot/lib/CodeItCommon.ps1"

$agentsDir = Join-Path $PSScriptRoot 'agents'
$toolchainsDir = Join-Path $PSScriptRoot 'toolchains'
$packageCachesDir = Join-Path $PSScriptRoot 'package-caches'

# -listAgents lists the available agent definitions and exits.
if ($listAgents) {
    foreach ($name in (Get-CodeItListAgents $agentsDir)) {
        $short = Get-CodeItAgentConfig $agentsDir $name 'AGENT_SHORT'
        if ($short) { "  {0,-10} -{1}" -f $name, $short } else { "  $name" }
    }
    exit 0
}

# Resolve which agent to run: -c / -o are shortcuts, else -agent NAME, else opencode.
if ($claude -and $opencode) {
    Write-Warning "Specify only one of -claude or -opencode."
    exit 1
}
$codeAgent = if ($claude) { "claude" } elseif ($opencode) { "opencode" } elseif ($agent) { $agent } else { "opencode" }

# Load the chosen agent's definition. The agent name is data: shortcut flags are
# resolved here, but every other detail comes from agents/<name>/config.
if (-not (Test-CodeItAgentExists $agentsDir $codeAgent)) {
    Write-Warning "Unknown agent '$codeAgent'. Known agents: $((Get-CodeItListAgents $agentsDir) -join ' ')"
    Write-Warning "Run .\Code-It.ps1 -listAgents to see them."
    exit 1
}
$agentBinary      = Get-CodeItAgentConfig $agentsDir $codeAgent 'AGENT_BINARY'
$agentStateDirs   = Get-CodeItAgentConfig $agentsDir $codeAgent 'AGENT_STATE_DIRS'
$agentStateFiles  = Get-CodeItAgentConfig $agentsDir $codeAgent 'AGENT_STATE_FILES'
$agentSaveSubdir  = Get-CodeItAgentConfig $agentsDir $codeAgent 'AGENT_SAVE_SUBDIR'
$agentExclusiveDirs  = Get-CodeItAgentConfig $agentsDir $codeAgent 'AGENT_EXCLUSIVE_DIRS'
$agentExclusiveCarry = Get-CodeItAgentConfig $agentsDir $codeAgent 'AGENT_EXCLUSIVE_CARRY'
$agentConfigLabel = Get-CodeItAgentConfig $agentsDir $codeAgent 'AGENT_CONFIG_LABEL'
$agentCmdInteractivePrompt   = Get-CodeItAgentConfig $agentsDir $codeAgent 'AGENT_CMD_INTERACTIVE_PROMPT'
$agentCmdInteractiveNoPrompt = Get-CodeItAgentConfig $agentsDir $codeAgent 'AGENT_CMD_INTERACTIVE_NO_PROMPT'
$agentCmdHeadlessPrompt      = Get-CodeItAgentConfig $agentsDir $codeAgent 'AGENT_CMD_HEADLESS_PROMPT'
$agentCmdHeadlessNoPrompt    = Get-CodeItAgentConfig $agentsDir $codeAgent 'AGENT_CMD_HEADLESS_NO_PROMPT'

# A leading bare argument is the agent's opening prompt, as in `.\Code-It.ps1 -c "do it"`;
# anything else goes to the agent verbatim
if (-not $prompt -and $agentArgs.Count -ge 1 -and -not $agentArgs[0].StartsWith('-')) {
    $prompt = $agentArgs[0]
    $agentArgs = @($agentArgs | Select-Object -Skip 1)
    if (Test-Path -Path $prompt -PathType Container -EA Silent) {
        Write-Warning "Passing '$prompt' to the agent as its prompt. To choose the directory to work on, use -WorkDirToMount."
    }
}
$promptSet = [bool]$prompt

# -environment, -envFile and -runArgs, in that order, as container run arguments
$cliRunArgs = @()
foreach ($spec in $environment) {
    if (-not (Test-CodeItEnvSpec $spec)) {
        Write-Warning "-environment needs NAME or NAME=VALUE, not '$spec'."
        exit 1
    }
    $cliRunArgs += @('-e', $spec)
}
foreach ($file in $envFile) {
    if (-not (Test-Path -Path $file -PathType Leaf)) {
        Write-Warning "-envFile not found: $file"
        exit 1
    }
    $cliRunArgs += @('--env-file', $file)
}
$cliRunArgs += $runArgs

# Removed parameters would otherwise reach the agent as pass-through arguments
$removed = @($agentArgs | Where-Object { $_ -match '^-(b|buildImage|rebuildImage|dockerfileDir)$' })
if ($removed) {
    Write-Warning "$($removed[0]) has been removed: build images with Code-It-Build.ps1, then run them."
    exit 1
}

# Resolve -toolchain / -packageCaches. Each takes a list, so there are no per-toolchain
# on/off parameters to clash with future toolchain names. -packageCaches defaults to
# the repos implied by the toolchains (dotnet->nuget, node->npm). Without -toolchain
# the list stays empty until the image is chosen, below.
$enabledToolchain = Resolve-CodeItToolchain $toolchain $toolchainsDir
if ($null -eq $enabledToolchain) { exit 1 }
if ($PSBoundParameters.ContainsKey('toolchain') -and $enabledToolchain.Count -eq 0) {
    Write-Warning "-toolchain needs at least one toolchain."
    exit 1
}
if ($PSBoundParameters.ContainsKey('packageCaches') -and -not $packageCaches) {
    $enabledPackageCaches = @()
} else {
    $enabledPackageCaches = Resolve-CodeItPackageCaches $packageCaches $enabledToolchain $toolchainsDir $packageCachesDir
}
if ($null -eq $enabledPackageCaches) { exit 1 }
$containerLocale = Resolve-CodeItLocale $locale
if (-not $containerLocale) { exit 1 }

# Default image name from the toolchain list, e.g. code-it-alpine-dotnet or
# code-it-alpine-node-bun. An explicit -image overrides it.
if (-not $image -and $enabledToolchain.Count) { $image = CodeIt-ImageName $enabledToolchain }

# Detect / validate the container runtime.
$runtime = Detect-CodeItRuntime $runtime
if ($null -eq $runtime) { exit 1 }
"    Using container runtime: $runtime"
"    Using code agent: $codeAgent"

# List existing images in a runtime-appropriate way. Done up front so the default
# selection below can use them, and a broken daemon is reported before first-run.
if ($runtime -eq "docker") {
    $validImages = (docker images --format "{{.Repository}}:{{.Tag}}")
} else {
    $validImages = (container image ls)
}
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Could not list $runtime images. Is the $runtime daemon or service running?"
    exit 1
}

# Default selection, when neither -toolchain nor -image was given: with no save dir
# yet, or no code-it image at all, there is no setup, so run first-run. With a save dir
# and history, the 70% weighted rule of Spec 09 applies; without history (or if it
# selects nothing), the most recent existing code-it image. See Spec 10, which amends
# Spec 09's final paragraph.
if (-not $PSBoundParameters.ContainsKey('toolchain') -and -not $PSBoundParameters.ContainsKey('image')) {
    $firstRun = if ($env:CODE_IT_FIRST_RUN) { $env:CODE_IT_FIRST_RUN } else { Join-Path $PSScriptRoot 'Code-It-FirstRun.ps1' }
    $defaultHistory = Join-Path $saveDir 'image-history'
    $defaultImage = ""
    $defaultLabel = "existing image"
    if (-not (Test-Path -Path $saveDir -PathType Container)) {
        $defaultImage = ""
    } else {
        if (Test-Path -Path $defaultHistory -PathType Leaf) {
            $defaultImage = Get-CodeItHistoryImage $runtime $defaultHistory $toolchainsDir
            if ($defaultImage) { $defaultLabel = "remembered image" }
        }
        if (-not $defaultImage) {
            $defaultImage = Get-CodeItDefaultImage $runtime $defaultHistory
        }
    }
    $selectedChains = if ($defaultImage) { Get-CodeItImageToolchain $runtime $defaultImage } else { "" }
    if (-not $selectedChains) {
        "    No code-it image or setup found; running Code-It-FirstRun.ps1."
        if ($dryRun) {
            "    (dry run: would run $firstRun)"
            exit 0
        }
        & $firstRun -saveDir $saveDir -workDir $WorkDirToMount -runtime $runtime
        exit $LASTEXITCODE
    }
    $enabledToolchain = Select-CodeItKnownToolchain $selectedChains $toolchainsDir
    if (($enabledToolchain -join ',') -ne $selectedChains) {
        "    Note: image '$defaultImage' has toolchains this code-it does not know ($selectedChains); using $(if ($enabledToolchain) { $enabledToolchain -join ',' } else { 'none' })."
    }
    if (-not $PSBoundParameters.ContainsKey('packageCaches')) {
        $enabledPackageCaches = Resolve-CodeItPackageCaches "" $enabledToolchain $toolchainsDir $packageCachesDir
    }
    $image = $defaultImage
    "    Using $defaultLabel`: $image"
} elseif (-not $PSBoundParameters.ContainsKey('toolchain')) {
    # -image without -toolchain: the image's own toolchains (its label, else its name)
    # decide the package caches.
    $enabledToolchain = Select-CodeItKnownToolchain (Get-CodeItImageToolchain $runtime $image) $toolchainsDir
    if (-not $PSBoundParameters.ContainsKey('packageCaches')) {
        $enabledPackageCaches = Resolve-CodeItPackageCaches "" $enabledToolchain $toolchainsDir $packageCachesDir
    }
}

# Give the Apple container runtime enough memory for the agent to work with
$containerArgs = if ($runtime -eq "container") { @('--memory', '3g') } else { @() }


# Ensure required commands
if (-not (Get-Command git -EA Silent)) {
    Write-Warning "Git command not found. Please install Git and ensure it is in your PATH."
    exit 1
}

# Port mapping. The container listens on 3000; -port is the host port mapped to it.
# The default, 0, means docker auto-assigns a free host port. The Apple container CLI
# (macOS only) cannot, so resolve 0 to a free port, starting at 3000, then a random
# high port if 3000-3010 are all taken.
$containerPort = 3000
function Test-PortInUse([int]$p) {
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p)
        $listener.Start(); $listener.Stop(); return $false
    } catch { return $true }
}
if ($port -eq 0 -and $runtime -eq "container") {
    $resolved = $null
    foreach ($candidate in 3000..3010) {
        if (-not (Test-PortInUse $candidate)) { $resolved = $candidate; break }
    }
    if (-not $resolved) { $resolved = (Get-Random -Minimum 30000 -Maximum 40000) }
    $port = $resolved
}
$portMapping = "${port}:${containerPort}"

# Ensure required paths exist
if (-not $WorkDirToMount -or -not (Test-Path -Path $WorkDirToMount -PathType Container -EA Silent)) {
    Write-Warning "WorkDirToMount directory does not exist: $WorkDirToMount.
    Please specify a directory where you have a git repo, or repos, you want the agent to work on."
    exit 1
}
$WorkDirToMount = (Resolve-Path $WorkDirToMount).Path

# Create the save dir structure so mounts always work, even on first run. State
# paths come from the agent definition: directories are created; single files are
# pre-created so the runtime does not make a directory in their place.
# An agent whose state would clash with another's (opencode-v2 reads the same
# paths as opencode, but rejects its config) keeps it under AGENT_SAVE_SUBDIR.
$agentSaveDir = if ($agentSaveSubdir) { "$saveDir/$agentSaveSubdir" } else { $saveDir }
$null = New-Item -ItemType Directory -Force -Path $agentSaveDir
$agentStateDirList   = Split-CodeItList ($agentStateDirs -replace ':', ',')
$agentStateFileList  = Split-CodeItList ($agentStateFiles -replace ':', ',')
foreach ($d in $agentStateDirList) {
    $null = New-Item -ItemType Directory -Force -Path "$agentSaveDir/$d"
}
foreach ($f in $agentStateFileList) {
    if (-not (Test-Path -Path "$agentSaveDir/$f")) {
        Set-Content -Path "$agentSaveDir/$f" -Value '{}'
    }
}

# Write the agent's default configuration file(s) on first run, preserving layout.
$defaultConfigDir = Join-Path $agentsDir (Join-Path $codeAgent 'default-config')
if (Test-Path -Path $defaultConfigDir -PathType Container) {
    $defaultConfigDir = (Resolve-Path $defaultConfigDir).Path
    foreach ($src in (Get-ChildItem -Force -Recurse -File -Path $defaultConfigDir | Sort-Object FullName)) {
        $rel = $src.FullName.Substring($defaultConfigDir.Length).TrimStart('/', '\')
        $dest = Join-Path $agentSaveDir $rel
        if (-not (Test-Path -Path $dest)) {
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent)
            Copy-Item -Path $src.FullName -Destination $dest
            "    Created $agentConfigLabel`: $dest"
        }
    }
}
$saveDir = (Resolve-Path $saveDir).Path
$agentSaveDir = (Resolve-Path $agentSaveDir).Path
$historyFile = Join-Path $saveDir 'image-history'
$runArgsFile = Join-Path $saveDir 'run-args'

"    Checking $image ..."

Write-Verbose ([string]::join("`n", @("    $runtime images") + $validImages)).ToString()

# If the exact image is missing and the user did not name one, use the most-recently
# built existing image whose recorded toolchains contain every requested chain.
$exactExists = $validImages | Where-Object { $_ -and ($_ -eq $image -or $_ -match "^$([regex]::Escape($image))[: ]") } | Select-Object -First 1
if (-not $exactExists) {
    if ($PSBoundParameters.ContainsKey('image')) {
        Write-Warning "$runtime image '$image' does not exist.
    Build it, or set -image to an image that exists."
        exit 1
    }
    $supersetImage = Find-CodeItSupersetImage $runtime $enabledToolchain
    if ($supersetImage) {
        "    '$image' does not exist; using '$supersetImage', which contains $($enabledToolchain -join ',')"
        $image = $supersetImage
    } else {
        Write-Warning "$runtime image '$image' does not exist.
    Build it with Code-It-Build.ps1 -toolchain $($enabledToolchain -join ','), or set -image to an image that exists."
        exit 1
    }
}

# Warn if the chosen image was built for a different toolchain set than the one we
# are about to run. Prefer the label Code-It-Build stamped on the image; fall back to
# the name-based guess. A superset image is fine: only warn when it does not contain
# every requested chain.
$imageToolchain = Get-CodeItImageToolchain $runtime $image
if ($imageToolchain -and -not (Test-CodeItToolchainInclude $imageToolchain $enabledToolchain)) {
    Write-Warning "Image '$image' looks built for toolchains '$imageToolchain' but -toolchain is '$($enabledToolchain -join ',')'."
    Write-Warning "Pass the same -toolchain used to build the image, or set -image explicitly."
} elseif ($imageToolchain -and $imageToolchain -ne ($enabledToolchain -join ',')) {
    $extras = @($imageToolchain -split ',' | Where-Object { $enabledToolchain -notcontains $_ })
    "    Note: image '$image' also contains $($extras -join ',')"
}

# The image must contain the chosen agent: go.sh cannot run one it lacks. Check here,
# where the error is readable, rather than in the container.
$imageAgents = Get-CodeItImageAgents $runtime $image $agentsDir
$rebuildToolchain = if ($imageToolchain) { $imageToolchain } else { $enabledToolchain -join ',' }
if ($imageAgents -and (($imageAgents -split ',') -notcontains $codeAgent)) {
    Write-Warning "Image '$image' does not contain agent '$codeAgent'; it has: $imageAgents."
    Write-Warning "Choose one of those with -agent, or rebuild with Code-It-Build.ps1 -toolchain $rebuildToolchain -agent $codeAgent,$imageAgents"
    exit 1
}
# An image built before a change to the agent's definition may install it somewhere
# else, or run another agent's binary from a shared path, so check the binary the
# image recorded against the one the definition names now.
if ($imageAgents) {
    $imageAgentBinary = Get-CodeItImageAgentBinary $runtime $image $codeAgent
    if ($null -eq $imageAgentBinary) {
        Write-Warning "Image '$image' predates code-it recording its agents' binaries, so it may run an out-of-date '$codeAgent'."
        Write-Warning "If the agent is not the one you expect, rebuild with Code-It-Build.ps1 -toolchain $rebuildToolchain -agent $imageAgents"
    } elseif ($imageAgentBinary -ne $agentBinary) {
        $recorded = if ($imageAgentBinary) { $imageAgentBinary } else { 'an unrecorded path' }
        Write-Warning "Image '$image' runs agent '$codeAgent' from $recorded, but agents/$codeAgent/config now names $agentBinary."
        Write-Warning "The image is out of date; rebuild it with Code-It-Build.ps1 -toolchain $rebuildToolchain -agent $imageAgents"
        exit 1
    }
}

# Git author info
$agentNameLower = $agentName.ToLower()
$onBehalfOf = $env:GIT_AUTHOR_NAME,$env:GIT_COMMITTER_NAME,"$(git -C $WorkDirToMount config --get user.name)" | Where-Object { $_ } | Select-Object -First 1
$onBehalfOf = $onBehalfOf -replace '^(\S+ for )+', ''
$gitAuthorName = "$agentName for $onBehalfOf"
$gitAuthorEmail = $env:GIT_AUTHOR_EMAIL,"$(git -C $WorkDirToMount config --get user.email)" | Where-Object { $_ } | Select-Object -First 1
if (-not $onBehalfOf -or -not $gitAuthorEmail) {
    Write-Warning "No git user.name or user.email found for $WorkDirToMount. The agent will not be able to commit.
    Set them with: git config --global user.name 'Your Name' ; git config --global user.email you@example.com"
}

# Locate the host package caches and mount the ones for the enabled package repos
# READ-ONLY, so the agent reuses downloads but can never write to the host cache.
# The image seeds its own writable caches from these mounts at startup.
$cacheMountArgs = @()
$cacheMountPrint = ""
function Add-CacheMount([string]$hostPath, [string]$containerPath, [string]$label) {
    $resolved = (Resolve-Path $hostPath).Path
    $script:cacheMountArgs += @('-v', "${resolved}:${containerPath}:ro")
    $script:cacheMountPrint += "`n                -v `"${resolved}:${containerPath}:ro`""
    "    Mounting $label read-only: $resolved"
}
$containerHome = "/home/$agentNameLower"

# NuGet
# https://learn.microsoft.com/en-us/nuget/consume-packages/managing-the-global-packages-and-cache-folders
if ($enabledPackageCaches -contains 'nuget') {
    $nugetPackages = ""
    if ($env:NUGET_PACKAGES -and (Test-Path -Path $env:NUGET_PACKAGES -PathType Container)) {
        $nugetPackages = $env:NUGET_PACKAGES
    } else {
        $nugetConfigs = @("$HOME/.nuget/NuGet/NuGet.Config", "$HOME/.config/NuGet/NuGet.Config")
        if ($env:APPDATA) { $nugetConfigs = @("$env:APPDATA/NuGet/NuGet.Config") + $nugetConfigs }
        foreach ($nugetConfig in $nugetConfigs) {
            if (Test-Path -Path $nugetConfig -PathType Leaf) {
                $globalPackagesFolder = $null
                try {
                    $globalPackagesFolder = ([xml](Get-Content $nugetConfig -Raw)).configuration.config.add |
                        Where-Object { $_.key -eq 'globalPackagesFolder' } |
                        Select-Object -First 1 -ExpandProperty value
                } catch {
                    # Like NuGet, silently ignore a malformed config file
                }
                if ($globalPackagesFolder -and (Test-Path -Path $globalPackagesFolder -PathType Container)) {
                    $nugetPackages = $globalPackagesFolder
                    break
                }
            }
        }
        if (-not $nugetPackages -and (Test-Path -Path "$HOME/.nuget/packages" -PathType Container)) {
            $nugetPackages = "$HOME/.nuget/packages"
        }
    }
    if ($nugetPackages) {
        Add-CacheMount $nugetPackages "$containerHome/.nuget/packages-host" 'NuGet package cache'
    } else {
        "    No NuGet package cache found; restore will use package sources only"
    }
}

# npm: NPM_CONFIG_CACHE, then the platform default (~/.npm, or %LocalAppData%\npm-cache)
if ($enabledPackageCaches -contains 'npm') {
    $npmCache = @($env:NPM_CONFIG_CACHE, "$env:LOCALAPPDATA/npm-cache", "$HOME/.npm") |
        Where-Object { $_ -and (Test-Path -Path $_ -PathType Container) } | Select-Object -First 1
    if ($npmCache) {
        Add-CacheMount $npmCache "$containerHome/.npm-host" 'npm package cache'
    } else {
        "    No npm package cache found; npm will download into the container"
    }
}

# Bun: BUN_INSTALL_CACHE_DIR, then the default ~/.bun/install/cache
if ($enabledPackageCaches -contains 'bun') {
    $bunCache = @($env:BUN_INSTALL_CACHE_DIR, "$HOME/.bun/install/cache") |
        Where-Object { $_ -and (Test-Path -Path $_ -PathType Container) } | Select-Object -First 1
    if ($bunCache) {
        Add-CacheMount $bunCache "$containerHome/.bun-host" 'Bun package cache'
    } else {
        "    No Bun package cache found; Bun will download into the container"
    }
}

# Translate the prompt, and any pass-through arguments, into the chosen agent's own
# command line, from the definition's cmd_* template. {args} expands to the agent
# args, {prompt} to the opening prompt. See
#   https://code.claude.com/docs/en/cli-reference
#   https://opencode.ai/docs/cli/
$agentCmd = @()
if ($headless) {
    $template = if ($promptSet) { $agentCmdHeadlessPrompt } else { $agentCmdHeadlessNoPrompt }
} else {
    $template = if ($promptSet) { $agentCmdInteractivePrompt } else { $agentCmdInteractiveNoPrompt }
}
foreach ($token in ($template -split '\s+' | Where-Object { $_ })) {
    switch ($token) {
        '{args}'   { $agentCmd += $agentArgs }
        '{prompt}' { if ($promptSet) { $agentCmd += $prompt } }
        default    { $agentCmd += $token }
    }
}

# One container at a time may use the AGENT_EXCLUSIVE_DIRS (opencode's SQLite session
# database corrupts when containers in different VMs share it). Slot 1 is the usual
# directory; when its lock is held by a running Code-It, take the next free slot, an
# empty copy under .code-it-instances/<agent>, carrying over AGENT_EXCLUSIVE_CARRY
# (credentials). A dry run takes no lock and copies nothing.
$exclusiveDirList = Split-CodeItList ($agentExclusiveDirs -replace ':', ',')
$instanceRoot  = $null
$exclusiveLock = $null
if ($exclusiveDirList.Count -gt 0) {
    $lockDir = "$agentSaveDir/.code-it-instances/$codeAgent"
    $slot = Get-CodeItSlot $lockDir "$PID" (-not $dryRun)
    if ($null -eq $slot) {
        Write-Warning "Could not lock $lockDir; sharing $agentExclusiveDirs with any other running container."
    } else {
        if (-not $dryRun) { $exclusiveLock = "$lockDir/$slot.lock" }
        if ($slot -ne 1) {
            $instanceRoot = "$lockDir/$slot"
            $newCopy = -not (Test-Path -Path $instanceRoot -PathType Container)
            foreach ($d in $exclusiveDirList) {
                Write-Warning ("Another $codeAgent container is using $agentSaveDir/$d.`n" +
                    "    Containers cannot share it (its session database would be corrupted), so this one uses its own copy:`n" +
                    "    $instanceRoot/$d")
            }
            if (-not $dryRun) {
                foreach ($d in $exclusiveDirList) {
                    $null = New-Item -ItemType Directory -Force -Path "$instanceRoot/$d"
                }
                foreach ($f in (Split-CodeItList ($agentExclusiveCarry -replace ':', ','))) {
                    $src = "$agentSaveDir/$f"
                    $dest = "$instanceRoot/$f"
                    if (-not (Test-Path -Path $src -PathType Leaf)) { continue }
                    if (-not (Test-Path -Path $dest) -or (Get-Item $src).LastWriteTimeUtc -gt (Get-Item $dest).LastWriteTimeUtc) {
                        $null = New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent)
                        Copy-Item -Path $src -Destination $dest -Force
                    }
                }
            }
            # A new copy with no credentials to carry (opencode-v2 keeps its login in
            # the database) starts logged out
            $hasLogin = $false
            foreach ($f in (Split-CodeItList ($agentExclusiveCarry -replace ':', ','))) {
                if ((Test-Path -Path "$agentSaveDir/$f" -PathType Leaf) -or (Test-Path -Path "$instanceRoot/$f" -PathType Leaf)) { $hasLogin = $true }
            }
            if ($newCopy -and -not $hasLogin) {
                Write-Warning ("This copy has no saved login: log in again inside the container. Later runs`n" +
                    "    that get this copy keep that login.")
            }
        }
    }
}

# Mount only the chosen agent's state, from its definition. An exclusive directory
# comes from this run's instance copy, when it has one.
$agentMountArgs = @()
$agentMountPrint = ""
foreach ($d in $agentStateDirList) {
    $src = if ($instanceRoot -and $exclusiveDirList -contains $d) { "$instanceRoot/$d" } else { "$agentSaveDir/$d" }
    $agentMountArgs += @('-v', "${src}:$containerHome/${d}")
    $agentMountPrint += "`n                -v `"${src}:$containerHome/${d}`""
}
foreach ($f in $agentStateFileList) {
    $agentMountArgs += @('-v', "$agentSaveDir/${f}:$containerHome/${f}")
    $agentMountPrint += "`n                -v `"$agentSaveDir/${f}:$containerHome/${f}`""
}

# Headless runs are one-shot: no tmux and no TTY, so the container exits when the
# agent does, and its output can be piped or redirected.
$ttyArgs     = if ($headless) { @('-i') }                        else { @('-it') }
$headlessEnv = if ($headless) { @('-e', 'CODE_AGENT_HEADLESS=1') } else { @() }
$headlessEnvPrint = if ($headless) { "`n                -e CODE_AGENT_HEADLESS=1" } else { "" }

# Extra run arguments: <saveDir>/run-args, then -environment, -envFile and -runArgs.
# They follow Code-It's own, so they can override them. Docker reads a bare `-e NAME`
# from the host's environment itself; for the Apple container CLI, Code-It does, keeping
# the printed command free of the value.
$extraRunArgs = Get-CodeItRunArgs $runArgsFile
if ($extraRunArgs.Count -gt 0) { "    Using run arguments from $runArgsFile" }
$extraRunArgs = @($extraRunArgs) + @($cliRunArgs)
# Printed one option per line: an argument starting with - begins a new line
$extraRunArgsPrint = ""
foreach ($a in $extraRunArgs) {
    $shown = if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    if ($a.StartsWith('-')) { $extraRunArgsPrint += "`n                $shown" } else { $extraRunArgsPrint += " $shown" }
}
$runExtraArgs = @()
$envFlag = $null
foreach ($a in $extraRunArgs) {
    if ($envFlag) {
        if ($runtime -eq 'container' -and -not $a.Contains('=') -and (Test-CodeItEnvSpec $a)) {
            $hostValue = [Environment]::GetEnvironmentVariable($a)
            if ($null -ne $hostValue) { $runExtraArgs += @($envFlag, "$a=$hostValue") }
        } else {
            $runExtraArgs += @($envFlag, $a)
        }
        $envFlag = $null
    } elseif ($a -eq '-e' -or $a -eq '--env') {
        $envFlag = $a
    } else {
        $runExtraArgs += $a
    }
}
if ($envFlag) { $runExtraArgs += $envFlag }

$agentCmdPrint = ($agentCmd | ForEach-Object {
    if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
}) -join ' '
if ($agentCmdPrint) { $agentCmdPrint = " $agentCmdPrint" }

@"
    $runtime run $ttyArgs --rm -p $portMapping $containerArgs `
                -e CODE_AGENT=`"$codeAgent`"$headlessEnvPrint `
                -e LANG=`"$containerLocale`" `
                -e GIT_AUTHOR_NAME=`"$gitAuthorName`" `
                -e GIT_AUTHOR_EMAIL=`"$gitAuthorEmail`" `
                -e GIT_COMMITTER_NAME=`"$gitAuthorName`" `
                -e GIT_COMMITTER_EMAIL=`"$gitAuthorEmail`" `
                -v `"$WorkDirToMount`:/work`"$agentMountPrint$cacheMountPrint$extraRunArgsPrint
            $image`:latest$agentCmdPrint
"@

if ($dryRun) {
    exit 0
}

$runRc = 0
try {
    & $runtime run $ttyArgs --rm -p $portMapping `
                $containerArgs `
                $headlessEnv `
                -e CODE_AGENT="$codeAgent" `
                -e LANG="$containerLocale" `
                -e GIT_AUTHOR_NAME="$gitAuthorName" `
                -e GIT_AUTHOR_EMAIL="$gitAuthorEmail" `
                -e GIT_COMMITTER_NAME="$gitAuthorName" `
                -e GIT_COMMITTER_EMAIL="$gitAuthorEmail" `
                -v "$WorkDirToMount`:/work" `
                $agentMountArgs `
                $cacheMountArgs `
                $runExtraArgs `
        $image`:latest $agentCmd
    if ($LASTEXITCODE -ne 0) { $runRc = $LASTEXITCODE }
} finally {
    # Free this run's exclusive slot, even on Ctrl-C
    if ($exclusiveLock) { Remove-Item -Force -Path $exclusiveLock -ErrorAction SilentlyContinue }
}

# Remember the image used, so later runs can take their toolchains from it.
Add-CodeItHistory $historyFile $image
exit $runRc

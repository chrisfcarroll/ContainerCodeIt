#! /usr/bin/env pwsh
<#
.SYNOPSIS
    Launches an Alpine Linux container with OpenCode, Claude Code, and a parameterisable tech stack.

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
    - A parameterisable tech stack (dotnet/node/bun and the nuget/npm package repos),
      chosen with switches and passed to docker build as build args
    - The enabled host package caches, mounted read-only
    - Port mappings

    The script supports optional image building and port mappings. Container mounts preserve:
    - ~/.config/opencode/      : OpenCode configuration (opencode.json, etc.)
    - ~/.local/share/opencode/ : OpenCode data and auth (auth.json, etc.)
    - ~/.claude/               : Claude credentials, settings, permissions, memory
    - ~/.claude.json           : Claude OAuth session data, MCP configs, preferences

.PARAMETER WorkDirToMount
    Host directory path to mount as /work in the container. Defaults to the current directory.

.PARAMETER opencode
    Run OpenCode in the container (default). Alias: -o

.PARAMETER claude
    Run Claude Code in the container. Alias: -c

.PARAMETER saveDir
    Host directory for storing agent configuration and state volumes. Created if missing.
    Default: ~/.config/code-it

.PARAMETER image
    Image name to run. Default: "code-it-alpine-<tech>", a slug of the resolved -toolChains
    list, e.g. code-it-alpine-dotnet or code-it-alpine-node-bun. Set it explicitly when
    running an image built with different tech, or give the same -toolChains.

.PARAMETER buildImage
    If specified, builds the image from the Dockerfile before running the container.
    Default: $false

.PARAMETER rebuildImage
    Like -buildImage, but first updates the "# last changed" cache-bust dates in the
    Dockerfile to today, forcing the agent install layers to rerun so the agents are
    updated. Default: $false

.PARAMETER dockerfileDir
    Directory containing the Dockerfile. Used with -buildImage.
    Defaults to this script's own directory.

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

.PARAMETER agentName
    Name of the agent running in the container. Used for Git author attribution and home
    directory naming. This must match the USER set in the Dockerfile for your image.
    Default: "Agent1"

.PARAMETER toolChains
    Comma-separated tech stacks to build into the image, passed to docker build as
    the DOTNET/NODE/BUN/PYTHON build args. Known: dotnet, node (aliases js-node,
    ts-node), bun (aliases js-bun, ts-bun), python (alias uv).
    Default: "dotnet,node". Alias: -stack.

.PARAMETER packageCaches
    Comma-separated package repos whose host cache is mounted read-only. 
    Known: nuget, npm, bun. 
    Default: the repos implied by -toolChains (dotnet->nuget, node->npm), so not specifying 
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
    .\Code-It.ps1 -buildImage
    Builds the image from the Dockerfile next to this script, then runs it.

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
    .\Code-It.ps1 -c --continue --model opus
    Passes those flags straight through to Claude Code.

.NOTES
    - The prompt and any pass-through arguments are translated into each agent's own
      command line: -prompt becomes `claude PROMPT` or `opencode --prompt PROMPT`, and
      with -headless it becomes `claude -p PROMPT` or `opencode run PROMPT`
    - Git author name and email are automatically captured from environment or git config
    - Volume mounts preserve both Claude and OpenCode state between container runs, so you
      can destroy the container and create a new one without logging in again
    - Alternatively, use ANTHROPIC_API_KEY (claude) or a provider API key env var (opencode)
      to avoid volume mounts for credentials
    - Host package caches are mounted read-only (never written) when the matching
      switch is on and a cache is found, so downloads are reused:
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
    [string]$saveDir        = "$HOME/.config/code-it",
    [string]$image          = "",
    [switch]$buildImage     = $false,
    [switch]$rebuildImage   = $false,
    [string]$dockerfileDir  = $PSScriptRoot,
    [ArgumentCompleter({ param($c, $p, $wordToComplete) @('docker', 'container') | Where-Object { $_ -like "$wordToComplete*" } })]
    [string]$runtime        = "",
    [int]$port              = 0,
    [string]$agentName      = "Agent1",
    [Alias('tech', 'stack')]
    [string]$toolChains     = "",
    [string]$packageCaches  = "",
    [string]$prompt         = "",
    [switch]$headless       = $false,
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

# Resolve which agent to run
if ($claude -and $opencode) {
    Write-Warning "Specify only one of -claude or -opencode."
    exit 1
}
$codeAgent = if ($claude) { "claude" } else { "opencode" }

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

# -rebuildImage implies -buildImage
if ($rebuildImage) { $buildImage = $true }

# Resolve -toolChains / -packageCaches. A list replaces the default set rather than
# toggling it, so there are no per-tech on/off parameters to clash with future tech
# names. -toolChains defaults to dotnet,node; -packageCaches defaults to the repos
# implied by -toolChains (dotnet->nuget, node->npm).
$enabledToolChains = Resolve-CodeItToolChains $toolChains
if ($null -eq $enabledToolChains) { exit 1 }
$enabledPackageCaches = Resolve-CodeItPackageCaches $packageCaches $enabledToolChains
if ($null -eq $enabledPackageCaches) { exit 1 }

# Default image name from the tool-chain list, e.g. code-it-alpine-dotnet or
# code-it-alpine-node-bun. An explicit -image overrides it.
if (-not $image) { $image = CodeIt-ImageName $enabledToolChains }

# Detect / validate the container runtime.
$runtime = Detect-CodeItRuntime $runtime
if ($null -eq $runtime) { exit 1 }
"    Using container runtime: $runtime"
"    Using code agent: $codeAgent"

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

# Create the save dir structure so mounts always work, even on first run.
# The .claude.json mount is a single file: pre-create it so the runtime does not
# create a directory in its place.
$null = New-Item -ItemType Directory -Force -Path "$saveDir/.config/opencode"
$null = New-Item -ItemType Directory -Force -Path "$saveDir/.local/share/opencode"
$null = New-Item -ItemType Directory -Force -Path "$saveDir/.claude"
if (-not (Test-Path -Path "$saveDir/.claude.json")) {
    Set-Content -Path "$saveDir/.claude.json" -Value '{}'
}
if ($codeAgent -eq "opencode") {
    $opencodeConfig = "$saveDir/.config/opencode/config.json"
    if (-not (Test-Path -Path $opencodeConfig)) {
        $configContents = @'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": "allow"
}
'@
        [System.IO.File]::WriteAllText($opencodeConfig, $configContents, [System.Text.UTF8Encoding]::new($false))
        "    Created OpenCode configuration: $opencodeConfig"
    }
}
else {
    $claudeSettings = "$saveDir/.claude/settings.json"
    if (-not (Test-Path -Path $claudeSettings)) {
        $settingsContents = @'
{
  "permissions": {
    "defaultMode": "auto"
  },
  "skipDangerousModePermissionPrompt": true
}
'@
        [System.IO.File]::WriteAllText($claudeSettings, $settingsContents, [System.Text.UTF8Encoding]::new($false))
        "    Created Claude Code settings: $claudeSettings"
    }
}
$saveDir = (Resolve-Path $saveDir).Path

"    Checking $image ..."

# List existing images in a runtime-appropriate way
if ($runtime -eq "docker") {
    $validImages = (docker images --format "{{.Repository}}:{{.Tag}}")
} else {
    $validImages = (container image ls)
}
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Could not list $runtime images. Is the $runtime daemon or service running?"
    exit 1
}
Write-Verbose ([string]::join("`n", @("    $runtime images") + $validImages)).ToString()

# Warn if the image was built for a different tool-chain set than the one we are
# about to run. Prefer the label Code-It-Build stamped on the image; fall back to
# the old name-based guess when the runtime cannot inspect labels.
$imageToolChains = ""
if ($runtime -eq "docker") {
    $imageToolChains = (docker image inspect --format '{{ index .Config.Labels "code-it.tool-chains" }}' "$image`:latest" 2>$null)
} else {
    $imageToolChains = (container image inspect --format '{{ index .Config.Labels "code-it.tool-chains" }}' "$image`:latest" 2>$null)
}
$imageToolChains = "$imageToolChains".Trim()
# A runtime that does not know the format prints its own error text; keep only a
# plausible comma-separated tool-chain list.
if ($imageToolChains -notmatch '^[a-z,]+$') { $imageToolChains = "" }
if (-not $imageToolChains -and $image -like 'code-it-alpine-*') {
    $imageToolChains = ($image.Substring('code-it-alpine-'.Length)) -replace '-', ','
}
if ($imageToolChains -and $imageToolChains -ne ($enabledToolChains -join ',')) {
    Write-Warning "Image '$image' looks built for tech '$imageToolChains' but -toolChains is '$($enabledToolChains -join ',')'."
    Write-Warning "Pass the same -toolChains used to build the image, or set -image explicitly."
}

# An existing image is only required when we are not about to build one.
if (-not $buildImage -and -not ($validImages | Where-Object { $_ -and ($_ -eq $image -or $_ -match "^$([regex]::Escape($image))[: ]") } | Select-Object -First 1)) {
    Write-Warning "$runtime image '$image' does not exist and -buildImage was not specified.
    Either build the image with -buildImage flag or ensure the image is available locally."
    exit 1
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

# Build image if requested. This is a thin shim: Code-It-Build.ps1 owns building,
# the Dockerfile's "# last changed" bump and the image label.
if ($buildImage) {
    "    Note: -buildImage is deprecated; use Code-It-Build.ps1. Delegating."
    $buildShimParams = @{
        toolChains    = ($enabledToolChains -join ',')
        packageCaches = ($enabledPackageCaches -join ',')
        image         = $image
        dockerfileDir = $dockerfileDir
        runtime       = $runtime
    }
    if ($rebuildImage) { $buildShimParams['rebuild'] = $true }
    & "$PSScriptRoot/Code-It-Build.ps1" @buildShimParams
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Code-It-Build.ps1 failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
}

# Translate the prompt, and any pass-through arguments, into the chosen agent's own
# command line, which the container entrypoint hands to the agent. See
#   https://code.claude.com/docs/en/cli-reference
#   https://opencode.ai/docs/cli/
$agentCmd = @()
if ($codeAgent -eq "claude") {
    # claude [flags] [PROMPT], and -p answers the prompt without going interactive
    if ($headless -and $promptSet) { $agentCmd += '-p' }
    $agentCmd += $agentArgs
    if ($promptSet) { $agentCmd += $prompt }
}
elseif ($headless) {
    # opencode run [flags] [MESSAGE] answers without starting the TUI
    $agentCmd += 'run'
    $agentCmd += $agentArgs
    if ($promptSet) { $agentCmd += $prompt }
}
else {
    # opencode --prompt MESSAGE opens the TUI with the message already sent
    if ($promptSet) { $agentCmd += @('--prompt', $prompt) }
    $agentCmd += $agentArgs
}

# Headless runs are one-shot: no tmux and no TTY, so the container exits when the
# agent does, and its output can be piped or redirected.
$ttyArgs     = if ($headless) { @('-i') }                        else { @('-it') }
$headlessEnv = if ($headless) { @('-e', 'CODE_AGENT_HEADLESS=1') } else { @() }
$headlessEnvPrint = if ($headless) { "`n                -e CODE_AGENT_HEADLESS=1" } else { "" }

$agentCmdPrint = ($agentCmd | ForEach-Object {
    if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
}) -join ' '
if ($agentCmdPrint) { $agentCmdPrint = " $agentCmdPrint" }

@"
    $runtime run $ttyArgs --rm -p $portMapping $containerArgs `
                -e CODE_AGENT=`"$codeAgent`"$headlessEnvPrint `
                -e GIT_AUTHOR_NAME=`"$gitAuthorName`" `
                -e GIT_AUTHOR_EMAIL=`"$gitAuthorEmail`" `
                -e GIT_COMMITTER_NAME=`"$gitAuthorName`" `
                -e GIT_COMMITTER_EMAIL=`"$gitAuthorEmail`" `
                -v `"$WorkDirToMount`:/work`" `
                -v `"$saveDir/.claude`:/home/$agentNameLower/.claude`" `
                -v `"$saveDir/.claude.json`:/home/$agentNameLower/.claude.json`" `
                -v `"$saveDir/.config/opencode`:/home/$agentNameLower/.config/opencode`" `
                -v `"$saveDir/.local/share/opencode`:/home/$agentNameLower/.local/share/opencode`"$cacheMountPrint
            $image`:latest$agentCmdPrint
"@

if ($dryRun) {
    exit 0
}

& $runtime run $ttyArgs --rm -p $portMapping `
            $containerArgs `
            $headlessEnv `
            -e CODE_AGENT="$codeAgent" `
            -e GIT_AUTHOR_NAME="$gitAuthorName" `
            -e GIT_AUTHOR_EMAIL="$gitAuthorEmail" `
            -e GIT_COMMITTER_NAME="$gitAuthorName" `
            -e GIT_COMMITTER_EMAIL="$gitAuthorEmail" `
            -v "$WorkDirToMount`:/work" `
            -v "$saveDir/.claude:/home/$agentNameLower/.claude" `
            -v "$saveDir/.claude.json:/home/$agentNameLower/.claude.json" `
            -v "$saveDir/.config/opencode:/home/$agentNameLower/.config/opencode" `
            -v "$saveDir/.local/share/opencode:/home/$agentNameLower/.local/share/opencode" `
            $cacheMountArgs `
    $image`:latest $agentCmd

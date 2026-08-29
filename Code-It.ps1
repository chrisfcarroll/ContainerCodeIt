#! /usr/bin/env pwsh
<#
.SYNOPSIS
    Launches a container with Alpine Linux, Claude Code AND OpenCode, and .NET development tools.

.DESCRIPTION
    Creates and runs a container for development using Claude Code or OpenCode as an agent.

    Picks a container runtime automatically:
    - On macOS, uses the Apple container CLI (container) if installed
    - Otherwise uses Docker if installed
    - Otherwise suggests the best runtime to install for the current platform
    Use -runtime to force one.

    The script recognises:
    - Volume mounts for code repositories and agent configuration
    - Git author environment variables or config settings (name and email)
    - Paths to preserve agent credentials, settings, and session data across container runs
    - Port mappings

    The script supports optional image building and port mappings. Container mounts preserve:
    - ~/.local/share/opencode/ : OpenCode data and auth (auth.json, etc.)
    - ~/.claude/               : Claude credentials, settings, permissions, memory
    - ~/.claude.json           : Claude OAuth session data, MCP configs, preferences

.PARAMETER WorkDirToMount
    Host directory path to mount as /repos in the container. Defaults to the current directory.

.PARAMETER opencode
    Run OpenCode in the container (default). Alias: -o

.PARAMETER claude
    Run Claude Code in the container. Alias: -c

.PARAMETER saveDir
    Host directory for storing agent configuration and state volumes. Created if missing.
    Default: ~/.config/code-it

.PARAMETER image
    Image name to run. Default: "code-it-alpine-dotnet"

.PARAMETER buildImage
    If specified, builds the image from the Dockerfile before running the container.
    Default: $false

.PARAMETER dockerfileDir
    Directory containing the Dockerfile. Used with -buildImage.
    Defaults to this script's own directory.

.PARAMETER runtime
    Container runtime to use: "docker" or "container".
    Default: auto-detected as described above.

.PARAMETER portsMap
    Array of port mappings in "host:container" format. Default: @("0:3000","0:3001")
    for docker (0 auto-assigns a free host port, so multiple containers can run at
    once without port collisions), @("3000:3000","3001:3001") for the Apple container
    runtime. Maximum of 2 port mappings supported; additional mappings are ignored.

.PARAMETER agentName
    Name of the agent running in the container. Used for Git author attribution and home
    directory naming. This must match the USER set in the Dockerfile for your image.
    Default: "Agent1"

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
    .\Code-It.ps1 -portsMap @("8000:3000", "8001:3001")
    Runs the container with custom port mappings.

.NOTES
    - Git author name and email are automatically captured from environment or git config
    - Volume mounts preserve both Claude and OpenCode state between container runs, so you
      can destroy the container and create a new one without logging in again
    - Alternatively, use ANTHROPIC_API_KEY (claude) or a provider API key env var (opencode)
      to avoid volume mounts for credentials

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
#   │ ~/.local/share/opencode/ │ OpenCode data and auth (auth.json, etc.)                       │
#   └──────────────────────────┴────────────────────────────────────────────────────────────────┘

[CmdletBinding()]
param (
    [string]$WorkDirToMount = (Resolve-Path '.').Path,
    [Alias('c')]
    [switch]$claude         = $false,
    [Alias('o')]
    [switch]$opencode       = $false,
    [string]$saveDir        = "$HOME/.config/code-it",
    [string]$image          = "code-it-alpine-dotnet",
    [switch]$buildImage     = $false,
    [string]$dockerfileDir  = $PSScriptRoot,
    [string]$runtime        = "",
    [string[]]$portsMap     = @(),
    [string]$agentName      = "Agent1",
    [switch]$help           = $false,
    [switch]$dryRun         = $false
)

# Handle help request
if ($help) {
    Get-Help $PSCommandPath -Full
    exit 0
}

# Resolve which agent to run
if ($claude -and $opencode) {
    Write-Warning "Specify only one of -claude or -opencode."
    exit 1
}
$codeAgent = if ($claude) { "claude" } else { "opencode" }

# $IsMacOS/$IsLinux are not defined in Windows PowerShell 5.1, so treat unset as false
$onMacOS = $IsMacOS -eq $true
$onLinux = $IsLinux -eq $true

# Detect / validate the container runtime.
# On macOS prefer the Apple container CLI if present; otherwise use docker if present;
# otherwise suggest what is best for the current platform.
if (-not $runtime) {
    if ($onMacOS -and (Get-Command container -EA Silent)) {
        $runtime = "container"
    }
    elseif (Get-Command docker -EA Silent) {
        $runtime = "docker"
    }
    elseif (Get-Command container -EA Silent) {
        $runtime = "container"
    }
    else {
        Write-Warning "No container runtime found."
        if ($onMacOS) {
            Write-Host "On macOS, the best options are:"
            Write-Host "  - Apple container CLI (native, lightweight):"
            Write-Host "      https://github.com/apple/container/blob/main/docs/tutorials/start-here.md"
            Write-Host "  - Docker Desktop: https://docs.docker.com/desktop/setup/install/mac-install/"
        }
        elseif ($onLinux) {
            Write-Host "On Linux, the best option is Docker Engine:"
            Write-Host "      https://docs.docker.com/engine/install/"
            Write-Host "  e.g. Debian/Ubuntu: sudo apt-get install docker.io"
            Write-Host "       Alpine:        doas apk add docker"
            Write-Host "       Fedora:        sudo dnf install docker"
        }
        else {
            Write-Host "On Windows, the best option is Docker Desktop with WSL2:"
            Write-Host "      https://docs.docker.com/desktop/setup/install/windows-install/"
        }
        exit 1
    }
}
elseif ($runtime -notin @("docker", "container")) {
    Write-Warning "Unknown runtime '$runtime'. Valid values are 'docker' or 'container'."
    exit 1
}
elseif (-not (Get-Command $runtime -EA Silent)) {
    Write-Warning "Requested runtime '$runtime' not found. Please install it and ensure it is in your PATH."
    exit 1
}
"    Using container runtime: $runtime"
"    Using code agent: $codeAgent"

# Ensure required commands
if (-not (Get-Command git -EA Silent)) {
    Write-Warning "Git command not found. Please install Git and ensure it is in your PATH."
    exit 1
}

# Default ports per runtime: docker supports host port 0 = auto-assign a free port
if ($portsMap.Count -eq 0) {
    $portsMap = if ($runtime -eq "docker") { @("0:3000", "0:3001") } else { @("3000:3000", "3001:3001") }
}

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
New-Item -ItemType Directory -Force -Path "$saveDir/.local/share/opencode"
New-Item -ItemType Directory -Force -Path "$saveDir/.claude"
if (-not (Test-Path -Path "$saveDir/.claude.json")) {
    Set-Content -Path "$saveDir/.claude.json" -Value '{}'
}
$saveDir = (Resolve-Path $saveDir).Path

"    Checking $image ..."

# List existing images in a runtime-appropriate way
if ($runtime -eq "docker") {
    $validImages = (docker images --format "{{.Repository}}:{{.Tag}}")
} else {
    $validImages = (container image ls)
}
Write-Verbose ([string]::join("`n", @("    $runtime images") + $validImages)).ToString()

if ($buildImage -and -not (Test-Path -Path "$dockerfileDir/Dockerfile")) {
    Write-Warning "You asked for buildImage, but Dockerfile not found in directory: $dockerfileDir"
    exit 1
}
elseif (-not $buildImage -and -not ($validImages | Where-Object { $_ -and ($_ -eq $image -or $_ -match "^$([regex]::Escape($image))[: ]") } | Select-Object -First 1)) {
    Write-Warning "$runtime image '$image' does not exist and -buildImage was not specified.
    Either build the image with -buildImage flag or ensure the image is available locally."
    exit 1
}

# Git author info
$agentNameLower = $agentName.ToLower()
$onBehalfOf = $env:GIT_AUTHOR_NAME,$env:GIT_COMMITTER_NAME,"$(git config --get user.name)" | Where-Object { $_ } | Select-Object -First 1
$gitAuthorName = "$agentName for $onBehalfOf"
$gitAuthorEmail = $env:GIT_AUTHOR_EMAIL,"$(git config --get user.email)" | Where-Object { $_ } | Select-Object -First 1

# Build image if requested
if ($buildImage) {
    $dockerfileDir = (Resolve-Path $dockerfileDir).Path
    & $runtime build -t "$image`:latest" $dockerfileDir
}

# Handle port mappings
if ($portsMap.Count -gt 2) {
    Write-Warning "This script only handles two port mappings. Extra mappings will be ignored."
}
# Pad to 2 port mappings (docker: 0 auto-assigns a free host port;
# the Apple container runtime needs fixed ports)
if ($portsMap.Count -lt 2) {
    $pad = if ($runtime -eq "docker") { @("0:3000", "0:3001") } else { @("3000:3000", "3001:3001") }
    $portsMap = ($portsMap + $pad) | Select-Object -First 2
}

@"
    $runtime run -it -p $($portsMap[0]) -p $($portsMap[1]) `
                -e CODE_AGENT=`"$codeAgent`" `
                -e GIT_AUTHOR_NAME=`"$gitAuthorName`" `
                -e GIT_AUTHOR_EMAIL=`"$gitAuthorEmail`" `
                -v `"$WorkDirToMount`:/repos`" `
                -v `"$saveDir/.claude`:/home/$agentNameLower/.claude`" `
                -v `"$saveDir/.claude.json`:/home/$agentNameLower/.claude.json`" `
                -v `"$saveDir/.local/share/opencode`:/home/$agentNameLower/.local/share/opencode`" `
            $image`:latest
"@

if ($dryRun) {
    exit 0
}

& $runtime run -it -p $($portsMap[0]) -p $($portsMap[1]) `
            -e CODE_AGENT="$codeAgent" `
            -e GIT_AUTHOR_NAME="$gitAuthorName" `
            -e GIT_AUTHOR_EMAIL="$gitAuthorEmail" `
            -v "$WorkDirToMount`:/repos" `
            -v "$saveDir/.claude:/home/$agentNameLower/.claude" `
            -v "$saveDir/.claude.json:/home/$agentNameLower/.claude.json" `
            -v "$saveDir/.local/share/opencode:/home/$agentNameLower/.local/share/opencode" `
    $image`:latest

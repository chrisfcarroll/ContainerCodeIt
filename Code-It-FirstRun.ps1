#! /usr/bin/env pwsh

<#
.SYNOPSIS
    Interactive first-run setup: detect, choose, build, carry over agent logins.

.DESCRIPTION
    Asks which container runtime to use, showing which of docker, Apple's container
    and wslc are found and suggesting the platform's own (container on macOS, wslc
    on Windows, docker elsewhere) when it is found, and saves the answer as code-it's
    default runtime (Code-It-Defaults.ps1 -runtime changes it later).

    Delegates toolchain, agent and build selection to Code-It-Build.ps1, offers to copy host
    agent state into the save dir without overwriting existing files, sets each
    agent's config there to run without permission prompts (AGENT_PERMISSIONS), and
    prints the Code-It.ps1 command to start.

.PARAMETER saveDir
    Where agent state is kept and copied. Default: ~/.config/code-it

.PARAMETER workDir
    Host directory to mount, at /work/<parent>/<name> (its parent's and its own
    names, for agents' per-directory memory). Default: .

.PARAMETER toolchain
    Select toolchains (skips that question).

.PARAMETER agents
    Select agents (skips that question).

.PARAMETER image
    Image name to build.

.PARAMETER dockerfileDir
    Directory containing the Dockerfile.

.PARAMETER runtime
    docker, container or wslc (skips that question, and is saved as the default).
    Default: asked; with -yes, the platform's own if found, else auto-detected.

.PARAMETER codeItBuild
    Code-It-Build.ps1 launcher to invoke. Default: sibling.

.PARAMETER yes
    Accept the defaults: no questions.

.PARAMETER dryRun
    Do everything except build and copy; print what would happen.

.EXAMPLE
    .\Code-It-FirstRun.ps1 -yes
#>

[CmdletBinding(PositionalBinding = $false)]
param (
    [string]$saveDir       = "$HOME/.config/code-it",
    [string]$workDir       = ".",
    [string]$toolchain    = "",
    [string]$agents        = "",
    [string]$image         = "",
    [string]$dockerfileDir = "",
    [string]$runtime       = "",
    [string]$codeItBuild   = "",
    [switch]$yes           = $false,
    [switch]$dryRun        = $false,
    [Alias('h')]
    [switch]$help          = $false
)

# Defaults naming this script's own directory are set here, not in param(): Windows
# PowerShell 5.1 leaves $PSScriptRoot empty in param() when run with -File.
if (-not $codeItBuild) { $codeItBuild = Join-Path $PSScriptRoot 'Code-It-Build.ps1' }
$codeItDefaults = Join-Path $PSScriptRoot 'Code-It-Defaults.ps1'

if ($help) {
    Get-Help $PSCommandPath -Full
    exit 0
}

. "$PSScriptRoot/lib/CodeItCommon.ps1"

$agentsDir = Join-Path $PSScriptRoot 'agents'

# Git configuration and agent-state copying remain first-run's responsibility.
if (-not (Get-Command git -EA Silent)) {
    Write-Warning "Git command not found. Please install Git and ensure it is in your PATH."
    exit 1
}

# Child scripts run in the same PowerShell as this script: pwsh, or Windows PowerShell
# 5.1, which is all a new Windows machine has.
$powershellExe = Get-CodeItPowerShellExe
if (-not $powershellExe) { Write-Warning 'Cannot find the PowerShell executable to run Code-It-Build.ps1.'; exit 1 }

# The container runtime: asked, unless given, and saved as the default, so Code-It,
# Code-It-Build and Code-It-Doctor use it from now on.
if (-not $runtime -and (Get-CodeItRuntimesFound).Count) {
    $runtime = Get-CodeItPreferredRuntime
    if (-not $yes) {
        Write-Host ""
        do { $choice = Read-CodeItRuntime $runtime } until ($choice.ok)
        $runtime = $choice.runtime
    }
}
if ($runtime) {
    $defaultsArgs = @('-NoProfile', '-File', $codeItDefaults, '-saveDir', $saveDir, '-runtime', $runtime)
    if ($dryRun) { $defaultsArgs += '-dryRun' }
    & $powershellExe @defaultsArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# Code-It-Build owns host detection, selection, runtime detection and build confirmation.
$selectionFile = Join-Path ([IO.Path]::GetTempPath()) ("code-it-first-run-selection-" + [Guid]::NewGuid().ToString('N'))
$buildParams = @{ interactive = $true; selectionFile = $selectionFile }
if ($toolchain) { $buildParams['toolchain'] = $toolchain }
if ($agents) { $buildParams['agent'] = $agents }
if ($image) { $buildParams['image'] = $image }
if ($dockerfileDir) { $buildParams['dockerfileDir'] = $dockerfileDir }
if ($runtime) { $buildParams['runtime'] = $runtime }
if ($saveDir -ne "$HOME/.config/code-it") { $buildParams['saveDir'] = $saveDir }
if ($yes) { $buildParams['yes'] = $true }
if ($dryRun) { $buildParams['dryRun'] = $true }

Write-Host "  $codeItBuild -interactive"
$buildArgumentList = @('-NoProfile', '-File', $codeItBuild)
foreach ($name in $buildParams.Keys) {
    $value = $buildParams[$name]
    if ($value -is [bool]) {
        if ($value) { $buildArgumentList += "-$name" }
    } else {
        $buildArgumentList += @("-$name", [string]$value)
    }
}
try {
    & $powershellExe @buildArgumentList
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if (-not (Test-Path -Path $selectionFile -PathType Leaf)) { exit 0 }
    $selectionLines = Get-Content -Path $selectionFile
} finally {
    Remove-Item -Path $selectionFile -Force -EA Silent
}
$chosenAgentsRaw = ($selectionLines | Where-Object { $_ -like 'agents=*' } | Select-Object -First 1) -replace '^agents=', ''
$chosenAgents = @($chosenAgentsRaw -split ',' | Where-Object { $_ })
if (-not $chosenAgents) { Write-Warning 'no agents selected.'; exit 1 }

# 5. Copy agent host state into the save dir, preserving layout, never overwriting.
function Copy-CodeItTreeNoClobber([string]$src, [string]$dest) {
    $null = New-Item -ItemType Directory -Force -Path $dest
    foreach ($d in (Get-ChildItem -Force -Recurse -Directory -Path $src)) {
        $rel = $d.FullName.Substring($src.Length).TrimStart('/', '\')
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $dest $rel)
    }
    foreach ($f in (Get-ChildItem -Force -Recurse -File -Path $src)) {
        $rel = $f.FullName.Substring($src.Length).TrimStart('/', '\')
        $target = Join-Path $dest $rel
        if (-not (Test-Path -Path $target)) {
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent)
            Copy-Item -Path $f.FullName -Destination $target
        }
    }
}

foreach ($a in $chosenAgents) {
    $hostPaths = @()
    foreach ($k in @('AGENT_STATE_DIRS', 'AGENT_STATE_FILES')) {
        $v = Get-CodeItAgentConfig $agentsDir $a $k
        if ($v) {
            foreach ($p in ($v -split ':')) {
                if ($p -and (Test-Path -Path (Join-Path $HOME $p))) { $hostPaths += $p }
            }
        }
    }
    if (-not $hostPaths) { continue }
    $subdir = Get-CodeItAgentConfig $agentsDir $a 'AGENT_SAVE_SUBDIR'
    $agentSaveDir = if ($subdir) { Join-Path $saveDir $subdir } else { $saveDir }

    Write-Host ""
    Write-Host "Agent '$a' has host configuration that can be copied into $agentSaveDir`:"
    foreach ($p in $hostPaths) { Write-Host "  ~/$p" }
    Write-Host "This copies credentials, which will be readable by the agent in the container."

    $doCopy = $true
    if (-not $yes -and -not $dryRun) {
        $answer = Read-Host "Copy them? [y/N]"
        $doCopy = ($answer -match '^[Yy]')
    }
    if ($doCopy) {
        foreach ($p in $hostPaths) {
            $src = Join-Path $HOME $p
            $dest = Join-Path $agentSaveDir $p
            if ($dryRun) {
                Write-Host "      would copy ~/$p -> $dest (existing files kept)"
            } elseif (Test-Path -Path $src -PathType Container) {
                Copy-CodeItTreeNoClobber $src $dest
                Write-Host "      copied ~/$p -> $dest (existing files kept)"
            } elseif (Test-Path -Path $dest) {
                Write-Host "      exists, not overwritten: $dest"
            } else {
                $null = New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent)
                Copy-Item -Path $src -Destination $dest
                Write-Host "      copied ~/$p -> $dest"
            }
        }
    }
}

# 6. Whether or not host state was copied, fill in the agent's default configuration
# and set it to work free of permissions interruption: the container is the sandbox.
foreach ($a in $chosenAgents) {
    if (-not (Get-CodeItAgentConfig $agentsDir $a 'AGENT_PERMISSIONS')) { continue }
    $subdir = Get-CodeItAgentConfig $agentsDir $a 'AGENT_SAVE_SUBDIR'
    $agentSaveDir = if ($subdir) { Join-Path $saveDir $subdir } else { $saveDir }
    Write-Host ""
    Write-Host "Setting agent '$a' to run without permission prompts in the container:"
    $defaultConfigDir = Join-Path $agentsDir (Join-Path $a 'default-config')
    if (-not $dryRun -and (Test-Path -Path $defaultConfigDir -PathType Container)) {
        Copy-CodeItTreeNoClobber (Resolve-Path $defaultConfigDir).Path $agentSaveDir
    }
    $null = Set-CodeItAgentPermissions $agentsDir $a $agentSaveDir $dryRun
}

# 7. Print the code-it command to start.
Write-Host ""
Write-Host "Start an agent with:"
foreach ($a in $chosenAgents) {
    $start = "  $PSScriptRoot/Code-It.ps1 -agent $a -WorkDirToMount $workDir"
    if ($saveDir -ne "$HOME/.config/code-it") { $start += " -saveDir $saveDir" }
    Write-Host $start
}

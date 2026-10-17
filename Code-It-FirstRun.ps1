#! /usr/bin/env pwsh

<#
.SYNOPSIS
    Interactive first-run setup: detect, choose, build, carry over agent logins.

.DESCRIPTION
    Delegates runtime and build selection to Code-It-Build.ps1, offers to copy host
    agent state into the save dir without overwriting existing files, and prints the
    Code-It.ps1 command to start.

.PARAMETER saveDir
    Where agent state is kept and copied. Default: ~/.config/code-it

.PARAMETER workDir
    Host directory mounted as /work. Default: .

.PARAMETER toolchain
    Select toolchains (skips that question).

.PARAMETER agents
    Select agents (skips that question).

.PARAMETER image
    Image name to build.

.PARAMETER dockerfileDir
    Directory containing the Dockerfile.

.PARAMETER runtime
    docker or container. Default: auto-detected.

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
    [string]$dockerfileDir = $PSScriptRoot,
    [string]$runtime       = "",
    [string]$codeItBuild   = (Join-Path $PSScriptRoot 'Code-It-Build.ps1'),
    [switch]$yes           = $false,
    [switch]$dryRun        = $false,
    [Alias('h')]
    [switch]$help          = $false
)

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

# Code-It-Build owns host detection, selection, runtime detection and build confirmation.
$selectionFile = Join-Path ([IO.Path]::GetTempPath()) ("code-it-first-run-selection-" + [Guid]::NewGuid().ToString('N'))
$buildParams = @{ interactive = $true; selectionFile = $selectionFile }
if ($toolchain) { $buildParams['toolchain'] = $toolchain }
if ($agents) { $buildParams['agent'] = $agents }
if ($image) { $buildParams['image'] = $image }
if ($dockerfileDir -ne $PSScriptRoot) { $buildParams['dockerfileDir'] = $dockerfileDir }
if ($runtime) { $buildParams['runtime'] = $runtime }
if ($yes) { $buildParams['yes'] = $true }
if ($dryRun) { $buildParams['dryRun'] = $true }

Write-Host "  $codeItBuild -interactive"
$powershellExe = (Get-Command pwsh -CommandType Application -EA Stop | Select-Object -First 1).Source
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

# 6. Print the code-it command to start.
Write-Host ""
Write-Host "Start an agent with:"
foreach ($a in $chosenAgents) {
    $start = "  $PSScriptRoot/Code-It.ps1 -agent $a -WorkDirToMount $workDir"
    if ($saveDir -ne "$HOME/.config/code-it") { $start += " -saveDir $saveDir" }
    Write-Host $start
}

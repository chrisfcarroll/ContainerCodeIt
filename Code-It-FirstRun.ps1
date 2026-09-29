#! /usr/bin/env pwsh
<#
.SYNOPSIS
    Interactive first-run setup: detect, choose, build, carry over agent logins.

.DESCRIPTION
    Detects the container runtime, host toolchains and agents, asks what to include,
    runs Code-It-Build.ps1, offers to copy agent state into the save dir, and prints
    the Code-It.ps1 command to start.

.PARAMETER saveDir
    Where agent state is kept and copied. Default: ~/.config/code-it

.PARAMETER workDir
    Host directory mounted as /work. Default: .

.PARAMETER toolchain
    Preselect toolchains (skips the question).

.PARAMETER agents
    Preselect agents (skips the question).

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
$toolchainsDir = Join-Path $PSScriptRoot 'toolchains'
$packageCachesDir = Join-Path $PSScriptRoot 'package-caches'

# 1. Container runtime and git, reusing code-it's detection and advice.
$runtime = Detect-CodeItRuntime $runtime
if ($null -eq $runtime) { exit 1 }
if (-not (Get-Command git -EA Silent)) {
    Write-Warning "Git command not found. Please install Git and ensure it is in your PATH."
    exit 1
}

# 2. Detect host toolchains and agents.
$toolchainAvailable = @(Get-CodeItListToolchains $toolchainsDir)
$agentsAvailable = @()
foreach ($a in $script:CodeItDefaultAgents) {
    if (Test-CodeItAgentExists $agentsDir $a) { $agentsAvailable += $a }
}
foreach ($a in (Get-CodeItListAgents $agentsDir)) {
    if ($agentsAvailable -notcontains $a) { $agentsAvailable += $a }
}

$detectedToolchain = @($toolchainAvailable | Where-Object { Test-CodeItToolchainDetected $toolchainsDir $_ })
$detectedAgents     = @($agentsAvailable | Where-Object { Test-CodeItAgentDetected $agentsDir $_ })

# Parse-answer ANSWER ITEMS...: numbers (1-based) or names -> comma list
function ConvertTo-CodeItSelection([string]$answer, [string[]]$items) {
    $out = @()
    foreach ($tok in ($answer -split '[,\s]+' | Where-Object { $_ })) {
        if ($tok -match '^\d+$') {
            $idx = [int]$tok
            if ($idx -ge 1 -and $idx -le $items.Count) { $out += $items[$idx - 1] }
        } elseif ($items -contains $tok) {
            $out += $tok
        }
    }
    return ($out | Select-Object -Unique)
}

# Read-CodeItChoice LABEL DEFAULT ITEMS...: numbered prompt -> selection
function Read-CodeItChoice([string]$label, [string]$default, [string[]]$items) {
    if ($yes) { return $default }
    Write-Host "$label (detected marked *):"
    for ($i = 0; $i -lt $items.Count; $i++) {
        $flag = ''
        if ($detectedToolchain -contains $items[$i] -or $detectedAgents -contains $items[$i]) { $flag = ' *' }
        Write-Host ("  {0}) {1}{2}" -f ($i + 1), $items[$i], $flag)
    }
    $answer = Read-Host "Choose $label [$($default -replace ' ', ',')]"
    if (-not $answer) { return $default }
    return ((ConvertTo-CodeItSelection $answer $items) -join ' ')
}

Write-Host "== ContainerCodeIt first run =="
Write-Host "Using container runtime: $runtime"

if ($toolchain) {
    $chosenToolchain = Resolve-CodeItToolchain $toolchain $toolchainsDir
    if ($null -eq $chosenToolchain) { exit 1 }
} else {
    $defaultTcs = if ($detectedToolchain.Count) { $detectedToolchain -join ' ' } else { $script:CodeItDefaultToolchain -join ' ' }
    $chosenToolchain = Read-CodeItChoice "Toolchains to build" $defaultTcs $toolchainAvailable
    $chosenToolchain = Split-CodeItList ($chosenToolchain -replace ' ', ',')
}
if (-not $chosenToolchain) { Write-Warning "no toolchains selected."; exit 1 }

if ($agents) {
    $chosenAgents = Resolve-CodeItAgents $agents $agentsDir
    if ($null -eq $chosenAgents) { exit 1 }
} else {
    $defaultAgents = if ($detectedAgents.Count) { $detectedAgents -join ' ' } else { $script:CodeItDefaultAgents -join ' ' }
    $chosenAgents = Read-CodeItChoice "Agents to install" $defaultAgents $agentsAvailable
    $chosenAgents = Split-CodeItList ($chosenAgents -replace ' ', ',')
}
if (-not $chosenAgents) { Write-Warning "no agents selected."; exit 1 }

# 3/4. Show the build command, confirm, run it.
$buildParams = @{
    toolchain = ($chosenToolchain -join ',')
    agent      = ($chosenAgents -join ',')
    runtime    = $runtime
}
if ($image) { $buildParams['image'] = $image }
if ($dockerfileDir -ne $PSScriptRoot) { $buildParams['dockerfileDir'] = $dockerfileDir }

Write-Host ""
Write-Host "Build command:"
Write-Host "  $codeItBuild -toolchain $($buildParams.toolchain) -agent $($buildParams.agent) -runtime $runtime"

if (-not $yes) {
    $answer = Read-Host "Build now? [Y/n]"
    if ($answer -match '^[Nn]') { Write-Host "Aborted."; exit 0 }
}

if ($dryRun) {
    Write-Host "    (dry run: not building)"
} else {
    # Reset so a stale native exit code cannot be mistaken for the build's.
    $global:LASTEXITCODE = 0
    & $codeItBuild @buildParams
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

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

    Write-Host ""
    Write-Host "Agent '$a' has host configuration that can be copied into $saveDir`:"
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
            $dest = Join-Path $saveDir $p
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

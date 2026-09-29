#! /usr/bin/env pwsh
<#
.SYNOPSIS
    Builds the code-it container image, selecting toolchains, caches and agents.

.DESCRIPTION
    Builds the Alpine image from the Dockerfile with the requested toolchains,
    package caches and coding agents, and labels the image with that resolution so
    Code-It.ps1 can check it rather than guess from the image name. Code-It.ps1's
    -buildImage and -rebuildImage flags delegate here.

    The agents' install layers live in agents/<name>/install.dockerfile. This script
    assembles them into the Dockerfile (replacing the "# @@CODE_IT_AGENT_INSTALLS@@"
    marker) and writes /etc/code-it-agents, the name=binary map go.sh reads.

.PARAMETER toolchain
    Comma-separated toolchains to build. Known: dotnet, node (aliases js-node,
    ts-node), bun (aliases js-bun, ts-bun), python (alias uv). Default: "dotnet,node".
    Alias: -stack.

.PARAMETER packageCaches
    Comma-separated package repos to support, independent of -toolchain. Known:
    nuget, npm, bun. Default: the repos implied by -toolchain (dotnet->nuget,
    node->npm). An explicit, empty list means no package caches.

.PARAMETER agent
    Comma-separated agents to install. Default: opencode,claude.

.PARAMETER listAgents
    List the available agents and exit.

.PARAMETER rebuild
    Bump the "# last changed" dates in the Dockerfile and selected agent install
    fragments to today first, so the agent install layers rerun and the agents update.

.PARAMETER image
    Image name to build. Default: "code-it-alpine-<chains>", a slug of the resolved
    -toolchain list.

.PARAMETER dockerfileDir
    Directory containing the Dockerfile. Defaults to this script's own directory.

.PARAMETER runtime
    Container runtime to use: "docker" or "container". Default: auto-detected.

.PARAMETER dryRun
    Print the build command without executing it.

.EXAMPLE
    .\Code-It-Build.ps1 -toolchain 'node,bun' -packageCaches npm -agent opencode

.EXAMPLE
    .\Code-It-Build.ps1 -rebuild
#>

[CmdletBinding(PositionalBinding = $false)]
param (
    [Alias('tech', 'stack')]
    [string]$toolchain    = "",
    [string]$packageCaches = "",
    [Alias('agents')]
    [string]$agent         = "",
    [switch]$listAgents    = $false,
    [switch]$rebuild       = $false,
    [string]$image         = "",
    [string]$dockerfileDir = $PSScriptRoot,
    [string]$runtime       = "",
    [switch]$dryRun        = $false,
    [Alias('h')]
    [switch]$help          = $false
)

if ($help) {
    Get-Help $PSCommandPath -Full
    exit 0
}

. "$PSScriptRoot/lib/CodeItCommon.ps1"

# The agent definitions live next to the Dockerfile when it ships them, else next
# to this script.
$agentsDir = Join-Path $dockerfileDir 'agents'
if (-not (Test-Path -Path $agentsDir -PathType Container)) { $agentsDir = Join-Path $PSScriptRoot 'agents' }

if ($listAgents) {
    foreach ($name in (Get-CodeItListAgents $agentsDir)) {
        $short = Get-CodeItAgentConfig $agentsDir $name 'AGENT_SHORT'
        if ($short) { "  {0,-10} -{1}" -f $name, $short } else { "  $name" }
    }
    exit 0
}

# Resolve the requested toolchains, package caches and agents. An explicit, empty
# -packageCaches means "no package caches", not "use the implied ones".
$enabledToolchain = Resolve-CodeItToolchain $toolchain
if ($null -eq $enabledToolchain) { exit 1 }
if ($PSBoundParameters.ContainsKey('packageCaches')) {
    $enabledPackageCaches = Resolve-CodeItPackageCaches $packageCaches $enabledToolchain
} else {
    $enabledPackageCaches = Resolve-CodeItPackageCaches "" $enabledToolchain
}
if ($null -eq $enabledPackageCaches) { exit 1 }
$enabledAgents = Resolve-CodeItAgents $agent $agentsDir
if ($null -eq $enabledAgents) { exit 1 }

if (-not $image) { $image = CodeIt-ImageName $enabledToolchain }

$runtime = Detect-CodeItRuntime $runtime
if ($null -eq $runtime) { exit 1 }

if (-not (Test-Path -Path "$dockerfileDir/Dockerfile" -PathType Leaf)) {
    Write-Warning "Dockerfile not found at: $dockerfileDir/Dockerfile"
    exit 1
}
$dockerfileDir = (Resolve-Path $dockerfileDir).Path

function Update-CodeItLastChanged([string]$file) {
    if (-not (Test-Path -Path $file -PathType Leaf)) { return }
    $today = [DateTime]::Today.ToString('yyyy-MM-dd')
    $text = [IO.File]::ReadAllText($file) -replace '# last changed [0-9]{4}-[0-9]{2}-[0-9]{2}', "# last changed $today"
    [IO.File]::WriteAllText($file, $text)
}

if ($rebuild) {
    Update-CodeItLastChanged "$dockerfileDir/Dockerfile"
    foreach ($a in $enabledAgents) {
        $install = Get-CodeItAgentConfig $agentsDir $a 'AGENT_INSTALL'
        if ($install) { Update-CodeItLastChanged (Join-Path $agentsDir (Join-Path $a $install)) }
    }
    "    Updated '# last changed' dates to $([DateTime]::Today.ToString('yyyy-MM-dd'))"
}

# Assemble the Dockerfile: replace the agent-install marker with the selected
# fragments plus the name=binary map go.sh reads.
$marker = '# @@CODE_IT_AGENT_INSTALLS@@'
$block = "# --- coding agents: $($enabledAgents -join ',') (assembled from agents/) ---`n"
foreach ($a in $enabledAgents) {
    $install = Get-CodeItAgentConfig $agentsDir $a 'AGENT_INSTALL'
    $fragmentPath = Join-Path $agentsDir (Join-Path $a $install)
    if (-not (Test-Path -Path $fragmentPath -PathType Leaf)) {
        Write-Warning "Agent '$a' has no install fragment at $fragmentPath"
        exit 1
    }
    $block += (Get-Content $fragmentPath -Raw)
    if (-not $block.EndsWith("`n")) { $block += "`n" }
}
$entries = foreach ($a in $enabledAgents) {
    $bin = Get-CodeItAgentConfig $agentsDir $a 'AGENT_BINARY'
    "'$a=$bin'"
}
# The marker sits after "USER agent1" (rightly: the install fragments above run as
# agent1, into its home). /etc is root-owned, so write the map as root and switch
# back for the rest of the file.
$block += "USER root`n"
$block += "RUN printf '%s\n' $($entries -join ' ') > /etc/code-it-agents`n"
$block += "USER agent1`n"

$base = ([IO.File]::ReadAllText("$dockerfileDir/Dockerfile")) -replace "`r`n", "`n"
$assembled = if ($base.Contains($marker)) { $base.Replace($marker, $block.TrimEnd("`n")) } else { $base }
# Keep the buildable Dockerfile small (Apple's builder fails above ~16 KB), without
# touching heredoc bodies such as go.sh.
$assembled = Remove-CodeItDockerfileComments $assembled

$buildContext = Join-Path ([IO.Path]::GetTempPath()) ("code-it-build-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $buildContext
[IO.File]::WriteAllText((Join-Path $buildContext 'Dockerfile'), $assembled, [System.Text.UTF8Encoding]::new($false))

try {
    # Build args for the toolchains and package caches, spelled the way the
    # Dockerfile's ARGs match them (uppercase), plus labels recording the resolution.
    $buildArgs = @()
    foreach ($tc in @('dotnet', 'node', 'bun', 'python')) {
        $buildArgs += @('--build-arg', "$($tc.ToUpper())=$(Bool-Arg ($enabledToolchain -contains $tc))")
    }
    foreach ($pc in @('nuget', 'npm')) {
        $buildArgs += @('--build-arg', "$($pc.ToUpper())=$(Bool-Arg ($enabledPackageCaches -contains $pc))")
    }
    $buildArgs += @('--label', "code-it.tool-chains=$($enabledToolchain -join ',')")
    $buildArgs += @('--label', "code-it.package-caches=$($enabledPackageCaches -join ',')")
    $buildArgs += @('--label', "code-it.agents=$($enabledAgents -join ',')")

    "    Building with tech $($enabledToolchain -join ','); package repos $($enabledPackageCaches -join ','); agents $($enabledAgents -join ',')"
    "    $runtime build $($buildArgs -join ' ') -t $image`:latest $buildContext"

    if ($dryRun) { exit 0 }

    & $runtime build $buildArgs -t "$image`:latest" $buildContext
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "$runtime build failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
} finally {
    Remove-Item -Recurse -Force $buildContext -EA Silent
}

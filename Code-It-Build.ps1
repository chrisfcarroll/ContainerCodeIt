#! /usr/bin/env pwsh
<#
.SYNOPSIS
    Builds the code-it container image, selecting tool chains and package caches.

.DESCRIPTION
    Builds the Alpine image from the Dockerfile with the requested tool chains and
    package caches, and labels the image with that resolution so Code-It.ps1 can
    check it rather than guess from the image name. Code-It.ps1's -buildImage and
    -rebuildImage flags delegate here.

.PARAMETER toolChains
    Comma-separated tool chains to build. Known: dotnet, node (aliases js-node,
    ts-node), bun (aliases js-bun, ts-bun), python (alias uv). Default: "dotnet,node".
    Alias: -stack.

.PARAMETER packageCaches
    Comma-separated package repos to support, independent of -toolChains. Known:
    nuget, npm, bun. Default: the repos implied by -toolChains (dotnet->nuget,
    node->npm). An explicit, empty list means no package caches.

.PARAMETER rebuild
    Bump the Dockerfile's "# last changed" dates to today first, so the agent install
    layers rerun and the agents update.

.PARAMETER image
    Image name to build. Default: "code-it-alpine-<chains>", a slug of the resolved
    -toolChains list.

.PARAMETER dockerfileDir
    Directory containing the Dockerfile. Defaults to this script's own directory.

.PARAMETER runtime
    Container runtime to use: "docker" or "container". Default: auto-detected.

.PARAMETER dryRun
    Print the build command without executing it.

.EXAMPLE
    .\Code-It-Build.ps1 -toolChains 'node,bun' -packageCaches npm

.EXAMPLE
    .\Code-It-Build.ps1 -rebuild
#>

[CmdletBinding(PositionalBinding = $false)]
param (
    [Alias('tech', 'stack')]
    [string]$toolChains    = "",
    [string]$packageCaches = "",
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

# Resolve the requested tool chains and package caches. An explicit, empty
# -packageCaches means "no package caches", not "use the implied ones".
$enabledToolChains = Resolve-CodeItToolChains $toolChains
if ($null -eq $enabledToolChains) { exit 1 }
if ($PSBoundParameters.ContainsKey('packageCaches')) {
    $enabledPackageCaches = Resolve-CodeItPackageCaches $packageCaches $enabledToolChains
} else {
    $enabledPackageCaches = Resolve-CodeItPackageCaches "" $enabledToolChains
}
if ($null -eq $enabledPackageCaches) { exit 1 }

if (-not $image) { $image = CodeIt-ImageName $enabledToolChains }

$runtime = Detect-CodeItRuntime $runtime
if ($null -eq $runtime) { exit 1 }

if (-not (Test-Path -Path "$dockerfileDir/Dockerfile" -PathType Leaf)) {
    Write-Warning "Dockerfile not found at: $dockerfileDir/Dockerfile"
    exit 1
}
$dockerfileDir = (Resolve-Path $dockerfileDir).Path

if ($rebuild) {
    # Bump the "# last changed" cache-bust dates in the Dockerfile to force re-run of installations.
    $today = [DateTime]::Today.ToString('yyyy-MM-dd')
    $dockerfile = "$dockerfileDir/Dockerfile"
    $dockerfileText = [IO.File]::ReadAllText($dockerfile) -replace '# last changed [0-9]{4}-[0-9]{2}-[0-9]{2}', "# last changed $today"
    [IO.File]::WriteAllText($dockerfile, $dockerfileText)
    "    Updated '# last changed' dates in $dockerfileDir/Dockerfile to $today"
}

# Build args for the tool chains and package caches, spelled the way the Dockerfile's
# ARGs match them (uppercase), plus a label recording the resolution.
$buildArgs = @()
foreach ($tc in @('dotnet', 'node', 'bun', 'python')) {
    $buildArgs += @('--build-arg', "$($tc.ToUpper())=$(Bool-Arg ($enabledToolChains -contains $tc))")
}
foreach ($pc in @('nuget', 'npm')) {
    $buildArgs += @('--build-arg', "$($pc.ToUpper())=$(Bool-Arg ($enabledPackageCaches -contains $pc))")
}
$buildArgs += @('--label', "code-it.tool-chains=$($enabledToolChains -join ',')")
$buildArgs += @('--label', "code-it.package-caches=$($enabledPackageCaches -join ',')")

"    Building with tech $($enabledToolChains -join ','); package repos $($enabledPackageCaches -join ',')"
"    $runtime build $($buildArgs -join ' ') -t $image`:latest $dockerfileDir"

if ($dryRun) { exit 0 }

& $runtime build $buildArgs -t "$image`:latest" $dockerfileDir
if ($LASTEXITCODE -ne 0) {
    Write-Warning "$runtime build failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

#! /usr/bin/env pwsh

<#
.SYNOPSIS
    Builds the code-it container image, selecting toolchains, caches and agents.

.DESCRIPTION
    Builds the Alpine image from the Dockerfile with the requested toolchains,
    package caches and coding agents, and labels the image with that resolution so
    Code-It.ps1 can check it rather than guess from the image name. The image's
    locale defaults to the host's. With no toolchain, it interactively detects and
    asks which toolchains and agents to build. Code-It.ps1 runs the images this builds.

    Toolchains, package caches and agents are data: each is a directory with a config
    and an install fragment. This script assembles only the selected fragments into
    the Dockerfile (replacing the markers), so unselected ones cost nothing in the
    size-limited buildable file. It also writes /etc/code-it-agents, the name=binary
    map go.sh reads.

.PARAMETER toolchain
    Comma-separated toolchains to build. Known: dotnet, node (aliases js-node,
    ts-node), bun (aliases js-bun, ts-bun), python (alias uv), powershell
    (alias pwsh), rust, go. Alias: -stack.
    With no selection, interactive setup asks which detected toolchains to build.

.PARAMETER packageCaches
    Comma-separated package repos to support, independent of -toolchain. Known:
    nuget, npm, bun. Default: the repos implied by -toolchain (dotnet->nuget,
    node->npm). An explicit, empty list means no package caches.

.PARAMETER agent
    Comma-separated agents to install. Default for parameterized builds: opencode,claude.
    Interactive setup preselects detected agents. Alias: -agents

.PARAMETER listAgents
    List the available agents and exit.

.PARAMETER listToolchains
    List the available toolchains (and their aliases) and exit.

.PARAMETER listPackageCaches
    List the available package caches and exit.

.PARAMETER rebuild
    Bump the "# last changed" dates in the Dockerfile and selected agent install
    fragments to today first, so the agent install layers rerun and the agents update.

.PARAMETER locale
    The container's locale (its LANG), e.g. en_GB.UTF-8 or en-GB. Default: like-host,
    the host's own locale, read from LC_ALL or LANG, else the Windows culture (also
    from WSL) or macOS's AppleLocale. Windows and macOS names are translated as best
    they can be, and the codeset is always UTF-8. C.UTF-8 if it cannot be told.

.PARAMETER image
    Image name to build. Default: "code-it-alpine-<chains>", a slug of the resolved
    -toolchain list.

.PARAMETER dockerfileDir
    Directory containing the Dockerfile and definitions. Defaults to this script's
    own directory.

.PARAMETER runtime
    Container runtime to use: "docker" or "container". Default: auto-detected.

.PARAMETER dryRun
    Print the build command without executing it.

.PARAMETER yes
    Accept detected/default selections and build without asking.

.PARAMETER interactive
    Ask about any missing toolchain/agent selection.

.PARAMETER selectionFile
    Internal: write the selected toolchains and agents for Code-It-FirstRun.ps1.

.EXAMPLE
    .\Code-It-Build.ps1 -toolchain 'node,bun' -packageCaches npm -agent opencode

.EXAMPLE
    .\Code-It-Build.ps1 -toolchain 'dotnet,node' -rebuild
#>

[CmdletBinding(PositionalBinding = $false)]
param (
    [Alias('tech', 'stack')]
    [string]$toolchain    = "",
    [string]$packageCaches = "",
    [Alias('agents')]
    [string]$agent         = "",
    [switch]$listAgents    = $false,
    [switch]$listToolchains = $false,
    [switch]$listPackageCaches = $false,
    [switch]$rebuild       = $false,
    [ArgumentCompleter({ param($c, $p, $wordToComplete) @('like-host', 'C.UTF-8') | Where-Object { $_ -like "$wordToComplete*" } })]
    [string]$locale        = 'like-host',
    [string]$image         = "",
    [string]$dockerfileDir = $PSScriptRoot,
    [string]$runtime       = "",
    [switch]$dryRun        = $false,
    [switch]$yes           = $false,
    [switch]$interactive   = $false,
    [string]$selectionFile = "",
    [Alias('h')]
    [switch]$help          = $false
)

if ($help) {
    Get-Help $PSCommandPath -Full
    exit 0
}

. "$PSScriptRoot/lib/CodeItCommon.ps1"

# The definitions live next to the Dockerfile when it ships them, else next to
# this script.
$agentsDir = Join-Path $dockerfileDir 'agents'
if (-not (Test-Path -Path $agentsDir -PathType Container)) { $agentsDir = Join-Path $PSScriptRoot 'agents' }
$toolchainsDir = Join-Path $dockerfileDir 'toolchains'
if (-not (Test-Path -Path $toolchainsDir -PathType Container)) { $toolchainsDir = Join-Path $PSScriptRoot 'toolchains' }
$packageCachesDir = Join-Path $dockerfileDir 'package-caches'
if (-not (Test-Path -Path $packageCachesDir -PathType Container)) { $packageCachesDir = Join-Path $PSScriptRoot 'package-caches' }

if ($listAgents) {
    foreach ($name in (Get-CodeItListAgents $agentsDir)) {
        $short = Get-CodeItAgentConfig $agentsDir $name 'AGENT_SHORT'
        if ($short) { "  {0,-10} -{1}" -f $name, $short } else { "  $name" }
    }
    exit 0
}
if ($listToolchains) {
    foreach ($name in (Get-CodeItListToolchains $toolchainsDir)) {
        $aliases = Get-CodeItAgentConfig $toolchainsDir $name 'TOOLCHAIN_ALIASES'
        if ($aliases) { "  {0,-12} (aliases: {1})" -f $name, ($aliases -replace ' ', ', ') } else { "  $name" }
    }
    exit 0
}
if ($listPackageCaches) {
    foreach ($name in (Get-CodeItListPackageCaches $packageCachesDir)) { "  $name" }
    exit 0
}

# With no toolchain, build is an interactive setup command. First-run also asks
# build to prompt for whichever selections were not supplied.
if (-not $toolchain -or $interactive) { $interactive = $true }

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

function Read-CodeItChoice([string]$label, [string[]]$default, [string[]]$detected, [string[]]$items) {
    if ($yes) { return $default }
    Write-Host "$label (detected marked *):"
    for ($i = 0; $i -lt $items.Count; $i++) {
        $flag = if ($detected -contains $items[$i]) { ' *' } else { '' }
        Write-Host ("  {0}) {1}{2}" -f ($i + 1), $items[$i], $flag)
    }
    $shown = if ($default.Count) { $default -join ',' } else { 'none' }
    $answer = Read-Host "Choose $label [$shown]"
    if (-not $answer) { return $default }
    return (ConvertTo-CodeItSelection $answer $items)
}

if ($interactive) {
    $toolchainAvailable = Get-CodeItListToolchains $toolchainsDir
    $agentsAvailable = Get-CodeItListAgents $agentsDir
    $detectedToolchain = @($toolchainAvailable | Where-Object { Test-CodeItToolchainDetected $toolchainsDir $_ })
    $detectedAgents = @($agentsAvailable | Where-Object { Test-CodeItAgentDetected $agentsDir $_ })

    if (-not $toolchain) {
        # Running this script means PowerShell is present, so preselect it too.
        $preselectedToolchains = @($detectedToolchain | Where-Object { $_ -ne 'powershell' }) + 'powershell'
        $toolchain = (Read-CodeItChoice 'Toolchains to build' $preselectedToolchains $detectedToolchain $toolchainAvailable) -join ','
    }
    if (-not $agent) {
        $defaultAgents = if ($detectedAgents.Count) { $detectedAgents } else { @($script:CodeItDefaultAgents) }
        $agent = (Read-CodeItChoice 'Agents to install' $defaultAgents $detectedAgents $agentsAvailable) -join ','
    }
}

# There is no default toolchain: building one nobody asked for wastes a long build.
# The empty-list check also catches -toolchain ','.
# An explicit, empty -packageCaches means "no package caches", not "use the implied ones".
$enabledToolchain = @()
if ($toolchain) {
    $enabledToolchain = Resolve-CodeItToolchain $toolchain $toolchainsDir
    if ($null -eq $enabledToolchain) { exit 1 }
}
if ($enabledToolchain.Count -eq 0) {
    Write-Warning "No toolchains selected. Choose at least one, or pass -toolchain."
    exit 1
}
if ($PSBoundParameters.ContainsKey('packageCaches')) {
    if ($packageCaches) {
        $enabledPackageCaches = Resolve-CodeItPackageCaches $packageCaches $enabledToolchain $toolchainsDir $packageCachesDir
    } else {
        $enabledPackageCaches = @()
    }
} else {
    $enabledPackageCaches = Resolve-CodeItPackageCaches "" $enabledToolchain $toolchainsDir $packageCachesDir
}
if ($null -eq $enabledPackageCaches) { exit 1 }
$enabledAgents = Resolve-CodeItAgents $agent $agentsDir
if ($null -eq $enabledAgents) { exit 1 }
$containerLocale = Resolve-CodeItLocale $locale
if (-not $containerLocale) { exit 1 }

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

# Get-CodeItFragmentPath DEFS_DIR NAME KEY: the install fragment path for a definition.
function Get-CodeItFragmentPath([string]$defsDir, [string]$name, [string]$key) {
    $fragment = Get-CodeItAgentConfig $defsDir $name $key
    if (-not $fragment) { $fragment = 'install.dockerfile' }
    return (Join-Path $defsDir (Join-Path $name $fragment))
}

if ($rebuild) {
    Update-CodeItLastChanged "$dockerfileDir/Dockerfile"
    foreach ($a in $enabledAgents) {
        Update-CodeItLastChanged (Get-CodeItFragmentPath $agentsDir $a 'AGENT_INSTALL')
    }
    foreach ($t in $enabledToolchain) {
        Update-CodeItLastChanged (Get-CodeItFragmentPath $toolchainsDir $t 'TOOLCHAIN_INSTALL')
    }
    foreach ($p in $enabledPackageCaches) {
        Update-CodeItLastChanged (Get-CodeItFragmentPath $packageCachesDir $p 'PACKAGE_CACHE_INSTALL')
    }
    "    Updated '# last changed' dates to $([DateTime]::Today.ToString('yyyy-MM-dd'))"
}

# Assemble the blocks from the selected definitions, failing if one is missing.
function Get-CodeItBlock([string]$defsDir, [string[]]$names, [string]$key) {
    $block = ""
    foreach ($name in $names) {
        $path = Get-CodeItFragmentPath $defsDir $name $key
        if (-not (Test-Path -Path $path -PathType Leaf)) {
            Write-Warning "'$name' has no install fragment at $path"
            exit 1
        }
        $block += (Get-Content $path -Raw)
        if (-not $block.EndsWith("`n")) { $block += "`n" }
    }
    return $block
}

$toolchainBlock = Get-CodeItBlock $toolchainsDir $enabledToolchain 'TOOLCHAIN_INSTALL'
$packageCacheBlock = Get-CodeItBlock $packageCachesDir $enabledPackageCaches 'PACKAGE_CACHE_INSTALL'

# The launcher bind-mounts each agent's state paths into the container home, and
# Docker creates a missing mount-point parent as root. A root-owned parent would
# then block the agent from writing beside the mount (a root-owned
# ~/.local/share stops the agent writing .local/share/powershell), so create each
# selected agent's state path here as agent1, before any mounts exist.
$statePaths = Get-CodeItAgentStateMkdirPaths $agentsDir $enabledAgents
$mkdirBlock = ""
if ($statePaths.Count) {
    $stateArgs = ($statePaths | ForEach-Object { "~/$_" }) -join ' '
    $mkdirBlock = "# Pre-create the selected agents' state paths, agent1-owned.`n"
    $mkdirBlock += "RUN mkdir -p $stateArgs`n"
}

# Agents run as agent1, into its home. /etc/code-it-agents is root-owned, so write
# the map as root and switch back for the rest of the file.
$block = "# --- coding agents: $($enabledAgents -join ',') (assembled from agents/) ---`n"
$block += $mkdirBlock
foreach ($a in $enabledAgents) {
    $fragmentPath = Get-CodeItFragmentPath $agentsDir $a 'AGENT_INSTALL'
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
$block += "USER root`n"
$block += "RUN printf '%s\n' $($entries -join ' ') > /etc/code-it-agents`n"
$block += "USER agent1`n"
# Each installed agent's binary directory goes on zsh's PATH, so a --no-agent
# shell can invoke any of them (Spec 18)
$agentPath = @()
foreach ($a in $enabledAgents) {
    $bin = Get-CodeItAgentConfig $agentsDir $a 'AGENT_BINARY'
    $dir = Split-Path -Parent $bin
    if ($agentPath -notcontains $dir) { $agentPath += $dir }
}
if ($agentPath) {
    $block += "RUN echo 'export PATH=`"$($agentPath -join ':'):`$PATH`" >> ~/.zshrc`n"
}
$agentBlock = $block

# The markers the Dockerfile declares. The agents' default region is replaced
# wholesale, so the base file can carry the default agent (opencode) and still
# assemble into an image with exactly the selected agents.
$toolchainMarker = '# @@CODE_IT_TOOLCHAIN_INSTALLS@@'
$packageCacheMarker = '# @@CODE_IT_PACKAGE_CACHE_INSTALLS@@'
$agentsBegin = '# @@CODE_IT_AGENTS_BEGIN@@'
$agentsEnd = '# @@CODE_IT_AGENTS_END@@'

$base = ([IO.File]::ReadAllText("$dockerfileDir/Dockerfile")) -replace "`r`n", "`n"
function Assert-CodeItMarker([string]$marker, [string]$what) {
    if (-not $base.Contains($marker)) {
        Write-Warning "Dockerfile has no '$marker' marker, so $what cannot be selected."
        exit 1
    }
}
if ($enabledToolchain.Count) { Assert-CodeItMarker $toolchainMarker 'toolchains' }
if ($enabledPackageCaches.Count) { Assert-CodeItMarker $packageCacheMarker 'package caches' }
Assert-CodeItMarker $agentsBegin 'agents'

$assembled = New-Object System.Collections.Generic.List[string]
$inAgents = $false
foreach ($line in ($base -split "`n")) {
    if ($line -eq $toolchainMarker) {
        if ($toolchainBlock) { $assembled.AddRange([string[]]($toolchainBlock.TrimEnd("`n") -split "`n")) }
        continue
    } elseif ($line -eq $packageCacheMarker) {
        if ($packageCacheBlock) { $assembled.AddRange([string[]]($packageCacheBlock.TrimEnd("`n") -split "`n")) }
        continue
    } elseif ($line -eq $agentsBegin) {
        $inAgents = $true
        $assembled.AddRange([string[]]($agentBlock.TrimEnd("`n") -split "`n"))
        continue
    } elseif ($line -eq $agentsEnd) {
        $inAgents = $false
        continue
    }
    if (-not $inAgents) { $assembled.Add($line) }
}
$assembled = ($assembled -join "`n")
# Keep the buildable Dockerfile small (Apple's builder fails above ~16 KB), without
# touching heredoc bodies such as go.sh.
$assembled = Remove-CodeItDockerfileComments $assembled

$buildContext = Join-Path ([IO.Path]::GetTempPath()) ("code-it-build-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $buildContext
[IO.File]::WriteAllText((Join-Path $buildContext 'Dockerfile'), $assembled, [System.Text.UTF8Encoding]::new($false))
# Extra CA certificates (ca-certificates/ next to the Dockerfile) go into the
# context, so a corporate TLS proxy's CA is trusted from the first apk fetch. The
# Dockerfile always copies the folder, so it exists even when empty.
$caContext = Join-Path $buildContext 'ca-certificates'
$null = New-Item -ItemType Directory -Force -Path $caContext
$caSource = Join-Path $dockerfileDir 'ca-certificates'
if (Test-Path -Path $caSource -PathType Container) {
    Copy-Item -Path (Join-Path $caSource '*') -Destination $caContext -Recurse -Force
}
$caFiles = @(Get-ChildItem -Path $caContext -File | Where-Object Extension -in '.crt', '.cer', '.pem' | ForEach-Object Name)
if ($caFiles) {
    "    Adding certificate trust from ca-certificates/: $($caFiles -join ' ')"
} else {
    "    No additional certificate trust was requested"
}

try {
    # The fragments are the toolchain and package-cache selection, so the only build
    # arg left is the locale; labels record the resolution.
    $buildArgs = @('--build-arg', "LOCALE=$containerLocale")
    $buildArgs += @('--label', "code-it.toolchains=$($enabledToolchain -join ',')")
    $buildArgs += @('--label', "code-it.package-caches=$($enabledPackageCaches -join ',')")
    $buildArgs += @('--label', "code-it.agents=$($enabledAgents -join ',')")
    $buildArgs += @('--label', "code-it.locale=$containerLocale")
    # Each agent's binary path, so Code-It can tell when an image predates a change to
    # an agent's definition and would run the wrong binary.
    $agentBinaries = foreach ($a in $enabledAgents) { "$a=$(Get-CodeItAgentConfig $agentsDir $a 'AGENT_BINARY')" }
    $buildArgs += @('--label', "code-it.agent-binaries=$($agentBinaries -join ',')")

    "    Building with toolchains $($enabledToolchain -join ','); package repos $($enabledPackageCaches -join ','); agents $($enabledAgents -join ','); locale $containerLocale"
    "    $runtime build $($buildArgs -join ' ') -t $image`:latest $buildContext"

    if ($interactive -and -not $yes) {
        $answer = Read-Host 'Build now? [Y/n]'
        if ($answer -match '^[Nn]') { Write-Host 'Aborted.'; exit 0 }
    }

    if ($selectionFile) {
        @("toolchains=$($enabledToolchain -join ',')", "agents=$($enabledAgents -join ',')") |
            Set-Content -Path $selectionFile -Encoding UTF8
    }

    if ($dryRun) { exit 0 }

    & $runtime build $buildArgs -t "$image`:latest" $buildContext
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "$runtime build failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
    Remove-Item -Recurse -Force $buildContext -EA Silent
} finally 
{
    # don't clean up after failure.
}

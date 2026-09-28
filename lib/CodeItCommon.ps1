<#
    Shared helpers for Code-It.ps1 and Code-It-Build.ps1. Dot-source this file; it
    defines functions and constants only, and runs nothing on its own.

        Split-CodeItList LIST                  comma string -> trimmed array
        Resolve-CodeItToolChains RAW           -> canonical array, or $null on error
        Resolve-CodeItPackageCaches RAW CHAINS -> array, or $null on error
        CodeIt-ImageName CHAINS                -> code-it-alpine-<chains>
        Detect-CodeItRuntime REQUESTED         -> docker|container, or $null on error
        Bool-Arg BOOL                          -> 'true'|'false'
#>

$script:CodeItDefaultToolChains  = @('dotnet', 'node')
$script:CodeItKnownToolChains    = @('dotnet', 'node', 'bun', 'python')
$script:CodeItKnownPackageCaches = @('nuget', 'npm', 'bun')
# js-/ts- spellings are aliases for the one runtime tech (Node.js or Bun runs both);
# uv is Python's package manager here, so it selects the python tool chain
$script:CodeItToolChainAliases   = @{ 'js-node' = 'node'; 'ts-node' = 'node'; 'js-bun' = 'bun'; 'ts-bun' = 'bun'; 'uv' = 'python' }
$script:CodeItContainerPort      = 3000
$script:CodeItDefaultAgents      = @('opencode', 'claude')

function Split-CodeItList([string]$list) {
    # The unary comma keeps an empty result as an array, not $null
    if (-not $list) { return ,@() }
    return ,@($list -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Resolve-CodeItToolChains([string]$raw) {
    $requested = if ($raw) { Split-CodeItList $raw } else { $script:CodeItDefaultToolChains }
    $resolved = @($requested | ForEach-Object {
        if ($script:CodeItToolChainAliases.ContainsKey($_)) { $script:CodeItToolChainAliases[$_] } else { $_ }
    } | Where-Object { $_ } | Select-Object -Unique)
    foreach ($t in $resolved) {
        if ($t -notmatch '^[a-z][a-z0-9-]*$' -or $t -notin $script:CodeItKnownToolChains) {
            Write-Warning "Unknown tech stack '$t'. Known: dotnet, node (aliases js-node, ts-node), bun (aliases js-bun, ts-bun), python (alias uv)."
            Write-Warning "A comma-separated list is expected, e.g. -toolChains 'node,bun'."
            return $null
        }
    }
    return ,$resolved
}

function Resolve-CodeItPackageCaches([string]$raw, [string[]]$toolChains) {
    $requested = if ($raw) { Split-CodeItList $raw } else {
        @(@('nuget') * ($toolChains -contains 'dotnet') + @('npm') * ($toolChains -contains 'node'))
    }
    foreach ($p in $requested) {
        if ($p -notmatch '^[a-z][a-z0-9-]*$' -or $p -notin $script:CodeItKnownPackageCaches) {
            Write-Warning "Unknown package repo '$p'. Known: $($script:CodeItKnownPackageCaches -join ', ')."
            Write-Warning "A comma-separated list is expected, e.g. -packageCaches nuget,npm."
            return $null
        }
    }
    return ,@($requested)
}

function CodeIt-ImageName([string[]]$toolChains) {
    return "code-it-alpine-$($toolChains -join '-')"
}

# Test-CodeItToolChainsInclude IMAGE_CHAINS_COMMA REQUESTED: true if every requested
# tool chain is present in the image's chain list.
function Test-CodeItToolChainsInclude([string]$imageChains, [string[]]$requested) {
    $have = @($imageChains -split ',')
    foreach ($r in $requested) {
        if ($have -notcontains $r) { return $false }
    }
    return $true
}

# Get-CodeItImageToolChains RUNTIME IMAGE: the comma-separated tool chains recorded on
# IMAGE (its code-it.tool-chains label, or the code-it-alpine-<chains> name), or "".
function Get-CodeItImageToolChains([string]$runtime, [string]$image) {
    $chains = ""
    if ($runtime -eq 'docker') {
        $chains = (docker image inspect --format '{{ index .Config.Labels "code-it.tool-chains" }}' $image 2>$null)
    } else {
        $chains = (container image inspect --format '{{ index .Config.Labels "code-it.tool-chains" }}' $image 2>$null)
    }
    $chains = "$chains".Trim()
    if ($chains -notmatch '^[a-z,]*$') { $chains = "" }
    if (-not $chains -and $image -like 'code-it-alpine-*') {
        $chains = ($image.Substring('code-it-alpine-'.Length)) -replace ':.*$', ''
        $chains = $chains -replace '-', ','
    }
    return $chains
}

# Get-CodeItImageList RUNTIME: existing image "repo:tag" names, most recent first.
function Get-CodeItImageList([string]$runtime) {
    if ($runtime -eq 'docker') {
        return @(docker images --format '{{.Repository}}:{{.Tag}}' 2>$null)
    }
    # Apple container's ls is newest first; NAME and TAG are the first two columns.
    return @(container image ls 2>$null | Select-Object -Skip 1 | ForEach-Object {
        $f = $_ -split '\s+'
        if ($f.Count -ge 2) { "$($f[0]):$($f[1])" }
    })
}

# Find-CodeItSupersetImage RUNTIME REQUESTED: the repo name of the most-recently built
# image whose recorded tool chains contain every requested chain, or "".
function Find-CodeItSupersetImage([string]$runtime, [string[]]$requested) {
    foreach ($image in (Get-CodeItImageList $runtime)) {
        if (-not $image) { continue }
        if ($image -notmatch ':') { $image = "$image`:latest" }
        $chains = Get-CodeItImageToolChains $runtime $image
        if (-not $chains) { continue }
        if (Test-CodeItToolChainsInclude $chains $requested) {
            return ($image -replace ':.*$', '')
        }
    }
    return ""
}

# Get-CodeItToolChainCommands NAME: the host commands that reveal NAME is installed.
function Get-CodeItToolChainCommands([string]$name) {
    switch ($name) {
        'dotnet' { return @('dotnet --version') }
        'node'   { return @('node --version', 'volta --version') }
        'bun'    { return @('bun --version') }
        'python' { return @('python3 --version', 'uv --version') }
        default  { return @() }
    }
}

function Test-CodeItToolChainDetected([string]$name) {
    foreach ($c in (Get-CodeItToolChainCommands $name)) {
        $exe = ($c -split '\s+')[0]
        if (Get-Command $exe -EA Silent) { return $true }
    }
    return $false
}

# Test-CodeItAgentDetected DIR NAME: true if the agent's host command is on PATH, or
# any of its host state paths (HOME/<state path>) exists.
function Test-CodeItAgentDetected([string]$dir, [string]$name) {
    $cmd = Get-CodeItAgentConfig $dir $name 'AGENT_COMMAND'
    if ($cmd -and (Get-Command $cmd -EA Silent)) { return $true }
    $paths = @()
    foreach ($k in @('AGENT_STATE_DIRS', 'AGENT_STATE_FILES')) {
        $v = Get-CodeItAgentConfig $dir $name $k
        if ($v) { $paths += ($v -split ':') }
    }
    foreach ($p in $paths) {
        if ($p -and (Test-Path -Path (Join-Path $HOME $p))) { return $true }
    }
    return $false
}

# Get-CodeItAgentConfig DIR NAME KEY: the (unquoted) value of KEY in an agent's
# config, or $null. Keys are uppercase and appear once per line.
function Get-CodeItAgentConfig([string]$dir, [string]$name, [string]$key) {
    $file = Join-Path $dir (Join-Path $name 'config')
    if (-not (Test-Path -Path $file -PathType Leaf)) { return $null }
    foreach ($line in Get-Content $file) {
        if ($line -match "^$([regex]::Escape($key))=(.*)$") {
            $v = $Matches[1]
            if ($v.Length -ge 2 -and (($v[0] -eq "'" -and $v[-1] -eq "'") -or ($v[0] -eq '"' -and $v[-1] -eq '"'))) {
                $v = $v.Substring(1, $v.Length - 2)
            }
            return $v
        }
    }
    return $null
}

function Test-CodeItAgentExists([string]$dir, [string]$name) {
    return (Test-Path -Path (Join-Path $dir (Join-Path $name 'config')) -PathType Leaf)
}

function Get-CodeItListAgents([string]$dir) {
    if (-not (Test-Path -Path $dir -PathType Container)) { return ,@() }
    return ,@(Get-ChildItem -Directory -Path $dir |
        Where-Object { Test-Path -Path (Join-Path $_.FullName 'config') -PathType Leaf } |
        ForEach-Object { $_.Name })
}

function Resolve-CodeItAgents([string]$raw, [string]$dir) {
    $requested = if ($raw) { Split-CodeItList $raw } else { $script:CodeItDefaultAgents }
    $out = @()
    foreach ($a in $requested) {
        if (-not $a) { continue }
        if (Test-CodeItAgentExists $dir $a) {
            $out += $a
        } else {
            Write-Warning "Unknown agent '$a'. Known agents: $((Get-CodeItListAgents $dir) -join ' ')"
            return $null
        }
    }
    return ,$out
}

function Bool-Arg([bool]$on) { if ($on) { 'true' } else { 'false' } }

# Invoke-CodeItAdder NAME BRANCH REPO CODEIT DRYRUN PROMPT: the plumbing shared by
# Code-It-Add-Agent and Code-It-Add-Tool-Chain. Prints its banners to the host and
# returns the exit code. With DRYRUN it prints the prompt and command and does nothing
# else. Otherwise it refuses a dirty repo or an existing branch, creates BRANCH, runs
# CODEIT headless with PROMPT, prints the branch and diff summary, and returns
# code-it's exit code.
function Invoke-CodeItAdder([string]$name, [string]$branch, [string]$repo, [string]$codeIt, [bool]$dryRun, [string]$prompt) {
    $codeItArgs = @('-headless', '-WorkDirToMount', $repo, '-prompt', $prompt)

    if ($dryRun) {
        Write-Host "Prompt:"
        Write-Host $prompt
        Write-Host ""
        Write-Host "Command:"
        Write-Host "$codeIt $($codeItArgs -join ' ')"
        return 0
    }

    # Refuse a dirty tree, so checking out a new branch cannot lose work.
    if ((git -C $repo status --porcelain)) {
        Write-Warning "'$repo' has uncommitted changes. Commit or stash them first."
        return 1
    }
    & git -C $repo rev-parse --verify --quiet $branch *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Warning "Branch '$branch' already exists in '$repo'."
        return 1
    }

    $baseRev = (git -C $repo rev-parse HEAD)
    Write-Host "    Creating branch $branch in $repo"
    & git -C $repo checkout -b $branch | Out-Host
    if ($LASTEXITCODE -ne 0) { return [int]$LASTEXITCODE }

    Write-Host "    Running: $codeIt -headless -WorkDirToMount $repo"
    # Stream the launcher's output straight to the host, so it is not captured as
    # this function's return value.
    & $codeIt @codeItArgs | Out-Host
    $rc = $LASTEXITCODE

    Write-Host ""
    Write-Host "    Branch: $branch"
    Write-Host "    Changes:"
    & git -C $repo log --oneline "$baseRev..HEAD" 2>$null | ForEach-Object { Write-Host "      $_" }
    & git -C $repo diff --stat "$baseRev..HEAD" 2>$null | ForEach-Object { Write-Host "      $_" }

    if ($rc -ne 0) {
        Write-Warning "code-it exited $rc (the agent may have refused the gate or failed)."
    }
    return [int]$rc
}

# Detect / validate the container runtime. On macOS prefer the Apple container CLI,
# then docker, then the container CLI; warn and return $null if none is usable.
function Detect-CodeItRuntime([string]$runtime) {
    # $IsMacOS/$IsLinux are not defined in Windows PowerShell 5.1, so treat unset as false
    $onMacOS = $IsMacOS -eq $true
    $onLinux = $IsLinux -eq $true
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
            return $null
        }
    }
    elseif ($runtime -notin @("docker", "container")) {
        Write-Warning "Unknown runtime '$runtime'. Valid values are 'docker' or 'container'."
        return $null
    }
    elseif (-not (Get-Command $runtime -EA Silent)) {
        Write-Warning "Requested runtime '$runtime' not found. Please install it and ensure it is in your PATH."
        return $null
    }
    return $runtime
}

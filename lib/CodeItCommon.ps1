<#
    Shared helpers for Code-It.ps1 and Code-It-Build.ps1. Dot-source this file; it
    defines functions and constants only, and runs nothing on its own.

        Split-CodeItList LIST                  comma string -> trimmed array
        Resolve-CodeItToolchain RAW DIR        -> canonical array, or $null on error
        Resolve-CodeItPackageCaches RAW CHAINS TC_DIR PC_DIR -> array, or $null on error
        CodeIt-ImageName CHAINS                -> code-it-alpine-<chains>
        Detect-CodeItRuntime REQUESTED         -> docker|container, or $null on error
        Bool-Arg BOOL                          -> 'true'|'false'

    Tool chains, package caches and agents are data: each is a directory with a
    config and an install fragment. Known names come from the directory listing;
    aliases and host detection from each config.
#>

$script:CodeItDefaultToolchain  = @('dotnet', 'node')
$script:CodeItContainerPort      = 3000
$script:CodeItDefaultAgents      = @('opencode', 'claude')

function Split-CodeItList([string]$list) {
    # The unary comma keeps an empty result as an array, not $null
    if (-not $list) { return ,@() }
    return ,@($list -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Get-CodeItDefinitions DIR: the definition names under DIR (DIR/<name>/config).
function Get-CodeItDefinitions([string]$dir) {
    if (-not (Test-Path -Path $dir -PathType Container)) { return ,@() }
    return ,@(Get-ChildItem -Directory -Path $dir |
        Where-Object { Test-Path -Path (Join-Path $_.FullName 'config') -PathType Leaf } |
        ForEach-Object { $_.Name })
}

function Get-CodeItListToolchains([string]$dir) { return Get-CodeItDefinitions $dir }
function Get-CodeItListPackageCaches([string]$dir) { return Get-CodeItDefinitions $dir }

# Get-CodeItToolchainAlias DIR NAME: canonical name for NAME, resolving the aliases
# declared in each toolchains/<name>/config. Unknown names pass through.
function Get-CodeItToolchainAlias([string]$dir, [string]$name) {
    if (Test-Path -Path (Join-Path $dir (Join-Path $name 'config')) -PathType Leaf) { return $name }
    foreach ($d in (Get-CodeItDefinitions $dir)) {
        $aliases = Get-CodeItAgentConfig $dir $d 'TOOLCHAIN_ALIASES'
        if ($aliases -and @($aliases -split '\s+' | Where-Object { $_ }) -contains $name) { return $d }
    }
    return $name
}

function Resolve-CodeItToolchain([string]$raw, [string]$dir) {
    $requested = if ($raw) { Split-CodeItList $raw } else { $script:CodeItDefaultToolchain }
    $resolved = @($requested | ForEach-Object { Get-CodeItToolchainAlias $dir $_ } |
        Where-Object { $_ } | Select-Object -Unique)
    foreach ($t in $resolved) {
        if ($t -notmatch '^[a-z][a-z0-9-]*$' -or -not (Test-Path -Path (Join-Path $dir (Join-Path $t 'config')) -PathType Leaf)) {
            Write-Warning "Unknown tool chain '$t'. Known: $((Get-CodeItListToolchains $dir) -join ', ')."
            Write-Warning "A comma-separated list is expected, e.g. -toolchain 'node,bun'."
            return $null
        }
    }
    return ,$resolved
}

function Resolve-CodeItPackageCaches([string]$raw, [string[]]$toolchain, [string]$tcDir, [string]$pcDir) {
    $requested = if ($raw) { Split-CodeItList $raw } else {
        $implied = @()
        foreach ($t in $toolchain) {
            $c = Get-CodeItAgentConfig $tcDir $t 'TOOLCHAIN_PACKAGE_CACHE'
            if ($c) { $implied += $c }
        }
        $implied
    }
    foreach ($p in $requested) {
        if ($p -notmatch '^[a-z][a-z0-9-]*$' -or -not (Test-Path -Path (Join-Path $pcDir (Join-Path $p 'config')) -PathType Leaf)) {
            Write-Warning "Unknown package repo '$p'. Known: $((Get-CodeItListPackageCaches $pcDir) -join ', ')."
            Write-Warning "A comma-separated list is expected, e.g. -packageCaches nuget,npm."
            return $null
        }
    }
    return ,@($requested)
}

function CodeIt-ImageName([string[]]$toolchain) {
    return "code-it-alpine-$($toolchain -join '-')"
}

# Test-CodeItToolchainInclude IMAGE_CHAINS_COMMA REQUESTED: true if every requested
# tool chain is present in the image's chain list.
function Test-CodeItToolchainInclude([string]$imageChains, [string[]]$requested) {
    $have = @($imageChains -split ',')
    foreach ($r in $requested) {
        if ($have -notcontains $r) { return $false }
    }
    return $true
}

# Get-CodeItImageToolchain RUNTIME IMAGE: the comma-separated toolchains recorded on
# IMAGE (its code-it.tool-chains label, or the code-it-alpine-<chains> name), or "".
function Get-CodeItImageToolchain([string]$runtime, [string]$image) {
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
    # Skip a header row if there is one.
    return @(container image ls 2>$null | Where-Object { $_ -and $_ -notmatch '^\s*NAME\b' } | ForEach-Object {
        $f = $_ -split '\s+'
        if ($f.Count -ge 2) { "$($f[0]):$($f[1])" }
    })
}

# Find-CodeItSupersetImage RUNTIME REQUESTED: the repo name of the most-recently built
# image whose recorded toolchains contain every requested chain, or "".
function Find-CodeItSupersetImage([string]$runtime, [string[]]$requested) {
    foreach ($image in (Get-CodeItImageList $runtime)) {
        if (-not $image) { continue }
        if ($image -notmatch ':') { $image = "$image`:latest" }
        $chains = Get-CodeItImageToolchain $runtime $image
        if (-not $chains) { continue }
        if (Test-CodeItToolchainInclude $chains $requested) {
            return ($image -replace ':.*$', '')
        }
    }
    return ""
}

# Test-CodeItImageExists RUNTIME IMAGE: true if the runtime has the image.
function Test-CodeItImageExists([string]$runtime, [string]$image) {
    try {
        if ($runtime -eq 'docker') {
            & docker image inspect $image *> $null
            return ($LASTEXITCODE -eq 0)
        }
        & container image inspect $image *> $null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

# Get-CodeItHistoryImage RUNTIME FILE TC_DIR: the most-recently remembered image
# that still exists and whose toolchains cover >=70% of weighted usage, or "". Weights
# run from 1 (oldest remembered) to 15 (most recent). Only the tool chains known in
# TC_DIR count. Spec 09.
function Get-CodeItHistoryImage([string]$runtime, [string]$file, [string]$tcDir) {
    if (-not (Test-Path -Path $file)) { return "" }
    $lines = @(Get-Content -Path $file | Where-Object { $_ })
    $n = $lines.Count
    if ($n -eq 0) { return "" }
    $images = @()
    $chains = @()
    foreach ($l in $lines) {
        $img = ($l -split '\s+', 2)[1]
        $images += $img
        $chains += (Get-CodeItImageToolchain $runtime $img)
    }
    $total = 0
    for ($i = 0; $i -lt $n; $i++) { $total += 15 - $n + 1 + $i }
    if ($total -le 0) { return "" }
    # Plain assignment: the definition helpers return an array object, and @() would
    # wrap it as a single nested element.
    $known = Get-CodeItListToolchains $tcDir
    if ($null -eq $known) { $known = @() }
    # Coverage of image j is sum over remembered i of w_i * |chains(i) ∩ chains(j)|,
    # counting only known tool chains.
    for ($j = $n - 1; $j -ge 0; $j--) {
        $cov = 0
        $setJ = @($chains[$j] -split ',')
        for ($i = 0; $i -lt $n; $i++) {
            $w = 15 - $n + 1 + $i
            $common = 0
            foreach ($c in @($chains[$i] -split ',')) {
                if (($known -contains $c) -and ($setJ -contains $c)) { $common++ }
            }
            $cov += $w * $common
        }
        if ($cov * 10 -ge $total * 7) {
            if (Test-CodeItImageExists $runtime $images[$j]) { return $images[$j] }
        }
    }
    return ""
}

# Remove-CodeItDockerfileComments TEXT: drop Dockerfile-level comment and blank lines,
# preserving heredoc bodies (RUN cat <<'EOF' ... EOF). Apple's container builder sends
# the Dockerfile in a gRPC header and fails above ~16 KB (apple/container#735), so a
# buildable Dockerfile is kept small.
function Remove-CodeItDockerfileComments([string]$text) {
    $out = New-Object System.Collections.Generic.List[string]
    $heredoc = ""
    foreach ($line in ($text -split "`n")) {
        if ($heredoc) {
            $out.Add($line)
            if ($line -eq $heredoc) { $heredoc = "" }
            continue
        }
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        if ($line -match '<<-?[''"]?([A-Za-z_][A-Za-z0-9_]*)') { $heredoc = $Matches[1] }
        $out.Add($line)
    }
    return ($out -join "`n")
}

# Add-CodeItHistory FILE IMAGE: append "yyyyMMdd IMAGE", keeping the newest 15 lines.
function Add-CodeItHistory([string]$file, [string]$image) {
    if (-not $image) { return }
    $lines = @()
    if (Test-Path -Path $file) { $lines = @(Get-Content -Path $file | Where-Object { $_ }) }
    $lines += "$([DateTime]::Today.ToString('yyyyMMdd')) $image"
    if ($lines.Count -gt 15) { $lines = $lines[-15..-1] }
    $dir = Split-Path $file -Parent
    if ($dir -and -not (Test-Path -Path $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    [IO.File]::WriteAllLines($file, $lines, [System.Text.UTF8Encoding]::new($false))
}

# Get-CodeItDefaultImage RUNTIME FILE: the default existing code-it image: the most
# recently used remembered one that still exists, else the most recently built.
# "" if there is no code-it image at all.
function Get-CodeItDefaultImage([string]$runtime, [string]$file) {
    $existing = @()
    foreach ($l in (Get-CodeItImageList $runtime)) {
        if (-not $l) { continue }
        $repo = ($l -split ':')[0]
        if ($repo -notlike 'code-it-*') { continue }
        if ($existing -notcontains $repo) { $existing += $repo }
    }
    if ($existing.Count -eq 0) { return "" }

    if (Test-Path -Path $file) {
        $hist = @(Get-Content -Path $file | Where-Object { $_ } | ForEach-Object { ($_ -split '\s+', 2)[1] })
        for ($i = $hist.Count - 1; $i -ge 0; $i--) {
            if ($existing -contains $hist[$i]) { return $hist[$i] }
        }
    }
    return $existing[0]
}

# Get-CodeItToolchainCommands DIR NAME: the host commands that reveal NAME is
# installed, from the tool chain's config (TOOLCHAIN_DETECT, colon-separated).
function Get-CodeItToolchainCommands([string]$dir, [string]$name) {
    $cmds = Get-CodeItAgentConfig $dir $name 'TOOLCHAIN_DETECT'
    if (-not $cmds) { return ,@() }
    return ,@($cmds -split ':' | Where-Object { $_ })
}

function Test-CodeItToolchainDetected([string]$dir, [string]$name) {
    foreach ($c in (Get-CodeItToolchainCommands $dir $name)) {
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

function Get-CodeItListAgents([string]$dir) { return Get-CodeItDefinitions $dir }

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

# Get-CodeItAgentStateMkdirPaths DIR NAMES: the home-relative state paths (state
# dirs, and the parent of state files) for the named agents, deduped in order.
# Used to pre-create them agent-owned so bind mounts have a writable parent.
function Get-CodeItAgentStateMkdirPaths([string]$dir, [string[]]$names) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($name in $names) {
        foreach ($key in @('AGENT_STATE_DIRS', 'AGENT_STATE_FILES')) {
            $v = Get-CodeItAgentConfig $dir $name $key
            if (-not $v) { continue }
            foreach ($p in @($v -split ':' | Where-Object { $_ })) {
                if ($key -eq 'AGENT_STATE_FILES') {
                    # A file in the home's root needs no directory created for it.
                    if (-not $p.Contains('/')) { continue }
                    $p = $p.Substring(0, $p.LastIndexOf('/'))
                }
                if (-not $out.Contains($p)) { $out.Add($p) }
            }
        }
    }
    return ,@($out)
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

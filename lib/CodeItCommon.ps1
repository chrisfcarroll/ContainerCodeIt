<#
    Shared helpers for Code-It.ps1 and Code-It-Build.ps1. Dot-source this file; it
    defines functions and constants only, and runs nothing on its own.

        Split-CodeItList LIST                  comma string -> trimmed array
        Get-CodeItPathComponent NAME           -> NAME as a mount path component
        Get-CodeItWorkMountPath WORKDIR         -> /work/<parent>/<name> mount path
        Get-CodeItDefinitions DIR              -> definition names under DIR
        Resolve-CodeItToolchain RAW DIR        -> canonical array, or $null on error
        Select-CodeItKnownToolchain LABEL DIR  -> canonical array of the known chains only
        Resolve-CodeItPackageCaches RAW CHAINS TC_DIR PC_DIR -> array, or $null on error
        CodeIt-ImageName CHAINS                -> code-it-alpine-<chains>
        Detect-CodeItRuntime REQUESTED         -> docker|container, or $null on error
        Bool-Arg BOOL                          -> 'true'|'false'
        Resolve-CodeItLocale RAW               -> e.g. en_GB.UTF-8, or $null on error
        Get-CodeItRunArgs FILE                 -> the file's run args, as an array
        Test-CodeItEnvSpec SPEC                -> $true if SPEC is NAME[=VALUE]
        Test-CodeItPidAlive PID                -> $true if process PID is running
        Get-CodeItSlot LOCKDIR PID TAKE        -> lowest free slot number, locked if TAKE

    Toolchains, package caches and agents are data: each is a directory with a config
    and an install fragment. Known names come from the directory listing; aliases and
    host detection from each config. Spec 13.
#>

$script:CodeItContainerPort      = 3000
$script:CodeItDefaultAgents      = @('opencode', 'claude')
# -locale's default: match the host. C.UTF-8 when the host's locale cannot be told.
$script:CodeItLocaleLikeHost     = 'like-host'
$script:CodeItFallbackLocale     = 'C.UTF-8'

function Split-CodeItList([string]$list) {
    # The unary comma keeps an empty result as an array, not $null
    if (-not $list) { return ,@() }
    return ,@($list -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Get-CodeItPathComponent NAME: a host directory's NAME as one component of a
# container mount path. Only ':' is replaced (by '-'), because docker's and the
# Apple container CLI's -v syntax reads a ':' on either side as a separator.
function Get-CodeItPathComponent([string]$name) {
    return $name -replace ':', '-'
}

# Get-CodeItWorkMountPath WORKDIR: the container path the host work directory
# (absolute) is mounted at, /work/<parent>/<name>, so directory names keep working
# for agents' per-directory memory instead of every project living at a fixed /work.
# WORKDIR whose parent is / has no parent name to keep, so it is mounted at
# /work/<name>; /, which has no name either, is mounted at /work itself. Spec 18.
# String arithmetic rather than Split-Path, which has no answer for the parent of /;
# both separators, because a Windows host gives a \-separated path.
function Get-CodeItWorkMountPath([string]$workDir) {
    $workDir = $workDir.TrimEnd('/','\')
    if (-not $workDir -or $workDir -eq '/' -or $workDir -eq '\') { return '/work' }
    $slash = [Math]::Max($workDir.LastIndexOf('/'), $workDir.LastIndexOf('\'))
    $name = Get-CodeItPathComponent $workDir.Substring($slash + 1)
    if ($slash -le 0) { return "/work/$name" }
    $parent = $workDir.Substring(0, $slash)
    $parentSlash = [Math]::Max($parent.LastIndexOf('/'), $parent.LastIndexOf('\'))
    $parentName = Get-CodeItPathComponent $parent.Substring($parentSlash + 1)
    return "/work/$parentName/$name"
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
    # There is no default toolchain: an empty RAW resolves to an empty list
    $requested = Split-CodeItList $raw
    $resolved = @($requested | ForEach-Object { Get-CodeItToolchainAlias $dir $_ } |
        Where-Object { $_ } | Select-Object -Unique)
    foreach ($t in $resolved) {
        if ($t -notmatch '^[a-z][a-z0-9-]*$' -or -not (Test-Path -Path (Join-Path $dir (Join-Path $t 'config')) -PathType Leaf)) {
            Write-Warning "Unknown toolchain '$t'. Known: $((Get-CodeItListToolchains $dir) -join ', ')."
            Write-Warning "A comma-separated list is expected, e.g. -toolchain 'node,bun'."
            return $null
        }
    }
    return ,$resolved
}

# The comma-separated LIST, read from an image label, as the canonical toolchains this
# checkout knows. Unlike Resolve-CodeItToolchain, unknown names are dropped, not errors:
# the image may have been built by another version or branch of code-it.
function Select-CodeItKnownToolchain([string]$list, [string]$dir) {
    # Assign first: piping Split-CodeItList's wrapped array would pass it as one item
    $requested = Split-CodeItList $list
    $known = @($requested | ForEach-Object { Get-CodeItToolchainAlias $dir $_ } |
        Where-Object { $_ -and (Test-Path -Path (Join-Path $dir (Join-Path $_ 'config')) -PathType Leaf) } |
        Select-Object -Unique)
    return ,$known
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
# toolchain is present in the image's chain list.
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

# Get-CodeItImageAgents RUNTIME IMAGE AGENTSDIR: the comma-separated agents recorded on
# IMAGE (its code-it.agents label), or "" if it cannot be told. Only names of known
# agents count, so an unlabelled image or a runtime's own error text gives "".
function Get-CodeItImageAgents([string]$runtime, [string]$image, [string]$agentsDir) {
    $raw = if ($runtime -eq 'docker') {
        (docker image inspect --format '{{ index .Config.Labels "code-it.agents" }}' $image 2>$null)
    } else {
        (container image inspect --format '{{ index .Config.Labels "code-it.agents" }}' $image 2>$null)
    }
    $raw = "$raw".Trim()
    if (-not $raw -or $raw -notmatch '^[a-z0-9,-]+$') { return "" }
    $agents = @($raw -split ',' | Where-Object { $_ })
    foreach ($a in $agents) {
        if (-not (Test-CodeItAgentExists $agentsDir $a)) { return "" }
    }
    return ($agents -join ',')
}

# Get-CodeItImageAgentBinary RUNTIME IMAGE AGENT: the binary path IMAGE's
# code-it.agent-binaries label (name=binary,...) records for AGENT; "" if the label does
# not list AGENT; $null if the image has no such label (built before it existed) or the
# runtime's own error text came back instead.
function Get-CodeItImageAgentBinary([string]$runtime, [string]$image, [string]$agent) {
    $raw = if ($runtime -eq 'docker') {
        (docker image inspect --format '{{ index .Config.Labels "code-it.agent-binaries" }}' $image 2>$null)
    } else {
        (container image inspect --format '{{ index .Config.Labels "code-it.agent-binaries" }}' $image 2>$null)
    }
    $raw = "$raw".Trim()
    if ($raw -notmatch '^[a-z0-9-]+=/[^,=\s]+(,[a-z0-9-]+=/[^,=\s]+)*$') { return $null }
    foreach ($entry in ($raw -split ',')) {
        $name, $bin = $entry -split '=', 2
        if ($name -eq $agent) { return $bin }
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

# Get-CodeItHistoryImage RUNTIME FILE TC_DIR: the most-recently remembered image that
# still exists and whose toolchains cover >=70% of weighted usage, or "". Weights run
# from 1 (oldest remembered) to 15 (most recent). Only the toolchains known in TC_DIR
# count. Spec 09.
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
    $weights = @{}
    foreach ($c in $known) { $weights[$c] = 0 }
    for ($i = 0; $i -lt $n; $i++) {
        $w = 15 - $n + 1 + $i
        $set = @($chains[$i] -split ',')
        foreach ($c in $known) {
            if ($set -contains $c) { $weights[$c] += $w }
        }
    }
    for ($j = $n - 1; $j -ge 0; $j--) {
        $cov = 0
        foreach ($c in @($chains[$j] -split ',')) {
            if ($weights.ContainsKey($c)) { $cov += $weights[$c] }
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
# installed, from the toolchain's config (TOOLCHAIN_DETECT, colon-separated).
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

# Get-CodeItKeyValue FILE KEY: the (unquoted) value of KEY in a KEY=value FILE, or
# $null. Keys appear once per line; CRLF endings and quoted values are tolerated.
function Get-CodeItKeyValue([string]$file, [string]$key) {
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

# Get-CodeItAgentConfig DIR NAME KEY: the (unquoted) value of KEY in an agent's
# config, or $null. Keys are uppercase and appear once per line.
function Get-CodeItAgentConfig([string]$dir, [string]$name, [string]$key) {
    return (Get-CodeItKeyValue (Join-Path $dir (Join-Path $name 'config')) $key)
}

# Get-CodeItDefault FILE KEY: the value of KEY in a code-it-defaults file, or $null.
function Get-CodeItDefault([string]$file, [string]$key) {
    return (Get-CodeItKeyValue $file $key)
}

# Get-CodeItRunArgs FILE: the extra container run arguments in FILE, as
# devcontainer.json's runArgs: one argument per line, so nothing is word-split and
# values need no quoting. Surrounding whitespace is trimmed; blank lines and lines
# starting with # are skipped. A missing FILE gives an empty array.
function Get-CodeItRunArgs([string]$file) {
    if (-not $file -or -not (Test-Path -Path $file -PathType Leaf)) { return ,@() }
    return ,@(Get-Content $file | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}

# Test-CodeItEnvSpec SPEC: $true if SPEC is NAME or NAME=VALUE, NAME being a valid
# environment variable name.
function Test-CodeItEnvSpec([string]$spec) {
    return ($spec -match '^[A-Za-z_][A-Za-z0-9_]*(=.*)?$')
}

# Test-CodeItPidAlive PID: $true if process PID is running
function Test-CodeItPidAlive([string]$id) {
    if ($id -notmatch '^\d+$') { return $false }
    return ($null -ne (Get-Process -Id ([int]$id) -ErrorAction SilentlyContinue))
}

# Get-CodeItSlot LOCKDIR PID TAKE: the lowest slot number N whose lock,
# LOCKDIR/N.lock, is absent or stale (its process has exited). With TAKE, also take
# it: remove a stale lock and create N.lock holding PID, atomically, so two runs
# starting together never get the same slot. $null if no slot could be had.
function Get-CodeItSlot([string]$dir, [string]$ownPid, [bool]$take) {
    if ($take) {
        try { $null = New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop } catch { return $null }
    }
    for ($n = 1; $n -lt 100; $n++) {
        $lock = Join-Path $dir "$n.lock"
        if (Test-Path -Path $lock) {
            $held = "$(Get-Content -Path $lock -TotalCount 1 -ErrorAction SilentlyContinue)".Trim()
            # An empty lock is one being written right now: treat it as held
            if (-not $held -or (Test-CodeItPidAlive $held)) { continue }
            if ($take) { Remove-Item -Force -Path $lock -ErrorAction SilentlyContinue }
        }
        if (-not $take) { return $n }
        try {
            $stream = [System.IO.File]::Open($lock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
            try {
                $bytes = [System.Text.Encoding]::ASCII.GetBytes("$ownPid`n")
                $stream.Write($bytes, 0, $bytes.Length)
            } finally { $stream.Dispose() }
            return $n
        } catch { continue }
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
        Write-Warning "code-it exited $rc (the agent may have refused, or failed)."
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

# A POSIX locale name for the container, always UTF-8, from a POSIX (en_GB.UTF-8,
# sr_RS@latin), Windows (en-GB, sr-Latn-RS, zh-Hans-CN) or macOS (en_GB@rg=gbzzzz,
# zh-Hans_CN) spelling. C and POSIX become C.UTF-8. $null if $raw does not start with
# a 2- or 3-letter language code. A script subtag is dropped, except Latn, which
# becomes the @latin modifier; numeric regions (es-419) are dropped.
function ConvertTo-CodeItLocale([string]$raw) {
    $raw = $raw.TrimEnd("`r")
    if ($raw -cmatch '^(C|POSIX)(\..*)?$') { return $script:CodeItFallbackLocale }
    $modifier = ''
    if ($raw.Contains('@')) {
        $modifier = $raw.Substring($raw.IndexOf('@') + 1)
        $raw = $raw.Substring(0, $raw.IndexOf('@'))
        # macOS's @rg=... and @currency=... keywords, and @euro, mean nothing to a UTF-8 locale
        if ($modifier -notmatch '^[A-Za-z]+$' -or $modifier -eq 'euro') { $modifier = '' }
    }
    $parts = @(($raw -split '\.')[0] -split '[-_]')
    if ($parts[0] -notmatch '^[A-Za-z]{2,3}$') { return $null }
    $lang = $parts[0].ToLowerInvariant()
    $region = ''
    foreach ($part in ($parts | Select-Object -Skip 1)) {
        if ($part -match '^[A-Za-z]{4}$') {
            if ($part -eq 'Latn' -and -not $modifier) { $modifier = 'latin' }
        } elseif (-not $region -and $part -match '^[A-Za-z]{2}$') {
            $region = $part.ToUpperInvariant()
        }
    }
    $name = $lang
    if ($region)   { $name += "_$region" }
    $name += '.UTF-8'
    if ($modifier) { $name += "@$modifier" }
    return $name
}

# The Windows user's locale name (e.g. en-GB) from the registry, or nothing. For WSL,
# where reg.exe is on the PATH but Get-Culture reads the Linux side.
function Get-CodeItWindowsRegistryLocale {
    if (-not (Get-Command reg.exe -EA Silent)) { return '' }
    $line = reg.exe query 'HKCU\Control Panel\International' /v LocaleName 2>$null |
        Where-Object { $_ -match '^\s*LocaleName\s' } | Select-Object -First 1
    if ($line) { return ($line.Trim() -split '\s+')[-1] }
    return ''
}

# The OS's own locale setting, as the OS spells it, or nothing: the Windows culture
# (also from WSL, whose distro LANG is often only C.UTF-8), or macOS's AppleLocale.
function Get-CodeItOsLocale {
    if ($env:OS -eq 'Windows_NT') { return (Get-Culture).Name }
    if ($IsMacOS -eq $true) {
        return "$(defaults read -g AppleLocale 2>$null)".Trim()
    }
    $osRelease = '/proc/sys/kernel/osrelease'
    if ((Test-Path $osRelease) -and ((Get-Content $osRelease -Raw) -match 'microsoft')) {
        return Get-CodeItWindowsRegistryLocale
    }
    return ''
}

# The host's locale, as the host spells it, or nothing. LC_ALL, then LANG, unless they
# are just C or POSIX, which say nothing about the user; then the OS's own setting.
function Get-CodeItHostLocale {
    foreach ($v in @($env:LC_ALL, $env:LANG)) {
        if ($v -and $v -cnotmatch '^(C|POSIX)(\..*)?$') { return $v }
    }
    return Get-CodeItOsLocale
}

# The container locale for -locale $raw. Empty or like-host means the host's locale,
# falling back to C.UTF-8 if it cannot be told or read. Anything else must be a locale
# name; an unreadable one warns and returns $null.
function Resolve-CodeItLocale([string]$raw) {
    if (-not $raw -or $raw -eq $script:CodeItLocaleLikeHost) {
        $hostLocale = Get-CodeItHostLocale
        $resolved = if ($hostLocale) { ConvertTo-CodeItLocale $hostLocale }
        if ($resolved) { return $resolved } else { return $script:CodeItFallbackLocale }
    }
    $resolved = ConvertTo-CodeItLocale $raw
    if (-not $resolved) {
        Write-Warning "Unknown locale '$raw'. Use a name like en_GB.UTF-8 or en-GB, C.UTF-8, or $($script:CodeItLocaleLikeHost)."
    }
    return $resolved
}

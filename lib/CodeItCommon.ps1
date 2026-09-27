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
$script:CodeItKnownToolChains    = @('dotnet', 'node', 'bun')
$script:CodeItKnownPackageCaches = @('nuget', 'npm', 'bun')
# js-/ts- spellings are aliases for the one runtime tech (Node.js or Bun runs both)
$script:CodeItToolChainAliases   = @{ 'js-node' = 'node'; 'ts-node' = 'node'; 'js-bun' = 'bun'; 'ts-bun' = 'bun' }
$script:CodeItContainerPort      = 3000

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
            Write-Warning "Unknown tech stack '$t'. Known: dotnet, node (aliases js-node, ts-node), bun (aliases js-bun, ts-bun)."
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

function Bool-Arg([bool]$on) { if ($on) { 'true' } else { 'false' } }

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

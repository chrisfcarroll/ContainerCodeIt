# Tests for Code-It.ps1 and its alias scripts.
#
# No container runtime is required: the tests place a stub `docker` executable on the
# PATH and run the scripts with -dryRun, asserting on the printed run command.
# Each scenario runs in a child pwsh process so `exit` in the scripts is isolated.
# Run with:
#   pwsh -NoProfile -File tests/Test-CodeIt.ps1

$ErrorActionPreference = 'Continue'

$testsDir  = $PSScriptRoot
$scriptDir = Split-Path $testsDir -Parent
$codeIt    = Join-Path $scriptDir 'Code-It.ps1'
# The helpers, for the unit assertions on Get-CodeItWorkMountPath below
. (Join-Path $scriptDir 'lib/CodeItCommon.ps1')
# Find a pwsh that actually runs (the first one on the PATH may be a build for the
# wrong architecture, e.g. an x64 pwsh on an arm64 host).
function Test-PwshWorks([string]$exe) {
    if (-not $exe -or -not (Test-Path $exe)) { return $false }
    try { $null = & $exe -NoProfile -Command 'exit 0' 2>$null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}
$pwshExe = @((Get-Command pwsh -EA Silent).Source, "$HOME/.local/bin/pwsh", "$HOME/.dotnet/tools/pwsh") |
    Where-Object { Test-PwshWorks $_ } | Select-Object -First 1
if (-not $pwshExe) { throw "No working pwsh found to run test scenarios" }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "code-it-tests-$PID"
$null = New-Item -ItemType Directory -Force -Path $tmp

$script:pass = 0
$script:fail = 0

function Assert([string]$desc, [bool]$ok) {
    if ($ok) { "  ok: $desc";   $script:pass++ }
    else     { "  FAIL: $desc"; $script:fail++ }
}

function Assert-Contains([string]$desc, [string]$haystack, [string]$needle) {
    Assert "$desc" ($haystack.Contains($needle))
}

# $IsWindows is not defined in Windows PowerShell 5.1, so derive it portably
$onWindows = ($env:OS -eq 'Windows_NT')

# Stub docker on the PATH (a .cmd shim on Windows, an sh script elsewhere)
$stubDocker = Join-Path $tmp 'stub-docker'
$null = New-Item -ItemType Directory -Force -Path $stubDocker
if ($onWindows) {
    Set-Content -Path (Join-Path $stubDocker 'docker.cmd') -Value @'
@echo off
if "%~1"=="images" if defined STUB_IMAGES_FAIL exit /b 1
if "%~1"=="build" if defined STUB_BUILD_FAIL exit /b 3
if "%~1"=="images" echo code-it-alpine-dotnet-node:latest& goto :eof
if "%~1"=="image" if "%~2"=="inspect" echo %* | findstr /c:"code-it.agent-binaries" >nul && (
    if defined STUB_IMAGE_AGENT_BINARIES (echo %STUB_IMAGE_AGENT_BINARIES%) else (echo.)
    goto :eof
)
if "%~1"=="image" if "%~2"=="inspect" echo %* | findstr /c:"code-it.agents" >nul && (
    if defined STUB_IMAGE_AGENTS (echo %STUB_IMAGE_AGENTS%) else (echo.)
    goto :eof
)
if "%~1"=="image" if "%~2"=="inspect" (
    if defined STUB_IMAGE_TOOLCHAINS (echo %STUB_IMAGE_TOOLCHAINS%) else (echo dotnet,node)
    goto :eof
)
if "%~1"=="build" echo STUB-DOCKER-BUILD %*& goto :eof
if "%~1"=="run" echo STUB-DOCKER-RUN %*& goto :eof
echo stub docker: %*
'@
} else {
    Set-Content -Path (Join-Path $stubDocker 'docker') -Value @'
#!/bin/sh
case "$1" in
    images) [ -n "$STUB_IMAGES_FAIL" ] && exit 1; echo "code-it-alpine-dotnet-node:latest" ;;
    image)  case "$2" in inspect) case "$*" in *code-it.agent-binaries*) echo "${STUB_IMAGE_AGENT_BINARIES-}" ;; *code-it.agents*) echo "${STUB_IMAGE_AGENTS-}" ;; *) echo "${STUB_IMAGE_TOOLCHAINS-dotnet,node}" ;; esac ;; *) echo "stub docker: $*" ;; esac ;;
    build)  [ -n "$STUB_BUILD_FAIL" ] && exit 3; echo "STUB-DOCKER-BUILD $*" ;;
    run)    echo "STUB-DOCKER-RUN $*" ;;
    *)      echo "stub docker: $*" ;;
esac
'@
    chmod +x (Join-Path $stubDocker 'docker')
}

# Stub Apple container CLI on the PATH, for the forced-runtime scenarios
$stubContainer = Join-Path $tmp 'stub-container'
$null = New-Item -ItemType Directory -Force -Path $stubContainer
if ($onWindows) {
    Set-Content -Path (Join-Path $stubContainer 'container.cmd') -Value @'
@echo off
if "%~1"=="image" if "%~2"=="ls" echo code-it-alpine-dotnet-node  latest& goto :eof
if "%~1"=="image" if "%~2"=="inspect" echo %* | findstr /c:"code-it.agent-binaries" >nul && (
    if defined STUB_IMAGE_AGENT_BINARIES (echo %STUB_IMAGE_AGENT_BINARIES%) else (echo.)
    goto :eof
)
if "%~1"=="image" if "%~2"=="inspect" echo %* | findstr /c:"code-it.agents" >nul && (
    if defined STUB_IMAGE_AGENTS (echo %STUB_IMAGE_AGENTS%) else (echo.)
    goto :eof
)
if "%~1"=="image" if "%~2"=="inspect" (
    if defined STUB_IMAGE_TOOLCHAINS (echo %STUB_IMAGE_TOOLCHAINS%) else (echo dotnet,node)
    goto :eof
)
if "%~1"=="build" echo STUB-CONTAINER-BUILD %*& goto :eof
if "%~1"=="run" echo STUB-CONTAINER-RUN %*& goto :eof
echo stub container: %*
'@
} else {
    Set-Content -Path (Join-Path $stubContainer 'container') -Value @'
#!/bin/sh
case "$1" in
    image)  case "$2" in
                ls)      echo "code-it-alpine-dotnet-node  latest" ;;
                inspect) case "$*" in *code-it.agent-binaries*) echo "${STUB_IMAGE_AGENT_BINARIES-}" ;; *code-it.agents*) echo "${STUB_IMAGE_AGENTS-}" ;; *) echo "${STUB_IMAGE_TOOLCHAINS-dotnet,node}" ;; esac ;;
                *)       echo "stub container: $*" ;;
            esac ;;
    build)  echo "STUB-CONTAINER-BUILD $*" ;;
    run)    echo "STUB-CONTAINER-RUN $*"; printf '[%s]' "$@"; echo ;;
    *)      echo "stub container: $*" ;;
esac
'@
    chmod +x (Join-Path $stubContainer 'container')
}

# A minimal PATH with git but no docker, to test the missing-docker branch
# hermetically even on machines where docker is installed. On Windows, git's own
# directory plus System32 serves; elsewhere, symlink the needed tools into a
# scratch dir. (dotnet is included because pwsh installed as a dotnet global
# tool needs it to launch.)
if ($onWindows) {
    $gitDir = Split-Path (Get-Command git).Source -Parent
    $cleanBin = "$gitDir;$env:SystemRoot\System32"
} else {
    $cleanBin = Join-Path $tmp 'cleanbin'
    $null = New-Item -ItemType Directory -Force -Path $cleanBin
    foreach ($cmd in @('git','sh','uname','dotnet')) {
        $src = (Get-Command $cmd -EA Silent).Source
        if ($src) { $null = New-Item -ItemType SymbolicLink -Path (Join-Path $cleanBin $cmd) -Target $src -EA Silent }
    }
}

$save = Join-Path $tmp 'save'
# Pre-create the save dir: code-it now runs first-run when the save dir is missing.
$null = New-Item -ItemType Directory -Force -Path $save
$sep = [System.IO.Path]::PathSeparator
$origPath = $env:PATH

function Invoke-Scenario([string]$scriptPath, [string[]]$scenarioArgs, [string]$path) {
    $env:PATH = $path
    try {
        $out = & $pwshExe -NoProfile -File $scriptPath @scenarioArgs 2>&1 | Out-String
        return @{ out = $out; code = $LASTEXITCODE }
    } finally {
        $env:PATH = $origPath
    }
}

# For scenarios needing PowerShell syntax in the arguments (e.g. array parameters,
# which -File binding does not split).
function Invoke-ScenarioCommand([string]$command, [string]$path) {
    $env:PATH = $path
    try {
        $out = & $pwshExe -NoProfile -Command $command 2>&1 | Out-String
        return @{ out = $out; code = $LASTEXITCODE }
    } finally {
        $env:PATH = $origPath
    }
}

$stubPath   = "$stubDocker$sep$origPath"
$commonArgs = @('-dryRun', '-WorkDirToMount', $scriptDir, '-saveDir', $save)

# A stub docker that also copies the assembled build-context Dockerfile, so the
# tests can assert exactly which fragments were assembled.
$capture = Join-Path $tmp 'captured.Dockerfile'
$env:CAPTURE = $capture
$captureBin = Join-Path $tmp 'capture-bin'
$null = New-Item -ItemType Directory -Force -Path $captureBin
if ($onWindows) {
    Set-Content -Path (Join-Path $captureBin 'docker.cmd') -Value @'
@echo off
if "%~1"=="build" (
    for %%a in (%*) do set "ctx=%%~a"
    copy /Y "%ctx%\Dockerfile" "%CAPTURE%" >nul 2>nul
    dir /b "%ctx%\ca-certificates" > "%CAPTURE%.ca" 2>nul
    echo STUB-DOCKER-BUILD %*
    goto :eof
)
if "%~1"=="images" echo code-it-alpine-dotnet-node:latest& goto :eof
if "%~1"=="image" (echo dotnet,node& goto :eof)
if "%~1"=="run" (echo STUB-DOCKER-RUN %*& goto :eof)
echo stub docker: %*
'@
} else {
    Set-Content -Path (Join-Path $captureBin 'docker') -Value @'
#!/bin/sh
case "$1" in
    build)
        for a in "$@"; do last="$a"; done
        cp "$last/Dockerfile" "$CAPTURE"
        ls "$last/ca-certificates" > "$CAPTURE.ca" 2>&1
        echo "STUB-DOCKER-BUILD $*" ;;
    images) echo "code-it-alpine-dotnet-node:latest" ;;
    image)  echo dotnet,node ;;
    run)    echo "STUB-DOCKER-RUN $*" ;;
    *)      echo "stub docker: $*" ;;
esac
'@
    chmod +x (Join-Path $captureBin 'docker')
}
$capturePath = "$captureBin$sep$origPath"
function Invoke-Capture([string]$scriptPath, [string[]]$scenarioArgs) {
    Remove-Item $capture -Force -EA Silent
    $null = Invoke-Scenario $scriptPath $scenarioArgs $capturePath
}
function Get-CaptureText {
    if (Test-Path $capture) { return [IO.File]::ReadAllText($capture) }
    return ''
}
function Assert-InCapture([string]$desc, [string]$needle) {
    Assert-Contains $desc (Get-CaptureText) $needle
}
function Assert-NotInCapture([string]$desc, [string]$needle) {
    Assert $desc (-not (Get-CaptureText).Contains($needle))
}

# ---------------------------------------------------------------------------
"1. Parse checks"
foreach ($f in @('Code-It.ps1','Code-It-Build.ps1','Code-It-FirstRun.ps1','Code-It-Add-Agent.ps1','Code-It-Add-Toolchain.ps1','Code-It-Defaults.ps1','lib/CodeItCommon.ps1','Claude-It.ps1','OpenCode-It.ps1','tests/Test-CodeIt.ps1','completions/CodeItCompletion.ps1')) {
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptDir $f), [ref]$null, [ref]$parseErrors)
    Assert "parses: $f" ($parseErrors.Count -eq 0)
}
# Files the bash scripts read or source must check out as LF even where Git
# converts text to CRLF (Windows), or every value read carries a trailing `r
if (Get-Command git -EA Silent) {
    $lfFiles = @('agents/*/config', 'toolchains/*/config', 'package-caches/*/config', 'lib/models.txt', 'completions/_code-it*') |
        ForEach-Object { Get-ChildItem -Path (Join-Path $scriptDir $_) -File } |
        ForEach-Object { [IO.Path]::GetRelativePath($scriptDir, $_.FullName) -replace '\\', '/' }
    foreach ($f in $lfFiles) {
        Assert "checks out LF: $f" ((git -C $scriptDir check-attr eol -- $f) -like '*: eol: lf')
    }
} else {
    "  skip: LF checkout attributes (no git)"
}
# Comment-based help needs a blank line after the shebang: with the shebang directly
# above it, Get-Help finds no help and prints only the one-line syntax.
foreach ($f in @('Code-It.ps1','Code-It-Build.ps1','Code-It-FirstRun.ps1','Code-It-Add-Agent.ps1','Code-It-Add-Toolchain.ps1','Code-It-Defaults.ps1')) {
    $path = Join-Path $scriptDir $f
    Assert "keeps its shebang: $f" ((Get-Content $path -TotalCount 1) -eq '#! /usr/bin/env pwsh')
    $help = Get-Help $path -Full | Out-String
    Assert "full help has a description: $f" ($help.Contains('DESCRIPTION') -and $help.Contains('PARAMETERS') -and ($help -split "`n").Count -gt 80)
}
$r = Invoke-ScenarioCommand "& '$codeIt' -help" $stubPath
Assert "-help exit code 0" ($r.code -eq 0)
Assert-Contains "-help shows the synopsis" $r.out 'Launches an Alpine Linux container'
Assert-Contains "-help documents -agent" $r.out 'Run the agent defined in agents/<name>'
Assert-Contains "-help documents -locale" $r.out "The container's locale (its LANG)"
Assert "-help no longer offers building" (-not $r.out.Contains('-buildImage') -and -not $r.out.Contains('-dockerfileDir'))
Assert-Contains "-help documents the remembered toolchain default" $r.out '<saveDir>/image-history'
foreach ($f in @('Code-It-Add-Agent.ps1','Code-It-Add-Toolchain.ps1')) {
    $help = Get-Help (Join-Path $scriptDir $f) -Full | Out-String
    Assert "help examples use PowerShell's -url: $f" (-not $help.Contains(' --url '))
}

# ---------------------------------------------------------------------------
"2. Default dry-run: opencode agent, only its state mounted"
$r = Invoke-Scenario $codeIt $commonArgs $stubPath
Assert "dry-run exit code 0" ($r.code -eq 0)
Assert-Contains "reports OpenCode config creation" $r.out 'Created OpenCode configuration'
Assert-Contains "uses docker runtime" $r.out 'Using container runtime: docker'
Assert-Contains "defaults to opencode" $r.out 'CODE_AGENT="opencode"'
Assert-Contains "docker run command" $r.out 'docker run -it'
Assert-Contains "image name" $r.out 'code-it-alpine-dotnet-node:latest'
$expectedWork = Get-CodeItWorkMountPath $scriptDir
Assert-Contains "work dir mount" $r.out "$scriptDir`:$expectedWork"
Assert-Contains "work dir env tells go.sh where to cd" $r.out "CODE_IT_WORK_DIR=`"$expectedWork`""
Assert-Contains "opencode config mount" $r.out '/.config/opencode:/home/agent1/.config/opencode'
Assert-Contains "opencode mount" $r.out '/.local/share/opencode:/home/agent1/.local/share/opencode'
Assert "opencode run mounts no claude state" (-not $r.out.Contains('/home/agent1/.claude'))
Assert "no port is mapped by default" (-not $r.out.Contains(' -p '))

# ---------------------------------------------------------------------------
"3. Save dir structure is created for first run"
# The default agent is opencode, which since v2's GA is v2: its state lives under
# save/opencode-v2/ (AGENT_SAVE_SUBDIR), where it has always lived
Assert "save/opencode-v2/.config/opencode created" (Test-Path "$save/opencode-v2/.config/opencode" -PathType Container)
Assert "save/opencode-v2/.local/share/opencode created" (Test-Path "$save/opencode-v2/.local/share/opencode" -PathType Container)
Assert "save/opencode-v2/.local/state/opencode created" (Test-Path "$save/opencode-v2/.local/state/opencode" -PathType Container)
$opencodeV2Config = Get-Content "$save/opencode-v2/.config/opencode/opencode.json" -Raw | ConvertFrom-Json
Assert "OpenCode v2 default config permits all actions" ($opencodeV2Config.permissions[0].action -eq '*' -and $opencodeV2Config.permissions[0].effect -eq 'allow')
$r = Invoke-Scenario $codeIt (@('-agent','opencode-v1') + $commonArgs) $stubPath
Assert-Contains "reports OpenCode v1 config creation" $r.out 'Created OpenCode v1 configuration'
$opencodeV1Config = Get-Content "$save/.config/opencode/config.json" -Raw | ConvertFrom-Json
Assert "OpenCode v1 config permits all actions" ($opencodeV1Config.permission -eq 'allow')
# opencode-v1 reads the same paths as opencode (v2), so it keeps its state at the
# save-dir root while v2's stays under save/opencode-v2/
Assert "opencode-v1 config is not written where opencode (v2) reads it" (-not (Test-Path "$save/opencode-v2/.config/opencode/config.json"))
Assert-Contains "opencode-v1 mounts config" $r.out "$save/.config/opencode:/home/agent1/.config/opencode"
Assert-Contains "opencode-v1 mounts data and auth" $r.out "$save/.local/share/opencode:/home/agent1/.local/share/opencode"
Assert "opencode-v1 mounts no v2 shared-service state" (-not $r.out.Contains('/home/agent1/.local/state/opencode'))
Assert "opencode-v1 mounts no claude state" (-not $r.out.Contains('/home/agent1/.claude'))
Assert "opencode run creates no claude state" (-not (Test-Path "$save/.claude"))

# ---------------------------------------------------------------------------
"4. Agent selection switches"
$r = Invoke-Scenario $codeIt (@('-opencode') + $commonArgs) $stubPath
Assert-Contains "-opencode selects opencode" $r.out 'CODE_AGENT="opencode"'
$r = Invoke-Scenario $codeIt (@('-o') + $commonArgs) $stubPath
Assert-Contains "-o selects opencode" $r.out 'CODE_AGENT="opencode"'
$r = Invoke-Scenario $codeIt (@('-claude') + $commonArgs) $stubPath
Assert-Contains "-claude selects claude" $r.out 'CODE_AGENT="claude"'
Assert-Contains "reports Claude settings creation" $r.out 'Created Claude Code settings'
Assert-Contains "claude dir mount" $r.out '/.claude:/home/agent1/.claude'
Assert-Contains "claude.json mount" $r.out '/.claude.json:/home/agent1/.claude.json'
Assert "claude run mounts no opencode state" (-not $r.out.Contains('/home/agent1/.config/opencode'))
$claudeSettings = Get-Content "$save/.claude/settings.json" -Raw | ConvertFrom-Json
Assert "Claude settings enable auto mode" ($claudeSettings.permissions.defaultMode -eq 'auto')
Assert "Claude settings skip dangerous-mode prompt" ($claudeSettings.skipDangerousModePermissionPrompt -eq $true)
Assert "save/.claude.json pre-created as a file" (Test-Path "$save/.claude.json" -PathType Leaf)
$r = Invoke-Scenario $codeIt (@('-c') + $commonArgs) $stubPath
Assert-Contains "-c selects claude" $r.out 'CODE_AGENT="claude"'
$r = Invoke-Scenario $codeIt (@('-agent','claude') + $commonArgs) $stubPath
Assert-Contains "-agent claude selects claude" $r.out 'CODE_AGENT="claude"'
$r = Invoke-Scenario $codeIt (@('-agent','opencode') + $commonArgs) $stubPath
Assert-Contains "-agent opencode selects opencode" $r.out 'CODE_AGENT="opencode"'
$r = Invoke-Scenario $codeIt (@('-agent','opencode-v1') + $commonArgs) $stubPath
Assert-Contains "-agent opencode-v1 selects v1" $r.out 'CODE_AGENT="opencode-v1"'
$r = Invoke-ScenarioCommand "& '$codeIt' -listAgents" $stubPath
Assert "listAgents exit code 0" ($r.code -eq 0)
Assert-Contains "-listAgents lists claude" $r.out 'claude'
Assert-Contains "-listAgents lists opencode" $r.out 'opencode'
Assert-Contains "-listAgents lists opencode-v1" $r.out 'opencode-v1'
$r = Invoke-Scenario $codeIt (@('-agent','nosuchagent') + $commonArgs) $stubPath
Assert "unknown -agent fails" ($r.code -ne 0)
Assert-Contains "unknown agent lists the available agents" $r.out 'The available agents are:'
Assert-Contains "the agent list includes a short flag" $r.out '  opencode   -o'
Assert-Contains "unknown agent explains code-it-add-agent" $r.out 'code-it-add-agent NAME adds a new one, if the agent has a recognised internet presence'
$r = Invoke-Scenario $codeIt (@('-c','-o') + $commonArgs) $stubPath
Assert "-c and -o together fails" ($r.code -ne 0)

# ---------------------------------------------------------------------------
"5. Alias scripts"
$r = Invoke-Scenario (Join-Path $scriptDir 'Claude-It.ps1') $commonArgs $stubPath
Assert "Claude-It.ps1 exit code 0" ($r.code -eq 0)
Assert-Contains "Claude-It.ps1 selects claude" $r.out 'CODE_AGENT="claude"'
$r = Invoke-Scenario (Join-Path $scriptDir 'OpenCode-It.ps1') $commonArgs $stubPath
Assert "OpenCode-It.ps1 exit code 0" ($r.code -eq 0)
Assert-Contains "OpenCode-It.ps1 selects opencode" $r.out 'CODE_AGENT="opencode"'

# ---------------------------------------------------------------------------
"6. No runtime found: fails with advice"
$r = Invoke-Scenario $codeIt $commonArgs $cleanBin
Assert "no runtime exits non-zero" ($r.code -ne 0)
Assert-Contains "no runtime warns" $r.out 'No container runtime found'
Assert-Contains "suggests an install link" $r.out 'docs.docker.com'

# ---------------------------------------------------------------------------
"7. Runtime selection"
$r = Invoke-Scenario $codeIt (@('-runtime', 'container') + $commonArgs) "$stubContainer$sep$stubPath"
Assert "-runtime container exit code 0" ($r.code -eq 0)
Assert-Contains "-runtime container forces apple container" $r.out 'Using container runtime: container'
Assert-Contains "container run command" $r.out 'container run -it'
Assert "the Apple container runtime maps no port by default" (-not $r.out.Contains(' -p '))
Assert-Contains "container dry-run shows memory limit" $r.out '--memory 3g'
if (-not $onWindows) {
    $r = Invoke-Scenario $codeIt @('-runtime', 'container', '-WorkDirToMount', $scriptDir, '-saveDir', $save) "$stubContainer$sep$stubPath"
    Assert-Contains "container run gets --memory and 3g as separate arguments" $r.out '[--memory][3g]'
}
$r = Invoke-Scenario $codeIt (@('-runtime', 'bogus') + $commonArgs) $stubPath
Assert "-runtime bogus fails" ($r.code -ne 0)

# ---------------------------------------------------------------------------
"8. Error handling"
$r = Invoke-Scenario $codeIt @('-dryRun', '-WorkDirToMount', (Join-Path $tmp 'does-not-exist'), '-saveDir', $save) $stubPath
Assert "missing work dir fails" ($r.code -ne 0)
$r = Invoke-Scenario $codeIt (@('-image', 'no-such-image') + $commonArgs) $stubPath
Assert "unknown explicit image fails" ($r.code -ne 0)
$env:STUB_IMAGES_FAIL = '1'
try { $r = Invoke-Scenario $codeIt $commonArgs $stubPath } finally { $env:STUB_IMAGES_FAIL = $null }
Assert "failure to list images fails" ($r.code -ne 0)
Assert-Contains "failure to list images asks if the runtime is running" $r.out 'Could not list docker images'

# ---------------------------------------------------------------------------
"9. Code-It does not build"
foreach ($removedArgs in @(@('-buildImage'), @('-b'), @('-rebuildImage'), @('-dockerfileDir', $tmp))) {
    $r = Invoke-Scenario $codeIt ($removedArgs + $commonArgs) $stubPath
    Assert "removed $($removedArgs[0]) fails" ($r.code -ne 0)
    Assert-Contains "removed $($removedArgs[0]) points to Code-It-Build" $r.out 'has been removed: build images with Code-It-Build.ps1'
    Assert "removed $($removedArgs[0]) does not build" (-not $r.out.Contains('STUB-DOCKER-BUILD'))
}

# ---------------------------------------------------------------------------
"9c. Code-It-Build.ps1: dry-run, labels, -tech, -rebuild"
$codeItBuild = Join-Path $scriptDir 'Code-It-Build.ps1'
$today = [DateTime]::Today.ToString('yyyy-MM-dd')

# With no toolchain, build enters interactive setup. -yes uses the detected/default selections.
$r = Invoke-Scenario $codeItBuild @('-yes', '-dryRun', '-dockerfileDir', $scriptDir) $stubPath
Assert "Code-It-Build without -toolchain enters setup successfully" ($r.code -eq 0)
Assert-Contains "interactive build resolves a toolchain" $r.out 'Building with toolchains'
Assert "interactive build does not invoke docker" (-not $r.out.Contains('STUB-DOCKER-BUILD'))
# Menu numbers select the requested items (toolchains and agents listed alphabetically).
$env:PATH = $stubPath
try {
    $out = "2`n1`ny" | & $pwshExe -NoProfile -Command "& '$codeItBuild' -dryRun -dockerfileDir '$scriptDir'" 2>&1 | Out-String
} finally { $env:PATH = $origPath }
Assert-Contains "interactive build asks about agents" $out 'Agents to install'
Assert-Contains "interactive build selects the numbered toolchain" $out 'toolchains dotnet'
Assert-Contains "interactive build selects the numbered agent" $out 'agents claude'
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-toolchain', ',') $stubPath
Assert "Code-It-Build with an empty -toolchain list exits 1" ($r.code -eq 1)
Invoke-Capture $codeItBuild @('-dockerfileDir', $scriptDir, '-toolchain', 'dotnet', '-runtime', 'docker')
Assert-InCapture "Code-It-Build assembles the toolchain given" 'dotnet-sdk-$version-linux-musl'
Assert-NotInCapture "Code-It-Build builds only the toolchain given" 'apk add --no-cache nodejs'

# -dryRun prints the build command without executing it
$r = Invoke-Scenario $codeItBuild @('-toolchain', 'dotnet,node', '-dryRun', '-dockerfileDir', $scriptDir) $stubPath
Assert "Code-It-Build -dryRun exit code 0" ($r.code -eq 0)
Assert-Contains "build dry-run prints the build command" $r.out 'docker build'
Assert-Contains "build dry-run labels the toolchains" $r.out '--label code-it.toolchains=dotnet,node'
Assert-Contains "build dry-run labels the package caches" $r.out '--label code-it.package-caches=nuget,npm'
Assert-Contains "build dry-run derives the default image name" $r.out '-t code-it-alpine-dotnet-node:latest'
Assert "build dry-run does not execute the build" (-not $r.out.Contains('STUB-DOCKER-BUILD'))

# The build assembles the selected toolchains and their implied caches only
Invoke-Capture $codeItBuild @('-toolchain', 'dotnet,node', '-dockerfileDir', $scriptDir, '-runtime', 'docker')
Assert-InCapture "build assembles dotnet" 'dotnet-sdk-$version-linux-musl'
Assert-InCapture "dotnet SDKs are verified against Microsoft's SHA-512" 'sha512sum -c "$file.sha512"'
Assert-InCapture "dotnet installs both the 10.0 and 8.0 SDKs" 'for channel in 10.0 8.0'
Assert-NotInCapture "dotnet does not use Alpine's mismatched dotnet10-sdk apk" 'apk add --no-cache dotnet10-sdk dotnet8-sdk'
Assert-InCapture "build assembles node" 'apk add --no-cache nodejs'
Assert-InCapture "dotnet implies the nuget package cache" 'fallbackPackageFolders'
Assert-InCapture "node implies the npm package cache" '/home/agent1/.npm-host'
Assert-NotInCapture "build leaves bun out" 'bun.sh/install'
Assert-NotInCapture "build leaves python out" 'apk add --no-cache python3 uv'
Assert-NotInCapture "build leaves powershell out" 'PowerShell/releases/download'
Assert "assembled Dockerfile is under Apple's 16KB limit" ((Get-CaptureText).Length -lt 16384)
Assert-InCapture "agent state dirs are pre-created for mounts" '~/.local/share/opencode'
# Each installed agent's binary directory goes on zsh's PATH, so a --no-agent
# shell can invoke any of them (Spec 18)
Assert-InCapture "each installed agent's binary dir goes on zsh's PATH" 'export PATH="/home/agent1/.opencode-v2/bin:/home/agent1/.local/bin:$PATH"'
Invoke-Capture $codeItBuild @('-toolchain', 'dotnet', '-agent', 'claude', '-dockerfileDir', $scriptDir, '-runtime', 'docker')
Assert-InCapture "claude state dir is pre-created for mounts" '~/.claude'
Assert-NotInCapture "claude state file is not created as a directory" '~/.claude.json'
Assert-NotInCapture "an assembled image has only the selected agents" 'opencode.ai/install'
Assert-InCapture "a single agent's binary dir goes on zsh's PATH" 'export PATH="/home/agent1/.local/bin:$PATH"'

# -tech is the kept alias of -toolchain
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-tech', 'bun') $stubPath
Assert-Contains "build -tech alias derives the image name" $r.out '-t code-it-alpine-bun:latest'
Invoke-Capture $codeItBuild @('-dockerfileDir', $scriptDir, '-tech', 'bun', '-runtime', 'docker')
Assert-InCapture "build -tech alias assembles bun" 'bun.sh/install'

# -packageCaches replaces the implied set
Invoke-Capture $codeItBuild @('-dockerfileDir', $scriptDir, '-toolchain', 'bun', '-packageCaches', 'nuget', '-runtime', 'docker')
Assert-InCapture "build -packageCaches nuget without dotnet assembles the cache" 'fallbackPackageFolders'
Assert-InCapture "build -packageCaches nuget adds its doas permit" 'cmd nuget'
Assert-NotInCapture "build -packageCaches nuget excludes npm" '/home/agent1/.npm-host'
$r = Invoke-ScenarioCommand "Remove-Item '$capture' -Force -EA Silent; & '$codeItBuild' -dockerfileDir '$scriptDir' -toolchain node -packageCaches '' -runtime docker" $capturePath
Assert-InCapture "empty -packageCaches still assembles node" 'apk add --no-cache nodejs'
Assert-NotInCapture "empty -packageCaches assembles no cache" '/home/agent1/.npm-host'

# A Dockerfile without the assembly markers is a hard error
$noMarker = Join-Path $tmp 'nomarker'
$null = New-Item -ItemType Directory -Force -Path $noMarker
Set-Content -Path (Join-Path $noMarker 'Dockerfile') -Value 'FROM alpine:3.24'
Copy-Item (Join-Path $scriptDir 'agents') (Join-Path $noMarker 'agents') -Recurse -Force
$r = Invoke-Scenario $codeItBuild @('-toolchain', 'dotnet', '-dockerfileDir', $noMarker, '-runtime', 'docker') $capturePath
Assert "Code-It-Build without assembly markers fails" ($r.code -ne 0)

# -listToolchains and -listPackageCaches read the definitions
$r = Invoke-ScenarioCommand "& '$codeItBuild' -listToolchains" $stubPath
Assert-Contains "Code-It-Build -listToolchains lists powershell" $r.out 'powershell'
Assert-Contains "Code-It-Build -listToolchains shows the pwsh alias" $r.out 'aliases: pwsh'
$r = Invoke-ScenarioCommand "& '$codeItBuild' -listPackageCaches" $stubPath
Assert-Contains "Code-It-Build -listPackageCaches lists nuget" $r.out 'nuget'

# Unknown names are hard errors
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-toolchain', 'cobol') $stubPath
Assert "Code-It-Build unknown toolchain fails" ($r.code -ne 0)
$r = Invoke-Scenario $codeItBuild @('-toolchain', 'dotnet,node', '-dryRun', '-dockerfileDir', $scriptDir, '-packageCaches', 'pip') $stubPath
Assert "Code-It-Build unknown package cache fails" ($r.code -ne 0)

# -rebuild bumps the dates and then really builds
$bDfDir = Join-Path $tmp 'build-dfdir'
$null = New-Item -ItemType Directory -Force -Path $bDfDir
Copy-Item (Join-Path $scriptDir 'Dockerfile') (Join-Path $bDfDir 'Dockerfile')
foreach ($d in @('agents', 'toolchains', 'package-caches')) {
    Copy-Item (Join-Path $scriptDir $d) (Join-Path $bDfDir $d) -Recurse -Force
}
foreach ($t in @('dotnet', 'bun')) {
    $p = Join-Path $bDfDir "toolchains/$t/install.dockerfile"
    [IO.File]::WriteAllText($p, ([IO.File]::ReadAllText($p) -replace '# last changed [0-9-]+', '# last changed 2000-01-01'))
}
foreach ($a in @('opencode', 'claude', 'opencode-v1')) {
    $p = Join-Path $bDfDir "agents/$a/install.dockerfile"
    [IO.File]::WriteAllText($p, ([IO.File]::ReadAllText($p) -replace '# last changed [0-9-]+', '# last changed 2000-01-01'))
}
$r = Invoke-Scenario $codeItBuild @('-toolchain', 'dotnet,node', '-rebuild', '-dockerfileDir', $bDfDir, '-runtime', 'docker', '-agent', 'opencode,claude,opencode-v1') $stubPath
Assert "Code-It-Build -rebuild exit code 0" ($r.code -eq 0)
Assert-Contains "Code-It-Build -rebuild invokes docker build" $r.out 'STUB-DOCKER-BUILD'
Assert "Code-It-Build -rebuild bumps the opencode fragment" ((Get-Content (Join-Path $bDfDir 'agents/opencode/install.dockerfile') -Raw).Contains("# last changed $today"))
Assert "Code-It-Build -rebuild bumps the claude fragment" ((Get-Content (Join-Path $bDfDir 'agents/claude/install.dockerfile') -Raw).Contains("# last changed $today"))
Assert "Code-It-Build -rebuild bumps the opencode-v1 fragment" ((Get-Content (Join-Path $bDfDir 'agents/opencode-v1/install.dockerfile') -Raw).Contains("# last changed $today"))
Assert "Code-It-Build -rebuild bumps the selected toolchain fragment" ((Get-Content (Join-Path $bDfDir 'toolchains/dotnet/install.dockerfile') -Raw).Contains("# last changed $today"))
Assert "Code-It-Build -rebuild leaves unselected toolchain fragments alone" ((Get-Content (Join-Path $bDfDir 'toolchains/bun/install.dockerfile') -Raw).Contains('# last changed 2000-01-01'))
# A missing Dockerfile is an error
$r = Invoke-Scenario $codeItBuild @('-toolchain', 'dotnet,node', '-dryRun', '-dockerfileDir', $tmp) $stubPath
Assert "Code-It-Build without a Dockerfile fails" ($r.code -ne 0)
# Extra CA certificates next to the Dockerfile reach the build context, and the
# assembled Dockerfile trusts them before its first apk fetch. With no
# ca-certificates/ folder, the context still has an empty one for COPY.
$caCapture = "$capture.ca"
Remove-Item $caCapture -Force -EA Silent
$r = Invoke-Scenario $codeItBuild @('-toolchain', 'dotnet', '-dockerfileDir', $bDfDir, '-runtime', 'docker') $capturePath
Assert "Code-It-Build without ca-certificates/ gives the context an empty one" ((Test-Path $caCapture) -and -not ([IO.File]::ReadAllText($caCapture).Trim()))
Assert-Contains "Code-It-Build says when no certificate trust was requested" $r.out 'No additional certificate trust was requested'
$bDfCa = Join-Path $bDfDir 'ca-certificates'
$null = New-Item -ItemType Directory -Force -Path $bDfCa
[IO.File]::WriteAllText((Join-Path $bDfCa 'test-proxy-ca.crt'), "-----BEGIN CERTIFICATE-----`nTEST`n-----END CERTIFICATE-----`n")
Remove-Item $caCapture -Force -EA Silent
Remove-Item $capture -Force -EA Silent
$r = Invoke-Scenario $codeItBuild @('-toolchain', 'dotnet', '-dockerfileDir', $bDfDir, '-runtime', 'docker') $capturePath
Assert-Contains "Code-It-Build lists the certificate files it adds trust for" $r.out 'Adding certificate trust from ca-certificates/: test-proxy-ca.crt'
Assert "Code-It-Build copies ca-certificates/ into the build context" ((Test-Path $caCapture) -and ((Get-Content $caCapture) -contains 'test-proxy-ca.crt'))
Assert-InCapture "assembled Dockerfile copies the extra CA certificates" 'COPY ca-certificates/'
$df = Get-CaptureText
$caCopyAt = $df.IndexOf('COPY ca-certificates/')
Assert "extra CA certificates are trusted before the first apk add" ($caCopyAt -ge 0 -and $caCopyAt -lt $df.IndexOf('apk add'))
Remove-Item -Recurse -Force $bDfCa

"9f. Code-It-Build agents"
$r = Invoke-Scenario $codeItBuild @('-toolchain', 'dotnet,node', '-dryRun', '-dockerfileDir', $scriptDir) $stubPath
Assert-Contains "default build installs opencode and claude" $r.out 'agents opencode,claude'
Assert-Contains "default build labels the agents" $r.out '--label code-it.agents=opencode,claude'
$r = Invoke-Scenario $codeItBuild @('-toolchain', 'dotnet,node', '-dryRun', '-dockerfileDir', $scriptDir, '-agent', 'opencode') $stubPath
Assert-Contains "-agent opencode selects only opencode" $r.out 'agents opencode'
Assert "default -agent excludes claude" (-not $r.out.Contains('agents opencode,claude'))
$r = Invoke-ScenarioCommand "& '$codeItBuild' -toolchain 'dotnet,node' -dryRun -dockerfileDir '$scriptDir' -agent 'claude,opencode'" $stubPath
Assert-Contains "-agent accepts a list" $r.out 'agents claude,opencode'
$r = Invoke-Scenario $codeItBuild @('-toolchain', 'dotnet,node', '-dryRun','-dockerfileDir',$scriptDir,'-agent','opencode-v1') $stubPath
Assert-Contains "-agent opencode-v1 selects the v1 installer" $r.out 'agents opencode-v1'
Assert-Contains "opencode-v1 image label records the agent" $r.out '--label code-it.agents=opencode-v1'
Assert-Contains "opencode-v1 image label records its binary" $r.out '--label code-it.agent-binaries=opencode-v1=/home/agent1/.opencode/bin/opencode'
$r = Invoke-ScenarioCommand "& '$codeItBuild' -toolchain 'dotnet,node' -dryRun -dockerfileDir '$scriptDir' -agent 'claude,opencode'" $stubPath
Assert-Contains "agent-binaries label lists every agent" $r.out '--label code-it.agent-binaries=claude=/home/agent1/.local/bin/claude,opencode=/home/agent1/.opencode-v2/bin/opencode'
$v2Install = Get-Content (Join-Path $scriptDir 'agents/opencode/install.dockerfile') -Raw
Assert "opencode (v2) uses the pinned official installer" ($v2Install.Contains('https://opencode.ai/v2/install -o') -and $v2Install -match 'HOME=\S+ bash \S+ --version 2\.0\.6')
Assert "opencode and opencode-v1 binaries do not overwrite each other" ((Select-String -Path (Join-Path $scriptDir 'agents/opencode/config') -Pattern '^AGENT_BINARY=').Line -ne (Select-String -Path (Join-Path $scriptDir 'agents/opencode-v1/config') -Pattern '^AGENT_BINARY=').Line)
Assert "opencode (v2) installs to its own AGENT_BINARY path" ($v2Install -match 'mv \S+/\.opencode/bin/opencode ~/\.opencode-v2/bin/opencode')
$r = Invoke-ScenarioCommand "& '$codeItBuild' -listAgents" $stubPath
Assert "Code-It-Build -listAgents exit code 0" ($r.code -eq 0)
Assert-Contains "Code-It-Build -listAgents lists claude" $r.out 'claude'
Assert-Contains "Code-It-Build -listAgents lists opencode" $r.out 'opencode'
$r = Invoke-Scenario $codeItBuild @('-toolchain', 'dotnet,node', '-dryRun', '-dockerfileDir', $scriptDir, '-agent', 'nosuch') $stubPath
Assert "Code-It-Build unknown agent fails" ($r.code -ne 0)

"9d. Code-It reads the image label"
$env:STUB_IMAGE_TOOLCHAINS = 'node,bun'
try { $r = Invoke-Scenario $codeIt (@('-toolchain', 'dotnet,node', '-image', 'code-it-alpine-dotnet-node') + $commonArgs) $stubPath }
finally { $env:STUB_IMAGE_TOOLCHAINS = $null }
Assert-Contains "warns when the image label disagrees with -toolchain" $r.out "looks built for toolchains 'node,bun'"
# There is no default toolchain: -image alone takes the image's own toolchains
$env:STUB_IMAGE_TOOLCHAINS = 'node,bun'
try { $r = Invoke-Scenario $codeIt (@('-image', 'code-it-alpine-dotnet-node') + $commonArgs) $stubPath }
finally { $env:STUB_IMAGE_TOOLCHAINS = $null }
Assert "-image without -toolchain runs" ($r.code -eq 0)
Assert "-image without -toolchain does not assume dotnet,node" (-not $r.out.Contains('looks built for'))
Assert "-image without -toolchain mounts the caches of the image's toolchains" (-not $r.out.Contains('NuGet'))
$r = Invoke-Scenario $codeIt (@('-toolchain', ',') + $commonArgs) $stubPath
Assert "an empty -toolchain list fails" ($r.code -ne 0)

"9g. PowerShell toolchain (powershell / pwsh)"
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-toolchain', 'dotnet,node,powershell') $stubPath
Assert-Contains "-toolchain powershell derives the image name" $r.out '-t code-it-alpine-dotnet-node-powershell:latest'
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-toolchain', 'pwsh') $stubPath
Assert-Contains "pwsh aliases powershell" $r.out '-t code-it-alpine-powershell:latest'
Invoke-Capture $codeItBuild @('-dockerfileDir', $scriptDir, '-toolchain', 'powershell,pwsh', '-runtime', 'docker')
Assert-InCapture "powershell toolchain assembles pwsh" 'PowerShell/releases/download'
Assert-NotInCapture "powershell does not drag the dotnet toolchain in" 'dotnet workload update'
Assert-InCapture "powershell on aarch64 uses Microsoft's musl .NET SDK" 'dotnet-sdk-$version-linux-musl-arm64'
Assert-InCapture "powershell verifies the .NET SDK against Microsoft's SHA-512" 'sha512sum -c "$file.sha512"'
Assert-NotInCapture "powershell does not use Alpine's mismatched dotnet10-sdk apk" 'apk add --no-cache dotnet10-sdk'
Assert-InCapture "powershell reuses a 10.0 SDK the dotnet toolchain installed" 'ls /usr/share/dotnet/sdk'
Invoke-Capture $codeItBuild @('-dockerfileDir', $scriptDir, '-toolchain', 'dotnet,node', '-runtime', 'docker')
Assert-NotInCapture "a build without powershell leaves it out" 'PowerShell/releases/download'

"9e. Python toolchain (python / uv / -stack)"
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-stack', 'python') $stubPath
Assert-Contains "-stack python derives the image name" $r.out '-t code-it-alpine-python:latest'
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-toolchain', 'uv') $stubPath
Assert-Contains "uv canonical image name" $r.out '-t code-it-alpine-python:latest'
Invoke-Capture $codeItBuild @('-dockerfileDir', $scriptDir, '-toolchain', 'uv', '-runtime', 'docker')
Assert-InCapture "uv aliases python and assembles both" 'apk add --no-cache python3 uv'
Assert-InCapture "python sets UV_CACHE_DIR in the agent home" 'UV_CACHE_DIR=/home/agent1/.cache/uv'
Invoke-Capture $codeItBuild @('-dockerfileDir', $scriptDir, '-toolchain', 'dotnet,node', '-runtime', 'docker')
Assert-NotInCapture "a build without python leaves it out" 'python3'
$r = Invoke-Scenario $codeIt (@('-stack', 'python') + $commonArgs) $stubPath
Assert-Contains "code-it -stack python looks for the python image" $r.out "image 'code-it-alpine-python' does not exist; building it"
$dfText = Get-Content (Join-Path $scriptDir 'Dockerfile') -Raw
Assert "base Dockerfile puts the default agent's binary dir on zsh's PATH" `
    ($dfText.Contains('RUN echo ''export PATH="/home/agent1/.opencode-v2/bin:$PATH"'' >> ~/.zshrc'))
Assert "the python fragment installs uv with Python" ((Get-Content (Join-Path $scriptDir 'toolchains/python/install.dockerfile') -Raw).Contains('apk add --no-cache python3 uv'))
Assert "the base Dockerfile has no toolchain switches" (-not ($dfText -match '(?m)^ARG (DOTNET|NODE|BUN|PYTHON|POWERSHELL)='))
Assert "Dockerfile does not install uv in the base image" (-not ($dfText -match '(?m)^RUN apk add --no-cache uv\s*$'))
# The base layer installs tools only: no GUI packages, no Kerberos, no edge repo.
# Libraries come with the toolchain or agent that needs them.
Assert "Dockerfile base installs no GUI, Kerberos or docs packages" (-not ($dfText -match 'apk .*(chromium|ttf-freefont|freetype-dev|krb5|\sdocs\s)'))
Assert "Dockerfile does not mix in the edge repository" (-not $dfText.Contains('edge/main'))
Assert "Dockerfile base keeps musl-locales for international text" ($dfText -match 'apk add --no-cache .*musl-locales')
Assert "PowerShell tarball layer adds the libraries it needs" ((Get-Content (Join-Path $scriptDir 'toolchains/powershell/install.dockerfile') -Raw).Contains('apk add --no-cache libgcc libstdc++ icu-libs libssl3 && '))
foreach ($a in @('opencode', 'opencode-v1')) {
    $fragment = Get-Content (Join-Path $scriptDir "agents/$a/install.dockerfile") -Raw
    Assert "$a install fragment adds libgcc and libstdc++" ($fragment -match '(?m)^RUN apk add --no-cache libgcc libstdc\+\+\r?$')
}

"9g. Choosing an existing image that contains the requested toolchains"
$superDocker = Join-Path $tmp 'super-docker'
$null = New-Item -ItemType Directory -Force -Path $superDocker
if ($onWindows) {
    Set-Content -Path (Join-Path $superDocker 'docker.cmd') -Value @'
@echo off
if "%~1"=="images" (for %%i in (%STUB_IMAGES%) do @echo %%i) & goto :eof
if "%~1"=="image" (
    echo %~n0 %* | findstr /C:"code-it-alpine-dotnet-bun" >nul && (echo dotnet,bun& goto :eof)
    echo %~n0 %* | findstr /C:"code-it-alpine-dotnet-node" >nul && (echo dotnet,node& goto :eof)
    echo %~n0 %* | findstr /C:"code-it-alpine-dotnet" >nul && (echo dotnet& goto :eof)
    echo.
    goto :eof
)
echo stub docker: %*
'@
} else {
    Set-Content -Path (Join-Path $superDocker 'docker') -Value @'
#!/bin/sh
case "$1" in
    images) printf '%s\n' $STUB_IMAGES ;;
    image)
        for a in "$@"; do last="$a"; done
        case "$last" in
            code-it-alpine-dotnet-bun*)  echo dotnet,bun ;;
            code-it-alpine-dotnet-node*) echo dotnet,node ;;
            code-it-alpine-dotnet*)      echo dotnet ;;
            *)                           echo "" ;;
        esac ;;
    *) echo "STUB $*" ;;
esac
'@
    chmod +x (Join-Path $superDocker 'docker')
}
$superPath = "$superDocker$sep$stubPath"

# The exact image, when it exists, is used unchanged
$env:STUB_IMAGES = 'code-it-alpine-dotnet-bun:latest code-it-alpine-dotnet:latest'
try { $r = Invoke-Scenario $codeIt (@('-toolchain', 'dotnet') + $commonArgs) $superPath }
finally { $env:STUB_IMAGES = $null }
Assert-Contains "uses the exact image when it exists" $r.out 'code-it-alpine-dotnet:latest'
Assert "no substitution when the exact image exists" (-not $r.out.Contains('does not exist; using'))

# The exact image missing: the most-recently listed image containing the chain wins
$env:STUB_IMAGES = 'code-it-alpine-dotnet-bun:latest code-it-alpine-dotnet-node:latest'
try { $r = Invoke-Scenario $codeIt (@('-toolchain', 'dotnet') + $commonArgs) $superPath }
finally { $env:STUB_IMAGES = $null }
Assert-Contains "substitutes a superset image" $r.out "does not exist; using 'code-it-alpine-dotnet-bun'"
Assert-Contains "runs the superset image" $r.out 'code-it-alpine-dotnet-bun:latest'
Assert-Contains "notes the extra toolchains" $r.out 'also contains bun'

# Order decides
$env:STUB_IMAGES = 'code-it-alpine-dotnet-node:latest code-it-alpine-dotnet-bun:latest'
try { $r = Invoke-Scenario $codeIt (@('-toolchain', 'dotnet') + $commonArgs) $superPath }
finally { $env:STUB_IMAGES = $null }
Assert-Contains "picks the most recent qualifying image" $r.out "using 'code-it-alpine-dotnet-node'"

# Every requested chain must be present
$env:STUB_IMAGES = 'code-it-alpine-dotnet-node:latest'
try { $r = Invoke-Scenario $codeIt (@('-toolchain', 'dotnet,bun') + $commonArgs) $superPath }
finally { $env:STUB_IMAGES = $null }
Assert-Contains "requires every requested chain to be present" $r.out "'code-it-alpine-dotnet-bun' does not exist; building it"

# No image contains the requested chain: warn, then build it and run it
$env:STUB_IMAGES = 'code-it-alpine-dotnet-node:latest code-it-alpine-dotnet-bun:latest'
try { $r = Invoke-Scenario $codeIt (@('-toolchain', 'python') + $commonArgs) $superPath }
finally { $env:STUB_IMAGES = $null }
Assert "builds when no image contains the requested chain" ($r.code -eq 0)
Assert-Contains "warns that the image is missing" $r.out "image 'code-it-alpine-python' does not exist; building it with Code-It-Build.ps1 -toolchain python"
Assert-Contains "builds the missing image" $r.out '-t code-it-alpine-python:latest'
Assert-Contains "builds the default agents and the chosen one" $r.out 'code-it.agents=opencode,claude '
Assert-Contains "then runs the built image" $r.out 'docker run'
Assert "-dryRun passes -dryRun to the build" (-not $r.out.Contains('STUB build'))

# The build is given the run's toolchains, package caches, locale, runtime and image,
# with the chosen agent added to the defaults
$stubBuild = Join-Path $tmp 'stub-build.ps1'
Set-Content -Path $stubBuild -Value @'
param([string]$toolchain, [string]$packageCaches, [string]$agent, [string]$locale,
      [string]$runtime, [string]$image, [switch]$yes, [switch]$dryRun)
"STUB-BUILD toolchain=$toolchain packageCaches=$packageCaches agent=$agent locale=$locale runtime=$runtime image=$image yes=$yes dryRun=$dryRun"
exit ([int]$env:STUB_BUILD_RC)
'@
$env:CODE_IT_BUILD = $stubBuild
$env:STUB_IMAGES = 'code-it-alpine-dotnet:latest'
try {
    $r = Invoke-Scenario $codeIt (@('-toolchain', 'python', '-packageCaches', 'npm', '-locale', 'en-GB', '-agent', 'opencode-v1') + $commonArgs) $superPath
    Assert-Contains "build gets the toolchains and package caches" $r.out 'STUB-BUILD toolchain=python packageCaches=npm'
    Assert-Contains "build gets the defaults plus the chosen agent" $r.out 'agent=opencode,claude,opencode-v1'
    Assert-Contains "build gets the locale, runtime and image" $r.out 'locale=en-GB runtime=docker image=code-it-alpine-python yes=True dryRun=True'
    $r = Invoke-Scenario $codeIt (@('-toolchain', 'python', '-claude') + $commonArgs) $superPath
    Assert-Contains "an agent already in the defaults is not repeated" $r.out 'agent=opencode,claude locale'
    $r = Invoke-Scenario $codeIt (@('-toolchain', 'python', '-noAgent') + $commonArgs) $superPath
    Assert-Contains "-noAgent builds the default agents" $r.out 'agent=opencode,claude locale'
    $env:STUB_BUILD_RC = '3'
    $r = Invoke-Scenario $codeIt (@('-toolchain', 'python') + $commonArgs) $superPath
    Assert "a failed build exits with its code" ($r.code -eq 3)
    Assert-Contains "a failed build says so" $r.out "Building 'code-it-alpine-python' failed"
    Assert "a failed build does not run" (-not $r.out.Contains('docker run'))
    $env:STUB_BUILD_RC = $null

    # An explicit -image is never substituted or built
    $env:STUB_IMAGES = 'code-it-alpine-dotnet-bun:latest'
    $r = Invoke-Scenario $codeIt (@('-toolchain', 'dotnet', '-image', 'code-it-alpine-nope') + $commonArgs) $superPath
    Assert "explicit -image is used as-is and errors if missing" ($r.code -ne 0)
    Assert "explicit -image is not built" (-not $r.out.Contains('STUB-BUILD'))
}
finally { $env:STUB_IMAGES = $null; $env:STUB_BUILD_RC = $null; $env:CODE_IT_BUILD = $null }

"9h. Dockerfile comment stripping keeps the buildable Dockerfile small"
$stripTest = @"
. '$scriptDir/lib/CodeItCommon.ps1'
`$text = [IO.File]::ReadAllText('$scriptDir/Dockerfile')
`$out = Remove-CodeItDockerfileComments `$text
"STRIPLEN:" + `$out.Length
"HEREDOC:" + ([regex]::Matches(`$out, 'Arguments given to the container').Count)
"RUNLINE:" + ([regex]::Matches(`$out, 'apk add --no-cache git').Count)
"@
$r = Invoke-ScenarioCommand $stripTest $stubPath
Assert "stripping script ran" ($r.code -eq 0 -or $null -eq $r.code)
if ($r.out -match 'STRIPLEN:(\d+)') { $stripLen = [int]$Matches[1] } else { $stripLen = 999999 }
Assert "stripped Dockerfile is under Apple's 16KB limit ($stripLen bytes)" ($stripLen -lt 16384)
Assert-Contains "stripping preserves heredoc bodies" $r.out 'HEREDOC:1'
Assert-Contains "stripping keeps RUN lines" $r.out 'RUNLINE:1'

# ---------------------------------------------------------------------------
"10. Custom options"
# -port is gone: no port is mapped by default, and -runArgs is how ports are
# mapped now (Spec 18). -File binding does not split array parameters, so the
# port scenario needs the command form.
$r = Invoke-Scenario $codeIt $commonArgs $stubPath
Assert "no port is mapped by default" (-not $r.out.Contains(' -p '))
$r = Invoke-ScenarioCommand "& '$codeIt' -dryRun -WorkDirToMount '$scriptDir' -saveDir '$save' -runArgs '-p','8000:3000'" $stubPath
Assert "-runArgs maps a port exit code 0" ($r.code -eq 0)
Assert-Contains "ports are mapped with -runArgs" $r.out '-p 8000:3000'
$r = Invoke-Scenario $codeIt (@('-port', '8000') + $commonArgs) $stubPath
Assert-Contains "the removed -port goes to the agent verbatim" $r.out 'code-it-alpine-dotnet-node:latest -port 8000'
$r = Invoke-Scenario $codeIt (@('-agentName', 'MyAgent') + $commonArgs) $stubPath
Assert-Contains "agent name lowercased in mounts" $r.out '/home/myagent/.config/opencode'
Assert-Contains "agent name in git author" $r.out 'GIT_AUTHOR_NAME="MyAgent for'
Assert-Contains "agent name in git committer" $r.out 'GIT_COMMITTER_NAME="MyAgent for'
Assert-Contains "git committer email passed" $r.out 'GIT_COMMITTER_EMAIL='
$savedAuthor = $env:GIT_AUTHOR_NAME
$env:GIT_AUTHOR_NAME = 'Agent1 for Some One'
try { $r = Invoke-Scenario $codeIt (@('-agentName', 'MyAgent') + $commonArgs) $stubPath }
finally { $env:GIT_AUTHOR_NAME = $savedAuthor }
Assert-Contains "run inside an agent container does not repeat the agent prefix" $r.out 'GIT_AUTHOR_NAME="MyAgent for Some One"'

# ---------------------------------------------------------------------------
"11. NuGet package cache: detection and read-only mount"
# Redirect HOME/USERPROFILE/APPDATA so detection is hermetic on any machine;
# child pwsh processes derive `$HOME` from USERPROFILE on Windows, HOME elsewhere.
$fakeHome  = Join-Path $tmp 'fakehome'
$emptyHome = Join-Path $tmp 'emptyhome'
$nugetCache = Join-Path $tmp 'nuget-cache'
$null = New-Item -ItemType Directory -Force -Path $fakeHome, $emptyHome, $nugetCache
$savedEnv = @{}
foreach ($v in 'NUGET_PACKAGES','HOME','USERPROFILE','APPDATA') { $savedEnv[$v] = [Environment]::GetEnvironmentVariable($v) }
function Restore-NugetTestEnv {
    foreach ($k in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k]) }
}
try {
    $env:HOME = $fakeHome; $env:USERPROFILE = $fakeHome; $env:APPDATA = (Join-Path $tmp 'no-appdata')

    # (a) NUGET_PACKAGES override: mounted read-only, in both printout and run command
    $env:NUGET_PACKAGES = $nugetCache
    $r = Invoke-Scenario $codeIt $commonArgs $stubPath
    Assert-Contains "NUGET_PACKAGES cache mounted read-only (printout)" $r.out "-v `"$nugetCache`:/home/agent1/.nuget/packages-host:ro`""
    $r = Invoke-Scenario $codeIt @('-WorkDirToMount', $scriptDir, '-saveDir', $save) $stubPath
    Assert-Contains "run command runs the stub" $r.out 'STUB-DOCKER-RUN'
    Assert-Contains "NUGET_PACKAGES cache mounted read-only (run)" $r.out "-v $nugetCache`:/home/agent1/.nuget/packages-host:ro"

    # (b) globalPackagesFolder from the user-level NuGet.Config
    $env:NUGET_PACKAGES = $null
    $null = New-Item -ItemType Directory -Force -Path "$fakeHome/.nuget/NuGet"
    @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <config>
    <add key="globalPackagesFolder" value="$nugetCache" />
  </config>
</configuration>
"@ | Set-Content -Path "$fakeHome/.nuget/NuGet/NuGet.Config"
    $r = Invoke-Scenario $codeIt $commonArgs $stubPath
    Assert-Contains "globalPackagesFolder from NuGet.Config mounted" $r.out "$nugetCache`:/home/agent1/.nuget/packages-host:ro"
    @"
<configuration>
  <config>
    <add value="$nugetCache" key="globalPackagesFolder" />
  </config>
</configuration>
"@ | Set-Content -Path "$fakeHome/.nuget/NuGet/NuGet.Config"
    $r = Invoke-Scenario $codeIt $commonArgs $stubPath
    Assert-Contains "globalPackagesFolder with value before key mounted" $r.out "$nugetCache`:/home/agent1/.nuget/packages-host:ro"
    @"
<configuration>
  <config>
    <!-- <add key="globalPackagesFolder" value="$nugetCache" /> -->
  </config>
</configuration>
"@ | Set-Content -Path "$fakeHome/.nuget/NuGet/NuGet.Config"
    $r = Invoke-Scenario $codeIt $commonArgs $stubPath
    Assert "commented-out globalPackagesFolder ignored" (-not $r.out.Contains('packages-host'))
    Remove-Item "$fakeHome/.nuget/NuGet/NuGet.Config"

    # (c) default ~/.nuget/packages
    $null = New-Item -ItemType Directory -Force -Path "$fakeHome/.nuget/packages"
    $resolvedPackages = (Resolve-Path "$fakeHome/.nuget/packages").Path
    $r = Invoke-Scenario $codeIt $commonArgs $stubPath
    Assert-Contains "default ~/.nuget/packages mounted" $r.out "$resolvedPackages`:/home/agent1/.nuget/packages-host:ro"

    # (d) no cache found: no mount, and a note is printed
    $env:HOME = $emptyHome; $env:USERPROFILE = $emptyHome
    $r = Invoke-Scenario $codeIt $commonArgs $stubPath
    Assert-Contains "no cache: note printed" $r.out 'No NuGet package cache found'
    Assert "no cache: no nuget mount line" (-not $r.out.Contains('packages-host'))
} finally {
    Restore-NugetTestEnv
}

# ---------------------------------------------------------------------------
"11b. Toolchain: -toolchain / -packageCaches fragment assembly and read-only caches"
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-toolchain', 'dotnet,node') $stubPath
Invoke-Capture $codeItBuild @('-dockerfileDir', $scriptDir, '-toolchain', 'dotnet,node', '-runtime', 'docker')
Assert-InCapture "dotnet,node assembles dotnet" 'dotnet-sdk-$version-linux-musl'
Assert-InCapture "dotnet,node assembles node" 'apk add --no-cache nodejs'
Assert-NotInCapture "dotnet,node leaves bun out" 'bun.sh/install'
Assert-InCapture "dotnet implies the nuget cache" 'fallbackPackageFolders'
Assert-InCapture "node implies the npm cache" '/home/agent1/.npm-host'
Assert-Contains "reports the resolved toolchains" $r.out 'toolchains dotnet,node; package repos nuget,npm'

# -toolchain replaces the default set
Invoke-Capture $codeItBuild @('-dockerfileDir', $scriptDir, '-toolchain', 'node,bun', '-runtime', 'docker')
Assert-InCapture "-toolchain node,bun assembles node" 'apk add --no-cache nodejs'
Assert-InCapture "-toolchain node,bun assembles bun" 'bun.sh/install'
Assert-NotInCapture "-toolchain node,bun drops dotnet" 'dotnet-sdk-$version-linux-musl'
Assert-NotInCapture "-toolchain node,bun drops nuget (dotnet gone)" 'fallbackPackageFolders'
Assert-InCapture "-toolchain node,bun keeps npm (node present)" '/home/agent1/.npm-host'

# -packageCaches replaces the implied set, independently of -toolchain
Invoke-Capture $codeItBuild @('-dockerfileDir', $scriptDir, '-toolchain', 'node,bun', '-packageCaches', 'npm', '-runtime', 'docker')
Assert-InCapture "-packageCaches npm keeps npm" '/home/agent1/.npm-host'
Assert-NotInCapture "-packageCaches npm excludes the bun cache" '/home/agent1/.bun-host'
Invoke-Capture $codeItBuild @('-dockerfileDir', $scriptDir, '-toolchain', 'node,bun', '-packageCaches', 'bun', '-runtime', 'docker')
Assert-InCapture "-packageCaches bun assembles the bun cache" '/home/agent1/.bun-host'
Assert-NotInCapture "-packageCaches bun excludes npm" '/home/agent1/.npm-host'
Invoke-Capture $codeItBuild @('-dockerfileDir', $scriptDir, '-toolchain', 'bun', '-packageCaches', 'nuget', '-runtime', 'docker')
Assert-InCapture "nuget package cache without dotnet" 'fallbackPackageFolders'

# The default image name follows -toolchain
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-toolchain', 'node,bun') $stubPath
Assert-Contains "image name derives from -toolchain" $r.out '-t code-it-alpine-node-bun:latest'

# The old -tech spelling is kept as a hidden alias
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-tech', 'bun') $stubPath
Assert-Contains "-tech alias derives the bun image" $r.out '-t code-it-alpine-bun:latest'

# Toolchain aliases resolve to the canonical name: js-node/ts-node -> node, js-bun/ts-bun -> bun
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-toolchain', 'js-node') $stubPath
Assert-Contains "js-node canonical image name" $r.out '-t code-it-alpine-node:latest'
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-toolchain', 'ts-node') $stubPath
Assert-Contains "ts-node canonical image name" $r.out '-t code-it-alpine-node:latest'
Assert-Contains "ts-node implies the npm package cache" $r.out 'package repos npm'
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-toolchain', 'js-bun') $stubPath
Assert-Contains "js-bun canonical image name" $r.out '-t code-it-alpine-bun:latest'
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-toolchain', 'ts-bun,bun') $stubPath
Assert-Contains "ts-bun aliases bun and dedupes with bun" $r.out '-t code-it-alpine-bun:latest'

# The old -packages spelling is gone as a parameter: it is now passed to the agent,
# so it no longer selects a package cache
$r = Invoke-Scenario $codeIt (@('-toolchain','dotnet,node','-packages','npm') + $commonArgs) $stubPath
Assert-Contains "removed -packages is forwarded to the agent" $r.out '-packages npm'

$env:STUB_IMAGE_TOOLCHAINS = 'dotnet'
try { $r = Invoke-Scenario $codeIt (@('-toolchain','node,bun','-image','code-it-alpine-dotnet-node') + $commonArgs) $stubPath }
finally { $env:STUB_IMAGE_TOOLCHAINS = $null }
Assert-Contains "warns when the image label disagrees with -toolchain" $r.out "looks built for toolchains 'dotnet'"
# An image whose agents label lacks the chosen agent stops before docker run, readably
# (the stub answers the agents label lookup with STUB_IMAGE_AGENTS)
$env:STUB_IMAGE_AGENTS = 'claude'
try { $r = Invoke-Scenario $codeIt (@('-agent','opencode') + $commonArgs) $stubPath }
finally { $env:STUB_IMAGE_AGENTS = $null }
Assert "image without the chosen agent fails" ($r.code -ne 0)
Assert-Contains "names the agents the image has" $r.out "does not contain agent 'opencode'; it has: claude"
Assert "image without the chosen agent is not run" (-not $r.out.Contains('STUB-DOCKER-RUN'))
$env:STUB_IMAGE_AGENTS = 'claude'
try { $r = Invoke-Scenario $codeIt (@('-agent','claude') + $commonArgs) $stubPath }
finally { $env:STUB_IMAGE_AGENTS = $null }
Assert "image with the chosen agent runs" ($r.code -eq 0)
# An image whose recorded agent binary differs from the agent's definition is out of
# date (e.g. opencode-v1 built when it shared opencode, v2's, path): stop before docker run
$env:STUB_IMAGE_AGENTS = 'opencode,opencode-v1'
$env:STUB_IMAGE_AGENT_BINARIES = 'opencode=/home/agent1/.opencode-v2/bin/opencode,opencode-v1=/home/agent1/.opencode-v2/bin/opencode'
try { $r = Invoke-Scenario $codeIt (@('-agent','opencode-v1') + $commonArgs) $stubPath }
finally { $env:STUB_IMAGE_AGENTS = $null; $env:STUB_IMAGE_AGENT_BINARIES = $null }
Assert "image with an out-of-date agent binary fails" ($r.code -ne 0)
Assert-Contains "names the recorded and expected binaries" $r.out "runs agent 'opencode-v1' from /home/agent1/.opencode-v2/bin/opencode, but agents/opencode-v1/config now names /home/agent1/.opencode/bin/opencode"
Assert-Contains "out-of-date agent binary suggests the rebuild" $r.out 'Code-It-Build.ps1 -toolchain dotnet,node -agent opencode,opencode-v1'
Assert "image with an out-of-date agent binary is not run" (-not $r.out.Contains('STUB-DOCKER-RUN'))
$env:STUB_IMAGE_AGENTS = 'opencode,opencode-v1'
$env:STUB_IMAGE_AGENT_BINARIES = 'opencode=/home/agent1/.opencode-v2/bin/opencode,opencode-v1=/home/agent1/.opencode/bin/opencode'
try { $r = Invoke-Scenario $codeIt (@('-agent','opencode-v1') + $commonArgs) $stubPath }
finally { $env:STUB_IMAGE_AGENTS = $null; $env:STUB_IMAGE_AGENT_BINARIES = $null }
Assert "image with the current agent binary runs" ($r.code -eq 0 -and $r.out.Contains("docker run -it"))
Assert "current agent binary gives no out-of-date warning" (-not $r.out.Contains('out of date') -and -not $r.out.Contains('predates'))
$env:STUB_IMAGE_AGENTS = 'opencode,opencode-v1'
try { $r = Invoke-Scenario $codeIt (@('-agent','opencode-v1') + $commonArgs) $stubPath }
finally { $env:STUB_IMAGE_AGENTS = $null }
Assert "image without agent-binaries label still runs" ($r.code -eq 0 -and $r.out.Contains("docker run -it"))
Assert-Contains "image without agent-binaries label warns it may be out of date" $r.out "predates code-it recording its agents' binaries"
# Without a label (older images), fall back to the name-based guess
$env:STUB_IMAGE_TOOLCHAINS = ''
try { $r = Invoke-Scenario $codeIt (@('-toolchain','node,bun','-image','code-it-alpine-dotnet-node') + $commonArgs) $stubPath }
finally { $env:STUB_IMAGE_TOOLCHAINS = $null }
Assert-Contains "falls back to the image-name guess without a label" $r.out "looks built for toolchains 'dotnet,node'"

# Unknown names are hard errors
$r = Invoke-Scenario $codeIt (@('-toolchain','cobol') + $commonArgs) $stubPath
Assert "-toolchain with an unknown name fails" ($r.code -ne 0)
$r = Invoke-Scenario $codeIt (@('-packageCaches','pip') + $commonArgs) $stubPath
Assert "-packageCaches with an unknown name fails" ($r.code -ne 0)

$npmCache = Join-Path $tmp 'npm-cache'; $bunCache = Join-Path $tmp 'bun-cache'
$null = New-Item -ItemType Directory -Force -Path $npmCache, $bunCache
$savedCacheEnv = @{}
foreach ($v in 'NPM_CONFIG_CACHE','BUN_INSTALL_CACHE_DIR','NUGET_PACKAGES','HOME','USERPROFILE') { $savedCacheEnv[$v] = [Environment]::GetEnvironmentVariable($v) }
try {
    $env:HOME = $fakeHome; $env:USERPROFILE = $fakeHome
    $env:NPM_CONFIG_CACHE = $npmCache
    $r = Invoke-Scenario $codeIt $commonArgs $stubPath
    Assert-Contains "npm cache mounted read-only" $r.out "-v `"$npmCache`:/home/agent1/.npm-host:ro`""
    $env:NPM_CONFIG_CACHE = $null
    $env:BUN_INSTALL_CACHE_DIR = $bunCache
    $r = Invoke-Scenario $codeIt (@('-packageCaches','bun') + $commonArgs) $stubPath
    Assert-Contains "bun cache mounted read-only" $r.out "-v `"$bunCache`:/home/agent1/.bun-host:ro`""
    $env:BUN_INSTALL_CACHE_DIR = $null
    $env:NPM_CONFIG_CACHE = $npmCache
    # An explicit but empty -packageCaches: ',' (PowerShell cannot easily pass a bare "")
    $r = Invoke-Scenario $codeIt (@('-toolchain','node','-packageCaches',',') + $commonArgs) $stubPath
    Assert "empty -packageCaches: no npm mount" (-not $r.out.Contains('.npm-host'))
    $env:NPM_CONFIG_CACHE = $null
    $env:NUGET_PACKAGES = (Resolve-Path "$fakeHome/.nuget/packages").Path
    $r = Invoke-Scenario $codeIt (@('-toolchain','dotnet','-packageCaches','npm') + $commonArgs) $stubPath
    Assert "packages without nuget: no nuget mount" (-not $r.out.Contains('packages-host'))
} finally {
    foreach ($k in $savedCacheEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $savedCacheEnv[$k]) }
}

# ---------------------------------------------------------------------------
"12. Prompt and agent arguments"
# A leading bare argument, or -prompt, is the opening prompt, spelled each agent's way
$r = Invoke-Scenario $codeIt (@('-c','explain this repo') + $commonArgs) $stubPath
Assert "bare prompt exit code 0" ($r.code -eq 0)
Assert-Contains "claude: bare prompt appended to the image" $r.out 'code-it-alpine-dotnet-node:latest "explain this repo"'
$r = Invoke-Scenario $codeIt (@('-c','-prompt','explain this repo') + $commonArgs) $stubPath
Assert-Contains "claude: -prompt is the same as a bare prompt" $r.out 'code-it-alpine-dotnet-node:latest "explain this repo"'
$r = Invoke-Scenario $codeIt (@('-o','explain this repo') + $commonArgs) $stubPath
Assert-Contains "opencode (v2): prompt becomes mini --prompt" $r.out 'code-it-alpine-dotnet-node:latest mini --prompt "explain this repo"'
$r = Invoke-Scenario $codeIt (@('-agent','opencode-v1','explain this repo') + $commonArgs) $stubPath
Assert-Contains "opencode-v1 interactive prompt uses --prompt" $r.out 'code-it-alpine-dotnet-node:latest --prompt "explain this repo"'
$r = Invoke-Scenario $codeIt (@('-o') + $commonArgs) $stubPath
Assert "opencode (v2) interactive no-prompt appends nothing" ($r.out.TrimEnd().EndsWith('code-it-alpine-dotnet-node:latest'))
Assert-Contains "opencode (v2) interactive no-prompt allocates a TTY" $r.out 'docker run -it'

# No prompt and no agent args: nothing is appended, and the run stays interactive
$r = Invoke-Scenario $codeIt $commonArgs $stubPath
Assert "no prompt appends nothing" ($r.out.TrimEnd().EndsWith('code-it-alpine-dotnet-node:latest'))
Assert-Contains "interactive runs allocate a TTY" $r.out 'docker run -it'
Assert "interactive runs are not headless" (-not $r.out.Contains('CODE_AGENT_HEADLESS'))

# -headless: one-shot, no TTY, and the agent's non-interactive form
$r = Invoke-Scenario $codeIt (@('-c','-headless','fix the build') + $commonArgs) $stubPath
Assert-Contains "claude -headless uses -p" $r.out 'code-it-alpine-dotnet-node:latest -p "fix the build"'
Assert-Contains "-headless passes CODE_AGENT_HEADLESS" $r.out '-e CODE_AGENT_HEADLESS=1'
Assert-Contains "-headless allocates no TTY" $r.out 'docker run -i --rm'
$r = Invoke-Scenario $codeIt (@('-o','-headless','fix the build') + $commonArgs) $stubPath
Assert-Contains "opencode (v2) -headless uses standalone run" $r.out 'code-it-alpine-dotnet-node:latest run --standalone "fix the build"'
$r = Invoke-Scenario $codeIt (@('-agent','opencode-v1','-headless','fix the build') + $commonArgs) $stubPath
Assert-Contains "opencode-v1 -headless uses run" $r.out 'code-it-alpine-dotnet-node:latest run "fix the build"'
$r = Invoke-Scenario $codeIt (@('-o','-headless') + $commonArgs) $stubPath
Assert-Contains "opencode (v2) headless no-prompt still runs standalone" $r.out 'code-it-alpine-dotnet-node:latest run --standalone'
Assert-Contains "opencode (v2) headless no-prompt has no TTY" $r.out 'docker run -i --rm'

# Unrecognised arguments go to the agent verbatim: PowerShell has no usable `--`
$r = Invoke-Scenario $codeIt (@('-c') + $commonArgs + @('--continue','--model','opus')) $stubPath
Assert-Contains "unrecognised flags pass through" $r.out 'code-it-alpine-dotnet-node:latest --continue --model opus'
$r = Invoke-Scenario $codeIt (@('-c','-headless','-prompt','tidy') + $commonArgs + @('--max-turns','5')) $stubPath
Assert-Contains "agent flags precede the prompt for claude" $r.out 'code-it-alpine-dotnet-node:latest -p --max-turns 5 tidy'
$r = Invoke-Scenario $codeIt (@('-agent','opencode-v1','-headless','-prompt','tidy') + $commonArgs + @('--model','opus')) $stubPath
Assert-Contains "agent flags follow run for opencode-v1" $r.out 'code-it-alpine-dotnet-node:latest run --model opus tidy'
$r = Invoke-Scenario $codeIt (@('-o','-headless','-prompt','tidy') + $commonArgs + @('--model','example/coder')) $stubPath
Assert-Contains "opencode (v2) headless flags precede prompt" $r.out 'code-it-alpine-dotnet-node:latest run --standalone --model example/coder tidy'
# -headless without a prompt leaves the agent command to the caller. Short agent flags
# that PowerShell reads as one of this script's own parameters (-p) have to be spelled out.
$r = Invoke-Scenario $codeIt (@('-c','-headless') + $commonArgs + @('--print','count the files')) $stubPath
Assert-Contains "-headless with no prompt adds no -p of its own" $r.out 'code-it-alpine-dotnet-node:latest --print "count the files"'
$r = Invoke-Scenario $codeIt (@('-c','-headless') + $commonArgs + @('-p','count the files')) $stubPath
Assert "an agent flag that collides with a parameter prefix is rejected, not silently bound" ($r.code -ne 0)

# The prompt reaches the container as a single argument
$r = Invoke-Scenario $codeIt (@('-c','-runtime','container','explain this repo','-WorkDirToMount',$scriptDir,'-saveDir',$save)) "$stubContainer$sep$stubPath"
Assert-Contains "prompt is passed as one argument" $r.out '[code-it-alpine-dotnet-node:latest][explain this repo]'
$r = Invoke-Scenario $codeIt (@('-c','-runtime','container','-headless','fix it','-WorkDirToMount',$scriptDir,'-saveDir',$save)) "$stubContainer$sep$stubPath"
Assert-Contains "headless run passes -i" $r.out '[-i][--rm]'
Assert-Contains "headless run passes the prompt after -p" $r.out '[code-it-alpine-dotnet-node:latest][-p][fix it]'

# The alias scripts forward prompts and agent flags
$r = Invoke-Scenario (Join-Path $scriptDir 'Claude-It.ps1') (@('explain this repo') + $commonArgs) $stubPath
Assert-Contains "Claude-It.ps1 forwards a prompt" $r.out 'code-it-alpine-dotnet-node:latest "explain this repo"'
$r = Invoke-Scenario (Join-Path $scriptDir 'OpenCode-It.ps1') ($commonArgs + @('--model','opus')) $stubPath
Assert-Contains "OpenCode-It.ps1 forwards agent flags" $r.out 'code-it-alpine-dotnet-node:latest --model opus'

# ---------------------------------------------------------------------------
"12a. -noAgent: a plain zsh shell instead of a coding agent"
$r = Invoke-Scenario $codeIt (@('-noAgent') + $commonArgs) $stubPath
Assert "-noAgent exit code 0" ($r.code -eq 0)
Assert-Contains "-noAgent passes CODE_AGENT_SHELL" $r.out '-e CODE_AGENT_SHELL=1'
Assert "-noAgent passes no CODE_AGENT" (-not $r.out.Contains('CODE_AGENT='))
Assert "-noAgent appends nothing after the image" ($r.out.TrimEnd().EndsWith('code-it-alpine-dotnet-node:latest'))
Assert-Contains "-noAgent stays interactive" $r.out 'docker run -it'
Assert-Contains "-noAgent says it runs no agent" $r.out 'Using code agent: none (zsh shell)'
Assert "-noAgent mounts no agent state" (-not $r.out.Contains('.config/opencode'))
Assert "-noAgent shows no errors" (-not ($r.out -match 'Join-Path|Test-Path|Cannot bind'))
$r = Invoke-Scenario $codeIt (@('-zsh') + $commonArgs) $stubPath
Assert-Contains "-zsh is -noAgent" $r.out '-e CODE_AGENT_SHELL=1'
# No agent to give a prompt to, nothing to run headlessly, and no agent to select
$r = Invoke-Scenario $codeIt (@('-noAgent','explain this repo') + $commonArgs) $stubPath
Assert "-noAgent with a prompt fails" ($r.code -ne 0)
$r = Invoke-Scenario $codeIt (@('-noAgent','-headless') + $commonArgs) $stubPath
Assert "-noAgent with -headless fails" ($r.code -ne 0)
$r = Invoke-Scenario $codeIt (@('-noAgent','-claude') + $commonArgs) $stubPath
Assert "-noAgent with -claude fails" ($r.code -ne 0)

# ---------------------------------------------------------------------------
"12b. Code-It-Add-Agent.ps1"
$addAgent = Join-Path $scriptDir 'Code-It-Add-Agent.ps1'
$stubCi = Join-Path $tmp 'stub-code-it.ps1'
Set-Content -Path $stubCi -Value @'
param([switch]$headless, [string]$WorkDirToMount, [string]$prompt)
"STUB-CODE-IT $headless $WorkDirToMount"
if ($env:STUB_CODE_IT_EXIT) { exit [int]$env:STUB_CODE_IT_EXIT }
exit 0
'@
function New-GitRepo([string]$dir) {
    $null = New-Item -ItemType Directory -Force -Path $dir
    & git -C $dir init -q
    & git -C $dir config user.email a@b.c
    & git -C $dir config user.name T
    Set-Content -Path (Join-Path $dir 'x') -Value 'x'
    & git -C $dir add -A
    & git -C $dir commit -qm init
}

# --dryRun prints the prompt and command, and changes nothing
$repoA = Join-Path $tmp 'addagent-a'; New-GitRepo $repoA
$r = Invoke-Scenario $addAgent @('cursor', '-repo', $repoA, '-codeIt', $stubCi, '-dryRun') $stubPath
Assert "add-agent -dryRun exit code 0" ($r.code -eq 0)
Assert-Contains "add-agent prompt names the agent" $r.out 'Agent to add: cursor'
Assert-Contains "add-agent prompt includes the gate" $r.out 'Gate first'
Assert-Contains "add-agent prompt requires an official install channel" $r.out 'official install channel'
Assert-Contains "add-agent -dryRun prints the command" $r.out 'stub-code-it.ps1'
Assert-Contains "add-agent -dryRun prints -headless" $r.out '-headless'
Assert "add-agent -dryRun creates no branch" (-not (& git -C $repoA branch --list 'add-agent/*'))

# -url is included in the prompt
$r = Invoke-Scenario $addAgent @('cursor', '-url', 'https://docs.example/cursor', '-repo', $repoA, '-codeIt', $stubCi, '-dryRun') $stubPath
Assert-Contains "add-agent prompt includes the docs URL" $r.out 'https://docs.example/cursor'

# a dirty repo is refused
Add-Content -Path (Join-Path $repoA 'x') -Value 'y'
$r = Invoke-Scenario $addAgent @('cursor', '-repo', $repoA, '-codeIt', $stubCi) $stubPath
Assert "add-agent refuses a dirty repo" ($r.code -ne 0)
& git -C $repoA checkout -q -- .

# it creates the branch, runs code-it, and prints the branch and summary
$r = Invoke-Scenario $addAgent @('cursor', '-repo', $repoA, '-codeIt', $stubCi) $stubPath
Assert "add-agent run exit code 0" ($r.code -eq 0)
Assert-Contains "add-agent runs code-it headless" $r.out 'STUB-CODE-IT'
Assert "add-agent checks out the new branch" ((& git -C $repoA rev-parse --abbrev-ref HEAD) -eq 'add-agent/cursor')
Assert-Contains "add-agent prints the branch" $r.out 'Branch: add-agent/cursor'
Assert-Contains "add-agent prints a changes summary" $r.out 'Changes:'

# a non-zero code-it exit (the gate refusal) is propagated
$repoB = Join-Path $tmp 'addagent-b'; New-GitRepo $repoB
$env:STUB_CODE_IT_EXIT = '3'
try { $r = Invoke-Scenario $addAgent @('cursor', '-repo', $repoB, '-codeIt', $stubCi) $stubPath }
finally { $env:STUB_CODE_IT_EXIT = $null }
Assert "add-agent propagates a non-zero gate refusal" ($r.code -eq 3)

# an existing branch is refused
$repoC = Join-Path $tmp 'addagent-c'; New-GitRepo $repoC
& git -C $repoC branch 'add-agent/cursor'
$r = Invoke-Scenario $addAgent @('cursor', '-repo', $repoC, '-codeIt', $stubCi) $stubPath
Assert "add-agent refuses an existing branch" ($r.code -ne 0)

# ---------------------------------------------------------------------------
"12c. Code-It-Add-Toolchain.ps1"
$addTc = Join-Path $scriptDir 'Code-It-Add-Toolchain.ps1'

# -dryRun prints the prompt (with the security gate) and the command
$repoD = Join-Path $tmp 'addtc-a'; New-GitRepo $repoD
$r = Invoke-Scenario $addTc @('java', '-repo', $repoD, '-codeIt', $stubCi, '-dryRun') $stubPath
Assert "add-toolchain -dryRun exit code 0" ($r.code -eq 0)
Assert-Contains "add-toolchain prompt names the toolchain" $r.out 'Toolchain to add: java'
Assert-Contains "add-toolchain prompt includes the gate" $r.out 'Gate first'
Assert-Contains "add-toolchain prompt requires a secure install" $r.out 'installs securely'
Assert-Contains "add-toolchain prompt requires musl builds" $r.out 'musl builds for x86_64 and aarch64'
Assert-Contains "add-toolchain -dryRun prints -headless" $r.out '-headless'
Assert "add-toolchain -dryRun creates no branch" (-not (& git -C $repoD branch --list 'add-toolchain/*'))

# -url is included
$r = Invoke-Scenario $addTc @('java', '-url', 'https://openjdk.org/install/', '-repo', $repoD, '-codeIt', $stubCi, '-dryRun') $stubPath
Assert-Contains "add-toolchain prompt includes the docs URL" $r.out 'https://openjdk.org/install/'

# a dirty repo is refused
Add-Content -Path (Join-Path $repoD 'x') -Value 'y'
$r = Invoke-Scenario $addTc @('java', '-repo', $repoD, '-codeIt', $stubCi) $stubPath
Assert "add-toolchain refuses a dirty repo" ($r.code -ne 0)
& git -C $repoD checkout -q -- .

# branch creation and summary
$r = Invoke-Scenario $addTc @('java', '-repo', $repoD, '-codeIt', $stubCi) $stubPath
Assert "add-toolchain run exit code 0" ($r.code -eq 0)
Assert "add-toolchain checks out the new branch" ((& git -C $repoD rev-parse --abbrev-ref HEAD) -eq 'add-toolchain/java')
Assert-Contains "add-toolchain prints the branch" $r.out 'Branch: add-toolchain/java'

# a gate refusal exit code is propagated
$repoE = Join-Path $tmp 'addtc-b'; New-GitRepo $repoE
$env:STUB_CODE_IT_EXIT = '4'
try { $r = Invoke-Scenario $addTc @('java', '-repo', $repoE, '-codeIt', $stubCi) $stubPath }
finally { $env:STUB_CODE_IT_EXIT = $null }
Assert "add-toolchain propagates a gate refusal" ($r.code -eq 4)

# ---------------------------------------------------------------------------
"12d. Code-It-FirstRun.ps1"
$firstRun = Join-Path $scriptDir 'Code-It-FirstRun.ps1'
$stubFirst = Join-Path $tmp 'stub-first-build.ps1'
Set-Content -Path $stubFirst -Value @'
param([string]$toolchain, [string]$agent, [string]$runtime, [string]$image, [string]$dockerfileDir,
    [string]$selectionFile, [switch]$interactive, [switch]$yes, [switch]$dryRun)
if (-not $toolchain) { $toolchain = 'node' }
if (-not $agent) { $agent = 'opencode' }
@("toolchains=$toolchain", "agents=$agent") | Set-Content -Path $selectionFile
if (-not $dryRun) { Set-Content -Path (Join-Path $PSScriptRoot 'first-build-ran') -Value 'ran' }
"STUB-FIRST-BUILD toolchain=$toolchain agent=$agent dryRun=$dryRun"
'@

$fh = Join-Path $tmp 'firstcopy-home'
$null = New-Item -ItemType Directory -Force -Path "$fh/.config/opencode"
Set-Content -Path "$fh/.config/opencode/config.json" -Value 'ORIGINAL'
$savedHome = $env:HOME; $savedUserProfile = $env:USERPROFILE

$env:HOME = $fh; $env:USERPROFILE = $fh
try {
    $r = Invoke-Scenario $firstRun @('-yes', '-dryRun', '-agents', 'opencode',
        '-saveDir', (Join-Path $tmp 'firstpwsh-ps'), '-codeItBuild', $stubFirst) $stubPath
} finally { $env:HOME = $savedHome; $env:USERPROFILE = $savedUserProfile }
Assert-Contains "first-run delegates build selection" $r.out '-interactive'
Assert-Contains "first-run forwards agent selection" $r.out '-agent opencode'
$env:HOME = $fh; $env:USERPROFILE = $fh
try {
    $r = Invoke-Scenario $firstRun @('-yes', '-dryRun', '-toolchain', 'node', '-agents', 'opencode',
        '-saveDir', (Join-Path $tmp 'firstpwsh-ps'), '-codeItBuild', $stubFirst) $stubPath
} finally { $env:HOME = $savedHome; $env:USERPROFILE = $savedUserProfile }
Assert-Contains "an explicit first-run -toolchain is forwarded unchanged" $r.out 'toolchain=node'

# --dryRun builds nothing and copies nothing
$fd = Join-Path $tmp 'firstdry-ps'
$env:HOME = $fh; $env:USERPROFILE = $fh
try {
    $r = Invoke-Scenario $firstRun @('-yes', '-dryRun', '-toolchain', 'node', '-agents', 'opencode',
        '-saveDir', (Join-Path $fd 'save'), '-codeItBuild', $stubFirst) $stubPath
} finally { $env:HOME = $savedHome; $env:USERPROFILE = $savedUserProfile }
Assert "first-run -dryRun exit code 0" ($r.code -eq 0)
Assert "first-run -dryRun creates no save dir" (-not (Test-Path -Path (Join-Path $fd 'save')))
Assert-Contains "first-run forwards -dryRun to build" $r.out 'dryRun=True'
Assert-Contains "first-run -dryRun says what it would copy" $r.out 'would copy'
Assert "first-run -dryRun ran no build" (-not (Test-Path -Path (Join-Path $tmp 'first-build-ran')))

# The real build script runs as a child PowerShell process so its successful dry-run
# exit still returns the selected agents to first-run for the configuration phase.
$actualSave = Join-Path $tmp 'firstactual-save'
$env:HOME = $fh; $env:USERPROFILE = $fh
try {
    $r = Invoke-Scenario $firstRun @('-yes', '-dryRun', '-toolchain', 'node', '-agents', 'opencode',
        '-runtime', 'docker', '-saveDir', $actualSave, '-codeItBuild', $codeItBuild) $stubPath
} finally { $env:HOME = $savedHome; $env:USERPROFILE = $savedUserProfile }
Assert "first-run survives the delegated build dry-run" ($r.code -eq 0)
Assert-Contains "first-run receives the selected agent from build" $r.out 'Code-It.ps1 -agent opencode'
Assert "delegated build dry-run makes no save directory" (-not (Test-Path -Path $actualSave))

# --yes copies state over but never overwrites
$fs = Join-Path $tmp 'firstcopy-save'
$null = New-Item -ItemType Directory -Force -Path "$fs/.config/opencode"
Set-Content -Path "$fs/.config/opencode/config.json" -Value 'KEEP'
Set-Content -Path "$fh/.config/opencode/new.json" -Value 'NEW'
$env:HOME = $fh; $env:USERPROFILE = $fh
try {
    $r = Invoke-Scenario $firstRun @('-yes', '-toolchain', 'node', '-agents', 'opencode-v1',
        '-saveDir', $fs, '-codeItBuild', $stubFirst) $stubPath
} finally { $env:HOME = $savedHome; $env:USERPROFILE = $savedUserProfile }
Assert "first-run copy exit code 0" ($r.code -eq 0)
Assert-Contains "first-run invoked the build" $r.out 'STUB-FIRST-BUILD'
Assert "first-run never overwrites existing state" ((Get-Content "$fs/.config/opencode/config.json" -Raw).Trim() -eq 'KEEP')
Assert "first-run copies missing state" ((Get-Content "$fs/.config/opencode/new.json" -Raw).Trim() -eq 'NEW')
Assert-Contains "first-run warns that credentials are copied" $r.out 'credentials'
Assert-Contains "first-run prints the start command" $r.out 'Code-It.ps1 -agent opencode-v1'
# an agent with AGENT_SAVE_SUBDIR (opencode, v2, whose state lives under opencode-v2/)
# gets its copy in that subdirectory
$env:HOME = $fh; $env:USERPROFILE = $fh
try {
    $r = Invoke-Scenario $firstRun @('-yes', '-toolchain', 'node', '-agents', 'opencode',
        '-saveDir', $fs, '-codeItBuild', $stubFirst) $stubPath
} finally { $env:HOME = $savedHome; $env:USERPROFILE = $savedUserProfile }
Assert "first-run copies opencode (v2) state into its save subdir" ((Get-Content "$fs/opencode-v2/.config/opencode/new.json" -Raw).Trim() -eq 'NEW')

# ---------------------------------------------------------------------------
"12e. Image memory and default toolchains"
$histDocker = Join-Path $tmp 'hist-docker'
$null = New-Item -ItemType Directory -Force -Path $histDocker
if ($onWindows) {
    Set-Content -Path (Join-Path $histDocker 'docker.cmd') -Value @'
@echo off
if "%~1"=="images" (
  echo code-it-alpine-dotnet:latest
  echo code-it-alpine-dotnet-node:latest
  echo code-it-alpine-python:latest
  echo code-it-alpine-dotnet-node-cobol:latest
  echo code-it-alpine-dotnet-node-powershell:latest
  goto :eof
)
if "%~1"=="image" (
  echo %* | findstr /C:"python" >nul && (echo python& goto :eof)
  echo %* | findstr /C:"cobol" >nul && (echo dotnet,node,cobol& goto :eof)
  echo %* | findstr /C:"powershell" >nul && (echo dotnet,node,powershell& goto :eof)
  echo %* | findstr /C:"dotnet-node" >nul && (echo dotnet,node& goto :eof)
  echo %* | findstr /C:"dotnet" >nul && (echo dotnet& goto :eof)
  echo.
  goto :eof
)
if "%~1"=="run" echo HIST-RUN %*& goto :eof
if "%~1"=="build" echo HIST-BUILD %*& goto :eof
echo STUB %*
'@
} else {
    Set-Content -Path (Join-Path $histDocker 'docker') -Value @'
#!/bin/sh
case "$1" in
    images) printf '%s\n' code-it-alpine-dotnet:latest code-it-alpine-dotnet-node:latest code-it-alpine-python:latest code-it-alpine-dotnet-node-cobol:latest code-it-alpine-dotnet-node-powershell:latest ;;
    image)
        for a in "$@"; do last="$a"; done
        case "$last" in
            *python*)      echo python ;;
            *cobol*)       echo dotnet,node,cobol ;;
            *powershell*)  echo dotnet,node,powershell ;;
            *dotnet-node*) echo dotnet,node ;;
            *dotnet*)      echo dotnet ;;
            *)             echo "" ;;
        esac ;;
    run)   echo "HIST-RUN $*" ;;
    build) echo "HIST-BUILD $*" ;;
    *)     echo "STUB $*" ;;
esac
'@
    chmod +x (Join-Path $histDocker 'docker')
}
$histPath = "$histDocker$sep$stubPath"

$stubFirstRun = Join-Path $tmp 'stub-first-run.ps1'
Set-Content -Path $stubFirstRun -Value @'
param([string]$saveDir, [string]$workDir, [string]$runtime)
"STUB-FIRST-RUN $saveDir $workDir $runtime"
exit 0
'@

# save dir exists with history: the 70% weighted rule (Spec 09) chooses
$hsel = Join-Path $tmp 'histselect'; $null = New-Item -ItemType Directory -Force -Path $hsel
@(
    '20260101 code-it-alpine-dotnet-node'
    '20260102 code-it-alpine-python'
    '20260103 code-it-alpine-python'
    '20260104 code-it-alpine-python'
    '20260105 code-it-alpine-python'
) | Set-Content -Path (Join-Path $hsel 'image-history')
$r = Invoke-Scenario $codeIt @('-dryRun', '-WorkDirToMount', $scriptDir, '-saveDir', $hsel) $histPath
Assert "default selection exit code 0" ($r.code -eq 0)
Assert-Contains "uses the remembered image (70% rule)" $r.out 'Using remembered image: code-it-alpine-python'
Assert-Contains "runs that image" $r.out 'code-it-alpine-python:latest'

# explicit -toolchain bypasses the default selection
$r = Invoke-Scenario $codeIt @('-dryRun', '-toolchain', 'dotnet', '-WorkDirToMount', $scriptDir, '-saveDir', $hsel) $histPath
Assert "explicit -toolchain bypasses the default" (-not ($r.out.Contains('Using remembered image') -or $r.out.Contains('Using existing image')))
Assert-Contains "explicit -toolchain is honoured" $r.out 'code-it-alpine-dotnet:latest'

# explicit -image bypasses the default selection
$r = Invoke-Scenario $codeIt @('-dryRun', '-image', 'code-it-alpine-dotnet-node', '-WorkDirToMount', $scriptDir, '-saveDir', $hsel) $histPath
Assert "explicit -image bypasses the default" (-not ($r.out.Contains('Using remembered image') -or $r.out.Contains('Using existing image')))

# a remembered image labelled with a toolchain this checkout does not know (built by
# another branch) is still used, for the chains that are known
$hunk = Join-Path $tmp 'histunknown'; $null = New-Item -ItemType Directory -Force -Path $hunk
'20260101 code-it-alpine-dotnet-node-cobol' | Set-Content -Path (Join-Path $hunk 'image-history')
$r = Invoke-Scenario $codeIt @('-dryRun', '-WorkDirToMount', $scriptDir, '-saveDir', $hunk) $histPath
Assert "an unknown chain in the remembered image's label is not an error" ($r.code -eq 0)
Assert "an unknown label chain gives no unknown-toolchain warning" (-not $r.out.Contains('Unknown toolchain'))
Assert-Contains "notes the unknown label chain" $r.out 'has toolchains this code-it does not know (dotnet,node,cobol); using dotnet,node'
Assert-Contains "runs the image with the unknown label chain" $r.out 'code-it-alpine-dotnet-node-cobol:latest'

# powershell is a known chain: its remembered image is used with no note
$hpwsh = Join-Path $tmp 'histpwsh'; $null = New-Item -ItemType Directory -Force -Path $hpwsh
@('20260101 code-it-alpine-dotnet-node-powershell', '20260102 code-it-alpine-dotnet-node-powershell') | Set-Content -Path (Join-Path $hpwsh 'image-history')
$r = Invoke-Scenario $codeIt @('-dryRun', '-WorkDirToMount', $scriptDir, '-saveDir', $hpwsh) $histPath
Assert-Contains "uses the remembered powershell image" $r.out 'Using remembered image: code-it-alpine-dotnet-node-powershell'
Assert "powershell in a label is known" (-not $r.out.Contains('does not know'))

# save dir exists but no history: the most recently built existing code-it image
$hnone = Join-Path $tmp 'histnone'; $null = New-Item -ItemType Directory -Force -Path $hnone
$r = Invoke-Scenario $codeIt @('-dryRun', '-WorkDirToMount', $scriptDir, '-saveDir', $hnone) $histPath
Assert-Contains "no history: uses the most recently built existing image" $r.out 'Using existing image: code-it-alpine-dotnet'
Assert-Contains "no history: runs that image" $r.out 'code-it-alpine-dotnet:latest'

# history exists but no remembered image covers 70%: fall back to an existing image
$hfall = Join-Path $tmp 'histfallback'; $null = New-Item -ItemType Directory -Force -Path $hfall
@(
    '20260101 code-it-alpine-dotnet'
    '20260102 code-it-alpine-node'
    '20260103 code-it-alpine-bun'
    '20260104 code-it-alpine-python'
    '20260105 code-it-alpine-dotnet'
) | Set-Content -Path (Join-Path $hfall 'image-history')
$r = Invoke-Scenario $codeIt @('-dryRun', '-WorkDirToMount', $scriptDir, '-saveDir', $hfall) $histPath
Assert-Contains "no 70% cover: falls back to an existing image" $r.out 'Using existing image: code-it-alpine-dotnet'
Assert-Contains "no 70% cover: runs that image" $r.out 'code-it-alpine-dotnet:latest'

# save dir missing: run first-run
$env:CODE_IT_FIRST_RUN = $stubFirstRun
$ns = Join-Path $tmp 'nosave-first-run'
try { $r = Invoke-Scenario $codeIt @('-WorkDirToMount', $scriptDir, '-saveDir', $ns) $histPath }
finally { $env:CODE_IT_FIRST_RUN = $null }
Assert "missing save dir exits 0 via first-run" ($r.code -eq 0)
Assert-Contains "missing save dir runs first-run" $r.out 'STUB-FIRST-RUN'
Assert-Contains "first-run is given the save dir" $r.out $ns

# save dir exists but no code-it image: run first-run
$emptyDocker = Join-Path $tmp 'empty-docker'
$null = New-Item -ItemType Directory -Force -Path $emptyDocker
if ($onWindows) {
    Set-Content -Path (Join-Path $emptyDocker 'docker.cmd') -Value @'
@echo off
if "%~1"=="image" exit /b 1
exit /b 0
'@
} else {
    # docker images succeeds with no output, but image inspect fails (no such image)
    Set-Content -Path (Join-Path $emptyDocker 'docker') -Value @'
#!/bin/sh
case "$1" in
    image) exit 1 ;;
esac
exit 0
'@
    chmod +x (Join-Path $emptyDocker 'docker')
}
$env:CODE_IT_FIRST_RUN = $stubFirstRun
try { $r = Invoke-Scenario $codeIt @('-WorkDirToMount', $scriptDir, '-saveDir', $hsel) "$emptyDocker$sep$origPath" }
finally { $env:CODE_IT_FIRST_RUN = $null }
Assert-Contains "no code-it image runs first-run" $r.out 'STUB-FIRST-RUN'

# -dryRun with a missing save dir: report, do not run first-run
$env:CODE_IT_FIRST_RUN = $stubFirstRun
$ns2 = Join-Path $tmp 'nosave-first-run2'
try { $r = Invoke-Scenario $codeIt @('-dryRun', '-WorkDirToMount', $scriptDir, '-saveDir', $ns2) $histPath }
finally { $env:CODE_IT_FIRST_RUN = $null }
Assert-Contains "dry-run says it would run first-run" $r.out 'would run'
Assert "-dry-run does not run first-run" (-not $r.out.Contains('STUB-FIRST-RUN'))

# every non-dry invocation is recorded, keeping only the newest 15
$hrec = Join-Path $tmp 'histrecord'; $null = New-Item -ItemType Directory -Force -Path $hrec
$recLines = 1..15 | ForEach-Object { ('202601{0:d2} code-it-alpine-dotnet-node' -f $_) }
$recLines | Set-Content -Path (Join-Path $hrec 'image-history')
$oldestBefore = (Get-Content (Join-Path $hrec 'image-history'))[0]
$r = Invoke-Scenario $codeIt @('-WorkDirToMount', $scriptDir, '-saveDir', $hrec, '-toolchain', 'dotnet,node') $histPath
Assert "history recording run exit code 0" ($r.code -eq 0)
$recOut = @(Get-Content (Join-Path $hrec 'image-history'))
Assert "history keeps only 15 lines" ($recOut.Count -eq 15)
Assert "history records 'yyyymmdd image-name'" ((($recOut | Select-Object -Last 1) -match '^\d{8} code-it-alpine-dotnet-node$'))
Assert "history forgets the oldest line" ($recOut[0] -ne $oldestBefore)

# dry-run records nothing
$hdry = Join-Path $tmp 'histdry'; $null = New-Item -ItemType Directory -Force -Path $hdry
$r = Invoke-Scenario $codeIt @('-dryRun', '-WorkDirToMount', $scriptDir, '-saveDir', $hdry, '-toolchain', 'dotnet,node') $histPath
Assert "dry-run records no history" (-not (Test-Path -Path (Join-Path $hdry 'image-history')))

# ---------------------------------------------------------------------------
"12f. Locale: -locale, defaulting to the host's"
$codeItBuild = Join-Path $scriptDir 'Code-It-Build.ps1'

# Windows, macOS and POSIX spellings all become a POSIX UTF-8 name
$localeCases = [ordered]@{
    'en_GB.UTF-8' = 'en_GB.UTF-8'; 'en_GB.utf8' = 'en_GB.UTF-8'; 'en_US.ISO-8859-1' = 'en_US.UTF-8'
    'en-GB' = 'en_GB.UTF-8'; 'sr-Latn-RS' = 'sr_RS.UTF-8@latin'; 'sr_RS@latin' = 'sr_RS.UTF-8@latin'
    'zh-Hans-CN' = 'zh_CN.UTF-8'; 'zh-Hans_CN' = 'zh_CN.UTF-8'; 'en_GB@rg=gbzzzz' = 'en_GB.UTF-8'
    'de_DE@euro' = 'de_DE.UTF-8'; 'es-419' = 'es.UTF-8'; 'fr' = 'fr.UTF-8'
    'C' = 'C.UTF-8'; 'POSIX' = 'C.UTF-8'; 'C.UTF-8' = 'C.UTF-8'
}
$localeTest = @"
. '$scriptDir/lib/CodeItCommon.ps1'
foreach (`$raw in @('$(($localeCases.Keys + @('', '123', 'x-IV', 'en GB')) -join "','")')) { "NORM[`$raw]=[`$(ConvertTo-CodeItLocale `$raw)]" }
# The OS layer is stubbed, so the order of the host's sources can be tested anywhere
function Get-CodeItOsLocale { `$env:STUB_OS_LOCALE }
`$env:LC_ALL = ''; `$env:LANG = 'fr_FR.UTF-8'; `$env:STUB_OS_LOCALE = 'de-CH'
"LANG=[`$(Resolve-CodeItLocale 'like-host')]"
`$env:LC_ALL = 'it_IT.UTF-8'
"LCALL=[`$(Resolve-CodeItLocale '')]"
`$env:LC_ALL = ''; `$env:LANG = 'C.UTF-8'
"OS=[`$(Resolve-CodeItLocale 'like-host')]"
`$env:STUB_OS_LOCALE = ''
"FALLBACK=[`$(Resolve-CodeItLocale 'like-host')]"
`$env:LANG = 'fr_FR.UTF-8'
"EXPLICIT=[`$(Resolve-CodeItLocale 'nb-NO')]"
"BAD=[`$(Resolve-CodeItLocale '!!' 3>`$null)]"
"@
$r = Invoke-ScenarioCommand $localeTest $stubPath
foreach ($k in $localeCases.Keys) {
    Assert-Contains "normalise '$k' -> '$($localeCases[$k])'" $r.out "NORM[$k]=[$($localeCases[$k])]"
}
foreach ($k in @('', '123', 'x-IV', 'en GB')) { Assert-Contains "normalise rejects '$k'" $r.out "NORM[$k]=[]" }
Assert-Contains "like-host reads LANG" $r.out 'LANG=[fr_FR.UTF-8]'
Assert-Contains "LC_ALL wins over LANG, and empty means like-host" $r.out 'LCALL=[it_IT.UTF-8]'
Assert-Contains "a C.UTF-8 LANG falls through to the OS locale" $r.out 'OS=[de_CH.UTF-8]'
Assert-Contains "nothing to tell falls back to C.UTF-8" $r.out 'FALLBACK=[C.UTF-8]'
Assert-Contains "an explicit locale overrides the host's" $r.out 'EXPLICIT=[nb_NO.UTF-8]'
Assert-Contains "an unreadable locale is an error" $r.out 'BAD=[]'

# WSL reads the Windows locale with reg.exe (a stub here; Windows itself uses Get-Culture)
if (-not $onWindows) {
    $regBin = Join-Path $tmp 'stub-reg'
    $null = New-Item -ItemType Directory -Force -Path $regBin
    Set-Content -Path (Join-Path $regBin 'reg.exe') -Value @'
#!/bin/sh
[ "$3" = "/v" ] && [ "$4" = "LocaleName" ] || exit 1
printf '\r\nHKEY_CURRENT_USER\\Control Panel\\International\r\n    LocaleName    REG_SZ    de-CH\r\n\r\n'
'@
    chmod +x (Join-Path $regBin 'reg.exe')
    $r = Invoke-ScenarioCommand ". '$scriptDir/lib/CodeItCommon.ps1'; 'REG=[' + (Get-CodeItWindowsRegistryLocale) + ']'" "$regBin$sep$stubPath"
    Assert-Contains "reads the Windows locale from reg.exe" $r.out 'REG=[de-CH]'
}

# Code-It-Build passes the locale as a build arg and labels the image with it
$savedLang = $env:LANG; $savedLcAll = $env:LC_ALL
$env:LANG = 'en_GB.UTF-8'; $env:LC_ALL = $null
try {
    $r = Invoke-Scenario $codeItBuild @('-toolchain', 'dotnet,node', '-dryRun', '-dockerfileDir', $scriptDir) $stubPath
    Assert-Contains "build defaults LOCALE to the host's" $r.out '--build-arg LOCALE=en_GB.UTF-8'
    Assert-Contains "build labels the image's locale" $r.out '--label code-it.locale=en_GB.UTF-8'
    $r = Invoke-Scenario $codeItBuild @('-toolchain', 'dotnet,node', '-dryRun', '-dockerfileDir', $scriptDir, '-locale', 'de-DE') $stubPath
    Assert-Contains "build -locale translates a Windows name" $r.out '--build-arg LOCALE=de_DE.UTF-8'
    $r = Invoke-Scenario $codeItBuild @('-toolchain', 'dotnet,node', '-dryRun', '-dockerfileDir', $scriptDir, '-locale', '!!') $stubPath
    Assert "Code-It-Build unreadable -locale fails" ($r.code -ne 0)

    # Code-It passes the locale to the run
    $r = Invoke-Scenario $codeIt (@('-toolchain', 'dotnet,node') + $commonArgs) $stubPath
    Assert-Contains "Code-It runs with the host's locale" $r.out '-e LANG="en_GB.UTF-8"'
    $r = Invoke-Scenario $codeIt (@('-toolchain', 'dotnet,node', '-locale', 'sv-SE') + $commonArgs) $stubPath
    Assert-Contains "Code-It -locale sets the run's LANG" $r.out '-e LANG="sv_SE.UTF-8"'
    $r = Invoke-Scenario $codeIt (@('-toolchain', 'dotnet,node', '-locale', '!!') + $commonArgs) $stubPath
    Assert "Code-It unreadable -locale fails" ($r.code -ne 0)
} finally {
    $env:LANG = $savedLang; $env:LC_ALL = $savedLcAll
}

# ---------------------------------------------------------------------------
"12g. Extra run arguments: -environment, -envFile, -runArgs and <saveDir>/run-args"
$raSave = Join-Path $tmp 'run-args-save'
$null = New-Item -ItemType Directory -Force -Path $raSave
$raEnvFile = Join-Path $tmp 'proxy.env'
Set-Content -Path $raEnvFile -Value 'HTTP_PROXY=http://proxy:8080'
$raArgs = "-WorkDirToMount '$scriptDir' -saveDir '$raSave' -toolchain 'dotnet'"

# (a) each parameter becomes run arguments, after Code-It's own and before the image
$r = Invoke-ScenarioCommand "& '$codeIt' $raArgs -dryRun -environment 'FOO=1','BAR' -envFile '$raEnvFile' -runArgs '--network=host','--dns','10.0.0.2'" $stubPath
Assert "dry-run with extra run arguments exit code 0" ($r.code -eq 0)
Assert-Contains "-environment NAME=VALUE is printed" $r.out '-e FOO=1'
Assert "-environment NAME is printed without a value" ($r.out -match '(?m)-e BAR\r?$')
Assert-Contains "-envFile is printed" $r.out "--env-file $raEnvFile"
Assert-Contains "-runArgs values join their option's line" $r.out '--dns 10.0.0.2'
$env:BAR = 'host-bar'
try {
    $r = Invoke-ScenarioCommand "& '$codeIt' $raArgs -e 'FOO=1','BAR' -envFile '$raEnvFile' -dockerArgs '--network=host' --continue" $stubPath
} finally { $env:BAR = $null }
Assert-Contains "extra run arguments keep their command-line order" $r.out `
    "-e FOO=1 -e BAR --env-file $raEnvFile --network=host"
Assert-Contains "agent data mount is present before runtime arguments" $r.out '/home/agent1/.local/share/opencode'
Assert-Contains "agent args follow the selected image" $r.out '--continue'
Assert "docker reads a bare -e NAME itself, so its value is not passed" (-not $r.out.Contains('host-bar'))
$r = Invoke-Scenario $codeIt (@('-toolchain', 'dotnet,node', '-env', 'FOO=1', '-runArgs', '--network=host', '-WorkDirToMount', $scriptDir, '-saveDir', $raSave)) $stubPath
Assert-Contains "-env and a single -runArgs bind from -File too" $r.out '-e FOO=1 --network=host code-it-alpine-dotnet-node:latest'

# (b) bad -environment and missing -envFile are errors
$r = Invoke-ScenarioCommand "& '$codeIt' $raArgs -dryRun -environment 'NOT A NAME=1'" $stubPath
Assert "-environment with an invalid name fails" ($r.code -ne 0)
$r = Invoke-ScenarioCommand "& '$codeIt' $raArgs -dryRun -envFile '$(Join-Path $tmp 'no-such.env')'" $stubPath
Assert "-envFile that does not exist fails" ($r.code -ne 0)

# (c) <saveDir>/run-args: one argument per line, trimmed, CRLF, comments and blanks
# skipped, before the command line's
[System.IO.File]::WriteAllText((Join-Path $raSave 'run-args'), "# Behind the office proxy`r`n  -e`r`nHTTPS_PROXY  `r`n`r`n--dns=10.0.0.2`r`n--label=x y`n")
$r = Invoke-ScenarioCommand "& '$codeIt' $raArgs -e 'FOO=1'" $stubPath
Assert-Contains "run-args file is reported" $r.out "Using run arguments from $(Join-Path $raSave 'run-args')"
Assert-Contains "run-args file comes first, then the command line's" $r.out `
    '-e HTTPS_PROXY --dns=10.0.0.2 --label=x y -e FOO=1'
Assert "run-args comments are skipped" (-not $r.out.Contains('Behind'))
$r = Invoke-ScenarioCommand "& '$codeIt' $raArgs -dryRun" $stubPath
Assert-Contains "run-args file is printed, quoted" $r.out '"--label=x y"'
Remove-Item (Join-Path $raSave 'run-args')
$r = Invoke-ScenarioCommand "& '$codeIt' $raArgs" $stubPath
Assert "no run-args file, no extra arguments" (-not $r.out.Contains('Using run arguments'))

# (d) the Apple container CLI is given the host's value for a bare -e NAME, and an
# unset NAME is dropped, as docker does; the printout still shows no value
$env:BAR = 'host-bar'
try {
    $r = Invoke-ScenarioCommand "& '$codeIt' $raArgs -runtime container -e 'BAR','UNSET_NAME_FOR_TEST','FOO=1' -runArgs '--env','BAZ=2'" "$stubContainer$sep$stubPath"
} finally { $env:BAR = $null }
Assert-Contains "container: bare -e NAME gets the host's value" $r.out '-e BAR=host-bar -e FOO=1 --env BAZ=2 code-it-alpine-dotnet-node:latest'
Assert "container: printout shows the bare name" ($r.out -match '(?m)-e BAR\r?$')

# (e) help documents the parameters
$help = Get-Help $codeIt -Full | Out-String
Assert-Contains "help documents -environment" $help '-environment'
Assert-Contains "help documents -envFile" $help '-envFile'
Assert-Contains "help documents -runArgs" $help '-runArgs'
Assert-Contains "help documents the run-args file" $help '<saveDir>/run-args'

# ---------------------------------------------------------------------------
"13. PowerShell tab completion"
$completion = Join-Path $scriptDir 'completions/CodeItCompletion.ps1'
$completerTest = @"
. '$completion'
function Complete([string]`$line) {
    `$r = TabExpansion2 `$line `$line.Length
    (`$r.CompletionMatches | ForEach-Object { `$_.CompletionText }) -join ' '
}
"CLAUDE:"   + (Complete "& '$codeIt' -claude -agentArgs --mod")
"OPENCODE:" + (Complete "& '$codeIt' -agentArgs --sta")
"OPENCODEV1:" + (Complete "& '$codeIt' -agent opencode-v1 -agentArgs --th")
"RUNTIME:"  + (Complete "& '$codeIt' -runtime ")
"LOCALE:"   + (Complete "& '$codeIt' -locale ")
"@
$r = Invoke-ScenarioCommand $completerTest $stubPath
Assert "completion script loads" ($r.code -eq 0 -or $null -eq $r.code)
Assert-Contains "-agentArgs completes claude flags" $r.out 'CLAUDE:--model'
Assert-Contains "-agentArgs completes opencode (v2) flags" $r.out 'OPENCODE:--standalone'
Assert-Contains "-agent opencode-v1 completes v1 flags" $r.out 'OPENCODEV1:--thinking'
Assert-Contains "-runtime completes its values" $r.out 'RUNTIME:docker container'
Assert-Contains "-locale completes like-host" $r.out 'LOCALE:like-host C.UTF-8'

# ---------------------------------------------------------------------------
"14. Exclusive agent state: one container per opencode session database"
$excl = Join-Path $tmp 'save-excl'
$null = New-Item -ItemType Directory -Force -Path $excl
$exclArgs  = @('-WorkDirToMount', $scriptDir, '-saveDir', $excl)
# opencode-v1 keeps its state at the save-dir root; its lock dir is named for it
$exclLocks = "$excl/.code-it-instances/opencode-v1"
$slot1Mount = "-v `"$excl/.local/share/opencode:/home/agent1/.local/share/opencode`""
# A pid that is certainly not running: a child that has already exited
$deadPid = (Start-Process -FilePath $pwshExe -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru -Wait).Id

# (a) no lock: slot 1, no warning, and a dry run takes no lock
$r = Invoke-Scenario $codeIt (@('-agent', 'opencode-v1', '-dryRun') + $exclArgs) $stubPath
Assert-Contains "no lock: slot 1 is mounted" $r.out $slot1Mount
Assert "no lock: no warning" (-not $r.out.Contains('Another opencode-v1 container'))
Assert "dry run takes no lock" (-not (Test-Path "$exclLocks/1.lock"))

# (b) slot 1 held by a live process (this test): warn and mount slot 2
$null = New-Item -ItemType Directory -Force -Path $exclLocks, "$excl/.local/share/opencode"
Set-Content -Path "$excl/.local/share/opencode/auth.json" -Value '{"anthropic":{"type":"api"}}'
Set-Content -Path "$exclLocks/1.lock" -Value "$PID"
$r = Invoke-Scenario $codeIt (@('-agent', 'opencode-v1', '-dryRun') + $exclArgs) $stubPath
Assert-Contains "held lock: warns of the other container" $r.out "Another opencode-v1 container is using $excl/.local/share/opencode"
Assert-Contains "held lock: slot 2 is mounted" $r.out "-v `"$exclLocks/2/.local/share/opencode:/home/agent1/.local/share/opencode`""
Assert-Contains "held lock: config is still shared" $r.out "-v `"$excl/.config/opencode:/home/agent1/.config/opencode`""
Assert "dry run copies nothing" (-not (Test-Path "$exclLocks/2"))

# (c) a real (stub) run holds slot 2's lock while the container runs, carries auth.json
# over, and frees the lock afterwards
$stubLocks = Join-Path $tmp 'stub-locks'
$null = New-Item -ItemType Directory -Force -Path $stubLocks
if ($onWindows) {
    Set-Content -Path (Join-Path $stubLocks 'docker.cmd') -Value @'
@echo off
if "%~1"=="images" echo code-it-alpine-dotnet-node:latest& goto :eof
if "%~1"=="image" echo dotnet,node& goto :eof
if "%~1"=="run" (
    echo STUB-DOCKER-RUN %*
    for %%f in ("%STUB_LOCK_DIR%\*.lock") do echo LOCK-DURING-RUN: %%~nxf
    goto :eof
)
echo stub docker: %*
'@
} else {
    Set-Content -Path (Join-Path $stubLocks 'docker') -Value @'
#!/bin/sh
case "$1" in
    images) echo "code-it-alpine-dotnet-node:latest" ;;
    image)  echo "dotnet,node" ;;
    run)    echo "STUB-DOCKER-RUN $*"; for f in "$STUB_LOCK_DIR"/*.lock; do echo "LOCK-DURING-RUN: ${f##*/}"; done ;;
    *)      echo "stub docker: $*" ;;
esac
'@
    chmod +x (Join-Path $stubLocks 'docker')
}
$stubLocksPath = "$stubLocks$sep$origPath"
$env:STUB_LOCK_DIR = $exclLocks
$r = Invoke-Scenario $codeIt (@('-agent', 'opencode-v1') + $exclArgs) $stubLocksPath
Assert-Contains "real run mounts slot 2" $r.out "$exclLocks/2/.local/share/opencode:/home/agent1/.local/share/opencode"
Assert-Contains "real run holds slot 2's lock while running" $r.out 'LOCK-DURING-RUN: 2.lock'
Assert-Contains "real run sees the other run's lock" $r.out 'LOCK-DURING-RUN: 1.lock'
Assert "auth.json to carry: no login note" (-not $r.out.Contains('no saved login'))
Assert "real run frees its lock afterwards" (-not (Test-Path "$exclLocks/2.lock"))
Assert "real run leaves the other run's lock alone" (Test-Path "$exclLocks/1.lock")
$slot2Auth = "$exclLocks/2/.local/share/opencode/auth.json"
Assert "auth.json is carried into the copy" ((Test-Path $slot2Auth) -and
    (Get-Content $slot2Auth -Raw) -eq (Get-Content "$excl/.local/share/opencode/auth.json" -Raw))

# (d) a newer auth.json in slot 1 refreshes the copy's; an older one does not
Set-Content -Path "$excl/.local/share/opencode/auth.json" -Value '{"anthropic":{"type":"oauth"}}'
(Get-Item "$excl/.local/share/opencode/auth.json").LastWriteTimeUtc = [datetime]'2030-01-01'
$null = Invoke-Scenario $codeIt (@('-agent', 'opencode-v1') + $exclArgs) $stubLocksPath
Assert "a newer auth.json refreshes the copy" ((Get-Content $slot2Auth -Raw).Contains('oauth'))
Set-Content -Path $slot2Auth -Value '{"in":"copy"}'
(Get-Item $slot2Auth).LastWriteTimeUtc = [datetime]'2031-01-01'
$null = Invoke-Scenario $codeIt (@('-agent', 'opencode-v1') + $exclArgs) $stubLocksPath
Assert "an older auth.json leaves the copy's alone" ((Get-Content $slot2Auth -Raw).Contains('"in":"copy"'))

# (e) slots 1 and 2 held: slot 3
Set-Content -Path "$exclLocks/2.lock" -Value "$PID"
$r = Invoke-Scenario $codeIt (@('-agent', 'opencode-v1', '-dryRun') + $exclArgs) $stubPath
Assert-Contains "slots 1 and 2 held: slot 3 is mounted" $r.out "$exclLocks/3/.local/share/opencode:/home/agent1/.local/share/opencode"
Remove-Item -Force "$exclLocks/2.lock"

# (f) a stale lock (its process has exited): slot 1, no warning; a real run replaces it
Set-Content -Path "$exclLocks/1.lock" -Value "$deadPid"
$r = Invoke-Scenario $codeIt (@('-agent', 'opencode-v1', '-dryRun') + $exclArgs) $stubPath
Assert-Contains "stale lock: slot 1 is mounted" $r.out $slot1Mount
Assert "stale lock: no warning" (-not $r.out.Contains('Another opencode-v1 container'))
$r = Invoke-Scenario $codeIt (@('-agent', 'opencode-v1') + $exclArgs) $stubLocksPath
Assert-Contains "stale lock: a real run takes slot 1" $r.out 'LOCK-DURING-RUN: 1.lock'
Assert "stale lock: removed after the run" (-not (Test-Path "$exclLocks/1.lock"))
Remove-Item Env:STUB_LOCK_DIR

# (g) an agent without AGENT_EXCLUSIVE_DIRS takes no lock
Remove-Item -Recurse -Force "$excl/.code-it-instances"
$null = Invoke-Scenario $codeIt (@('-c') + $exclArgs) $stubPath
Assert "claude takes no lock" (-not (Test-Path "$excl/.code-it-instances"))

# (h) opencode (v2, the default agent): both its data and its shared-service state are
# exclusive, locked under its own save subdir, apart from opencode-v1's
$v2Locks = "$excl/opencode-v2/.code-it-instances/opencode"
$null = New-Item -ItemType Directory -Force -Path $v2Locks, "$excl/opencode-v2/.local/share/opencode"
Set-Content -Path "$v2Locks/1.lock" -Value "$PID"
$r = Invoke-Scenario $codeIt (@('-agent', 'opencode', '-dryRun') + $exclArgs) $stubPath
Assert-Contains "v2 held lock: warns of the other container" $r.out "Another opencode container is using $excl/opencode-v2/.local/share/opencode"
Assert-Contains "v2 held lock: data from slot 2" $r.out "-v `"$v2Locks/2/.local/share/opencode:/home/agent1/.local/share/opencode`""
Assert-Contains "v2 held lock: shared-service state from slot 2" $r.out "-v `"$v2Locks/2/.local/state/opencode:/home/agent1/.local/state/opencode`""
Assert-Contains "v2 held lock: config is still shared" $r.out "-v `"$excl/opencode-v2/.config/opencode:/home/agent1/.config/opencode`""
Assert-Contains "v2 new copy: says it has no saved login" $r.out 'This copy has no saved login'
Set-Content -Path "$excl/opencode-v2/.local/share/opencode/auth.json" -Value '{"v1":"style"}'
$env:STUB_LOCK_DIR = $v2Locks
$r = Invoke-Scenario $codeIt (@('-agent', 'opencode') + $exclArgs) $stubLocksPath
Assert-Contains "v2 real run holds slot 2's lock" $r.out 'LOCK-DURING-RUN: 2.lock'
Assert "v2 copy has its own shared-service state" (Test-Path "$v2Locks/2/.local/state/opencode" -PathType Container)
Assert "v2 carries no auth.json (its login is in its database)" (-not (Test-Path "$v2Locks/2/.local/share/opencode/auth.json"))
$r = Invoke-Scenario $codeIt (@('-agent', 'opencode') + $exclArgs) $stubLocksPath
Remove-Item Env:STUB_LOCK_DIR
Assert "v2 reused copy: no login note (it keeps its own)" (-not $r.out.Contains('no saved login'))
Remove-Item -Force "$v2Locks/1.lock"
$r = Invoke-Scenario $codeIt (@('-agent', 'opencode', '-dryRun') + $exclArgs) $stubPath
Assert-Contains "v2 free: slot 1 state is mounted" $r.out "-v `"$excl/opencode-v2/.local/state/opencode:/home/agent1/.local/state/opencode`""
$null = New-Item -ItemType Directory -Force -Path $exclLocks
Set-Content -Path "$exclLocks/1.lock" -Value "$PID"
$r = Invoke-Scenario $codeIt (@('-agent', 'opencode', '-dryRun') + $exclArgs) $stubPath
Assert "an opencode-v1 lock does not affect opencode (v2)" (-not $r.out.Contains('Another opencode container'))
Remove-Item -Recurse -Force "$excl/.code-it-instances"

# (i) help documents it
$r = Invoke-ScenarioCommand "Get-Help '$codeIt' -Full | Out-String -Width 200" $stubPath
Assert-Contains "help documents exclusive state" $r.out 'AGENT_EXCLUSIVE_DIRS'

# ---------------------------------------------------------------------------
"23. Work dir mounts at /work/<parent>/<name> (Spec 18)"
Assert "mount path of / is /work" ((Get-CodeItWorkMountPath '/') -eq '/work')
Assert "a work dir with no parent to name mounts at /work/<name>" ((Get-CodeItWorkMountPath '/tmp') -eq '/work/tmp')
Assert "mount path uses the parent directory's name" ((Get-CodeItWorkMountPath '/tmp/x') -eq '/work/tmp/x')
Assert "mount path uses the nearest names only" ((Get-CodeItWorkMountPath '/a/b/c/d') -eq '/work/c/d')
Assert "a ':' in a directory name cannot break -v syntax" ((Get-CodeItWorkMountPath '/a/b:c/d') -eq '/work/b-c/d')
Assert "a trailing slash does not change the mount path" ((Get-CodeItWorkMountPath '/a/b/') -eq '/work/a/b')
Assert "a backslash-separated work dir mounts at /work/<parent>/<name>" ((Get-CodeItWorkMountPath 'C:\Users\me\work-parent\work-dir') -eq '/work/work-parent/work-dir')
$sep = [IO.Path]::DirectorySeparatorChar
$nested = Join-Path $tmp "work-parent${sep}work-dir"
$null = New-Item -ItemType Directory -Force -Path $nested
$r = Invoke-Scenario $codeIt (@('-dryRun','-WorkDirToMount',$nested,'-saveDir',$save)) $stubPath
Assert "dry-run with a nested work dir exit code 0" ($r.code -eq 0)
Assert-Contains "nested work dir mounts at /work/<parent>/<name>" $r.out "work-parent${sep}work-dir:/work/work-parent/work-dir"
Assert-Contains "nested work dir env tells go.sh where to cd" $r.out 'CODE_IT_WORK_DIR="/work/work-parent/work-dir"'

# ---------------------------------------------------------------------------
Remove-Item -Recurse -Force $tmp -EA Silent
""
"Results: $script:pass passed, $script:fail failed"
if ($script:fail -ne 0) { exit 1 }

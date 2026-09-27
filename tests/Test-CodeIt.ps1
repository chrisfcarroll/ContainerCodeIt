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
if "%~1"=="image" if "%~2"=="inspect" (
    if defined STUB_IMAGE_TOOL_CHAINS (echo %STUB_IMAGE_TOOL_CHAINS%) else (echo dotnet,node)
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
    image)  case "$2" in inspect) echo "${STUB_IMAGE_TOOL_CHAINS-dotnet,node}" ;; *) echo "stub docker: $*" ;; esac ;;
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
if "%~1"=="image" if "%~2"=="inspect" (
    if defined STUB_IMAGE_TOOL_CHAINS (echo %STUB_IMAGE_TOOL_CHAINS%) else (echo dotnet,node)
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
                inspect) echo "${STUB_IMAGE_TOOL_CHAINS-dotnet,node}" ;;
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

# ---------------------------------------------------------------------------
"1. Parse checks"
foreach ($f in @('Code-It.ps1','Code-It-Build.ps1','lib/CodeItCommon.ps1','Claude-It.ps1','OpenCode-It.ps1','tests/Test-CodeIt.ps1','completions/CodeItCompletion.ps1')) {
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptDir $f), [ref]$null, [ref]$parseErrors)
    Assert "parses: $f" ($parseErrors.Count -eq 0)
}

# ---------------------------------------------------------------------------
"2. Default dry-run: opencode agent, all state mounts"
$r = Invoke-Scenario $codeIt $commonArgs $stubPath
Assert "dry-run exit code 0" ($r.code -eq 0)
Assert-Contains "reports OpenCode config creation" $r.out 'Created OpenCode configuration'
Assert-Contains "uses docker runtime" $r.out 'Using container runtime: docker'
Assert-Contains "defaults to opencode" $r.out 'CODE_AGENT="opencode"'
Assert-Contains "docker run command" $r.out 'docker run -it'
Assert-Contains "image name" $r.out 'code-it-alpine-dotnet-node:latest'
Assert-Contains "work dir mount" $r.out "$scriptDir`:/work"
Assert-Contains "claude dir mount" $r.out '/.claude:/home/agent1/.claude'
Assert-Contains "claude.json mount" $r.out '/.claude.json:/home/agent1/.claude.json'
Assert-Contains "opencode config mount" $r.out '/.config/opencode:/home/agent1/.config/opencode'
Assert-Contains "opencode mount" $r.out '/.local/share/opencode:/home/agent1/.local/share/opencode'
Assert-Contains "default auto-assign port" $r.out '-p 0:3000'

# ---------------------------------------------------------------------------
"3. Save dir structure is created for first run"
Assert "save/.claude created" (Test-Path "$save/.claude" -PathType Container)
Assert "save/.config/opencode created" (Test-Path "$save/.config/opencode" -PathType Container)
Assert "save/.local/share/opencode created" (Test-Path "$save/.local/share/opencode" -PathType Container)
Assert "save/.claude.json created as a file" (Test-Path "$save/.claude.json" -PathType Leaf)
$opencodeConfig = Get-Content "$save/.config/opencode/config.json" -Raw | ConvertFrom-Json
Assert "OpenCode config permits all actions" ($opencodeConfig.permission -eq 'allow')

# ---------------------------------------------------------------------------
"4. Agent selection switches"
$r = Invoke-Scenario $codeIt (@('-opencode') + $commonArgs) $stubPath
Assert-Contains "-opencode selects opencode" $r.out 'CODE_AGENT="opencode"'
$r = Invoke-Scenario $codeIt (@('-o') + $commonArgs) $stubPath
Assert-Contains "-o selects opencode" $r.out 'CODE_AGENT="opencode"'
$r = Invoke-Scenario $codeIt (@('-claude') + $commonArgs) $stubPath
Assert-Contains "-claude selects claude" $r.out 'CODE_AGENT="claude"'
Assert-Contains "reports Claude settings creation" $r.out 'Created Claude Code settings'
$claudeSettings = Get-Content "$save/.claude/settings.json" -Raw | ConvertFrom-Json
Assert "Claude settings enable auto mode" ($claudeSettings.permissions.defaultMode -eq 'auto')
Assert "Claude settings skip dangerous-mode prompt" ($claudeSettings.skipDangerousModePermissionPrompt -eq $true)
$r = Invoke-Scenario $codeIt (@('-c') + $commonArgs) $stubPath
Assert-Contains "-c selects claude" $r.out 'CODE_AGENT="claude"'
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
$r = Invoke-Scenario $codeIt (@('-runtime', 'container', '-port', '3000') + $commonArgs) "$stubContainer$sep$stubPath"
Assert "-runtime container exit code 0" ($r.code -eq 0)
Assert-Contains "-runtime container forces apple container" $r.out 'Using container runtime: container'
Assert-Contains "container run command" $r.out 'container run -it'
Assert-Contains "container maps the single requested port" $r.out '-p 3000:3000'
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
Assert "unknown image without -buildImage fails" ($r.code -ne 0)
$env:STUB_IMAGES_FAIL = '1'
try { $r = Invoke-Scenario $codeIt $commonArgs $stubPath } finally { $env:STUB_IMAGES_FAIL = $null }
Assert "failure to list images fails" ($r.code -ne 0)
Assert-Contains "failure to list images asks if the runtime is running" $r.out 'Could not list docker images'

# ---------------------------------------------------------------------------
"9. Build image"
$r = Invoke-Scenario $codeIt (@('-buildImage') + $commonArgs) $stubPath
Assert "-buildImage exit code 0" ($r.code -eq 0)
Assert-Contains "docker build invoked" $r.out 'STUB-DOCKER-BUILD'
Assert-Contains "build tags the image" $r.out '-t code-it-alpine-dotnet-node:latest'
$r = Invoke-Scenario $codeIt (@('-buildImage', '-dockerfileDir', $tmp) + $commonArgs) $stubPath
Assert "-buildImage with no Dockerfile fails" ($r.code -ne 0)
$env:STUB_BUILD_FAIL = '1'
try { $r = Invoke-Scenario $codeIt @('-buildImage', '-WorkDirToMount', $scriptDir, '-saveDir', $save) $stubPath }
finally { $env:STUB_BUILD_FAIL = $null }
Assert "failed build exits non-zero" ($r.code -ne 0)
Assert "failed build does not run the container" (-not $r.out.Contains('STUB-DOCKER-RUN'))

# ---------------------------------------------------------------------------
"9b. Rebuild image (updates the agents)"
$dfDir = Join-Path $tmp 'dfdir'
$null = New-Item -ItemType Directory -Force -Path $dfDir
$dfPath = Join-Path $dfDir 'Dockerfile'
# Write the fixture with explicit LF: Set-Content would join lines with CRLF on Windows
$dfOriginal = [IO.File]::ReadAllText((Join-Path $scriptDir 'Dockerfile')) -replace '# last changed [0-9-]+', '# last changed 2000-01-01'
$dfLF = $dfOriginal -replace "`r`n", "`n"
[IO.File]::WriteAllText($dfPath, $dfLF)
$today = [DateTime]::Today.ToString('yyyy-MM-dd')
$r = Invoke-Scenario $codeIt (@('-rebuildImage', '-dockerfileDir', $dfDir) + $commonArgs) $stubPath
Assert "-rebuildImage exit code 0" ($r.code -eq 0)
Assert-Contains "rebuild invokes docker build" $r.out 'STUB-DOCKER-BUILD'
Assert-Contains "rebuild implies build (no -buildImage needed)" $r.out '-t code-it-alpine-dotnet-node:latest'
$df = Get-Content $dfPath -Raw
Assert "Dockerfile dates bumped to today" ($df.Contains("# last changed $today"))
Assert "old dates gone from Dockerfile" (-not $df.Contains('# last changed 2000-01-01'))
Assert "rebuild leaves LF Dockerfile without carriage returns" (-not $df.Contains("`r"))
Assert "rebuild changes only the dates" ($df -eq ($dfLF -replace '# last changed 2000-01-01', "# last changed $today"))
$dfBytes = [IO.File]::ReadAllBytes($dfPath)
Assert "rebuild writes no BOM" (-not ($dfBytes[0] -eq 0xEF -and $dfBytes[1] -eq 0xBB -and $dfBytes[2] -eq 0xBF))
[IO.File]::WriteAllText($dfPath, ($dfLF -replace "`n", "`r`n"))
$r = Invoke-Scenario $codeIt (@('-rebuildImage', '-dockerfileDir', $dfDir) + $commonArgs) $stubPath
$df = [IO.File]::ReadAllText($dfPath)
Assert "rebuild keeps CRLF Dockerfile as CRLF" (-not ($df -replace "`r`n", '').Contains("`n"))
# plain -buildImage leaves the dates untouched
(Get-Content (Join-Path $scriptDir 'Dockerfile')) -replace '# last changed [0-9-]+', '# last changed 2000-01-01' | Set-Content $dfPath
$r = Invoke-Scenario $codeIt (@('-buildImage', '-dockerfileDir', $dfDir) + $commonArgs) $stubPath
Assert "-buildImage exit code 0 (dfdir)" ($r.code -eq 0)
$df = Get-Content $dfPath -Raw
Assert "-buildImage leaves dates unchanged" ($df.Contains('# last changed 2000-01-01'))

# ---------------------------------------------------------------------------
"9c. Code-It-Build.ps1: dry-run, labels, -tech, -rebuild"
$codeItBuild = Join-Path $scriptDir 'Code-It-Build.ps1'

# -dryRun prints the build command without executing it
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir) $stubPath
Assert "Code-It-Build -dryRun exit code 0" ($r.code -eq 0)
Assert-Contains "build dry-run prints the build command" $r.out 'docker build'
Assert-Contains "build dry-run passes DOTNET=true" $r.out '--build-arg DOTNET=true'
Assert-Contains "build dry-run passes NODE=true" $r.out '--build-arg NODE=true'
Assert-Contains "build dry-run passes NUGET=true (implied by dotnet)" $r.out '--build-arg NUGET=true'
Assert-Contains "build dry-run passes NPM=true (implied by node)" $r.out '--build-arg NPM=true'
Assert-Contains "build dry-run labels the tool chains" $r.out '--label code-it.tool-chains=dotnet,node'
Assert-Contains "build dry-run labels the package caches" $r.out '--label code-it.package-caches=nuget,npm'
Assert-Contains "build dry-run derives the default image name" $r.out '-t code-it-alpine-dotnet-node:latest'
Assert "build dry-run does not execute the build" (-not $r.out.Contains('STUB-DOCKER-BUILD'))

# -tech is the kept alias of -toolChains
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-tech', 'bun') $stubPath
Assert-Contains "build -tech alias selects BUN" $r.out '--build-arg BUN=true'
Assert-Contains "build -tech alias derives the image name" $r.out '-t code-it-alpine-bun:latest'

# -packageCaches replaces the implied set
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-toolChains', 'bun', '-packageCaches', 'nuget') $stubPath
Assert-Contains "build -packageCaches nuget without dotnet" $r.out '--build-arg NUGET=true'
Assert-Contains "build -packageCaches nuget excludes NPM" $r.out '--build-arg NPM=false'

# Unknown names are hard errors
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-toolChains', 'cobol') $stubPath
Assert "Code-It-Build unknown tool chain fails" ($r.code -ne 0)
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-packageCaches', 'pip') $stubPath
Assert "Code-It-Build unknown package cache fails" ($r.code -ne 0)

# -rebuild bumps the dates and then really builds
$bDfDir = Join-Path $tmp 'build-dfdir'
$null = New-Item -ItemType Directory -Force -Path $bDfDir
$bDfPath = Join-Path $bDfDir 'Dockerfile'
[IO.File]::WriteAllText($bDfPath, $dfLF)
$r = Invoke-Scenario $codeItBuild @('-rebuild', '-dockerfileDir', $bDfDir, '-runtime', 'docker') $stubPath
Assert "Code-It-Build -rebuild exit code 0" ($r.code -eq 0)
Assert-Contains "Code-It-Build -rebuild invokes docker build" $r.out 'STUB-DOCKER-BUILD'
Assert "Code-It-Build -rebuild bumps the dates" ((Get-Content $bDfPath -Raw).Contains("# last changed $today"))
# A missing Dockerfile is an error
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $tmp) $stubPath
Assert "Code-It-Build without a Dockerfile fails" ($r.code -ne 0)

"9d. Code-It reads the image label"
$env:STUB_IMAGE_TOOL_CHAINS = 'node,bun'
try { $r = Invoke-Scenario $codeIt (@('-image', 'code-it-alpine-dotnet-node') + $commonArgs) $stubPath }
finally { $env:STUB_IMAGE_TOOL_CHAINS = $null }
Assert-Contains "warns when the image label disagrees with -toolChains" $r.out "looks built for tech 'node,bun'"
$r = Invoke-Scenario $codeIt (@('-buildImage') + $commonArgs) $stubPath
Assert-Contains "the -buildImage shim prints a deprecation note" $r.out 'deprecated'

"9e. Python tool chain (python / uv / -stack)"
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-stack', 'python') $stubPath
Assert-Contains "-stack python sets PYTHON=true" $r.out '--build-arg PYTHON=true'
Assert-Contains "-stack python derives the image name" $r.out '-t code-it-alpine-python:latest'
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-toolChains', 'uv') $stubPath
Assert-Contains "uv aliases python (PYTHON=true)" $r.out '--build-arg PYTHON=true'
Assert-Contains "uv canonical image name" $r.out '-t code-it-alpine-python:latest'
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir) $stubPath
Assert-Contains "default build sets PYTHON=false" $r.out '--build-arg PYTHON=false'
$r = Invoke-Scenario $codeIt (@('-stack', 'python', '-buildImage') + $commonArgs) $stubPath
Assert-Contains "code-it -stack python delegates a PYTHON=true build" $r.out '--build-arg PYTHON=true'
$dfText = Get-Content (Join-Path $scriptDir 'Dockerfile') -Raw
Assert "Dockerfile installs uv for every image" ($dfText.Contains('apk add --no-cache uv'))
Assert "Dockerfile gates python3 on PYTHON" ($dfText.Contains('if [ "$PYTHON" = true ]'))

# ---------------------------------------------------------------------------
"10. Custom options"
$r = Invoke-Scenario $codeIt (@('-port', '8000') + $commonArgs) $stubPath
Assert-Contains "custom -port maps the host port to container 3000" $r.out '-p 8000:3000'
$r = Invoke-Scenario $codeIt (@('-port', '0') + $commonArgs) $stubPath
Assert-Contains "-port 0 lets docker auto-assign" $r.out '-p 0:3000'
$r = Invoke-Scenario $codeIt (@('-agentName', 'MyAgent') + $commonArgs) $stubPath
Assert-Contains "agent name lowercased in mounts" $r.out '/home/myagent/.claude'
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
"11b. Tech stack: -toolChains / -packageCaches build args and read-only caches"
$r = Invoke-Scenario $codeIt (@('-buildImage') + $commonArgs) $stubPath
Assert-Contains "default build passes DOTNET=true" $r.out '--build-arg DOTNET=true'
Assert-Contains "default build passes NODE=true" $r.out '--build-arg NODE=true'
Assert-Contains "default build passes BUN=false" $r.out '--build-arg BUN=false'
Assert-Contains "dotnet implies NUGET=true" $r.out '--build-arg NUGET=true'
Assert-Contains "node implies NPM=true" $r.out '--build-arg NPM=true'
Assert-Contains "reports the resolved tech" $r.out 'tech dotnet,node; package repos nuget,npm'

# -toolChains replaces the default set
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolChains','node,bun') + $commonArgs) $stubPath
Assert-Contains "-toolChains node,bun drops DOTNET" $r.out '--build-arg DOTNET=false'
Assert-Contains "-toolChains node,bun keeps NODE" $r.out '--build-arg NODE=true'
Assert-Contains "-toolChains node,bun keeps BUN" $r.out '--build-arg BUN=true'
Assert-Contains "-toolChains node,bun drops NUGET (dotnet gone)" $r.out '--build-arg NUGET=false'
Assert-Contains "-toolChains node,bun keeps NPM (node present)" $r.out '--build-arg NPM=true'

# -packageCaches replaces the implied set, independently of -toolChains
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolChains','node,bun','-packageCaches','npm') + $commonArgs) $stubPath
Assert-Contains "-packageCaches npm keeps NPM" $r.out '--build-arg NPM=true'
Assert-Contains "-packageCaches npm excludes NUGET" $r.out '--build-arg NUGET=false'
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolChains','node,bun','-packageCaches','bun') + $commonArgs) $stubPath
Assert-Contains "-packageCaches bun selects the BUN package cache" $r.out '--build-arg NPM=false'
Assert-Contains "-packageCaches bun excludes NUGET" $r.out '--build-arg NUGET=false'
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolChains','bun','-packageCaches','nuget') + $commonArgs) $stubPath
Assert-Contains "nuget package cache without dotnet" $r.out '--build-arg NUGET=true'

# The default image name follows -toolChains
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolChains','node,bun') + $commonArgs) $stubPath
Assert-Contains "image name derives from -toolChains" $r.out '-t code-it-alpine-node-bun:latest'

# The old -tech spelling is kept as a hidden alias
$r = Invoke-Scenario $codeIt (@('-buildImage','-tech','bun') + $commonArgs) $stubPath
Assert-Contains "-tech alias selects BUN" $r.out '--build-arg BUN=true'

# Tech aliases resolve to the canonical name: js-node/ts-node -> node, js-bun/ts-bun -> bun
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolChains','js-node') + $commonArgs) $stubPath
Assert-Contains "js-node aliases node (NODE=true)" $r.out '--build-arg NODE=true'
Assert-Contains "js-node canonical image name" $r.out '-t code-it-alpine-node:latest'
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolChains','ts-node') + $commonArgs) $stubPath
Assert-Contains "ts-node aliases node (NODE=true)" $r.out '--build-arg NODE=true'
Assert-Contains "ts-node canonical image name" $r.out '-t code-it-alpine-node:latest'
Assert-Contains "ts-node implies the npm package cache" $r.out '--build-arg NPM=true'
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolChains','js-bun') + $commonArgs) $stubPath
Assert-Contains "js-bun aliases bun (BUN=true)" $r.out '--build-arg BUN=true'
Assert-Contains "js-bun canonical image name" $r.out '-t code-it-alpine-bun:latest'
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolChains','ts-bun,bun') + $commonArgs) $stubPath
Assert-Contains "ts-bun aliases bun and dedupes with bun" $r.out '-t code-it-alpine-bun:latest'

# The old -packages spelling is gone as a parameter: it is now passed to the agent,
# so it no longer selects a package cache
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolChains','bun','-packages','npm') + $commonArgs) $stubPath
Assert-Contains "removed -packages is forwarded to the agent" $r.out '-packages npm'
Assert-Contains "removed -packages no longer selects NPM" $r.out '--build-arg NPM=false'

$env:STUB_IMAGE_TOOL_CHAINS = 'dotnet'
try { $r = Invoke-Scenario $codeIt (@('-toolChains','node,bun','-image','code-it-alpine-dotnet') + $commonArgs) $stubPath }
finally { $env:STUB_IMAGE_TOOL_CHAINS = $null }
Assert-Contains "warns when the image label disagrees with -toolChains" $r.out "looks built for tech 'dotnet'"
# Without a label (older images), fall back to the name-based guess
$env:STUB_IMAGE_TOOL_CHAINS = ''
try { $r = Invoke-Scenario $codeIt (@('-toolChains','node,bun','-image','code-it-alpine-dotnet') + $commonArgs) $stubPath }
finally { $env:STUB_IMAGE_TOOL_CHAINS = $null }
Assert-Contains "falls back to the image-name guess without a label" $r.out "looks built for tech 'dotnet'"

# Unknown names are hard errors
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolChains','cobol') + $commonArgs) $stubPath
Assert "-toolChains with an unknown name fails" ($r.code -ne 0)
$r = Invoke-Scenario $codeIt (@('-buildImage','-packageCaches','pip') + $commonArgs) $stubPath
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
    $r = Invoke-Scenario $codeIt (@('-toolChains','node','-packageCaches',',') + $commonArgs) $stubPath
    Assert "empty -packageCaches: no npm mount" (-not $r.out.Contains('.npm-host'))
    $env:NPM_CONFIG_CACHE = $null
    $env:NUGET_PACKAGES = (Resolve-Path "$fakeHome/.nuget/packages").Path
    $r = Invoke-Scenario $codeIt (@('-toolChains','dotnet','-packageCaches','npm') + $commonArgs) $stubPath
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
Assert-Contains "opencode: prompt becomes --prompt" $r.out 'code-it-alpine-dotnet-node:latest --prompt "explain this repo"'

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
Assert-Contains "opencode -headless uses run" $r.out 'code-it-alpine-dotnet-node:latest run "fix the build"'

# Unrecognised arguments go to the agent verbatim: PowerShell has no usable `--`
$r = Invoke-Scenario $codeIt (@('-c') + $commonArgs + @('--continue','--model','opus')) $stubPath
Assert-Contains "unrecognised flags pass through" $r.out 'code-it-alpine-dotnet-node:latest --continue --model opus'
$r = Invoke-Scenario $codeIt (@('-c','-headless','-prompt','tidy') + $commonArgs + @('--max-turns','5')) $stubPath
Assert-Contains "agent flags precede the prompt for claude" $r.out 'code-it-alpine-dotnet-node:latest -p --max-turns 5 tidy'
$r = Invoke-Scenario $codeIt (@('-o','-headless','-prompt','tidy') + $commonArgs + @('--model','opus')) $stubPath
Assert-Contains "agent flags follow run for opencode" $r.out 'code-it-alpine-dotnet-node:latest run --model opus tidy'
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
"13. PowerShell tab completion"
$completion = Join-Path $scriptDir 'completions/CodeItCompletion.ps1'
$completerTest = @"
. '$completion'
function Complete([string]`$line) {
    `$r = TabExpansion2 `$line `$line.Length
    (`$r.CompletionMatches | ForEach-Object { `$_.CompletionText }) -join ' '
}
"CLAUDE:"   + (Complete "& '$codeIt' -claude -agentArgs --mod")
"OPENCODE:" + (Complete "& '$codeIt' -agentArgs --se")
"RUNTIME:"  + (Complete "& '$codeIt' -runtime ")
"@
$r = Invoke-ScenarioCommand $completerTest $stubPath
Assert "completion script loads" ($r.code -eq 0 -or $null -eq $r.code)
Assert-Contains "-agentArgs completes claude flags" $r.out 'CLAUDE:--model'
Assert-Contains "-agentArgs completes opencode flags" $r.out 'OPENCODE:--session'
Assert-Contains "-runtime completes its values" $r.out 'RUNTIME:docker container'

# ---------------------------------------------------------------------------
Remove-Item -Recurse -Force $tmp -EA Silent
""
"Results: $script:pass passed, $script:fail failed"
if ($script:fail -ne 0) { exit 1 }

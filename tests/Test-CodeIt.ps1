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
if "%~1"=="images" echo code-it-alpine-dotnet:latest& goto :eof
if "%~1"=="build" echo STUB-DOCKER-BUILD %*& goto :eof
if "%~1"=="run" echo STUB-DOCKER-RUN %*& goto :eof
echo stub docker: %*
'@
} else {
    Set-Content -Path (Join-Path $stubDocker 'docker') -Value @'
#!/bin/sh
case "$1" in
    images) echo "code-it-alpine-dotnet:latest" ;;
    build)  echo "STUB-DOCKER-BUILD $*" ;;
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
if "%~1"=="image" echo code-it-alpine-dotnet  latest& goto :eof
if "%~1"=="build" echo STUB-CONTAINER-BUILD %*& goto :eof
if "%~1"=="run" echo STUB-CONTAINER-RUN %*& goto :eof
echo stub container: %*
'@
} else {
    Set-Content -Path (Join-Path $stubContainer 'container') -Value @'
#!/bin/sh
case "$1" in
    image)  echo "code-it-alpine-dotnet  latest" ;;
    build)  echo "STUB-CONTAINER-BUILD $*" ;;
    run)    echo "STUB-CONTAINER-RUN $*" ;;
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
foreach ($f in @('Code-It.ps1','Claude-It.ps1','OpenCode-It.ps1','tests/Test-CodeIt.ps1')) {
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptDir $f), [ref]$null, [ref]$parseErrors)
    Assert "parses: $f" ($parseErrors.Count -eq 0)
}

# ---------------------------------------------------------------------------
"2. Default dry-run: opencode agent, all state mounts"
$r = Invoke-Scenario $codeIt $commonArgs $stubPath
Assert "dry-run exit code 0" ($r.code -eq 0)
Assert-Contains "uses docker runtime" $r.out 'Using container runtime: docker'
Assert-Contains "defaults to opencode" $r.out 'CODE_AGENT="opencode"'
Assert-Contains "docker run command" $r.out 'docker run -it'
Assert-Contains "image name" $r.out 'code-it-alpine-dotnet:latest'
Assert-Contains "work dir mount" $r.out "$scriptDir`:/repos"
Assert-Contains "claude dir mount" $r.out '/.claude:/home/agent1/.claude'
Assert-Contains "claude.json mount" $r.out '/.claude.json:/home/agent1/.claude.json'
Assert-Contains "opencode mount" $r.out '/.local/share/opencode:/home/agent1/.local/share/opencode'
Assert-Contains "default auto-assign ports" $r.out '-p 0:3000 -p 0:3001'

# ---------------------------------------------------------------------------
"3. Save dir structure is created for first run"
Assert "save/.claude created" (Test-Path "$save/.claude" -PathType Container)
Assert "save/.local/share/opencode created" (Test-Path "$save/.local/share/opencode" -PathType Container)
Assert "save/.claude.json created as a file" (Test-Path "$save/.claude.json" -PathType Leaf)

# ---------------------------------------------------------------------------
"4. Agent selection switches"
$r = Invoke-Scenario $codeIt (@('-opencode') + $commonArgs) $stubPath
Assert-Contains "-opencode selects opencode" $r.out 'CODE_AGENT="opencode"'
$r = Invoke-Scenario $codeIt (@('-o') + $commonArgs) $stubPath
Assert-Contains "-o selects opencode" $r.out 'CODE_AGENT="opencode"'
$r = Invoke-Scenario $codeIt (@('-claude') + $commonArgs) $stubPath
Assert-Contains "-claude selects claude" $r.out 'CODE_AGENT="claude"'
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
$r = Invoke-Scenario $codeIt (@('-runtime', 'container') + $commonArgs) "$stubContainer$sep$stubPath"
Assert "-runtime container exit code 0" ($r.code -eq 0)
Assert-Contains "-runtime container forces apple container" $r.out 'Using container runtime: container'
Assert-Contains "container run command" $r.out 'container run -it'
Assert-Contains "container default fixed ports" $r.out '-p 3000:3000 -p 3001:3001'
$r = Invoke-Scenario $codeIt (@('-runtime', 'bogus') + $commonArgs) $stubPath
Assert "-runtime bogus fails" ($r.code -ne 0)

# ---------------------------------------------------------------------------
"8. Error handling"
$r = Invoke-Scenario $codeIt @('-dryRun', '-WorkDirToMount', (Join-Path $tmp 'does-not-exist'), '-saveDir', $save) $stubPath
Assert "missing work dir fails" ($r.code -ne 0)
$r = Invoke-Scenario $codeIt (@('-image', 'no-such-image') + $commonArgs) $stubPath
Assert "unknown image without -buildImage fails" ($r.code -ne 0)

# ---------------------------------------------------------------------------
"9. Build image"
$r = Invoke-Scenario $codeIt (@('-buildImage') + $commonArgs) $stubPath
Assert "-buildImage exit code 0" ($r.code -eq 0)
Assert-Contains "docker build invoked" $r.out 'STUB-DOCKER-BUILD'
Assert-Contains "build tags the image" $r.out '-t code-it-alpine-dotnet:latest'
$r = Invoke-Scenario $codeIt (@('-buildImage', '-dockerfileDir', $tmp) + $commonArgs) $stubPath
Assert "-buildImage with no Dockerfile fails" ($r.code -ne 0)

# ---------------------------------------------------------------------------
"10. Custom options"
$r = Invoke-ScenarioCommand "& '$codeIt' -portsMap '8000:3000','8001:3001' -dryRun -WorkDirToMount '$scriptDir' -saveDir '$save'" $stubPath
Assert-Contains "custom ports" $r.out '-p 8000:3000 -p 8001:3001'
$r = Invoke-Scenario $codeIt (@('-agentName', 'MyAgent') + $commonArgs) $stubPath
Assert-Contains "agent name lowercased in mounts" $r.out '/home/myagent/.claude'
Assert-Contains "agent name in git author" $r.out 'GIT_AUTHOR_NAME="MyAgent for'

# ---------------------------------------------------------------------------
Remove-Item -Recurse -Force $tmp -EA Silent
""
"Results: $script:pass passed, $script:fail failed"
if ($script:fail -ne 0) { exit 1 }

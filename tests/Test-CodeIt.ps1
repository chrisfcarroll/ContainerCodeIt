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

# ---------------------------------------------------------------------------
"1. Parse checks"
foreach ($f in @('Code-It.ps1','Code-It-Build.ps1','Code-It-FirstRun.ps1','Code-It-Add-Agent.ps1','Code-It-Add-Tool-Chain.ps1','lib/CodeItCommon.ps1','Claude-It.ps1','OpenCode-It.ps1','tests/Test-CodeIt.ps1','completions/CodeItCompletion.ps1')) {
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptDir $f), [ref]$null, [ref]$parseErrors)
    Assert "parses: $f" ($parseErrors.Count -eq 0)
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
Assert-Contains "work dir mount" $r.out "$scriptDir`:/work"
Assert-Contains "opencode config mount" $r.out '/.config/opencode:/home/agent1/.config/opencode'
Assert-Contains "opencode mount" $r.out '/.local/share/opencode:/home/agent1/.local/share/opencode'
Assert "opencode run mounts no claude state" (-not $r.out.Contains('/home/agent1/.claude'))
Assert-Contains "default auto-assign port" $r.out '-p 0:3000'

# ---------------------------------------------------------------------------
"3. Save dir structure is created for first run"
Assert "save/.config/opencode created" (Test-Path "$save/.config/opencode" -PathType Container)
Assert "save/.local/share/opencode created" (Test-Path "$save/.local/share/opencode" -PathType Container)
$opencodeConfig = Get-Content "$save/.config/opencode/config.json" -Raw | ConvertFrom-Json
Assert "OpenCode config permits all actions" ($opencodeConfig.permission -eq 'allow')
$r = Invoke-Scenario $codeIt (@('-agent','opencode-v2') + $commonArgs) $stubPath
Assert-Contains "reports OpenCode v2 config creation" $r.out 'Created OpenCode v2 configuration'
Assert "save/.local/state/opencode created" (Test-Path "$save/.local/state/opencode" -PathType Container)
$opencodeV2Config = Get-Content "$save/.config/opencode/opencode.json" -Raw | ConvertFrom-Json
Assert "OpenCode v2 default config permits all actions" ($opencodeV2Config.permissions[0].action -eq '*' -and $opencodeV2Config.permissions[0].effect -eq 'allow')
Assert-Contains "opencode-v2 mounts config" $r.out '/.config/opencode:/home/agent1/.config/opencode'
Assert-Contains "opencode-v2 mounts data and auth" $r.out '/.local/share/opencode:/home/agent1/.local/share/opencode'
Assert-Contains "opencode-v2 mounts shared-service state" $r.out '/.local/state/opencode:/home/agent1/.local/state/opencode'
Assert "opencode-v2 mounts no claude state" (-not $r.out.Contains('/home/agent1/.claude'))
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
$r = Invoke-Scenario $codeIt (@('-agent','opencode-v2') + $commonArgs) $stubPath
Assert-Contains "-agent opencode-v2 selects v2" $r.out 'CODE_AGENT="opencode-v2"'
$r = Invoke-ScenarioCommand "& '$codeIt' -listAgents" $stubPath
Assert "listAgents exit code 0" ($r.code -eq 0)
Assert-Contains "-listAgents lists claude" $r.out 'claude'
Assert-Contains "-listAgents lists opencode" $r.out 'opencode'
Assert-Contains "-listAgents lists opencode-v2" $r.out 'opencode-v2'
$r = Invoke-Scenario $codeIt (@('-agent','nosuchagent') + $commonArgs) $stubPath
Assert "unknown -agent fails" ($r.code -ne 0)
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
"9b. Rebuild image (updates the agent install fragments)"
$dfDir = Join-Path $tmp 'dfdir'
$null = New-Item -ItemType Directory -Force -Path $dfDir
Copy-Item (Join-Path $scriptDir 'Dockerfile') (Join-Path $dfDir 'Dockerfile')
Copy-Item (Join-Path $scriptDir 'agents') (Join-Path $dfDir 'agents') -Recurse -Force
$openFragmentPath = Join-Path $dfDir 'agents/opencode/install.dockerfile'
$openFragmentOld = [IO.File]::ReadAllText($openFragmentPath) -replace '# last changed [0-9-]+', '# last changed 2000-01-01'
[IO.File]::WriteAllText($openFragmentPath, $openFragmentOld)
$today = [DateTime]::Today.ToString('yyyy-MM-dd')
$r = Invoke-Scenario $codeIt (@('-rebuildImage', '-dockerfileDir', $dfDir) + $commonArgs) $stubPath
Assert "-rebuildImage exit code 0" ($r.code -eq 0)
Assert-Contains "rebuild invokes docker build" $r.out 'STUB-DOCKER-BUILD'
Assert-Contains "rebuild implies build (no -buildImage needed)" $r.out '-t code-it-alpine-dotnet-node:latest'
$frag = Get-Content $openFragmentPath -Raw
Assert "opencode fragment dates bumped to today" ($frag.Contains("# last changed $today"))
Assert "old dates gone from the fragment" (-not $frag.Contains('# last changed 2000-01-01'))
Assert "rebuild changes only the dates" ($frag -eq ($openFragmentOld -replace '# last changed 2000-01-01', "# last changed $today"))
$fragBytes = [IO.File]::ReadAllBytes($openFragmentPath)
Assert "rebuild writes no BOM" (-not ($fragBytes[0] -eq 0xEF -and $fragBytes[1] -eq 0xBB -and $fragBytes[2] -eq 0xBF))
# plain -buildImage leaves the dates untouched
[IO.File]::WriteAllText($openFragmentPath, $openFragmentOld)
$r = Invoke-Scenario $codeIt (@('-buildImage', '-dockerfileDir', $dfDir) + $commonArgs) $stubPath
Assert "-buildImage exit code 0 (dfdir)" ($r.code -eq 0)
$frag = Get-Content $openFragmentPath -Raw
Assert "-buildImage leaves dates unchanged" ($frag.Contains('# last changed 2000-01-01'))

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
Assert-Contains "build dry-run labels the toolchains" $r.out '--label code-it.tool-chains=dotnet,node'
Assert-Contains "build dry-run labels the package caches" $r.out '--label code-it.package-caches=nuget,npm'
Assert-Contains "build dry-run derives the default image name" $r.out '-t code-it-alpine-dotnet-node:latest'
Assert "build dry-run does not execute the build" (-not $r.out.Contains('STUB-DOCKER-BUILD'))

# -tech is the kept alias of -toolchain
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-tech', 'bun') $stubPath
Assert-Contains "build -tech alias selects BUN" $r.out '--build-arg BUN=true'
Assert-Contains "build -tech alias derives the image name" $r.out '-t code-it-alpine-bun:latest'

# -packageCaches replaces the implied set
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-toolchain', 'bun', '-packageCaches', 'nuget') $stubPath
Assert-Contains "build -packageCaches nuget without dotnet" $r.out '--build-arg NUGET=true'
Assert-Contains "build -packageCaches nuget excludes NPM" $r.out '--build-arg NPM=false'

# Unknown names are hard errors
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-toolchain', 'cobol') $stubPath
Assert "Code-It-Build unknown tool chain fails" ($r.code -ne 0)
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-packageCaches', 'pip') $stubPath
Assert "Code-It-Build unknown package cache fails" ($r.code -ne 0)

# -rebuild bumps the dates and then really builds
$bDfDir = Join-Path $tmp 'build-dfdir'
$null = New-Item -ItemType Directory -Force -Path $bDfDir
Copy-Item (Join-Path $scriptDir 'Dockerfile') (Join-Path $bDfDir 'Dockerfile')
Copy-Item (Join-Path $scriptDir 'agents') (Join-Path $bDfDir 'agents') -Recurse -Force
foreach ($a in @('opencode', 'claude', 'opencode-v2')) {
    $p = Join-Path $bDfDir "agents/$a/install.dockerfile"
    [IO.File]::WriteAllText($p, ([IO.File]::ReadAllText($p) -replace '# last changed [0-9-]+', '# last changed 2000-01-01'))
}
$r = Invoke-Scenario $codeItBuild @('-rebuild', '-dockerfileDir', $bDfDir, '-runtime', 'docker', '-agent', 'opencode,claude,opencode-v2') $stubPath
Assert "Code-It-Build -rebuild exit code 0" ($r.code -eq 0)
Assert-Contains "Code-It-Build -rebuild invokes docker build" $r.out 'STUB-DOCKER-BUILD'
Assert "Code-It-Build -rebuild bumps the opencode fragment" ((Get-Content (Join-Path $bDfDir 'agents/opencode/install.dockerfile') -Raw).Contains("# last changed $today"))
Assert "Code-It-Build -rebuild bumps the claude fragment" ((Get-Content (Join-Path $bDfDir 'agents/claude/install.dockerfile') -Raw).Contains("# last changed $today"))
Assert "Code-It-Build -rebuild bumps the opencode-v2 fragment" ((Get-Content (Join-Path $bDfDir 'agents/opencode-v2/install.dockerfile') -Raw).Contains("# last changed $today"))
# A missing Dockerfile is an error
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $tmp) $stubPath
Assert "Code-It-Build without a Dockerfile fails" ($r.code -ne 0)

"9f. Code-It-Build agents"
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir) $stubPath
Assert-Contains "default build installs opencode and claude" $r.out 'agents opencode,claude'
Assert-Contains "default build labels the agents" $r.out '--label code-it.agents=opencode,claude'
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-agent', 'opencode') $stubPath
Assert-Contains "-agent opencode selects only opencode" $r.out 'agents opencode'
Assert "default -agent excludes claude" (-not $r.out.Contains('agents opencode,claude'))
$r = Invoke-ScenarioCommand "& '$codeItBuild' -dryRun -dockerfileDir '$scriptDir' -agent 'claude,opencode'" $stubPath
Assert-Contains "-agent accepts a list" $r.out 'agents claude,opencode'
$r = Invoke-Scenario $codeItBuild @('-dryRun','-dockerfileDir',$scriptDir,'-agent','opencode-v2') $stubPath
Assert-Contains "-agent opencode-v2 selects the v2 installer" $r.out 'agents opencode-v2'
Assert-Contains "opencode-v2 image label records the agent" $r.out '--label code-it.agents=opencode-v2'
Assert "opencode-v2 uses the pinned official installer" ((Get-Content (Join-Path $scriptDir 'agents/opencode-v2/install.dockerfile') -Raw).Contains('https://opencode.ai/v2/install | bash -s -- --version 2.0.6'))
$r = Invoke-ScenarioCommand "& '$codeItBuild' -listAgents" $stubPath
Assert "Code-It-Build -listAgents exit code 0" ($r.code -eq 0)
Assert-Contains "Code-It-Build -listAgents lists claude" $r.out 'claude'
Assert-Contains "Code-It-Build -listAgents lists opencode" $r.out 'opencode'
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-agent', 'nosuch') $stubPath
Assert "Code-It-Build unknown agent fails" ($r.code -ne 0)

"9d. Code-It reads the image label"
$env:STUB_IMAGE_TOOL_CHAINS = 'node,bun'
try { $r = Invoke-Scenario $codeIt (@('-image', 'code-it-alpine-dotnet-node') + $commonArgs) $stubPath }
finally { $env:STUB_IMAGE_TOOL_CHAINS = $null }
Assert-Contains "warns when the image label disagrees with -toolchain" $r.out "looks built for tech 'node,bun'"
$r = Invoke-Scenario $codeIt (@('-buildImage') + $commonArgs) $stubPath
Assert-Contains "the -buildImage shim prints a deprecation note" $r.out 'deprecated'

"9e. Python tool chain (python / uv / -stack)"
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-stack', 'python') $stubPath
Assert-Contains "-stack python sets PYTHON=true" $r.out '--build-arg PYTHON=true'
Assert-Contains "-stack python derives the image name" $r.out '-t code-it-alpine-python:latest'
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir, '-toolchain', 'uv') $stubPath
Assert-Contains "uv aliases python (PYTHON=true)" $r.out '--build-arg PYTHON=true'
Assert-Contains "uv canonical image name" $r.out '-t code-it-alpine-python:latest'
$r = Invoke-Scenario $codeItBuild @('-dryRun', '-dockerfileDir', $scriptDir) $stubPath
Assert-Contains "default build sets PYTHON=false" $r.out '--build-arg PYTHON=false'
$r = Invoke-Scenario $codeIt (@('-stack', 'python', '-buildImage') + $commonArgs) $stubPath
Assert-Contains "code-it -stack python delegates a PYTHON=true build" $r.out '--build-arg PYTHON=true'
$dfText = Get-Content (Join-Path $scriptDir 'Dockerfile') -Raw
Assert "Dockerfile installs uv for every image" ($dfText.Contains('apk add --no-cache uv'))
Assert "Dockerfile gates python3 on PYTHON" ($dfText.Contains('if [ "$PYTHON" = true ]'))
# The base layer installs tools only: no GUI packages, no Kerberos, no edge repo.
# Libraries come with the toolchain or agent that needs them.
Assert "Dockerfile base installs no GUI, Kerberos or docs packages" (-not ($dfText -match 'apk .*(chromium|ttf-freefont|freetype-dev|krb5|\sdocs\s)'))
Assert "Dockerfile does not mix in the edge repository" (-not $dfText.Contains('edge/main'))
Assert "Dockerfile base keeps musl-locales for international text" ($dfText -match 'apk add --no-cache .*musl-locales')
Assert "PowerShell tarball layer adds the libraries it needs" ($dfText.Contains('apk add --no-cache libgcc libstdc++ icu-libs libssl3 && '))
foreach ($a in @('opencode', 'opencode-v2')) {
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
Assert "requires every requested chain to be present" ($r.code -ne 0)

# No image contains the requested chain
$env:STUB_IMAGES = 'code-it-alpine-dotnet-node:latest code-it-alpine-dotnet-bun:latest'
try { $r = Invoke-Scenario $codeIt (@('-toolchain', 'python') + $commonArgs) $superPath }
finally { $env:STUB_IMAGES = $null }
Assert "errors when no image contains the requested chain" ($r.code -ne 0)

# An explicit -image is never substituted
$env:STUB_IMAGES = 'code-it-alpine-dotnet-bun:latest'
try { $r = Invoke-Scenario $codeIt (@('-toolchain', 'dotnet', '-image', 'code-it-alpine-nope') + $commonArgs) $superPath }
finally { $env:STUB_IMAGES = $null }
Assert "explicit -image is used as-is and errors if missing" ($r.code -ne 0)

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
$r = Invoke-Scenario $codeIt (@('-port', '8000') + $commonArgs) $stubPath
Assert-Contains "custom -port maps the host port to container 3000" $r.out '-p 8000:3000'
$r = Invoke-Scenario $codeIt (@('-port', '0') + $commonArgs) $stubPath
Assert-Contains "-port 0 lets docker auto-assign" $r.out '-p 0:3000'
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
"11b. Tech stack: -toolchain / -packageCaches build args and read-only caches"
$r = Invoke-Scenario $codeIt (@('-buildImage') + $commonArgs) $stubPath
Assert-Contains "default build passes DOTNET=true" $r.out '--build-arg DOTNET=true'
Assert-Contains "default build passes NODE=true" $r.out '--build-arg NODE=true'
Assert-Contains "default build passes BUN=false" $r.out '--build-arg BUN=false'
Assert-Contains "dotnet implies NUGET=true" $r.out '--build-arg NUGET=true'
Assert-Contains "node implies NPM=true" $r.out '--build-arg NPM=true'
Assert-Contains "reports the resolved tech" $r.out 'tech dotnet,node; package repos nuget,npm'

# -toolchain replaces the default set
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolchain','node,bun') + $commonArgs) $stubPath
Assert-Contains "-toolchain node,bun drops DOTNET" $r.out '--build-arg DOTNET=false'
Assert-Contains "-toolchain node,bun keeps NODE" $r.out '--build-arg NODE=true'
Assert-Contains "-toolchain node,bun keeps BUN" $r.out '--build-arg BUN=true'
Assert-Contains "-toolchain node,bun drops NUGET (dotnet gone)" $r.out '--build-arg NUGET=false'
Assert-Contains "-toolchain node,bun keeps NPM (node present)" $r.out '--build-arg NPM=true'

# -packageCaches replaces the implied set, independently of -toolchain
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolchain','node,bun','-packageCaches','npm') + $commonArgs) $stubPath
Assert-Contains "-packageCaches npm keeps NPM" $r.out '--build-arg NPM=true'
Assert-Contains "-packageCaches npm excludes NUGET" $r.out '--build-arg NUGET=false'
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolchain','node,bun','-packageCaches','bun') + $commonArgs) $stubPath
Assert-Contains "-packageCaches bun selects the BUN package cache" $r.out '--build-arg NPM=false'
Assert-Contains "-packageCaches bun excludes NUGET" $r.out '--build-arg NUGET=false'
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolchain','bun','-packageCaches','nuget') + $commonArgs) $stubPath
Assert-Contains "nuget package cache without dotnet" $r.out '--build-arg NUGET=true'

# The default image name follows -toolchain
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolchain','node,bun') + $commonArgs) $stubPath
Assert-Contains "image name derives from -toolchain" $r.out '-t code-it-alpine-node-bun:latest'

# The old -tech spelling is kept as a hidden alias
$r = Invoke-Scenario $codeIt (@('-buildImage','-tech','bun') + $commonArgs) $stubPath
Assert-Contains "-tech alias selects BUN" $r.out '--build-arg BUN=true'

# Tech aliases resolve to the canonical name: js-node/ts-node -> node, js-bun/ts-bun -> bun
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolchain','js-node') + $commonArgs) $stubPath
Assert-Contains "js-node aliases node (NODE=true)" $r.out '--build-arg NODE=true'
Assert-Contains "js-node canonical image name" $r.out '-t code-it-alpine-node:latest'
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolchain','ts-node') + $commonArgs) $stubPath
Assert-Contains "ts-node aliases node (NODE=true)" $r.out '--build-arg NODE=true'
Assert-Contains "ts-node canonical image name" $r.out '-t code-it-alpine-node:latest'
Assert-Contains "ts-node implies the npm package cache" $r.out '--build-arg NPM=true'
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolchain','js-bun') + $commonArgs) $stubPath
Assert-Contains "js-bun aliases bun (BUN=true)" $r.out '--build-arg BUN=true'
Assert-Contains "js-bun canonical image name" $r.out '-t code-it-alpine-bun:latest'
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolchain','ts-bun,bun') + $commonArgs) $stubPath
Assert-Contains "ts-bun aliases bun and dedupes with bun" $r.out '-t code-it-alpine-bun:latest'

# The old -packages spelling is gone as a parameter: it is now passed to the agent,
# so it no longer selects a package cache
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolchain','bun','-packages','npm') + $commonArgs) $stubPath
Assert-Contains "removed -packages is forwarded to the agent" $r.out '-packages npm'
Assert-Contains "removed -packages no longer selects NPM" $r.out '--build-arg NPM=false'

$env:STUB_IMAGE_TOOL_CHAINS = 'dotnet'
try { $r = Invoke-Scenario $codeIt (@('-toolchain','node,bun','-image','code-it-alpine-dotnet-node') + $commonArgs) $stubPath }
finally { $env:STUB_IMAGE_TOOL_CHAINS = $null }
Assert-Contains "warns when the image label disagrees with -toolchain" $r.out "looks built for tech 'dotnet'"
# Without a label (older images), fall back to the name-based guess
$env:STUB_IMAGE_TOOL_CHAINS = ''
try { $r = Invoke-Scenario $codeIt (@('-toolchain','node,bun','-image','code-it-alpine-dotnet-node') + $commonArgs) $stubPath }
finally { $env:STUB_IMAGE_TOOL_CHAINS = $null }
Assert-Contains "falls back to the image-name guess without a label" $r.out "looks built for tech 'dotnet,node'"

# Unknown names are hard errors
$r = Invoke-Scenario $codeIt (@('-buildImage','-toolchain','cobol') + $commonArgs) $stubPath
Assert "-toolchain with an unknown name fails" ($r.code -ne 0)
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
Assert-Contains "opencode: prompt becomes --prompt" $r.out 'code-it-alpine-dotnet-node:latest --prompt "explain this repo"'
$r = Invoke-Scenario $codeIt (@('-agent','opencode-v2','explain this repo') + $commonArgs) $stubPath
Assert-Contains "opencode-v2 interactive prompt uses mini --prompt" $r.out 'code-it-alpine-dotnet-node:latest mini --prompt "explain this repo"'
$r = Invoke-Scenario $codeIt (@('-agent','opencode-v2') + $commonArgs) $stubPath
Assert "opencode-v2 interactive no-prompt appends nothing" ($r.out.TrimEnd().EndsWith('code-it-alpine-dotnet-node:latest'))
Assert-Contains "opencode-v2 interactive no-prompt allocates a TTY" $r.out 'docker run -it'

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
$r = Invoke-Scenario $codeIt (@('-agent','opencode-v2','-headless','fix the build') + $commonArgs) $stubPath
Assert-Contains "opencode-v2 headless prompt uses standalone run" $r.out 'code-it-alpine-dotnet-node:latest run --standalone "fix the build"'
$r = Invoke-Scenario $codeIt (@('-agent','opencode-v2','-headless') + $commonArgs) $stubPath
Assert-Contains "opencode-v2 headless no-prompt still runs standalone" $r.out 'code-it-alpine-dotnet-node:latest run --standalone'
Assert-Contains "opencode-v2 headless no-prompt has no TTY" $r.out 'docker run -i --rm'

# Unrecognised arguments go to the agent verbatim: PowerShell has no usable `--`
$r = Invoke-Scenario $codeIt (@('-c') + $commonArgs + @('--continue','--model','opus')) $stubPath
Assert-Contains "unrecognised flags pass through" $r.out 'code-it-alpine-dotnet-node:latest --continue --model opus'
$r = Invoke-Scenario $codeIt (@('-c','-headless','-prompt','tidy') + $commonArgs + @('--max-turns','5')) $stubPath
Assert-Contains "agent flags precede the prompt for claude" $r.out 'code-it-alpine-dotnet-node:latest -p --max-turns 5 tidy'
$r = Invoke-Scenario $codeIt (@('-o','-headless','-prompt','tidy') + $commonArgs + @('--model','opus')) $stubPath
Assert-Contains "agent flags follow run for opencode" $r.out 'code-it-alpine-dotnet-node:latest run --model opus tidy'
$r = Invoke-Scenario $codeIt (@('-agent','opencode-v2','-headless','-prompt','tidy') + $commonArgs + @('--model','example/coder')) $stubPath
Assert-Contains "opencode-v2 headless flags precede prompt" $r.out 'code-it-alpine-dotnet-node:latest run --standalone --model example/coder tidy'
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
"12c. Code-It-Add-Tool-Chain.ps1"
$addTc = Join-Path $scriptDir 'Code-It-Add-Tool-Chain.ps1'

# -dryRun prints the prompt (with the security gate) and the command
$repoD = Join-Path $tmp 'addtc-a'; New-GitRepo $repoD
$r = Invoke-Scenario $addTc @('java', '-repo', $repoD, '-codeIt', $stubCi, '-dryRun') $stubPath
Assert "add-tool-chain -dryRun exit code 0" ($r.code -eq 0)
Assert-Contains "add-tool-chain prompt names the tool chain" $r.out 'Tool chain to add: java'
Assert-Contains "add-tool-chain prompt includes the gate" $r.out 'Gate first'
Assert-Contains "add-tool-chain prompt requires a secure install" $r.out 'installs securely'
Assert-Contains "add-tool-chain prompt requires musl builds" $r.out 'musl builds for x86_64 and aarch64'
Assert-Contains "add-tool-chain -dryRun prints -headless" $r.out '-headless'
Assert "add-tool-chain -dryRun creates no branch" (-not (& git -C $repoD branch --list 'add-tool-chain/*'))

# -url is included
$r = Invoke-Scenario $addTc @('java', '-url', 'https://openjdk.org/install/', '-repo', $repoD, '-codeIt', $stubCi, '-dryRun') $stubPath
Assert-Contains "add-tool-chain prompt includes the docs URL" $r.out 'https://openjdk.org/install/'

# a dirty repo is refused
Add-Content -Path (Join-Path $repoD 'x') -Value 'y'
$r = Invoke-Scenario $addTc @('java', '-repo', $repoD, '-codeIt', $stubCi) $stubPath
Assert "add-tool-chain refuses a dirty repo" ($r.code -ne 0)
& git -C $repoD checkout -q -- .

# branch creation and summary
$r = Invoke-Scenario $addTc @('java', '-repo', $repoD, '-codeIt', $stubCi) $stubPath
Assert "add-tool-chain run exit code 0" ($r.code -eq 0)
Assert "add-tool-chain checks out the new branch" ((& git -C $repoD rev-parse --abbrev-ref HEAD) -eq 'add-tool-chain/java')
Assert-Contains "add-tool-chain prints the branch" $r.out 'Branch: add-tool-chain/java'

# a gate refusal exit code is propagated
$repoE = Join-Path $tmp 'addtc-b'; New-GitRepo $repoE
$env:STUB_CODE_IT_EXIT = '4'
try { $r = Invoke-Scenario $addTc @('java', '-repo', $repoE, '-codeIt', $stubCi) $stubPath }
finally { $env:STUB_CODE_IT_EXIT = $null }
Assert "add-tool-chain propagates a gate refusal" ($r.code -eq 4)

# ---------------------------------------------------------------------------
"12d. Code-It-FirstRun.ps1"
$firstRun = Join-Path $scriptDir 'Code-It-FirstRun.ps1'
$stubFirst = Join-Path $tmp 'stub-first-build.ps1'
Set-Content -Path $stubFirst -Value @'
param([string]$toolchain, [string]$agent, [string]$runtime, [string]$image, [string]$dockerfileDir)
Set-Content -Path (Join-Path $PSScriptRoot 'first-build-ran') -Value 'ran'
"STUB-FIRST-BUILD $toolchain $agent"
'@

$fh = Join-Path $tmp 'firstcopy-home'
$null = New-Item -ItemType Directory -Force -Path "$fh/.config/opencode"
Set-Content -Path "$fh/.config/opencode/config.json" -Value 'ORIGINAL'
$savedHome = $env:HOME; $savedUserProfile = $env:USERPROFILE

# --dryRun builds nothing and copies nothing
$fd = Join-Path $tmp 'firstdry-ps'
$env:HOME = $fh; $env:USERPROFILE = $fh
try {
    $r = Invoke-Scenario $firstRun @('-yes', '-dryRun', '-toolchain', 'node', '-agents', 'opencode',
        '-saveDir', (Join-Path $fd 'save'), '-codeItBuild', $stubFirst) $stubPath
} finally { $env:HOME = $savedHome; $env:USERPROFILE = $savedUserProfile }
Assert "first-run -dryRun exit code 0" ($r.code -eq 0)
Assert "first-run -dryRun creates no save dir" (-not (Test-Path -Path (Join-Path $fd 'save')))
Assert-Contains "first-run -dryRun says it will not build" $r.out 'dry run: not building'
Assert-Contains "first-run -dryRun says what it would copy" $r.out 'would copy'
Assert "first-run -dryRun ran no build" (-not (Test-Path -Path (Join-Path $tmp 'first-build-ran')))

# --yes copies state over but never overwrites
$fs = Join-Path $tmp 'firstcopy-save'
$null = New-Item -ItemType Directory -Force -Path "$fs/.config/opencode"
Set-Content -Path "$fs/.config/opencode/config.json" -Value 'KEEP'
Set-Content -Path "$fh/.config/opencode/new.json" -Value 'NEW'
$env:HOME = $fh; $env:USERPROFILE = $fh
try {
    $r = Invoke-Scenario $firstRun @('-yes', '-toolchain', 'node', '-agents', 'opencode',
        '-saveDir', $fs, '-codeItBuild', $stubFirst) $stubPath
} finally { $env:HOME = $savedHome; $env:USERPROFILE = $savedUserProfile }
Assert "first-run copy exit code 0" ($r.code -eq 0)
Assert-Contains "first-run invoked the build" $r.out 'STUB-FIRST-BUILD'
Assert "first-run never overwrites existing state" ((Get-Content "$fs/.config/opencode/config.json" -Raw).Trim() -eq 'KEEP')
Assert "first-run copies missing state" ((Get-Content "$fs/.config/opencode/new.json" -Raw).Trim() -eq 'NEW')
Assert-Contains "first-run warns that credentials are copied" $r.out 'credentials'
Assert-Contains "first-run prints the start command" $r.out 'Code-It.ps1 -agent opencode'

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
  goto :eof
)
if "%~1"=="image" (
  echo %* | findstr /C:"python" >nul && (echo python& goto :eof)
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
    images) printf '%s\n' code-it-alpine-dotnet:latest code-it-alpine-dotnet-node:latest code-it-alpine-python:latest ;;
    image)
        for a in "$@"; do last="$a"; done
        case "$last" in
            *python*)      echo python ;;
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
"OPENCODEV2:" + (Complete "& '$codeIt' -agent opencode-v2 -agentArgs --sta")
"RUNTIME:"  + (Complete "& '$codeIt' -runtime ")
"@
$r = Invoke-ScenarioCommand $completerTest $stubPath
Assert "completion script loads" ($r.code -eq 0 -or $null -eq $r.code)
Assert-Contains "-agentArgs completes claude flags" $r.out 'CLAUDE:--model'
Assert-Contains "-agentArgs completes opencode flags" $r.out 'OPENCODE:--session'
Assert-Contains "-agent opencode-v2 completes v2 flags" $r.out 'OPENCODEV2:--standalone'
Assert-Contains "-runtime completes its values" $r.out 'RUNTIME:docker container'

# ---------------------------------------------------------------------------
Remove-Item -Recurse -Force $tmp -EA Silent
""
"Results: $script:pass passed, $script:fail failed"
if ($script:fail -ne 0) { exit 1 }

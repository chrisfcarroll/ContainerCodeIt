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
if "%~1"=="images" echo code-it-alpine-dotnet:latest& goto :eof
if "%~1"=="build" echo STUB-DOCKER-BUILD %*& goto :eof
if "%~1"=="run" echo STUB-DOCKER-RUN %*& goto :eof
echo stub docker: %*
'@
} else {
    Set-Content -Path (Join-Path $stubDocker 'docker') -Value @'
#!/bin/sh
case "$1" in
    images) [ -n "$STUB_IMAGES_FAIL" ] && exit 1; echo "code-it-alpine-dotnet:latest" ;;
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
foreach ($f in @('Code-It.ps1','Claude-It.ps1','OpenCode-It.ps1','tests/Test-CodeIt.ps1','completions/CodeItCompletion.ps1')) {
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
Assert-Contains "work dir mount" $r.out "$scriptDir`:/work"
Assert-Contains "claude dir mount" $r.out '/.claude:/home/agent1/.claude'
Assert-Contains "claude.json mount" $r.out '/.claude.json:/home/agent1/.claude.json'
Assert-Contains "opencode config mount" $r.out '/.config/opencode:/home/agent1/.config/opencode'
Assert-Contains "opencode mount" $r.out '/.local/share/opencode:/home/agent1/.local/share/opencode'
Assert-Contains "default auto-assign ports" $r.out '-p 0:3000 -p 0:3001'

# ---------------------------------------------------------------------------
"3. Save dir structure is created for first run"
Assert "save/.claude created" (Test-Path "$save/.claude" -PathType Container)
Assert "save/.config/opencode created" (Test-Path "$save/.config/opencode" -PathType Container)
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
Assert-Contains "build tags the image" $r.out '-t code-it-alpine-dotnet:latest'
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
Assert-Contains "rebuild implies build (no -buildImage needed)" $r.out '-t code-it-alpine-dotnet:latest'
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
"10. Custom options"
$r = Invoke-ScenarioCommand "& '$codeIt' -portsMap '8000:3000','8001:3001' -dryRun -WorkDirToMount '$scriptDir' -saveDir '$save'" $stubPath
Assert-Contains "custom ports" $r.out '-p 8000:3000 -p 8001:3001'
$r = Invoke-ScenarioCommand "& '$codeIt' -portsMap '8000:3000' -dryRun -WorkDirToMount '$scriptDir' -saveDir '$save'" $stubPath
Assert-Contains "single port padded with the second default" $r.out '-p 8000:3000 -p 0:3001'
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
"12. Prompt and agent arguments"
# A leading bare argument, or -prompt, is the opening prompt, spelled each agent's way
$r = Invoke-Scenario $codeIt (@('-c','explain this repo') + $commonArgs) $stubPath
Assert "bare prompt exit code 0" ($r.code -eq 0)
Assert-Contains "claude: bare prompt appended to the image" $r.out 'code-it-alpine-dotnet:latest "explain this repo"'
$r = Invoke-Scenario $codeIt (@('-c','-prompt','explain this repo') + $commonArgs) $stubPath
Assert-Contains "claude: -prompt is the same as a bare prompt" $r.out 'code-it-alpine-dotnet:latest "explain this repo"'
$r = Invoke-Scenario $codeIt (@('-o','explain this repo') + $commonArgs) $stubPath
Assert-Contains "opencode: prompt becomes --prompt" $r.out 'code-it-alpine-dotnet:latest --prompt "explain this repo"'

# No prompt and no agent args: nothing is appended, and the run stays interactive
$r = Invoke-Scenario $codeIt $commonArgs $stubPath
Assert "no prompt appends nothing" ($r.out.TrimEnd().EndsWith('code-it-alpine-dotnet:latest'))
Assert-Contains "interactive runs allocate a TTY" $r.out 'docker run -it'
Assert "interactive runs are not headless" (-not $r.out.Contains('CODE_AGENT_HEADLESS'))

# -headless: one-shot, no TTY, and the agent's non-interactive form
$r = Invoke-Scenario $codeIt (@('-c','-headless','fix the build') + $commonArgs) $stubPath
Assert-Contains "claude -headless uses -p" $r.out 'code-it-alpine-dotnet:latest -p "fix the build"'
Assert-Contains "-headless passes CODE_AGENT_HEADLESS" $r.out '-e CODE_AGENT_HEADLESS=1'
Assert-Contains "-headless allocates no TTY" $r.out 'docker run -i --rm'
$r = Invoke-Scenario $codeIt (@('-o','-headless','fix the build') + $commonArgs) $stubPath
Assert-Contains "opencode -headless uses run" $r.out 'code-it-alpine-dotnet:latest run "fix the build"'

# Unrecognised arguments go to the agent verbatim: PowerShell has no usable `--`
$r = Invoke-Scenario $codeIt (@('-c') + $commonArgs + @('--continue','--model','opus')) $stubPath
Assert-Contains "unrecognised flags pass through" $r.out 'code-it-alpine-dotnet:latest --continue --model opus'
$r = Invoke-Scenario $codeIt (@('-c','-headless','-prompt','tidy') + $commonArgs + @('--max-turns','5')) $stubPath
Assert-Contains "agent flags precede the prompt for claude" $r.out 'code-it-alpine-dotnet:latest -p --max-turns 5 tidy'
$r = Invoke-Scenario $codeIt (@('-o','-headless','-prompt','tidy') + $commonArgs + @('--model','opus')) $stubPath
Assert-Contains "agent flags follow run for opencode" $r.out 'code-it-alpine-dotnet:latest run --model opus tidy'
# -headless without a prompt leaves the agent command to the caller. Short agent flags
# that PowerShell reads as one of this script's own parameters (-p) have to be spelled out.
$r = Invoke-Scenario $codeIt (@('-c','-headless') + $commonArgs + @('--print','count the files')) $stubPath
Assert-Contains "-headless with no prompt adds no -p of its own" $r.out 'code-it-alpine-dotnet:latest --print "count the files"'
$r = Invoke-Scenario $codeIt (@('-c','-headless') + $commonArgs + @('-p','count the files')) $stubPath
Assert "an agent flag that collides with a parameter prefix is rejected, not silently bound" ($r.code -ne 0)

# The prompt reaches the container as a single argument
$r = Invoke-Scenario $codeIt (@('-c','-runtime','container','explain this repo','-WorkDirToMount',$scriptDir,'-saveDir',$save)) "$stubContainer$sep$stubPath"
Assert-Contains "prompt is passed as one argument" $r.out '[code-it-alpine-dotnet:latest][explain this repo]'
$r = Invoke-Scenario $codeIt (@('-c','-runtime','container','-headless','fix it','-WorkDirToMount',$scriptDir,'-saveDir',$save)) "$stubContainer$sep$stubPath"
Assert-Contains "headless run passes -i" $r.out '[-i][--rm]'
Assert-Contains "headless run passes the prompt after -p" $r.out '[code-it-alpine-dotnet:latest][-p][fix it]'

# The alias scripts forward prompts and agent flags
$r = Invoke-Scenario (Join-Path $scriptDir 'Claude-It.ps1') (@('explain this repo') + $commonArgs) $stubPath
Assert-Contains "Claude-It.ps1 forwards a prompt" $r.out 'code-it-alpine-dotnet:latest "explain this repo"'
$r = Invoke-Scenario (Join-Path $scriptDir 'OpenCode-It.ps1') ($commonArgs + @('--model','opus')) $stubPath
Assert-Contains "OpenCode-It.ps1 forwards agent flags" $r.out 'code-it-alpine-dotnet:latest --model opus'

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

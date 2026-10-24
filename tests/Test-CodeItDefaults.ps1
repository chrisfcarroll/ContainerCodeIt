# Tests for Code-It-Defaults.ps1, and for how Code-It.ps1 uses what it saves.
#
# No container runtime is required: the launcher tests place a stub `docker` on the
# PATH and run Code-It.ps1 with -dryRun, asserting on the printed run command.
# Interactive scenarios pipe answers to the child pwsh's Read-Host.
# Run with:
#   pwsh -NoProfile -File tests/Test-CodeItDefaults.ps1

$ErrorActionPreference = 'Continue'

$testsDir      = $PSScriptRoot
$scriptDir     = Split-Path $testsDir -Parent
$defaults      = Join-Path $scriptDir 'Code-It-Defaults.ps1'
$codeIt        = Join-Path $scriptDir 'Code-It.ps1'
# Find a pwsh that actually runs (the first one on the PATH may be a build for the
# wrong architecture, e.g. an x64 pwsh on an arm64 host).
function Test-PwshWorks([string]$exe) {
    if (-not $exe -or -not (Test-Path $exe)) { return $false }
    try { $null = & $exe -NoProfile -Command 'exit 0' 2>$null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}
$pwshExe = @((Get-Command pwsh -EA Silent).Source, "$HOME/.local/bin/pwsh", "$HOME/.dotnet/tools/pwsh") |
    Where-Object { Test-PwshWorks $_ } | Select-Object -First 1
if (-not $pwshExe) { throw "No working pwsh found to run test scenarios" }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "code-it-defaults-tests-$PID"
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

# Stub docker on the PATH (a .cmd shim on Windows, an sh script elsewhere). It lists
# one superset image and answers label queries with dotnet,node.
$onWindows = ($env:OS -eq 'Windows_NT')
$stubDocker = Join-Path $tmp 'stub-docker'
$null = New-Item -ItemType Directory -Force -Path $stubDocker
if ($onWindows) {
    Set-Content -Path (Join-Path $stubDocker 'docker.cmd') -Value @'
@echo off
if "%~1"=="images" echo code-it-alpine-dotnet-node:latest& goto :eof
if "%~1"=="image" if "%~2"=="inspect" echo dotnet,node& goto :eof
echo stub docker: %*
'@
} else {
    Set-Content -Path (Join-Path $stubDocker 'docker') -Value @'
#!/bin/sh
case "$1" in
    images) echo "code-it-alpine-dotnet-node:latest" ;;
    image)  case "$*" in *code-it.agent-binaries*) echo "" ;; *code-it.agents*) echo "" ;; *) echo "dotnet,node" ;; esac ;;
    *)      echo "stub docker: $*" ;;
esac
'@
    chmod +x (Join-Path $stubDocker 'docker')
}

$sep = [System.IO.Path]::PathSeparator
$origPath = $env:PATH
# Run each scenario in a child pwsh so `exit` in the scripts is isolated.
function Invoke-Scenario([string]$command, [string]$path) {
    $env:PATH = $path
    try {
        $out = & $pwshExe -NoProfile -Command $command 2>&1 | Out-String
        return @{ out = $out; code = $LASTEXITCODE }
    } finally {
        $env:PATH = $origPath
    }
}

# Run a scenario with lines piped to the script's Read-Host answers
function Invoke-ScenarioWithAnswers([string]$command, [string]$path, [string[]]$answers) {
    $env:PATH = $path
    try {
        $out = ($answers -join "`n") | & $pwshExe -NoProfile -Command $command 2>&1 | Out-String
        return @{ out = $out; code = $LASTEXITCODE }
    } finally {
        $env:PATH = $origPath
    }
}

$stubPath = "$stubDocker$sep$origPath"

# ---------------------------------------------------------------------------
"1. -help exits 0 and documents the options"
$r = Invoke-Scenario "& '$defaults' -help" $stubPath
Assert "-help exit code 0" ($r.code -eq 0)
Assert-Contains "-help shows the synopsis" $r.out 'Sets the defaults Code-It uses'
Assert-Contains "-help has a PARAMETERS section" $r.out 'PARAMETERS'
Assert-Contains "-help documents -agent" $r.out '-agent <String>'
Assert-Contains "-help documents -model" $r.out '-model <String[]>'
Assert-Contains "-help documents -toolchain" $r.out '-toolchain <String>'
Assert-Contains "-help documents -show" $r.out '-show'
Assert-Contains "-help documents -refreshModels" $r.out '-refreshModels'
Assert-Contains "-help documents -dryRun" $r.out '-dryRun'

# ---------------------------------------------------------------------------
"2. -show with no defaults"
$save = Join-Path $tmp 'show'; $null = New-Item -ItemType Directory -Force -Path $save
$r = Invoke-Scenario "& '$defaults' -show -saveDir '$save'" $stubPath
Assert "-show exit code 0" ($r.code -eq 0)
Assert-Contains "-show says none saved yet" $r.out 'No defaults saved yet'

# ---------------------------------------------------------------------------
"3. -agent sets the default agent; unknown agents fail"
$save = Join-Path $tmp 'agent'; $null = New-Item -ItemType Directory -Force -Path $save
$r = Invoke-Scenario "& '$defaults' -saveDir '$save' -agent claude" $stubPath
Assert "-agent exit code 0" ($r.code -eq 0)
Assert-Contains "-agent reports it" $r.out 'Default agent: claude'
Assert "defaults file records the agent" ((Get-Content "$save/defaults") -contains 'default-agent=claude')
$r = Invoke-Scenario "& '$defaults' -saveDir '$save' -agent nope" $stubPath
Assert "unknown agent fails" ($r.code -ne 0)
Assert "unknown agent saves nothing" ((Get-Content "$save/defaults") -notcontains 'default-agent=nope')

# ---------------------------------------------------------------------------
"4. -toolchain resolves aliases; unknown toolchains fail"
$r = Invoke-Scenario "& '$defaults' -saveDir '$save' -toolchain 'ts-node,bun'" $stubPath
Assert "-toolchain exit code 0" ($r.code -eq 0)
Assert "defaults records the canonical names" ((Get-Content "$save/defaults") -contains 'default-toolchain=node,bun')
$r = Invoke-Scenario "& '$defaults' -saveDir '$save' -toolchain pv-node" $stubPath
Assert "unknown toolchain fails" ($r.code -ne 0)

# ---------------------------------------------------------------------------
"5. -model writes each agent's own config under the save dir"
# Reusing $save, which has the agent and toolchain set above, so -show lists them
$r = Invoke-Scenario "& '$defaults' -saveDir '$save' -model 'opencode-v1=anthropic/claude-sonnet-4-5','claude=opus','opencode=zhipuai/glm-4.6'" $stubPath
Assert "-model exit code 0" ($r.code -eq 0)
$c = Get-Content "$save/defaults"
Assert "defaults records opencode-v1's model" ($c -contains 'model.opencode-v1=anthropic/claude-sonnet-4-5')
Assert "defaults records claude's model" ($c -contains 'model.claude=opus')
Assert "defaults records opencode (v2)'s model" ($c -contains 'model.opencode=zhipuai/glm-4.6')
$freshConfig = (Get-Content "$save/.config/opencode/config.json" -Raw | ConvertFrom-Json)
Assert "opencode-v1 config gets the model key" ($freshConfig.model -eq 'anthropic/claude-sonnet-4-5')
Assert "claude settings get the model key" ((Get-Content "$save/.claude/settings.json" -Raw | ConvertFrom-Json).model -eq 'opus')
Assert "opencode (v2) config, under its save subdir, gets the model key" `
    ((Get-Content "$save/opencode-v2/.config/opencode/opencode.json" -Raw | ConvertFrom-Json).model -eq 'zhipuai/glm-4.6')

# Models survive a round-trip into an existing, other-keyed config
$null = New-Item -ItemType Directory -Force -Path "$save/.config/opencode", "$save/.claude"
Copy-Item "$scriptDir/agents/opencode-v1/default-config/.config/opencode/config.json" "$save/.config/opencode/config.json"
Copy-Item "$scriptDir/agents/claude/default-config/.claude/settings.json" "$save/.claude/settings.json"
$r = Invoke-Scenario "& '$defaults' -saveDir '$save' -model 'opencode-v1=openai/gpt-5','claude=claude-opus-4-5'" $stubPath
Assert "model round-trip exit code 0" ($r.code -eq 0)
$rtConfig = Get-Content "$save/.config/opencode/config.json" -Raw | ConvertFrom-Json
Assert "other opencode config keys survive" ($null -ne $rtConfig.'$schema')
Assert "opencode-v1 model set in existing config" ($rtConfig.model -eq 'openai/gpt-5')
$rtSettings = Get-Content "$save/.claude/settings.json" -Raw | ConvertFrom-Json
Assert "other claude settings keys survive" ($rtSettings.permissions.defaultMode -eq 'auto')
Assert "claude model set in existing settings" ($rtSettings.model -eq 'claude-opus-4-5')

# The bundled catalog is parseable
$catalog = @(Get-Content (Join-Path $scriptDir 'lib/models.txt') | Where-Object { $_ -and $_ -notmatch '^\s*#' })
Assert "lib/models.txt has models" ($catalog.Count -gt 0)
Assert "lib/models.txt entries are provider/model" (@($catalog | Where-Object { $_ -notmatch '^[a-z0-9][a-z0-9.-]*/[a-z0-9][a-z0-9.-]*$' }).Count -eq 0)
Assert "lib/models.txt says which models opencode-go serves" (@($catalog | Where-Object { $_ -like 'opencode-go/*' }).Count -gt 0)

# -show lists them
$r = Invoke-Scenario "& '$defaults' -show -saveDir '$save'" $stubPath
Assert-Contains "-show lists the agent" $r.out 'default agent:'
Assert-Contains "-show lists the toolchain" $r.out 'default toolchain:'
Assert-Contains "-show lists a model" $r.out 'model for claude:'

# ---------------------------------------------------------------------------
"6. -model AGENT= clears the model; bad specs fail"
$r = Invoke-Scenario "& '$defaults' -saveDir '$save' -model 'claude='" $stubPath
Assert "clearing a model exits 0" ($r.code -eq 0)
Assert "cleared model removed from claude settings" `
    ($null -eq (Get-Content "$save/.claude/settings.json" -Raw | ConvertFrom-Json).PSObject.Properties['model'])
Assert "cleared model removed from the defaults file" `
    (@(Get-Content "$save/defaults") -notcontains 'model.claude=claude-opus-4-5')
$r = Invoke-Scenario "& '$defaults' -saveDir '$save' -model 'opencode'" $stubPath
Assert "-model without AGENT= fails" ($r.code -ne 0)
$r = Invoke-Scenario "& '$defaults' -saveDir '$save' -model 'nope=x'" $stubPath
Assert "-model of an unknown agent fails" ($r.code -ne 0)

# ---------------------------------------------------------------------------
"7. -dryRun writes nothing"
$saveDry = Join-Path $tmp 'dry'; $null = New-Item -ItemType Directory -Force -Path $saveDry
$r = Invoke-Scenario "& '$defaults' -saveDir '$saveDry' -dryRun -agent claude -toolchain 'node,bun' -model 'opencode=x/y'" $stubPath
Assert "-dryRun exit code 0" ($r.code -eq 0)
Assert-Contains "-dryRun says what it would set" $r.out 'would set'
Assert "-dryRun wrote no files" (@(Get-ChildItem $saveDry -Recurse -File).Count -eq 0)

# ---------------------------------------------------------------------------
"8. Interactive: picks by number, blanks keep, none clears"
$saveInt = Join-Path $tmp 'interactive'; $null = New-Item -ItemType Directory -Force -Path $saveInt
# Agents are listed alphabetically: claude, opencode, opencode-v1. The toolchains
# are listed as Code-It-Build lists them: bun, dotnet, node, powershell, python.
$r = Invoke-ScenarioWithAnswers "& '$defaults' -saveDir '$saveInt'" $stubPath @('1', '', '', '', '3,5')
Assert "interactive exit code 0" ($r.code -eq 0)
Assert "first agent answer is claude" ((Get-Content "$saveInt/defaults") -contains 'default-agent=claude')
Assert "toolchain answered by numbers" ((Get-Content "$saveInt/defaults") -contains 'default-toolchain=node,python')
Assert "blank model answer keeps (creates nothing)" (-not (Test-Path "$saveInt/.claude/settings.json"))
# (Get-ChildItem lists agents alphabetically: claude, opencode, opencode-v1)
$r = Invoke-ScenarioWithAnswers "& '$defaults' -saveDir '$saveInt'" $stubPath @('3', '', '', 'my-favourite-model', 'node')
Assert "second interactive run exit code 0" ($r.code -eq 0)
Assert "agent answered as a number" ((Get-Content "$saveInt/defaults") -contains 'default-agent=opencode-v1')
Assert "a free-text model is accepted" ((Get-Content "$saveInt/defaults") -contains 'model.opencode-v1=my-favourite-model')
Assert "kept model is not overwritten" (-not (Get-Content "$saveInt/defaults" -Raw).Contains("model.claude="))
Assert-Contains "the interactive picker lists the bundled catalog" $r.out 'anthropic/claude-opus-5-5'
Assert-Contains "claude's list offers bare aliases" $r.out "  1) opus"
# The opencode agents' lists prefer opencode-go's models; Claude Code's keeps
# Anthropic's bare names, which is all it takes
Assert-Contains "the opencode picker offers opencode-go's models under opencode-go" $r.out 'opencode-go/glm-5.3'
Assert "a model opencode-go serves is not also offered under its other provider" `
    (@($r.out -split "`r?`n" | Where-Object { $_ -match '^\s+\d+\) zai/glm-5\.3$' }).Count -eq 0)
Assert "a model opencode-go does not serve keeps its provider" `
    (@($r.out -split "`r?`n" | Where-Object { $_ -match '^\s+\d+\) zai/glm-5\.3-flashx$' }).Count -gt 0)
Assert "claude's list keeps Anthropic's models without the prefix" `
    (@($r.out -split "`r?`n" | Where-Object { $_ -match '^\s+\d+\) claude-sonnet-5-5$' }).Count -gt 0)
$r = Invoke-ScenarioWithAnswers "& '$defaults' -saveDir '$saveInt'" $stubPath @('5', 'sonnet', '', 'none', 'none')
Assert "third interactive run exit code 0" ($r.code -eq 0)
Assert "out-of-range number keeps the saved agent" ((Get-Content "$saveInt/defaults") -contains 'default-agent=opencode-v1')
Assert "'sonnet' is accepted for claude" ((Get-Content "$saveInt/defaults") -contains 'model.claude=sonnet')
Assert "'none' clears a model" `
    (-not (Get-Content "$saveInt/defaults" -Raw).Contains("model.opencode-v1="))
Assert "'none' clears the model from the agent's config" `
    ($null -eq (Get-Content "$saveInt/.config/opencode/config.json" -Raw | ConvertFrom-Json).PSObject.Properties['model'])
Assert "'none' clears the toolchain" `
    (-not (Get-Content "$saveInt/defaults" -Raw).Contains("default-toolchain="))

# ---------------------------------------------------------------------------
"9. Code-It uses the saved defaults; its own options win"
$d = Join-Path $tmp 'launcher'; $null = New-Item -ItemType Directory -Force -Path $d
Set-Content -Path "$d/defaults" -Value "default-agent=claude`ndefault-toolchain=node`nmodel.opencode=y/z`n"

$r = Invoke-Scenario "& '$codeIt' -dryRun -WorkDirToMount '$scriptDir' -saveDir '$d'" $stubPath
Assert-Contains "launches the saved agent" $r.out 'CODE_AGENT="claude"'
Assert-Contains "says the toolchain came from defaults" $r.out 'Using saved default toolchain: node'
Assert-Contains "uses an image whose label contains the default toolchain" $r.out "'code-it-alpine-node' does not exist; using 'code-it-alpine-dotnet-node'"

$r = Invoke-Scenario "& '$codeIt' -o -dryRun -WorkDirToMount '$scriptDir' -saveDir '$d'" $stubPath
Assert-Contains "-opencode beats the saved agent" $r.out 'CODE_AGENT="opencode"'

$r = Invoke-Scenario "& '$codeIt' -c -dryRun -WorkDirToMount '$scriptDir' -saveDir '$d'" $stubPath
Assert-Contains "-claude launches claude" $r.out 'CODE_AGENT="claude"'
Assert-Contains "claude's state is mounted" $r.out '.claude'

$r = Invoke-Scenario "& '$codeIt' -toolchain dotnet -dryRun -WorkDirToMount '$scriptDir' -saveDir '$d'" $stubPath
Assert "-toolchain beats the saved default" (-not $r.out.Contains('saved default toolchain'))
Assert-Contains "-toolchain derives the image" $r.out 'code-it-alpine-dotnet'

$r = Invoke-Scenario "& '$codeIt' -image code-it-alpine-custom -dryRun -WorkDirToMount '$scriptDir' -saveDir '$d'" $stubPath
Assert "-image beats the saved default" (-not $r.out.Contains('saved default toolchain'))

# A remembered image does not override the default toolchain (Spec 09's heuristic)
Set-Content -Path "$d/image-history" -Value '20260101 code-it-alpine-dotnet-node'
$r = Invoke-Scenario "& '$codeIt' -dryRun -WorkDirToMount '$scriptDir' -saveDir '$d'" $stubPath
Assert-Contains "the saved default beats the remembered-image heuristic" $r.out 'Using saved default toolchain: node'

# Unknown saved agents error like unknown -agent
Set-Content -Path "$d/defaults" -Value 'default-agent=ghost'
$r = Invoke-Scenario "& '$codeIt' -dryRun -WorkDirToMount '$scriptDir' -saveDir '$d'" $stubPath
Assert-Contains "unknown saved agent warns" $r.out "Unknown agent 'ghost'"

# Without a relevant default, everything is as before
Remove-Item "$d/defaults"
$r = Invoke-Scenario "& '$codeIt' -dryRun -WorkDirToMount '$scriptDir' -saveDir '$d'" $stubPath
Assert-Contains "no defaults: opencode" $r.out 'CODE_AGENT="opencode"'
Assert "no defaults: no toolchain note" (-not $r.out.Contains('saved default toolchain'))

# ---------------------------------------------------------------------------
"10. A save dir that does not exist yet; -show names the model files; the agent switch says so"

# Saving must create the save dir: on a machine Code-It has not run on yet, it is absent
$fresh = Join-Path $tmp 'fresh-save'
$r = Invoke-Scenario "& '$defaults' -saveDir '$fresh' -agent opencode -toolchain node" $stubPath
Assert "parameterised run into a missing save dir exits 0" ($r.code -eq 0)
Assert "defaults file written" (Test-Path "$fresh/defaults")
Assert-Contains "it says the agent was set" $r.out 'Default agent: opencode'

# -show names where each agent's model was set
$showD = Join-Path $tmp 'show-d'
$null = New-Item -ItemType Directory -Force -Path "$showD/.config/opencode"
Set-Content -Path "$showD/defaults" -Value "default-agent=opencode`nmodel.opencode=anthropic/claude-sonnet-4-5"
Set-Content -Path "$showD/.config/opencode/config.json" -Value "{`n  `"model`": `"anthropic/claude-sonnet-4-5`"`n}"
$r = Invoke-Scenario "& '$defaults' -saveDir '$showD' -show" $stubPath
Assert-Contains "-show shows the model" $r.out 'model for opencode:'
Assert-Contains "-show shows the model value" $r.out 'anthropic/claude-sonnet-4-5'
Assert-Contains "-show names the model file" $r.out "(set in $showD/.config/opencode/config.json)"

# Switching the default agent interactively explains that the agent's own state,
# and login, come with it
$noteD = Join-Path $tmp 'note-d'
$r = Invoke-ScenarioWithAnswers "& '$defaults' -saveDir '$noteD'" $stubPath @('opencode-v1', 'none', 'none', 'none', 'none')
Assert "interactive switch exits 0" ($r.code -eq 0)
Assert-Contains "the switch explains each agent's own state and login" $r.out 'log in again'
Assert "the switched agent is saved" ((Get-Content "$noteD/defaults") -contains 'default-agent=opencode-v1')

# Plain Code-It says when the saved agent is what it launches
$agentD = Join-Path $tmp 'agent-note'; $null = New-Item -ItemType Directory -Force -Path $agentD
Set-Content -Path "$agentD/defaults" -Value 'default-agent=claude'
$r = Invoke-Scenario "& '$codeIt' -dryRun -WorkDirToMount '$scriptDir' -saveDir '$agentD'" $stubPath
Assert-Contains "Code-It says which saved agent it launches" $r.out 'Using saved default agent: claude'
Remove-Item "$agentD/defaults"
$r = Invoke-Scenario "& '$codeIt' -dryRun -WorkDirToMount '$scriptDir' -saveDir '$agentD'" $stubPath
Assert "no default agent: no agent note" (-not $r.out.Contains('saved default agent'))

# ---------------------------------------------------------------------------
""
"Results: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }

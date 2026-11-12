# Tests for XS/Code-It.ps1.
#
# No container runtime is required: the tests put stub `docker` and `container`
# executables on the PATH, and assert on the arguments the stubs receive. Each
# scenario runs in a child pwsh process, with HOME a temporary directory, so `exit`,
# the default save dir and first run are isolated.
# Run with:
#   pwsh -NoProfile -File tests/xs/Test-CodeItXS.ps1

$ErrorActionPreference = 'Continue'

$codeIt = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'XS/Code-It.ps1'
$pwshExe = (Get-Process -Id $PID).Path
$onWindows = ($env:OS -eq 'Windows_NT')

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "code-it-xs-tests-$PID"
$null = New-Item -ItemType Directory -Force -Path $tmp

$script:pass = 0
$script:fail = 0

function Assert([string]$desc, [bool]$ok) {
    if ($ok) { "  ok: $desc";   $script:pass++ }
    else     { "  FAIL: $desc"; $script:fail++ }
}
function Assert-Contains([string]$desc, [string]$haystack, [string]$needle) {
    Assert $desc ($haystack.Contains($needle))
}
function Assert-NotContains([string]$desc, [string]$haystack, [string]$needle) {
    Assert $desc (-not $haystack.Contains($needle))
}

# Stubs. Each runtime prints the arguments it was run with, one [arg] each.
# `image inspect` succeeds unless STUB_NO_IMAGE is set.
foreach ($rt in 'docker', 'container') {
    $dir = Join-Path $tmp "stub-$rt"
    $null = New-Item -ItemType Directory -Force $dir
    if ($onWindows) {
        Set-Content (Join-Path $dir "$rt.cmd") @"
@echo off
if "%~1"=="image" ( if defined STUB_NO_IMAGE exit /b 1
  exit /b 0 )
setlocal enabledelayedexpansion
if "%~1"=="build" (
  set context=
  for %%a in (%*) do set context=%%~a
  if exist "!context!\Dockerfile" echo STUB_HAS_DOCKERFILE
  if exist "!context!\snippets\ca-certificates.dockerfile" echo STUB_HAS_XS_FILES
  if exist "!context!\ca-certificates\README.md" echo STUB_HAS_TOP_LEVEL_CA_README
)
set out=STUB-$rt
:loop
if "%~1"=="" goto done
set out=!out! [%~1]
shift
goto loop
:done
echo !out!
"@
    } else {
        Set-Content (Join-Path $dir $rt) @"
#!/bin/sh
[ "`$1" = image ] && { [ -n "`${STUB_NO_IMAGE:-}" ] && exit 1; exit 0; }
if [ "`$1" = build ]; then
  context=""
  for arg do context="`$arg"; done
  [ -f "`$context/Dockerfile" ] && echo STUB_HAS_DOCKERFILE
  [ -f "`$context/snippets/ca-certificates.dockerfile" ] && echo STUB_HAS_XS_FILES
  [ -f "`$context/ca-certificates/README.md" ] && echo STUB_HAS_TOP_LEVEL_CA_README
fi
printf 'STUB-$rt'; printf ' [%s]' "`$@"; echo
"@
        chmod +x (Join-Path $dir $rt)
    }
}

$sep = [IO.Path]::PathSeparator
$home_ = Join-Path $tmp 'home'
$work = Join-Path $tmp 'projects/my-proj'
$null = New-Item -ItemType Directory -Force $home_, $work
$save = Join-Path $home_ '.config/code-it-xs'

# Run-XS COMMAND [answer] [env]: run COMMAND (PowerShell source invoking $codeIt as
# `& $x`) in a child pwsh, in the work dir, with docker stubbed, HOME set, a known git
# identity and locale, and $answer piped to first run.
function Run-XS([string]$command, [string]$answer = 'n', [hashtable]$envs = @{}) {
    $vars = @{ HOME = $home_; USERPROFILE = $home_; PATH = "$tmp/stub-docker$sep$env:PATH"
               GIT_AUTHOR_NAME = 'Ada L'; GIT_AUTHOR_EMAIL = 'ada@example.com'; LANG = 'en_GB.UTF-8'; LC_ALL = '' }
    foreach ($k in $envs.Keys) { $vars[$k] = $envs[$k] }
    $saved = @{}
    foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
    Push-Location $work
    try { ($answer | & $pwshExe -NoProfile -Command "`$x = '$codeIt'; $command" 2>&1) -join "`n" }
    finally {
        Pop-Location
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

# ---------------------------------------------------------------------------
"First run"
$null = New-Item -ItemType Directory -Force "$home_/.claude", "$home_/.config/opencode"
Set-Content "$home_/.claude/.credentials.json" 'secret'
Set-Content "$home_/.claude.json" '{"a":1}'
Set-Content "$home_/.config/opencode/opencode.json" '{}'
$out = Run-XS '& $x' 'y'
Assert-Contains "y copies ~/.claude" $out "copied ~/.claude to"
Assert "the copied ~/.claude keeps its files" (Test-Path "$save/.claude/.credentials.json")
Assert "~/.claude.json is copied as a file" ((Get-Content "$save/.claude.json") -eq '{"a":1}')
Assert "~/.config/opencode is copied" (Test-Path "$save/.config/opencode/opencode.json")
Assert-NotContains "a missing host path is skipped" $out "copied ~/.local/share/opencode"
Assert-Contains "the agent still runs after first run" $out "STUB-docker [run]"
$out = Run-XS '& $x' 'y'
Assert-NotContains "an existing save dir is not first run" $out "copied"
Remove-Item -Recurse -Force $save
$out = Run-XS '& $x -c'
Assert-NotContains "n copies nothing" $out "copied"
Assert "n still creates the save dir" (Test-Path $save)
Assert "n leaves the save dir without host credentials" (-not (Test-Path "$save/.claude/.credentials.json"))
Assert "a missing .claude.json is created as a file" ((Test-Path "$save/.claude.json" -PathType Leaf) -and ((Get-Content "$save/.claude.json") -eq '{}'))
Remove-Item -Recurse -Force $save
$out = Run-XS '& $x -dryRun'
Assert "-dryRun makes no save dir" (-not (Test-Path $save))
Assert-NotContains "-dryRun runs nothing" $out "STUB-docker"
Assert-Contains "-dryRun prints the run command" $out "docker run -it --rm"
$out = Run-XS '& $x'
Assert-NotContains "a failing agent waits for Enter by default" $out "CODE_IT_NO_WAIT"
$out = Run-XS '& $x -noWait'
Assert-Contains "-noWait tells go.sh not to wait for Enter" $out "[-e] [CODE_IT_NO_WAIT=1]"

# ---------------------------------------------------------------------------
"Agents and their state"
$out = Run-XS '& $x'
Assert-Contains "opencode is the default agent" $out "[CODE_AGENT=opencode]"
Assert-Contains "opencode's config is mounted" $out "/.config/opencode:/home/agent1/.config/opencode]"
Assert-Contains "opencode's data is mounted" $out "/.local/share/opencode:/home/agent1/.local/share/opencode]"
Assert-Contains "opencode's state is mounted" $out "/.local/state/opencode:/home/agent1/.local/state/opencode]"
Assert-NotContains "opencode does not see claude's state" $out ".claude"
$out = Run-XS '& $x -c'
Assert-Contains "-c runs claude" $out "[CODE_AGENT=claude]"
Assert-Contains "claude's dir is mounted" $out "/.claude:/home/agent1/.claude]"
Assert-Contains "claude's json is mounted" $out "/.claude.json:/home/agent1/.claude.json]"
Assert-NotContains "claude does not see opencode's state" $out "opencode:"
$out = Run-XS '& $x -agent codex'
Assert-Contains "-agent codex runs codex" $out "[CODE_AGENT=codex]"
Assert-Contains "codex's state is mounted" $out "/.codex:/home/agent1/.codex]"
$out = Run-XS '& $x -zsh'
Assert-Contains "-zsh runs zsh" $out "[CODE_AGENT=zsh]"
Assert-NotContains "-zsh mounts no agent state" $out "/home/agent1/"
$out = Run-XS '& $x -a cursor; "rc=$LASTEXITCODE"'
Assert-Contains "an unknown agent fails" $out "rc=1"
Assert-Contains "an unknown agent says where to add it" $out "Unknown agent 'cursor'"

# ---------------------------------------------------------------------------
"Pass-through"
$out = Run-XS '& $x -c -D ''-p'',''8080:3000'' -- --model ''two words'''
Assert-Contains "-D goes to the runtime, before the image" $out "[-p] [8080:3000] [code-it-xs]"
Assert-Contains "-- passes the rest to the agent, after the image" $out "[code-it-xs] [--model] [two words]"
$out = Run-XS '& $x -D:''-p'',''8080:3000'' -c'
Assert-Contains "-D:a,b goes to the runtime" $out "[-p] [8080:3000] [code-it-xs]"
$out = Run-XS '& $x --D:-p --D:8080:3000 --model m'
Assert-Contains "--D:ARG goes to the runtime" $out "[-p] [8080:3000] [code-it-xs]"
Assert-Contains "other remaining arguments go to the agent" $out "[code-it-xs] [--model] [m]"

# ---------------------------------------------------------------------------
"Prompt"
$out = Run-XS '& $x ''fix the tests'' --continue'
Assert-Contains "a prompt opens opencode with --prompt" $out "[code-it-xs] [--prompt] [fix the tests] [--continue]"
$out = Run-XS '& $x -c ''fix the tests'' --model m'
Assert-Contains "a prompt goes first to claude as is" $out "[code-it-xs] [fix the tests] [--model] [m]"
$out = Run-XS '& $x --model m'
Assert-NotContains "a leading option is not a prompt" $out "--prompt"

# ---------------------------------------------------------------------------
"Work dir"
$out = Run-XS '& $x'
Assert-Contains "the work dir mounts at /work/<parent>/<name>" $out ":/work/projects/my-proj]"
Assert-Contains "go.sh is told the mount path" $out "[CODE_IT_WORK_DIR=/work/projects/my-proj]"
if (-not $onWindows) {
    $null = New-Item -ItemType Directory -Force "$tmp/a:b/c"
    $out = Run-XS "& `$x -workDir '$tmp/a:b/c'"
    Assert-Contains "a ':' in the mount path becomes '-'" $out "[CODE_IT_WORK_DIR=/work/a-b/c]"
    $out = Run-XS '& $x -w /tmp'
    Assert-Contains "a dir under / mounts at /work/<name>" $out "[/tmp:/work/tmp]"
}
$root = [IO.Path]::GetPathRoot($work)
$out = Run-XS "& `$x -w '$root'"
Assert-Contains "the root mounts at /work" $out "[CODE_IT_WORK_DIR=/work]"
$out = Run-XS "& `$x -w '$tmp/nope'; `"rc=`$LASTEXITCODE`""
Assert-Contains "a missing work dir fails" $out "rc=1"
$out = Run-XS '& $x -s rel-save -dryRun'
Assert-Contains "a relative save dir is made absolute" $out "my-proj$([IO.Path]::DirectorySeparatorChar)rel-save/.config/opencode:"

# ---------------------------------------------------------------------------
"Locale"
$out = Run-XS '& $x -l de-AT'
Assert-Contains "-locale de-AT becomes de_AT.UTF-8" $out "[LANG=de_AT.UTF-8]"
$out = Run-XS '& $x -l fr_FR.ISO-8859-1'
Assert-Contains "-locale always gives UTF-8" $out "[LANG=fr_FR.UTF-8]"
$out = Run-XS '& $x -l C.UTF-8'
Assert-Contains "-locale C.UTF-8 is kept" $out "[LANG=C.UTF-8]"
$out = Run-XS '& $x -l nonsense; "rc=$LASTEXITCODE"'
Assert-Contains "an unreadable -locale fails" $out "rc=1"
$out = Run-XS '[cultureinfo]::CurrentCulture = ''pt-BR''; & $x'
Assert-Contains "the host's culture is used" $out "[LANG=pt_BR.UTF-8]"
$out = Run-XS '[cultureinfo]::CurrentCulture = [cultureinfo]::InvariantCulture; & $x'
Assert-Contains "an invariant host culture gives C.UTF-8" $out "[LANG=C.UTF-8]"

# ---------------------------------------------------------------------------
"Runtime and image"
$out = Run-XS '& $x'
Assert-Contains "docker is used when present" $out "STUB-docker [run] [-it] [--rm]"
Assert-NotContains "an existing image is not rebuilt" $out "[build]"
$out = Run-XS '& $x' 'n' @{ STUB_NO_IMAGE = '1' }
Assert-Contains "a missing image is built from the staged XS context" $out "[build] [-t] [code-it-xs] ["
Assert-Contains "the staged XS context contains its Dockerfile" $out 'STUB_HAS_DOCKERFILE'
Assert-Contains "the staged XS context preserves the XS files" $out 'STUB_HAS_XS_FILES'
Assert-Contains "the staged XS context includes the top-level CA folder" $out 'STUB_HAS_TOP_LEVEL_CA_README'
$out = Run-XS '& $x -b -i my-image'
Assert-Contains "-build rebuilds, with -image's name" $out "[build] [-t] [my-image]"
Assert-Contains "-image is run" $out "[my-image]"
$out = Run-XS '& $x -r container' 'n' @{ PATH = "$tmp/stub-container$sep$env:PATH" }
Assert-Contains "-runtime container uses Apple's container" $out "STUB-container [run]"
Assert-Contains "Apple's container gets 3g of memory" $out "[--memory] [3g]"
$out = Run-XS '& $x -r podman; "rc=$LASTEXITCODE"'
Assert-Contains "an unknown runtime fails" $out "rc=1"

# ---------------------------------------------------------------------------
"Git identity"
$out = Run-XS '& $x'
Assert-Contains "the author is the agent on the user's behalf" $out "[GIT_AUTHOR_NAME=Agent1 for Ada L]"
Assert-Contains "the committer is too" $out "[GIT_COMMITTER_NAME=Agent1 for Ada L]"
Assert-Contains "the user's email is used" $out "[GIT_COMMITTER_EMAIL=ada@example.com]"

# ---------------------------------------------------------------------------
"Dockerfile"
$dockerfile = Get-Content (Join-Path (Split-Path $codeIt -Parent) 'Dockerfile') -Raw
Assert "the trust-prompt suppression is offered, commented out" ($dockerfile -match '(?m)^# Suppress Claude''s "do you trust this folder\?" prompt\r?\n#ENV CLAUDE_CODE_SANDBOXED=1\r?$')
Assert "Claude always skips permissions" $dockerfile.Contains('[[ $1 == claude ]] && set -- claude --dangerously-skip-permissions "${@:2}"')
Assert "OpenCode's TUI auto-approves permissions" $dockerfile.Contains('[[ $1 == opencode && ( -z $2 || $2 == -* ) ]] && set -- opencode --auto "${@:2}"')
Assert "opencode run auto-approves permissions" $dockerfile.Contains('[[ $1 == opencode && $2 == run ]] && set -- opencode run --auto "${@:3}"')
Assert "go.sh quotes the agent command for tmux" $dockerfile.Contains('agent_cmd="${(j: :)${(q)@}}"')
Assert "a failing agent's error stays on screen until Enter, unless CODE_IT_NO_WAIT or zsh" $dockerfile.Contains('[[ -n $CODE_IT_NO_WAIT || $1 == zsh ]] || agent_cmd+=" || { printf ''\n%s exited with status %s. Press Enter to close. '' ${(q)1} \$?; read -r _; }"')
Assert "tmux runs the agent command" $dockerfile.Contains('exec tmux -u new-session "$agent_cmd"')
Assert "OpenCode's libstdc++ is installed" ($dockerfile -match 'musl-locales libstdc\+\+\r?\n')
Assert "libgcc is left to apk" (-not $dockerfile.Contains('libgcc libstdc++'))
Assert "the home is handed to agent1 after the toolchain snippets" ($dockerfile -match '(?m)here ---\r?\n\r?\n#[^\n]*\r?\n#[^\n]*\r?\nRUN chown -R agent1:wheel /home/agent1\r?\n\r?\nUSER agent1\r?$')

Remove-Item -Recurse -Force $tmp
""
"Passed: $script:pass, Failed: $script:fail"
exit ([int]($script:fail -gt 0))

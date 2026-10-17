# Tests for Code-It-Doctor.ps1.
#
# No container runtime or terminal is required: a stub `docker` (and, off Windows,
# stub `tmux`, `defaults`, `pbpaste`/`pbcopy` and `xclip`) goes on the PATH, and
# CODE_IT_DOCTOR_TTY points the doctor's escape sequences at a file. A stub "terminal
# that accepts OSC 52" is a clipboard tool decoding the last OSC 52 written there.
# Each scenario runs in a child pwsh process so `exit` in the script is isolated.
# Run with:
#   pwsh -NoProfile -File tests/Test-CodeItDoctor.ps1

$ErrorActionPreference = 'Continue'

$testsDir  = $PSScriptRoot
$scriptDir = Split-Path $testsDir -Parent
$doctor    = Join-Path $scriptDir 'Code-It-Doctor.ps1'
function Test-PwshWorks([string]$exe) {
    if (-not $exe -or -not (Test-Path $exe)) { return $false }
    try { $null = & $exe -NoProfile -Command 'exit 0' 2>$null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}
$pwshExe = @((Get-Command pwsh -EA Silent).Source, "$HOME/.local/bin/pwsh", "$HOME/.dotnet/tools/pwsh") |
    Where-Object { Test-PwshWorks $_ } | Select-Object -First 1
if (-not $pwshExe) { throw "No working pwsh found to run test scenarios" }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "code-it-doctor-tests-$PID"
$null = New-Item -ItemType Directory -Force -Path $tmp

$script:pass = 0
$script:fail = 0
function Assert([string]$desc, [bool]$ok) {
    if ($ok) { "  ok: $desc";   $script:pass++ }
    else     { "  FAIL: $desc"; $script:fail++ }
}
function Assert-Contains([string]$desc, [string]$haystack, [string]$needle) {
    if ($haystack.Contains($needle)) { Assert $desc $true } else { Assert "$desc (missing: $needle)" $false }
}

$onWindows = ($env:OS -eq 'Windows_NT')
$sep = [System.IO.Path]::PathSeparator

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
$bin = Join-Path $tmp 'bin'
$null = New-Item -ItemType Directory -Force -Path $bin
if ($onWindows) {
    Set-Content -Path (Join-Path $bin 'docker.cmd') -Value @'
@echo off
if "%~1"=="--version" (
    echo Docker version 0.0.0-stub
    goto :eof
)
if "%~1"=="info" (
    if defined STUB_DAEMON_DOWN exit /b 1
    goto :eof
)
if "%~1"=="images" (
    if not defined STUB_NO_IMAGE echo code-it-alpine-dotnet-node:latest
    goto :eof
)
if "%~1"=="image" (
    if defined STUB_NO_IMAGE exit /b 1
    goto :eof
)
if "%~1"=="ps" goto :eof
if "%~1"=="run" (
    if defined STUB_TMUX_CONF (echo %STUB_TMUX_CONF%) else (echo set -g set-clipboard on)
    goto :eof
)
'@
} else {
    Set-Content -Path (Join-Path $bin 'docker') -Value @'
#!/bin/sh
case "$1" in
    --version) echo "Docker version 0.0.0-stub" ;;
    info)      [ -z "${STUB_DAEMON_DOWN:-}" ] ;;
    images)    [ -z "${STUB_NO_IMAGE:-}" ] && echo "code-it-alpine-dotnet-node:latest" ; exit 0 ;;
    image)     [ -z "${STUB_NO_IMAGE:-}" ] ;;
    ps)        [ -n "${STUB_RUNNING:-}" ] && printf '%s\n' "$STUB_RUNNING" ; exit 0 ;;
    run)
        for a in "$@"; do last="$a"; done
        case " $* " in
            *" cat "*) printf '%s\n' "${STUB_TMUX_CONF-set -g set-clipboard on}" ;;
            *" -c "*)
                echo "STUB-DOCKER-RUN $*" >> "$STUB_LOG"
                [ -n "${STUB_CONTAINER_NO_OSC:-}" ] && exit 0
                b64=$(printf '%s' "$last" | grep -o '52;c;[A-Za-z0-9+/=]*' | sed 's/.*;//')
                printf '\033]52;c;%s\007' "$b64" ;;
        esac ;;
esac
'@
    Set-Content -Path (Join-Path $bin 'defaults') -Value "#!/bin/sh`necho `"`${STUB_ITERM_ALLOW:-0}`""
    Set-Content -Path (Join-Path $bin 'tmux') -Value @'
#!/bin/sh
case "$*" in
    *set-clipboard*)        echo "${STUB_HOST_CLIPBOARD:-external}" ;;
    *client_termtype*)      echo "${STUB_TERMTYPE:-}" ;;
    *client_termfeatures*)  echo "${STUB_FEATURES-clipboard,focus,title}" ;;
    *client_termname*)      echo "xterm-256color" ;;
esac
'@
    # One clipboard tool, installed as pbpaste/pbcopy (macOS) and xclip (Linux)
    $paste = @'
#!/bin/sh
if [ -n "${STUB_TERMINAL_OSC52:-}" ] && [ -f "$CODE_IT_DOCTOR_TTY" ]; then
    b64=$(grep -ao ']52;c;[A-Za-z0-9+/=]*' "$CODE_IT_DOCTOR_TTY" | tail -n 1 | sed 's/.*;//')
    if [ -n "$b64" ]; then
        printf '%s' "$b64" | base64 -d 2>/dev/null || printf '%s' "$b64" | base64 -D
        exit 0
    fi
fi
cat "$STUB_CLIPBOARD" 2>/dev/null
'@
    $copy = @'
#!/bin/sh
cat > "$STUB_CLIPBOARD"
: > "$CODE_IT_DOCTOR_TTY"
'@
    Set-Content -Path (Join-Path $bin 'pbpaste') -Value $paste
    Set-Content -Path (Join-Path $bin 'pbcopy') -Value $copy
    Set-Content -Path (Join-Path $bin 'xclip') -Value @"
#!/bin/sh
case "`$*" in
    *-o*) exec "$bin/pbpaste" ;;
    *)    exec "$bin/pbcopy" ;;
esac
"@
    foreach ($f in Get-ChildItem $bin) { chmod +x $f.FullName }
}

$home2 = Join-Path $tmp 'home'
$saveDir = Join-Path $home2 '.config/code-it'
$null = New-Item -ItemType Directory -Force -Path $saveDir
$tty = Join-Path $tmp 'tty'
$clipboard = Join-Path $tmp 'clipboard'
$log = Join-Path $tmp 'log'

# Variables of the terminal (and tmux) this suite runs in, cleared for each scenario
$clearVars = @('TMUX', 'TERM_PROGRAM', 'LC_TERMINAL', 'ITERM_SESSION_ID', 'GHOSTTY_RESOURCES_DIR',
    'WEZTERM_PANE', 'KITTY_WINDOW_ID', 'ALACRITTY_WINDOW_ID', 'WT_SESSION', 'STY', 'SSH_CONNECTION',
    'SSH_TTY', 'WAYLAND_DISPLAY', 'DISPLAY', 'XDG_CONFIG_HOME')

# Invoke-Doctor ARGS VARS: run the doctor in a child pwsh with the stubs first on the
# PATH, the terminal variables cleared, and VARS (a hashtable) set.
function Invoke-Doctor([string[]]$doctorArgs, [hashtable]$vars = @{}) {
    $saved = @{}
    $all = $clearVars + @('PATH', 'HOME', 'CODE_IT_DOCTOR_TTY', 'STUB_CLIPBOARD', 'STUB_LOG',
        'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL') + @($vars.Keys)
    foreach ($k in $all) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
    try {
        foreach ($k in $clearVars) { [Environment]::SetEnvironmentVariable($k, $null) }
        $env:PATH = "$bin$sep$($saved['PATH'])"
        if (-not $onWindows) { $env:HOME = $home2 }
        $env:CODE_IT_DOCTOR_TTY = $tty
        $env:STUB_CLIPBOARD = $clipboard
        $env:STUB_LOG = $log
        $env:GIT_AUTHOR_NAME = 'Test User'
        $env:GIT_AUTHOR_EMAIL = 'test@example.com'
        foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
        Set-Content -Path $tty -Value '' -NoNewline
        Set-Content -Path $log -Value '' -NoNewline
        Set-Content -Path $clipboard -Value 'precious' -NoNewline
        $out = & $pwshExe -NoProfile -File $doctor -runtime docker -saveDir $saveDir @doctorArgs 2>&1 | Out-String
        return @{ out = $out; code = $LASTEXITCODE }
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

# ---------------------------------------------------------------------------
"1. Parse and help"
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($doctor, [ref]$null, [ref]$errors)
Assert "Code-It-Doctor.ps1 parses" ($errors.Count -eq 0)
$out = & $pwshExe -NoProfile -File $doctor -help 2>&1 | Out-String
Assert-Contains "-help documents -fix" $out '-fix'
Assert-Contains "-help documents -noLiveTest" $out '-noLiveTest'

# ---------------------------------------------------------------------------
"2. Terminal.app cannot take the clipboard from the container"
$r = Invoke-Doctor @('-noLiveTest') @{ TERM_PROGRAM = 'Apple_Terminal' }
Assert "a problem exits 1" ($r.code -eq 1)
Assert-Contains "the docker daemon is reachable" $r.out 'ok:      the docker daemon is reachable'
Assert-Contains "the default image is found" $r.out 'ok:      image code-it-alpine-dotnet-node exists'
Assert-Contains "the image's tmux passes OSC 52 on" $r.out '(set-clipboard on)'
Assert-Contains "Terminal.app is the problem" $r.out 'PROBLEM: macOS Terminal.app ignores OSC 52'
Assert-Contains "says to select natively" $r.out "makes Terminal.app's own selection"
Assert-Contains "live test can be skipped" $r.out 'skipped: the clipboard round trip (-noLiveTest)'

# ---------------------------------------------------------------------------
"3. Terminals"
$r = Invoke-Doctor @('-noLiveTest') @{ TERM_PROGRAM = 'iTerm.app'; STUB_ITERM_ALLOW = '0' }
Assert-Contains "iTerm2 says where its clipboard permission is" $r.out "Applications in terminal"
$r = Invoke-Doctor @('-noLiveTest') @{ TERM_PROGRAM = 'WezTerm' }
Assert-Contains "WezTerm is ok" $r.out 'ok:      wezterm accepts OSC 52'
Assert "no problems exits 0" ($r.code -eq 0)
Assert-Contains "no problems is summarised" $r.out 'No problems found.'
$r = Invoke-Doctor @('-noLiveTest') @{ TERM_PROGRAM = 'SomethingElse' }
Assert-Contains "an unknown terminal is reported" $r.out "unknown: terminal 'unknown' (TERM_PROGRAM=SomethingElse"
$ghostty = Join-Path $tmp 'xdg/ghostty'
$null = New-Item -ItemType Directory -Force -Path $ghostty
Set-Content -Path (Join-Path $ghostty 'config') -Value 'clipboard-write = deny'
$r = Invoke-Doctor @('-noLiveTest') @{ TERM_PROGRAM = 'ghostty'; XDG_CONFIG_HOME = (Join-Path $tmp 'xdg') }
Assert-Contains "Ghostty denying writes is a problem" $r.out "PROBLEM: Ghostty's clipboard-write = deny"

# ---------------------------------------------------------------------------
"4. tmux on the host"
if ($onWindows) {
    "  skip: host tmux (Windows)"
} else {
    $r = Invoke-Doctor @('-noLiveTest') @{ TMUX = '/tmp/tmux-1/default,1,0'; TERM_PROGRAM = 'tmux'; STUB_TERMTYPE = 'WezTerm 20240203' }
    Assert-Contains "the terminal behind host tmux is found" $r.out 'ok:      wezterm accepts OSC 52'
    Assert-Contains "host tmux with set-clipboard external is a problem" $r.out 'PROBLEM: tmux on the host has set-clipboard external'
    Assert-Contains "says to set set-clipboard on" $r.out 'set -s set-clipboard on'
    $r = Invoke-Doctor @('-noLiveTest') @{ TMUX = '/tmp/tmux-1/default,1,0'; TERM_PROGRAM = 'WezTerm'; STUB_HOST_CLIPBOARD = 'on' }
    Assert-Contains "host tmux with set-clipboard on is ok" $r.out 'ok:      tmux on the host passes OSC 52 on'
}

# ---------------------------------------------------------------------------
"5. Runtime and image"
$r = Invoke-Doctor @('-noLiveTest') @{ TERM_PROGRAM = 'WezTerm'; STUB_TMUX_CONF = 'set -g mouse on' }
Assert-Contains "an image without set-clipboard on is a problem" $r.out 'PROBLEM: tmux in code-it-alpine-dotnet-node does not pass'
Assert-Contains "says to rebuild, with the image's toolchains" $r.out '-toolchain dotnet,node -image code-it-alpine-dotnet-node -rebuild'
$r = Invoke-Doctor @('-noLiveTest') @{ TERM_PROGRAM = 'WezTerm'; STUB_DAEMON_DOWN = '1' }
Assert-Contains "an unreachable daemon is a problem" $r.out 'PROBLEM: the docker daemon is not reachable'
Assert-Contains "the image check is skipped" $r.out 'skipped: no running container runtime'
$r = Invoke-Doctor @('-noLiveTest') @{ TERM_PROGRAM = 'WezTerm'; STUB_NO_IMAGE = '1' }
Assert-Contains "no code-it image is a problem" $r.out 'PROBLEM: there is no code-it image'

# ---------------------------------------------------------------------------
"6. The clipboard round trip"
if ($onWindows) {
    "  skip: clipboard round trip (Windows)"
} else {
    $r = Invoke-Doctor @('-yes') @{ TERM_PROGRAM = 'WezTerm'; STUB_TERMINAL_OSC52 = '1'; DISPLAY = ':0' }
    Assert-Contains "OSC 52 from the shell arrives" $r.out 'ok:      round trip: OSC 52 from this shell reached the clipboard'
    Assert-Contains "OSC 52 from tmux in the container arrives" $r.out 'ok:      round trip: OSC 52 from tmux in the container reached the clipboard'
    Assert-Contains "runs tmux in the image" (Get-Content $log -Raw) '--entrypoint /bin/sh code-it-alpine-dotnet-node:latest -c tmux -u new-session'
    Assert "a working clipboard exits 0" ($r.code -eq 0)
    Assert "the clipboard is restored" ((Get-Content $clipboard -Raw).Trim() -eq 'precious')

    $r = Invoke-Doctor @('-yes') @{ TERM_PROGRAM = 'SomethingElse'; DISPLAY = ':0' }
    Assert-Contains "a terminal ignoring OSC 52 is a problem" $r.out 'PROBLEM: round trip: OSC 52 from this shell did not reach the clipboard'
    Assert "the container leg is not tried when the terminal fails" (-not (Get-Content $log -Raw))

    $r = Invoke-Doctor @('-yes') @{ TERM_PROGRAM = 'WezTerm'; STUB_TERMINAL_OSC52 = '1'; STUB_CONTAINER_NO_OSC = '1'; DISPLAY = ':0' }
    Assert-Contains "nothing from the container is a problem" $r.out 'none arrived from tmux'

    $r = Invoke-Doctor @() @{ TERM_PROGRAM = 'WezTerm'; DISPLAY = ':0' }
    Assert-Contains "not interactive without -yes skips the round trip" $r.out 'not interactive; -yes runs it'
}

# ---------------------------------------------------------------------------
"7. -fix hands the report to code-it"
$stubCi = Join-Path $tmp 'Stub-Code-It.ps1'
Set-Content -Path $stubCi -Value @'
Write-Output "STUB-CODE-IT $($args -join ' ')"
exit [int]($env:STUB_CODE_IT_EXIT ?? 0)
'@
function New-Repo([string]$d) {
    $null = New-Item -ItemType Directory -Force -Path $d
    git -C $d init -q
    git -C $d config user.email a@b.c
    git -C $d config user.name T
    Set-Content -Path (Join-Path $d 'x') -Value 'x'
    git -C $d add -A
    git -C $d commit -qm init
}
$repoA = Join-Path $tmp 'repo-a'; New-Repo $repoA

$r = Invoke-Doctor @('-noLiveTest', '-repo', $repoA, '-codeIt', $stubCi, '-dryRun', 'copy does not work') @{ TERM_PROGRAM = 'Apple_Terminal' }
Assert "-fix -dryRun exit code" ($r.code -eq 0)
Assert-Contains "the prompt carries the problem" $r.out "The user's problem: copy does not work"
Assert-Contains "the prompt carries the report" $r.out 'PROBLEM: macOS Terminal.app ignores OSC 52'
Assert-Contains "the prompt asks for tests" $r.out './tests/run-all-tests.sh'
Assert-Contains "dry-run prints code-it -headless" $r.out '-headless'
Assert "-dryRun creates no branch" (-not (git -C $repoA branch --list 'doctor/*'))

$r = Invoke-Doctor @('-noLiveTest', '-repo', $repoA, '-codeIt', $stubCi, '-fix') @{ TERM_PROGRAM = 'WezTerm' }
Assert-Contains "-fix with nothing wrong has nothing to fix" $r.out 'Nothing to fix'
Assert "nothing to fix exits 0" ($r.code -eq 0)

$r = Invoke-Doctor @('-noLiveTest', '-repo', $repoA, '-codeIt', $stubCi, '-branch', 'doctor/test', 'it broke') @{ TERM_PROGRAM = 'WezTerm' }
Assert "-fix run exit code" ($r.code -eq 0)
Assert-Contains "-fix runs code-it headless" $r.out 'STUB-CODE-IT -headless -WorkDirToMount'
Assert "-fix works on its own branch" ((git -C $repoA rev-parse --abbrev-ref HEAD) -eq 'doctor/test')

$repoB = Join-Path $tmp 'repo-b'; New-Repo $repoB
$r = Invoke-Doctor @('-noLiveTest', '-repo', $repoB, '-codeIt', $stubCi, 'it broke') @{ TERM_PROGRAM = 'WezTerm'; STUB_CODE_IT_EXIT = '3' }
Assert "-fix propagates code-it's exit code" ($r.code -eq 3)

# ---------------------------------------------------------------------------
Remove-Item -Recurse -Force $tmp -EA Silent
""
"Results: $script:pass passed, $script:fail failed"
if ($script:fail -ne 0) { exit 1 }

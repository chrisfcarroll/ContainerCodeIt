#! /usr/bin/env pwsh
<#
.SYNOPSIS
    Checks your code-it setup for known problems and says how to fix each one.

.DESCRIPTION
    The first of the known problems is copying to the host clipboard from the agent in
    the container, which has to pass from the agent, through tmux in the container, the
    container runtime, any tmux on the host, to your terminal, which must accept OSC 52.

    With -fix, or a Problem described in words, it then runs code-it headless on this
    repository with that problem and the report, so the in-container agent investigates
    and fixes it, on a new branch, or tells you what to change on the host.

    The clipboard round trip briefly puts a marker on your clipboard with OSC 52, first
    from this shell and then from tmux inside the image, and reads it back with the
    host's clipboard tool. Text that was on the clipboard is restored afterwards;
    anything else (an image, say) is not.

    Exit code: 0 if no problem was found, 1 if one was; with -fix, code-it's exit code.

.PARAMETER Problem
    The problem, in words. Implies -fix.

.PARAMETER runtime
    docker or container. Default: auto-detect, as Code-It.ps1 does.

.PARAMETER image
    Image to check. Default: the most recently used existing code-it image, else the
    most recently built.

.PARAMETER saveDir
    code-it's save dir. Default: ~/.config/code-it

.PARAMETER noLiveTest
    Skip the clipboard round trip.

.PARAMETER yes
    Run the clipboard round trip without asking first.

.PARAMETER fix
    After the checks, run code-it headless on this repository with the report (and
    Problem, if given) to investigate and fix it.

.PARAMETER repo
    Repository for -fix. Default: this script's directory.

.PARAMETER codeIt
    code-it launcher for -fix. Default: Code-It.ps1 next to this script.

.PARAMETER branch
    Branch for -fix. Default: doctor/<yyyymmdd-HHmmss>.

.PARAMETER dryRun
    With -fix, print the prompt and code-it command, and run nothing.

.EXAMPLE
    .\Code-It-Doctor.ps1

.EXAMPLE
    .\Code-It-Doctor.ps1 "opencode can't create a session"
#>

[CmdletBinding(PositionalBinding = $false)]
param (
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Problem    = @(),
    [ArgumentCompleter({ param($c, $p, $wordToComplete) @('docker', 'container') | Where-Object { $_ -like "$wordToComplete*" } })]
    [string]$runtime      = "",
    [string]$image        = "",
    [string]$saveDir      = "$HOME/.config/code-it",
    [switch]$noLiveTest   = $false,
    [Alias('y')]
    [switch]$yes          = $false,
    [switch]$fix          = $false,
    [string]$repo         = $PSScriptRoot,
    [string]$codeIt       = (Join-Path $PSScriptRoot 'Code-It.ps1'),
    [string]$branch       = "",
    [switch]$dryRun       = $false,
    [Alias('h')]
    [switch]$help         = $false
)

if ($help) {
    Get-Help $PSCommandPath -Full
    exit 0
}

. "$PSScriptRoot/lib/CodeItCommon.ps1"

$problemText = ($Problem -join ' ').Trim()
if ($problemText) { $fix = $true }

# The report is printed as it is made, and kept, so -fix can hand it to the agent.
$script:report   = [System.Text.StringBuilder]::new()
$script:problems = 0
function Say([string]$text)     { Write-Host $text; $null = $script:report.AppendLine($text) }
function Section([string]$text) { Say ""; Say $text }
function Ok([string]$text)      { Say "  ok:      $text" }
function Problem([string]$text) { Say "  PROBLEM: $text"; $script:problems++ }
function Warn([string]$text)    { Say "  warning: $text" }
function Unknown([string]$text) { Say "  unknown: $text" }
function Detail([string]$text)  { Say "           $text" }

$onMacOS   = $IsMacOS -eq $true
$onWindows = $env:OS -eq 'Windows_NT'
$containerHome = '/home/agent1'

# ---------------------------------------------------------------------------
Section "Host"
Say "  $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription) $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture), PowerShell $($PSVersionTable.PSVersion)"
if (Test-Path '/etc/code-it-agents') {
    Warn "this looks like the inside of a code-it container; run code-it-doctor on the host"
}
# code-it takes the git identity from GIT_AUTHOR_* if set, else from git config.
$gitName  = if ($env:GIT_AUTHOR_NAME)  { $env:GIT_AUTHOR_NAME }  else { git config --get user.name 2>$null }
$gitEmail = if ($env:GIT_AUTHOR_EMAIL) { $env:GIT_AUTHOR_EMAIL } else { git config --get user.email 2>$null }
if ($gitName -and $gitEmail) {
    Ok "git user.name and user.email are set, so the agent can commit"
} else {
    Problem "git user.name or user.email is not set, so the agent cannot commit"
    Detail "fix: git config --global user.name 'Your Name' ; git config --global user.email you@example.com"
}

# ---------------------------------------------------------------------------
Section "Container runtime"
$runtimeOk = $false
$detected = Detect-CodeItRuntime $runtime 3>$null 6>$null
if ($detected) {
    $runtime = $detected
    Say "  ${runtime}: $(& $runtime --version 2>$null | Select-Object -First 1)"
    if ($runtime -eq 'container') {
        & container system status *> $null
        if ($LASTEXITCODE -eq 0) { Ok "the container system service is running"; $runtimeOk = $true }
        else { Problem "the container system service is not running"; Detail "fix: container system start" }
    } else {
        & docker info *> $null
        if ($LASTEXITCODE -eq 0) { Ok "the docker daemon is reachable"; $runtimeOk = $true }
        else { Problem "the docker daemon is not reachable"; Detail "fix: start Docker Desktop, or the docker service" }
    }
} else {
    Problem "no usable container runtime"
    Detail "install Docker, or on macOS the Apple container CLI; Code-It.ps1 says which suits your platform"
}

# ---------------------------------------------------------------------------
Section "Image"
$imageOk = $false
if ($runtimeOk) {
    if (-not $image) { $image = Get-CodeItDefaultImage $runtime (Join-Path $saveDir 'image-history') }
    $image = "$image" -replace ':latest$', ''
    # Code-It-Build needs the toolchains: take them from the image's label or name
    $imageChains = if ($image) { Get-CodeItImageToolchain $runtime "${image}:latest" } else { '' }
    if (-not $imageChains) { $imageChains = '<toolchains>' }
    $rebuildCmd = "$(Join-Path $PSScriptRoot 'Code-It-Build.ps1') -toolchain $imageChains -image $image"
    if (-not $image) {
        Problem "there is no code-it image"
        Detail "fix: $(Join-Path $PSScriptRoot 'Code-It-FirstRun.ps1')"
    } elseif (-not (Test-CodeItImageExists $runtime "${image}:latest")) {
        Problem "image $image does not exist"
        Detail "fix: $rebuildCmd"
    } else {
        Ok "image $image exists"
        $imageOk = $true
        # tmux in the container must accept OSC 52 from the agent and pass it on.
        $tmuxConf = (& $runtime run --rm --entrypoint cat "${image}:latest" "$containerHome/.tmux.conf" 2>$null) -join "`n"
        if (-not $tmuxConf) {
            Unknown "could not read ~/.tmux.conf from $image"
        } elseif ($tmuxConf -match '(?m)^\s*set(-option)?\s+(-[a-z]+\s+)*set-clipboard\s+on') {
            Ok "tmux in the image passes the agent's clipboard (OSC 52) on (set-clipboard on)"
        } else {
            Problem "tmux in $image does not pass the agent's clipboard on (no 'set-clipboard on')"
            Detail "fix: rebuild the image: $rebuildCmd -rebuild"
        }
    }
} else {
    Unknown "skipped: no running container runtime"
}

# ---------------------------------------------------------------------------
Section "Save dir"
if (Test-Path $saveDir -PathType Container) { Ok "$saveDir exists" }
else { Warn "$saveDir does not exist yet; code-it will run first-run" }
# opencode's session databases: under opencode-v2/, and the copies a second
# container gets (Spec 12). A corrupt one
# gives "can't create session".
$opencodeDbs = @()
if (Test-Path $saveDir -PathType Container) {
    $opencodeDbs = @(Get-ChildItem -Path $saveDir -Recurse -Force -Filter 'opencode.db' -File -EA Silent |
        Where-Object { ($_.FullName -replace '\\', '/') -like '*/.local/share/opencode/opencode.db' })
}
if ($opencodeDbs.Count -and -not (Get-Command sqlite3 -EA Silent)) {
    Unknown "no sqlite3 on the host to check opencode's database"
} else {
    foreach ($db in $opencodeDbs) {
        $rel = [IO.Path]::GetRelativePath($saveDir, $db.FullName)
        $check = (& sqlite3 $db.FullName 'pragma quick_check;' 2>&1 | Select-Object -First 1)
        if ("$check" -eq 'ok') { Ok "opencode's database passes quick_check: $rel" }
        else {
            Problem "opencode's database fails quick_check: ${rel}: $check"
            Detail "fix: with no code-it running, move $($db.DirectoryName) aside (you may need to log in again)"
        }
    }
}

# ---------------------------------------------------------------------------
Section "Clipboard"

# Which terminal is this? Ask tmux on the host first, as it knows the terminal that is
# attached now, then the variables terminals set (some of which survive into tmux).
$hostTmux = $env:TMUX -and (Get-Command tmux -EA Silent)
$termtype = if ($hostTmux) { "$(tmux display-message -p '#{client_termtype}' 2>$null)" } else { '' }
function Get-Terminal {
    switch -Wildcard ($termtype) {
        'iTerm2*'   { return 'iterm2' }
        'ghostty*'  { return 'ghostty' }
        'WezTerm*'  { return 'wezterm' }
        'kitty*'    { return 'kitty' }
        'xterm.js*' { return 'vscode' }
    }
    switch ($env:TERM_PROGRAM) {
        'iTerm.app'      { return 'iterm2' }
        'ghostty'        { return 'ghostty' }
        'WezTerm'        { return 'wezterm' }
        'vscode'         { return 'vscode' }
        'mintty'         { return 'mintty' }
        'WarpTerminal'   { return 'warp' }
        'Apple_Terminal' { return 'apple-terminal' }
    }
    if ($env:LC_TERMINAL -eq 'iTerm2' -or $env:ITERM_SESSION_ID) { return 'iterm2' }
    if ($env:GHOSTTY_RESOURCES_DIR -or $env:TERM -eq 'xterm-ghostty') { return 'ghostty' }
    if ($env:WEZTERM_PANE) { return 'wezterm' }
    if ($env:KITTY_WINDOW_ID -or $env:TERM -eq 'xterm-kitty') { return 'kitty' }
    if ($env:ALACRITTY_WINDOW_ID -or $env:TERM -eq 'alacritty') { return 'alacritty' }
    if ($env:WT_SESSION) { return 'windows-terminal' }
    return 'unknown'
}
$terminal = Get-Terminal
$configHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }

# The terminal is the last link: it must accept OSC 52.
switch ($terminal) {
    'apple-terminal' {
        Problem "macOS Terminal.app ignores OSC 52, the escape sequence tmux and the agents"
        Detail "use to set the clipboard from the container, so nothing copied there arrives."
        Detail "fix: turn mouse reporting off with View > Allow Mouse Reporting (⌘R), so a drag"
        Detail "makes Terminal.app's own selection, not tmux's; ⌘C, then ⌘R to turn it back on;"
        Detail "or turn tmux's mouse off in the container: Ctrl-B then :set mouse off;"
        Detail "or use a terminal that supports OSC 52: iTerm2, Ghostty, WezTerm or kitty."
    }
    'iterm2' {
        $allowed = if ($onMacOS) { "$(defaults read com.googlecode.iterm2 AllowClipboardAccess 2>$null)" } else { '' }
        if ($allowed -eq '1') {
            Ok "iTerm2 lets applications set the clipboard (AllowClipboardAccess)"
        } elseif ($onMacOS) {
            Problem "iTerm2 is not letting applications set the clipboard, so OSC 52 is ignored"
            Detail "fix: iTerm2 > Settings > General > Selection > tick 'Applications in terminal"
            Detail "may access clipboard', or run, then restart iTerm2:"
            Detail "     defaults write com.googlecode.iterm2 AllowClipboardAccess -bool true"
        } else {
            Unknown "iTerm2 over ssh: tick 'Applications in terminal may access clipboard' in"
            Detail "iTerm2 > Settings > General > Selection on your Mac"
        }
        Detail "tip: hold ⌥ (Option) while dragging to make iTerm2's own selection instead of tmux's"
    }
    'ghostty' {
        $denied = $false
        foreach ($f in @((Join-Path $configHome 'ghostty/config'), (Join-Path $configHome 'ghostty/config.ghostty'),
                         (Join-Path $HOME 'Library/Application Support/com.mitchellh.ghostty/config'),
                         (Join-Path $HOME 'Library/Application Support/com.mitchellh.ghostty/config.ghostty'))) {
            if (-not (Test-Path $f)) { continue }
            if (Select-String -Path $f -Pattern '^\s*clipboard-write\s*=\s*deny' -Quiet) {
                $denied = $true
                Problem "Ghostty's clipboard-write = deny in $f, so OSC 52 is ignored"
                Detail "fix: set clipboard-write = allow in $f, then reload Ghostty's config"
            }
        }
        if (-not $denied) { Ok "Ghostty accepts OSC 52 (clipboard-write is not deny)" }
    }
    'kitty' {
        $conf = Join-Path $configHome 'kitty/kitty.conf'
        $line = if (Test-Path $conf) { Select-String -Path $conf -Pattern '^\s*clipboard_control' | Select-Object -Last 1 } else { $null }
        if ($line -and "$($line.Line)" -notmatch 'write-clipboard') {
            Problem "kitty's clipboard_control in $conf lacks write-clipboard, so OSC 52 is ignored"
            Detail "fix: add write-clipboard to clipboard_control in $conf"
        } else {
            Ok "kitty accepts OSC 52 (clipboard_control allows write-clipboard)"
        }
    }
    'mintty' {
        $rc = Join-Path $HOME '.minttyrc'
        if ((Test-Path $rc) -and (Select-String -Path $rc -Pattern '^\s*AllowSetSelection\s*=\s*(yes|true|1)' -Quiet)) {
            Ok "mintty accepts OSC 52 (AllowSetSelection=yes)"
        } else {
            Problem "mintty ignores OSC 52 unless AllowSetSelection=yes"
            Detail "fix: add AllowSetSelection=yes to ~/.minttyrc, then open a new window"
        }
    }
    { $_ -in @('wezterm', 'alacritty', 'vscode', 'windows-terminal') } {
        Ok "$terminal accepts OSC 52"
    }
    { $_ -in @('warp', 'unknown') } {
        Unknown "terminal '$terminal' (TERM_PROGRAM=$($env:TERM_PROGRAM), TERM=$($env:TERM)): it must accept OSC 52"
        Detail "for copying from the container; the round trip below tests that"
    }
}

# A tmux on the host sees the container as one more application: with its default
# set-clipboard (external) it drops the OSC 52 that arrives from it.
if ($hostTmux) {
    $hostClipboard = "$(tmux show-options -sv set-clipboard 2>$null)"
    if ($hostClipboard -eq 'on') {
        Ok "tmux on the host passes OSC 52 on (set-clipboard on)"
    } else {
        Problem "tmux on the host has set-clipboard $(if ($hostClipboard) { $hostClipboard } else { 'unset' }), so it drops the"
        Detail "container's OSC 52 (it only passes on OSC 52 from applications when 'on')"
        Detail "fix: echo 'set -s set-clipboard on' >> ~/.tmux.conf && tmux source-file ~/.tmux.conf"
    }
    $features = "$(tmux display-message -p '#{client_termfeatures}' 2>$null)"
    if ($features -and $features -notmatch 'clipboard') {
        $clientTerm = "$(tmux display-message -p '#{client_termname}' 2>$null)"
        if (-not $clientTerm) { $clientTerm = '*' }
        Problem "tmux on the host does not think your terminal ($clientTerm) has a clipboard"
        Detail "fix: echo `"set -as terminal-features ',${clientTerm}:clipboard'`" >> ~/.tmux.conf && tmux source-file ~/.tmux.conf"
    }
}
if ($env:STY) {
    Warn "GNU screen on the host does not reliably pass OSC 52 on; run code-it outside"
    Detail "screen, or in tmux with set-clipboard on"
}
$overSsh = [bool]("$($env:SSH_CONNECTION)$($env:SSH_TTY)")
if ($overSsh) {
    Say "  note:    over ssh, the clipboard is your local terminal's; the checks above are"
    Detail "only as good as the variables ssh passed on"
}

# Clipboard round trip: OSC 52 out, the host clipboard tool back in.
function Get-ClipTool {
    if ($onWindows) { return 'windows' }
    if ($onMacOS) { if (Get-Command pbpaste -EA Silent) { return 'pb' } else { return $null } }
    if ($env:WAYLAND_DISPLAY -and (Get-Command wl-paste -EA Silent)) { return 'wl' }
    if ($env:DISPLAY -and (Get-Command xclip -EA Silent)) { return 'xclip' }
    if ($env:DISPLAY -and (Get-Command xsel -EA Silent)) { return 'xsel' }
    return $null
}
$clipTool = Get-ClipTool
function Read-Clip {
    switch ($clipTool) {
        'windows' { return "$(Get-Clipboard -Raw)" }
        'pb'      { return (& pbpaste) -join "`n" }
        'wl'      { return (& wl-paste --no-newline) -join "`n" }
        'xclip'   { return (& xclip -selection clipboard -o) -join "`n" }
        'xsel'    { return (& xsel --clipboard --output) -join "`n" }
    }
}
function Write-Clip([string]$text) {
    switch ($clipTool) {
        'windows' { Set-Clipboard -Value $text }
        'pb'      { $text | & pbcopy }
        'wl'      { $text | & wl-copy }
        'xclip'   { $text | & xclip -selection clipboard -i }
        'xsel'    { $text | & xsel --clipboard --input }
    }
}
# Wait-Clip MARKER: true once the clipboard holds MARKER, polling for ~2s
function Wait-Clip([string]$marker) {
    for ($i = 0; $i -lt 10; $i++) {
        try { if ((Read-Clip) -eq $marker) { return $true } } catch { }
        Start-Sleep -Milliseconds 200
    }
    return $false
}
# Where the escape sequences go: the console. Tests point CODE_IT_DOCTOR_TTY at a file.
$ttyPath = $env:CODE_IT_DOCTOR_TTY
function Send-Osc52([string]$b64) {
    $seq = "$([char]27)]52;c;$b64$([char]7)"
    if ($ttyPath) { Add-Content -Path $ttyPath -Value $seq -NoNewline } else { [Console]::Write($seq) }
}
$interactive = $ttyPath -or (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected)

$runLive = $false
if ($noLiveTest) {
    Say "  skipped: the clipboard round trip (-noLiveTest)"
} elseif ($overSsh) {
    Say "  skipped: the clipboard round trip, as this host's clipboard is not yours over ssh"
} elseif (-not $interactive) {
    Say "  skipped: the clipboard round trip, as there is no terminal"
} elseif (-not $clipTool) {
    Unknown "no clipboard tool on the host to read back; skipped the clipboard round trip"
} elseif ($yes) {
    $runLive = $true
} elseif (-not [Console]::IsInputRedirected) {
    $answer = Read-Host "  Run the clipboard round trip? It briefly replaces your clipboard (text is restored) [Y/n]"
    if ($answer -match '^[nN]') { Say "  skipped: the clipboard round trip" } else { $runLive = $true }
} else {
    Say "  skipped: the clipboard round trip (not interactive; -yes runs it)"
}

function ConvertTo-Base64([string]$s) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }

if ($runLive) {
    $savedClipboard = try { Read-Clip } catch { '' }
    $marker = "code-it-doctor-host-$PID-$(Get-Random -Maximum 32768)"
    Send-Osc52 (ConvertTo-Base64 $marker)
    $hostLive = Wait-Clip $marker
    if ($hostLive) {
        Ok "round trip: OSC 52 from this shell reached the clipboard"
    } else {
        Problem "round trip: OSC 52 from this shell did not reach the clipboard, so your"
        Detail "terminal$(if ($hostTmux) { ' or the tmux on the host' }) ignores it: see the fix above"
    }

    if ($hostLive -and $imageOk) {
        $marker = "code-it-doctor-container-$PID-$(Get-Random -Maximum 32768)"
        $b64 = ConvertTo-Base64 $marker
        # The same path as the agent: an application in tmux, in the container.
        $inner = 'tmux -u new-session "printf ''\033]52;c;' + $b64 + '\007''; sleep 1"'
        Say "  running: $runtime run --rm -it --entrypoint /bin/sh ${image}:latest -c '<tmux, printf OSC 52>'"
        $runArgs = @('run', '--rm', '-it', '--entrypoint', '/bin/sh', "${image}:latest", '-c', $inner)
        if ($ttyPath) { & $runtime @runArgs 2>&1 | Add-Content -Path $ttyPath }
        else { & $runtime @runArgs }
        if (Wait-Clip $marker) {
            Ok "round trip: OSC 52 from tmux in the container reached the clipboard"
            Detail "copying works: in the container, drag to select and tmux copies on release;"
            Detail "an agent's own copy command (Claude Code /copy, opencode's select) works too"
        } else {
            Problem "round trip: your terminal accepts OSC 52, but none arrived from tmux in $image"
            Detail "fix: rebuild the image: $rebuildCmd -rebuild"
            Detail "and if that does not cure it, run: $PSCommandPath -fix 'clipboard from the container'"
        }
    }
    try { Write-Clip "$savedClipboard" } catch { }
}

# ---------------------------------------------------------------------------
Section "Summary"
if ($script:problems -eq 0) { Say "  No problems found." }
else { Say "  $($script:problems) problem(s) found; each PROBLEM above says how to fix it." }

if (-not $fix) {
    if ($script:problems -eq 0) { exit 0 }
    Say "  To have an agent investigate and fix them: $PSCommandPath -fix [PROBLEM]"
    exit 1
}

if (-not $problemText -and $script:problems -eq 0) {
    Write-Host "  Nothing to fix: describe the problem, e.g. $PSCommandPath `"opencode can't create a session`""
    exit 0
}

# ---------------------------------------------------------------------------
# -fix: hand the report to an agent in code-it, working on this repository.
if (-not (Test-Path -Path (Join-Path $repo '.git'))) {
    Write-Warning "'$repo' is not a git repository."
    exit 1
}
$repo = (Resolve-Path $repo).Path
if (-not $branch) { $branch = "doctor/$(Get-Date -Format 'yyyyMMdd-HHmmss')" }

$problemLine = if ($problemText) { $problemText } else { 'none described; fix the problems the doctor found below' }
$prompt = @"
You are diagnosing and fixing a problem with ContainerCodeIt (code-it), the repository
in /work, for a user who ran code-it-doctor on their host.

The user's problem: $problemLine

code-it-doctor's report from the host. You are inside a code-it container and cannot
see the host, so treat this as your evidence about it:
$($script:report.ToString())
"@
$prompt += @'
Investigate:
- Read HumansAndAgents.md, README.md and Specs/ to see how code-it is meant to work.
- You run in a code-it container like the user's: inspect it (tmux and its options,
  the environment, ~/.tmux.conf, ~/go.sh, /etc/code-it-agents, the mounted state)
  to reproduce the problem where you can.
- Decide whether the cause is in this repository (scripts, Dockerfile, definitions)
  or on the host (terminal, container runtime, save dir, settings).

Then:
1. If the fix belongs in this repository, make it, keeping the bash and PowerShell
   scripts in step; add tests, run ./tests/run-all-tests.sh until it passes, and
   commit with a conventional commit message. If code-it-doctor could have detected
   the problem, add that check to code-it-doctor.sh and Code-It-Doctor.ps1, with tests.
2. If the fix is on the host, change nothing for it here; write the exact steps or
   commands for the user to run, and why, to stdout.
3. Finish with a short summary: the cause, what you changed, what the user must do.

Do not push. Work only on the current branch.
'@

$rc = Invoke-CodeItAdder -name 'doctor' -branch $branch -repo $repo -codeIt $codeIt -dryRun $dryRun.IsPresent -prompt $prompt
exit $rc

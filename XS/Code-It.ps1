#! /usr/bin/env pwsh
<#
.SYNOPSIS
    code-it XS: run a coding agent in a container that can see only one directory.

.DESCRIPTION
    Runs OpenCode (default), Claude Code, or another agent added to the Dockerfile,
    in the image built from the Dockerfile next to this script.

    First run (no save dir yet) offers to copy your existing Claude and OpenCode
    config into the save dir, so the containerised agents can use your current logins.

.PARAMETER opencode
    Run OpenCode (the default). Alias: -o
.PARAMETER claude
    Run Claude Code. Alias: -c
.PARAMETER agent
    Run agent NAME, e.g. codex once snippets/codex.dockerfile is added. Alias: -a
.PARAMETER zsh
    Run zsh instead of an agent.
.PARAMETER workDir
    The host directory the agent can see. Default: the current directory. It is
    mounted at /work/<parent>/<name>, so it keeps its name. Alias: -w
.PARAMETER saveDir
    Where agent logins and state are kept. Default: ~/.config/code-it-xs. Alias: -s
.PARAMETER image
    Image to run, built from the Dockerfile here if missing. Default: code-it-xs. Alias: -i
.PARAMETER build
    Build the image even if it exists. Alias: -b
.PARAMETER runtime
    docker, or container (Apple's). Default: container on macOS if installed, else docker. Alias: -r
.PARAMETER locale
    The container's LANG, e.g. en_GB.UTF-8 or en-GB. Default: the host's. Alias: -l
.PARAMETER runArgs
    Arguments passed to `docker run` / `container run`, e.g. -D '-p','8080:3000'.
    Alias: -D. A remaining argument of the form --D:ARG is also passed.
.PARAMETER noWait
    If the agent fails, close at once instead of waiting for Enter.
.PARAMETER dryRun
    Print the commands without running them.
.PARAMETER agentArgs
    Any remaining arguments, or those after --, are passed to the agent. A leading
    one not starting with - is the agent's opening prompt.

.EXAMPLE
    .\Code-It.ps1 'add a README'
.EXAMPLE
    .\Code-It.ps1 -c -workDir ~/my-repo -- --model opus
#>
[CmdletBinding(PositionalBinding = $false)]
param (
    [Alias('o')][switch]$opencode,
    [Alias('c')][switch]$claude,
    [Alias('a')][string]$agent = 'opencode',
    [switch]$zsh,
    [Alias('w')][string]$workDir = '.',
    [Alias('s')][string]$saveDir = "$HOME/.config/code-it-xs",
    [Alias('i')][string]$image = 'code-it-xs',
    [Alias('b')][switch]$build,
    [Alias('r')][string]$runtime = '',
    [Alias('l')][string]$locale = '',
    [Alias('D')][string[]]$runArgs = @(),
    [switch]$noWait,
    [switch]$dryRun,
    [Alias('h')][switch]$help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$agentArgs = @()
)

if ($help) { Get-Help $PSCommandPath -Full; exit 0 }
if ($claude) { $agent = 'claude' }
if ($opencode) { $agent = 'opencode' }
if ($zsh) { $agent = 'zsh' }
$runArgs += @($agentArgs | Where-Object { $_ -like '-D:*' -or $_ -like '--D:*' } | ForEach-Object { $_ -replace '^--?D:', '' })
$agentArgs = @($agentArgs | Where-Object { $_ -notlike '-D:*' -and $_ -notlike '--D:*' })

# Each agent sees only its own state, kept under the save dir. A new agent needs a line here.
$state = switch ($agent) {
    'opencode' { '.config/opencode', '.local/share/opencode', '.local/state/opencode' }
    'claude'   { '.claude', '.claude.json' }
    'codex'    { '.codex' }
    'zsh'      { @() }
    default    { Write-Warning "Unknown agent '$agent': add its state paths to $PSCommandPath"; exit 1 }
}

# A leading bare argument is the opening prompt. OpenCode reads a bare argument as a
# project directory, so it needs --prompt.
if ($agent -eq 'opencode' -and $agentArgs.Count -and -not $agentArgs[0].StartsWith('-')) {
    $agentArgs = @('mini', '--prompt') + $agentArgs
}

if (-not $runtime) {
    $runtime = if ($IsMacOS -and (Get-Command container -EA Ignore)) { 'container' }
               elseif (Get-Command docker -EA Ignore) { 'docker' }
               elseif (Get-Command container -EA Ignore) { 'container' }
    if (-not $runtime) { Write-Warning "No container runtime found: install Docker, or on macOS Apple's container"; exit 1 }
}
if ($runtime -notin 'docker', 'container') { Write-Warning "Unknown runtime '$runtime': use docker or container"; exit 1 }

# The container's LANG: -locale, else the host's culture. en-GB, en_GB.UTF-8 and
# en_GB@rg=gbzzzz all become en_GB.UTF-8.
$lang = (($locale, (Get-Culture).Name | Where-Object { $_ } | Select-Object -First 1) -split '[.@]')[0] -replace '-', '_'
if ($lang -cmatch '^[a-z]{2,3}(_[A-Z]{2})?$') { $lang = "$lang.UTF-8" }
elseif ($locale -and $locale -ne 'C.UTF-8') { Write-Warning "Unknown locale '$locale': use a name like en_GB.UTF-8 or en-GB"; exit 1 }
else { $lang = 'C.UTF-8' }

# Mount the work dir at /work/<parent>/<name>, so agents' per-directory memory sees
# its real name. A ':' would split the -v argument, so it becomes '-'.
if (-not (Test-Path $workDir -PathType Container)) { Write-Warning "Work dir not found: $workDir"; exit 1 }
$workDir = (Resolve-Path $workDir).Path
$parent = [IO.Path]::GetDirectoryName($workDir)
$mount = if (-not $parent) { '/work' }
         elseif (-not [IO.Path]::GetDirectoryName($parent)) { "/work/$([IO.Path]::GetFileName($workDir))" }
         else { "/work/$([IO.Path]::GetFileName($parent))/$([IO.Path]::GetFileName($workDir))" }
$mount = $mount -replace ':', '-'
$saveDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($saveDir)

if (-not $dryRun) {
    # First run: offer to copy the host's agent config into the new save dir.
    if (-not (Test-Path $saveDir)) {
        $answer = Read-Host 'Shall I copy your existing Claude and OpenCode config so that your containerised agents can use your current logins? [y/N]'
        $null = New-Item -ItemType Directory -Force $saveDir
        if ($answer -like 'y*') {
            foreach ($p in '.claude', '.claude.json', '.config/opencode', '.local/share/opencode', '.local/state/opencode') {
                if (-not (Test-Path "$HOME/$p")) { continue }
                $null = New-Item -ItemType Directory -Force (Split-Path "$saveDir/$p")
                Copy-Item -Recurse -Force "$HOME/$p" "$saveDir/$p"
                "    copied ~/$p to $saveDir/$p"
            }
        }
    }
    # Create the agent's state so the mounts work. A missing .json file is created
    # as a file, or the runtime would create a directory in its place.
    foreach ($p in $state) {
        if ($p -like '*.json') { if (-not (Test-Path "$saveDir/$p")) { Set-Content "$saveDir/$p" '{}' } }
        else { $null = New-Item -ItemType Directory -Force "$saveDir/$p" }
    }
}

# Invoke-Run COMMAND...: print it, then run it unless -dryRun
function Invoke-Run {
    '    ' + (($args | ForEach-Object { if ($_ -match '[\s"''$]') { "'$($_ -replace "'", "''")'" } else { $_ } }) -join ' ')
    $exe, $rest = $args
    if (-not $dryRun) { & $exe @rest }
}

& $runtime image inspect $image *> $null
if ($build -or $LASTEXITCODE -ne 0) { Invoke-Run $runtime build -t $image $PSScriptRoot }

$user = ($env:GIT_AUTHOR_NAME, "$(git config --get user.name 2>$null)" | Where-Object { $_ } | Select-Object -First 1)
$email = ($env:GIT_AUTHOR_EMAIL, "$(git config --get user.email 2>$null)" | Where-Object { $_ } | Select-Object -First 1)

$cmd = @($runtime, 'run', '-it', '--rm')
# Apple's container gives too little memory by default for an agent
if ($runtime -eq 'container') { $cmd += '--memory', '3g' }
$cmd += '-e', "CODE_AGENT=$agent", '-e', "CODE_IT_WORK_DIR=$mount", '-e', "LANG=$lang",
        '-e', "GIT_AUTHOR_NAME=Agent1 for $user", '-e', "GIT_AUTHOR_EMAIL=$email",
        '-e', "GIT_COMMITTER_NAME=Agent1 for $user", '-e', "GIT_COMMITTER_EMAIL=$email",
        '-v', "${workDir}:$mount"
if ($noWait) { $cmd += '-e', 'CODE_IT_NO_WAIT=1' }
foreach ($p in $state) { $cmd += '-v', "$saveDir/${p}:/home/agent1/$p" }
$cmd += @($runArgs) + $image + @($agentArgs)
Invoke-Run @cmd

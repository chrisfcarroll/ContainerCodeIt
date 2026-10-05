#! /usr/bin/env pwsh

<#
.SYNOPSIS
    Adds a new coding agent definition to this repository using code-it headless.

.DESCRIPTION
    Runs code-it headless on this repository with a built-in prompt. The in-container
    agent reads the new agent's official documentation, adds agents/<name>/ in the
    format documented in README.md, adds tests, and commits.

    The tool refuses to run if the repository has uncommitted changes, creates the
    branch, runs code-it headless, and prints the branch and a diff summary. It never
    commits to the current branch and never pushes.

.PARAMETER Name
    The agent name to add, e.g. "cursor".

.PARAMETER url
    URL of the agent's official documentation (optional).

.PARAMETER repo
    Repository to add the agent to. Default: this script's directory.

.PARAMETER codeIt
    code-it launcher to invoke. Default: Code-It.ps1 next to this script.

.PARAMETER branch
    Branch to create. Default: add-agent/<name>.

.PARAMETER dryRun
    Print the prompt and the code-it command, and do nothing else.

.EXAMPLE
    .\Code-It-Add-Agent.ps1 cursor --url https://docs.cursor.com/cli
#>

[CmdletBinding(PositionalBinding = $false)]
param (
    [Parameter(Position = 0)]
    [string]$Name         = "",
    [string]$url          = "",
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

if (-not $Name) {
    Write-Warning "Usage: Code-It-Add-Agent.ps1 NAME [-url URL] [-dryRun]"
    exit 1
}
if ($Name -notmatch '^[a-z][a-z0-9-]*$') {
    Write-Warning "'$Name' is not a valid agent name; use lowercase letters, digits and dashes."
    exit 1
}
if (-not $branch) { $branch = "add-agent/$Name" }

if (-not (Test-Path -Path (Join-Path $repo '.git'))) {
    Write-Warning "'$repo' is not a git repository."
    exit 1
}

$prompt = @"
You are adding a new coding agent to this ContainerCodeIt repository.

Agent to add: $Name
"@
if ($url) { $prompt += "`nOfficial documentation URL: $url" }
$prompt += @'

Gate first. Proceed ONLY if that agent is a reasonably well-known coding agent: an
established vendor or a widely used open-source project, actively maintained, with
official documentation and an official install channel. If it is not, stop, write
the reason to stdout, make no changes, and exit non-zero.

If it passes the gate:
1. Read the agent's official documentation: the install method, its binary path in
   the container, its config/state/auth locations, and its CLI flags for opening a
   prompt interactively and for non-interactive (headless) runs.
2. Add agents/<name>/ following the format in README.md ("Agents") and the existing
   agents/opencode and agents/claude:
   - config (key=value): AGENT_NAME, AGENT_SHORT, AGENT_COMMAND, AGENT_BINARY,
     AGENT_INSTALL, AGENT_CONFIG_LABEL, AGENT_STATE_DIRS, AGENT_STATE_FILES and the
     four AGENT_CMD_* prompt-translation templates.
     If its state paths are the same as another agent's (as opencode-v2 shares
     opencode's), also set AGENT_SAVE_SUBDIR so its state is kept separately.
   - install.dockerfile: install from the official channel only, as user agent1,
     pinning versions where possible, keeping a "# last changed YYYY-MM-DD"
     cache-bust line. If the agent binary needs shared libraries the base image
     lacks, add them here (USER root, RUN apk add --no-cache ..., USER agent1):
     the base image installs tools only, not libraries.
   - default-config/: any configuration written on first run, with the layout the
     agent expects under the container home.
3. Add tests to tests/test-code-it.sh and tests/Test-CodeIt.ps1 (prompt translation
   in all modes, mounts, unknown agent), a README row, and completion entries.
4. Run ./tests/run-all-tests.sh and fix any failures.
5. Commit with a conventional commit message.

Do not push. Work only on the current branch.
'@

. "$PSScriptRoot/lib/CodeItCommon.ps1"

# Hand off to the plumbing shared with Code-It-Add-Tool-Chain.ps1.
$rc = Invoke-CodeItAdder -name $Name -branch $branch -repo $repo -codeIt $codeIt -dryRun $dryRun.IsPresent -prompt $prompt
exit $rc

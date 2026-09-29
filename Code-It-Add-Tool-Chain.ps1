#! /usr/bin/env pwsh
<#
.SYNOPSIS
    Adds a new tool chain to this repository using code-it headless.

.DESCRIPTION
    Runs code-it headless on this repository with a built-in prompt. The in-container
    agent applies a security gate, then follows how bun was added, adds tests, and
    commits.

    The tool refuses to run if the repository has uncommitted changes, creates the
    branch, runs code-it headless, and prints the branch and a diff summary. It never
    commits to the current branch and never pushes.

.PARAMETER Name
    The tool chain name to add, e.g. "java".

.PARAMETER url
    URL of the language/runtime's official documentation (optional).

.PARAMETER repo
    Repository to add the tool chain to. Default: this script's directory.

.PARAMETER codeIt
    code-it launcher to invoke. Default: Code-It.ps1 next to this script.

.PARAMETER branch
    Branch to create. Default: add-tool-chain/<name>.

.PARAMETER dryRun
    Print the prompt and the code-it command, and do nothing else.

.EXAMPLE
    .\Code-It-Add-Tool-Chain.ps1 java --url https://openjdk.org/install/
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
    Write-Warning "Usage: Code-It-Add-Tool-Chain.ps1 NAME [-url URL] [-dryRun]"
    exit 1
}
if ($Name -notmatch '^[a-z][a-z0-9-]*$') {
    Write-Warning "'$Name' is not a valid tool chain name; use lowercase letters, digits and dashes."
    exit 1
}
if (-not $branch) { $branch = "add-tool-chain/$Name" }

if (-not (Test-Path -Path (Join-Path $repo '.git'))) {
    Write-Warning "'$repo' is not a git repository."
    exit 1
}

$prompt = @"
You are adding a new tool chain to this ContainerCodeIt repository.

Tool chain to add: $Name
"@
if ($url) { $prompt += "`nOfficial documentation URL: $url" }
$prompt += @'

Gate first. Proceed ONLY if that name is a reasonably well-known language or runtime
AND its tool chain installs securely:
- from Alpine's own repositories, or from the vendor's official HTTPS distribution,
  with checksum or signature verification where one is published;
- ships musl builds for x86_64 and aarch64, or fails the build clearly on
  unsupported architectures;
- actively maintained with security updates.
Otherwise stop, write the reason to stdout, make no changes, and exit non-zero.

If it passes the gate, follow how the existing tool chains are defined as data:
1. Add a toolchains/<name>/ definition, exactly like the existing ones. Do not edit
   the Dockerfile, Code-It-Build or the shared library: definitions are discovered
   from the directory.
   - toolchains/<name>/install.dockerfile: a root-run, self-contained install layer
     with a "# last changed YYYY-MM-DD" cache-bust line, plus its own passwordless
     doas permit appended to /etc/doas.d/doas.conf.
   - toolchains/<name>/config: TOOLCHAIN_INSTALL=install.dockerfile,
     TOOLCHAIN_DETECT=<host command(s), colon-separated>,
     TOOLCHAIN_ALIASES=<space-separated aliases, if any>, and
     TOOLCHAIN_PACKAGE_CACHE=<implied package cache, if any>.
2. Add completions (bash, zsh, PowerShell) and the README tables and "Toolchains"
   section.
3. If the tool chain has a package manager with a well-known global cache, add a
   package-caches/<name>/ definition: find the host cache (environment variable,
   then config, then default path, as NuGet does), mount it read-only at
   ~/.<name>-host, and either seed the container's writable cache from it (as npm
   and bun do in go.sh) or register it as a read-only fallback (as NuGet does).
   Never let the container write to the host cache.
4. Add tests to tests/test-code-it.sh and tests/Test-CodeIt.ps1 mirroring the bun
   ones. Build the image and run the tool chain's --version headlessly.
5. Commit with a conventional commit message.

Do not push. Work only on the current branch.
'@

. "$PSScriptRoot/lib/CodeItCommon.ps1"

# Hand off to the plumbing shared with Code-It-Add-Agent.ps1.
$rc = Invoke-CodeItAdder -name $Name -branch $branch -repo $repo -codeIt $codeIt -dryRun $dryRun.IsPresent -prompt $prompt
exit $rc

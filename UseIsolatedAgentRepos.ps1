#! /usr/bin/env pwsh

<#
.SYNOPSIS
    When dot-sourced, initializes powershell variables and functions in this session 
    to simplify a “very” isolated agent git workflow.
    
    By “very isolated”, we mean, the containerised agent is unable to push or pull. It has
    no access to your upstream origin repo, only to the working directory you give it.

    This script must be dot-sourced to be of any use:

    . ./UseIsolatedAgentRepos.ps1

.DESCRIPTION

    Dot-sourcing this script declares 3 functions:

    updateAgentFromOrigin : run in the agent repo. Brings the agent branch up to date with the origin branch.
    mergeFromAgent        : run in the original repo. Merges the agent branch into the origin branch.
    updateAgentAndDiff    : run in the original repo. Updates the agent branch from origin, then shows the diff.

    Running the script without dot-sourcing it declares the functions in script scope only, where
    they are discarded as soon as the script finishes.

.PARAMETER defaultOriginalBranchName
    The branch name to assume for your own, or feature, branch, when a function is called without one.
    Default: 'main'

.PARAMETER defaultAgentBranchName
    The branch name to assume for the agent's branch, when a function is called without one.
    Default: 'agent1'

.PARAMETER originalReposUnder
    Restrict the directories in which mergeFromAgent and updateAgentAndDiff will run, if this helps to avoid accidents.
    Default: $null. don't check the current path before running mergeFromAgent or updateAgentAndDiff.

.PARAMETER agentReposUnder
    Restrict the directories in which updateAgentFromOrigin will run, if this helps to avoid accidents.
    Default: $null. don't check the current path before running updateAgentFromOrigin

.EXAMPLE

    . ./UseIsolatedAgentRepos.ps1

    Will declare the 3 functions useful for using isolated agent repos, and have them default to assuming
    that your origin or feature branch is main, and your branch for the agent is agent1.

    updateAgentFromOrigin
    mergeFromAgent
    updateAgentAndDiff

.EXAMPLE

    . ./UseIsolatedAgentRepos.ps1 -defaultOriginalBranchName feature-branch-name -defaultAgentBranchName feature-branch-agent-x

    Will declare the 3 functions useful for using isolated agent repos, and have them default to assuming
    that your origin or feature branch is feature-branch-name, and your branch for the agent is feature-branch-agent-x.

    updateAgentFromOrigin
    mergeFromAgent
    updateAgentAndDiff

.EXAMPLE

    . ./UseIsolatedAgentRepos.ps1 -originalReposUnder ~/Repos -agentReposUnder ~/Agents

    Will declare the 3 functions useful for using isolated agent repos and cause them to halt
    if run in an invalid directory

    updateAgentFromOrigin : will only run if current path starts with $agentReposUnder
    mergeFromAgent        : will only run if current path starts with $originalReposUnder
    updateAgentAndDiff    : will only run if current path starts with $originalReposUnder

.NOTES

    This script is not needed to containerise your agents. But is useful to support a workflow
    in which agents have no visibility of your remote repos, only of
    1) the working directory you supply to the container, and
    2) implicit knowledge of the existence of —but no access to— an origin repo,
       which is also a local filesystem hosted working directory.

.LINK
    https://github.com/chrisfcarroll/ContainerCodeIt
#>

[CmdletBinding()]
param (
    [Alias('obranch')]
    [string]$defaultOriginalBranchName = 'main',
    [Alias('abranch')]
    [string]$defaultAgentBranchName = 'agent1',
    [string]$originalReposUnder = $null,
    [string]$agentReposUnder = $null,
    [switch]$help
)

# Handle help request
if ($help) {
    Get-Help $PSCommandPath -Full
    exit 0
}

if($MyInvocation.InvocationName -ne "."){
    Write-Warning "This script defines functions, which only works if you source it:
    
    . ./UseIsolatedAgentRepos.ps1"
}

# Expand ~ and relative paths now, so that the guard clauses can compare them to (Get-Location).Path
if ($originalReposUnder) {
    $originalReposUnder = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($originalReposUnder)
}
if ($agentReposUnder) {
    $agentReposUnder = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($agentReposUnder)
}

function updateAgentFromOrigin(
            [string]$originBranch=$defaultOriginalBranchName,
            [string]$agentBranch="$(git rev-parse --abbrev-ref HEAD)"
)
{
    if( $agentReposUnder -and -not ((Get-Location).Path -ilike "$agentReposUnder*")){
        Write-Error "This command only runs in $agentReposUnder" -ErrorAction Stop
    }
    git fetch --all
    git checkout $originBranch ; git pull --ff-only ; if ($LASTEXITCODE -ne 0) { git pull }
    git checkout $agentBranch
    git merge $originBranch --ff-only ; if ($LASTEXITCODE -ne 0) { git merge $originBranch }
    git push
}

function mergeFromAgent(
        [string]$agentBranch=$defaultAgentBranchName,
        [string]$originBranch="$(git rev-parse --abbrev-ref HEAD)",
        [switch]$pullpushOriginBeforeMerge)
{
    if( $originalReposUnder -and -not ((Get-Location).Path -ilike "$originalReposUnder*")){
        Write-Error "This command only runs in $originalReposUnder" -ErrorAction Stop
    }
    if($pullpushOriginBeforeMerge){ git checkout $originBranch ; git pull ; git push }
    git checkout $originBranch
    git merge $agentBranch --ff-only ; if ($LASTEXITCODE -ne 0) { git merge $agentBranch }
}


function updateAgentAndDiff(
        [string]$agentBranch=$defaultAgentBranchName,
        [string]$originBranch="$(git rev-parse --abbrev-ref HEAD)",
        [switch]$pullpushOriginBeforeMerge)
{
    if( $originalReposUnder -and -not ((Get-Location).Path -ilike "$originalReposUnder*")){
        Write-Error "This command only runs in $originalReposUnder" -ErrorAction Stop
    }
    if($pullpushOriginBeforeMerge){ git checkout $originBranch ; git pull ; git push }
    git checkout $agentBranch ; git merge $originBranch
    git diff $originBranch
    git checkout $originBranch
}

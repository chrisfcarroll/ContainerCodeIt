<#
.SYNOPSIS
    Tab completion for Code-It.ps1, Claude-It.ps1, OpenCode-It.ps1 and
    Code-It-Defaults.ps1.

.DESCRIPTION
    PowerShell already completes the launchers' own parameters (-claude, -prompt,
    -headless, -runtime, ...) from their param block. This adds value completion for
    -agentArgs, the arguments passed straight to the coding agent, offering the flags
    people reach for most:
        https://code.claude.com/docs/en/cli-reference
        https://opencode.ai/docs/cli/
        https://opencode.ai/v2/docs/cli/

    and, for Code-It-Defaults.ps1, the agents to install next to -agent and the
    AGENT= prefix next to -model.

    Dot-source it from your profile:
        . /path/to/ContainerCodeIt/completions/CodeItCompletion.ps1

    Because PowerShell completes anything starting with "-" as a parameter name, agent
    flags complete after an explicit -agentArgs, e.g.
        .\Claude-It.ps1 -agentArgs --mo<TAB>
    Typed without -agentArgs they are still passed through; they just do not complete.

.NOTES
    Add your own favourites to $script:CodeItClaudeArgs / $script:CodeItOpenCodeArgs.
#>

$script:CodeItClaudeArgs = @(
    '--print', '-p', '--continue', '-c', '--resume', '-r', '--fork-session', '--model',
    '--fallback-model', '--effort', '--agent', '--permission-mode',
    '--dangerously-skip-permissions', '--allowed-tools', '--disallowed-tools',
    '--add-dir', '--append-system-prompt', '--settings', '--mcp-config',
    '--output-format', '--max-turns', '--max-budget-usd', '--verbose', '--debug', '--ide',
    'opus', 'sonnet', 'haiku', 'claude-opus-5', 'claude-sonnet-5', 'claude-haiku-4-5',
    'default', 'acceptEdits', 'plan', 'auto', 'dontAsk', 'bypassPermissions', 'manual',
    'low', 'medium', 'high', 'xhigh', 'max', 'text', 'json', 'stream-json'
)

$script:CodeItOpenCodeArgs = @(
    # OpenCode v2, the default `opencode` since v2's GA
    'run', 'mini', '--standalone', '--server', '--model', '--agent', '--prompt',
    '--continue', '-c', '--session', '--format', '--file', '--help', 'text', 'json'
)

$script:CodeItOpenCodeV1Args = @(
    'run', '--continue', '-c', '--session', '-s', '--fork', '--prompt', '--model', '-m',
    '--agent', '--auto', '--port', '--hostname', '--share', '--file', '-f', '--format',
    '--title', '--thinking', '--variant', '--dir', 'default', 'json'
)

$script:CodeItCodexArgs = @(
    # OpenAI Codex: the flags people reach for most
    'exec', 'resume', 'login', 'logout', 'review', 'mcp', '-m', '--model', '-s', '--sandbox',
    '-a', '--ask-for-approval', '-p', '--profile', '-c', '--config', '-C', '--cd',
    '--worktree', '--search', '--add-dir', '-i', '--image', '--oss',
    'gpt-6.1-sol', 'gpt-6-sol', 'gpt-6-luna', 'gpt-6-astra', 'o4-mini',
    'read-only', 'workspace-write', 'danger-full-access', 'on-request', 'never'
)

$codeItCommands = @(
    'Code-It.ps1', './Code-It.ps1', '.\Code-It.ps1',
    'Claude-It.ps1', './Claude-It.ps1', '.\Claude-It.ps1',
    'OpenCode-It.ps1', './OpenCode-It.ps1', '.\OpenCode-It.ps1'
)

Register-ArgumentCompleter -CommandName $codeItCommands -ParameterName agentArgs -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

    # Which agent's flags to offer: the alias script chooses it, -claude/-opencode wins
    $agent = if ("$commandName" -like '*Claude-It*') { 'claude' } else { 'opencode' }
    if ($fakeBoundParameters.ContainsKey('agent') -and $fakeBoundParameters['agent']) { $agent = "$($fakeBoundParameters['agent'])" }
    if ($fakeBoundParameters.ContainsKey('claude'))   { $agent = 'claude' }
    if ($fakeBoundParameters.ContainsKey('opencode')) { $agent = 'opencode' }

    $candidates = if ($agent -eq 'claude') { $script:CodeItClaudeArgs } elseif ($agent -eq 'opencode-v1') { $script:CodeItOpenCodeV1Args } elseif ($agent -eq 'codex') { $script:CodeItCodexArgs } else { $script:CodeItOpenCodeArgs }
    $candidates | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', "$agent $_")
}
}

# Code-It-Defaults.ps1: the agents of its agents/ directory next to -agent, and the
# AGENT= prefix of each next to -model (the model itself is free text: the catalog is
# always incomplete). $PSScriptRoot here is completions/, so the agents/ directory
# next to the scripts is its parent's.
$script:CodeItAgentsDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'agents'
$defaultsScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Code-It-Defaults.ps1'
if (Test-Path -Path $defaultsScript) {
    $script:defaultsCommands = @('Code-It-Defaults.ps1', './Code-It-Defaults.ps1', '.\Code-It-Defaults.ps1')
    Register-ArgumentCompleter -CommandName $script:defaultsCommands -ParameterName agent -ScriptBlock {
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        @($script:CodeItAgentsDir | ForEach-Object { [IO.Directory]::GetDirectories($_) } |
            ForEach-Object { Split-Path $_ -Leaf }) + @('none') |
            Where-Object { $_ -like "$wordToComplete*" } |
            ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
    }
    Register-ArgumentCompleter -CommandName $script:defaultsCommands -ParameterName model -ScriptBlock {
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        @($script:CodeItAgentsDir | ForEach-Object { [IO.Directory]::GetDirectories($_) } |
            ForEach-Object { "$((Split-Path $_ -Leaf))='model'" }) |
            Where-Object { $_ -like "$wordToComplete*" } |
            ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
    }
}

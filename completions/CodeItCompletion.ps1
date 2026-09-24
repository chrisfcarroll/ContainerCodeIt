<#
.SYNOPSIS
    Tab completion for Code-It.ps1, Claude-It.ps1 and OpenCode-It.ps1.

.DESCRIPTION
    PowerShell already completes the launchers' own parameters (-claude, -prompt,
    -headless, -runtime, ...) from their param block. This adds value completion for
    -agentArgs, the arguments passed straight to the coding agent, offering the flags
    people reach for most:
        https://code.claude.com/docs/en/cli-reference
        https://opencode.ai/docs/cli/

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
    'run', '--continue', '-c', '--session', '-s', '--fork', '--prompt', '--model', '-m',
    '--agent', '--auto', '--port', '--hostname', '--share', '--file', '-f', '--format',
    '--title', '--thinking', '--variant', '--dir', 'default', 'json'
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
    if ($fakeBoundParameters.ContainsKey('claude'))   { $agent = 'claude' }
    if ($fakeBoundParameters.ContainsKey('opencode')) { $agent = 'opencode' }

    $candidates = if ($agent -eq 'claude') { $script:CodeItClaudeArgs } else { $script:CodeItOpenCodeArgs }
    $candidates | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', "$agent $_")
    }
}


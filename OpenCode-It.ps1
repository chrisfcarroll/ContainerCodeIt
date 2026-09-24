# Alias for: Code-It.ps1 -opencode
# Arguments are passed through, including a prompt and any OpenCode flags:
#     ./OpenCode-It.ps1 "explain this repo"
#     ./OpenCode-It.ps1 -headless "run the tests" --model anthropic/claude-sonnet-5   # one-shot
& "$PSScriptRoot/Code-It.ps1" -opencode @args
exit $LASTEXITCODE

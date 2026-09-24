# Alias for: Code-It.ps1 -claude
# Arguments are passed through, including a prompt and any Claude Code flags:
#     ./Claude-It.ps1 "explain this repo"
#     ./Claude-It.ps1 -headless "run the tests" --max-turns 5   # one-shot, then exits
& "$PSScriptRoot/Code-It.ps1" -claude @args
exit $LASTEXITCODE

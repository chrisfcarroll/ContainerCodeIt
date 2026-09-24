#!/usr/bin/env bash
# Alias for: code-it.sh --claude
# Arguments are passed through, including a prompt and, after --, Claude Code flags:
#     ./claude-it.sh "explain this repo"
#     ./claude-it.sh --headless "run the tests" -- --max-turns 5
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/code-it.sh" --claude "$@"

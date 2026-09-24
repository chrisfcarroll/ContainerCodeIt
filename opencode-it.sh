#!/usr/bin/env bash
# Alias for: code-it.sh --opencode
# Arguments are passed through, including a prompt and, after --, OpenCode flags:
#     ./opencode-it.sh "explain this repo"
#     ./opencode-it.sh --headless "run the tests" -- --model anthropic/claude-sonnet-5
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/code-it.sh" --opencode "$@"

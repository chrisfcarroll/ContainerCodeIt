#!/usr/bin/env bash
# Alias for: code-it.sh --claude
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/code-it.sh" --claude "$@"

#!/usr/bin/env bash
# Runs the bash test suite, then the PowerShell test suite (if pwsh is available).
set -uo pipefail

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
rc=0

echo "=== bash: test-code-it.sh ==="
bash "$tests_dir/test-code-it.sh" || rc=1

# Find a pwsh that actually runs on this machine (e.g. /usr/bin/pwsh may be for
# the wrong architecture; a dotnet global tool install may work instead).
pwsh_bin=""
for candidate in pwsh "$HOME/.local/bin/pwsh" "$HOME/.dotnet/tools/pwsh"; do
    if command -v "$candidate" &>/dev/null && "$candidate" -NoProfile -Command 'exit 0' &>/dev/null; then
        pwsh_bin="$candidate"
        break
    fi
done

if [[ -n "$pwsh_bin" ]]; then
    echo
    echo "=== pwsh: Test-CodeIt.ps1 (using $pwsh_bin) ==="
    "$pwsh_bin" -NoProfile -File "$tests_dir/Test-CodeIt.ps1" || rc=1
else
    echo "No working pwsh found: skipping PowerShell tests"
fi

exit $rc

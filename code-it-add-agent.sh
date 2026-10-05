#!/usr/bin/env bash
#
# Adds a new coding agent definition to this repository by running code-it headless
# with a built-in prompt. The in-container agent reads the new agent's official docs,
# adds agents/<name>/ in the format documented in README.md, adds tests, and commits.
#
# Usage:
#   ./code-it-add-agent.sh NAME [OPTIONS]
#
# Options:
#   --url URL         URL of the agent's official documentation (optional; the agent
#                     will otherwise search for it).
#   --repo DIR        Repository to add the agent to. Default: this script's directory.
#   --code-it PATH    code-it launcher to invoke. Default: ./code-it.sh next to this
#                     script. Mainly useful for testing.
#   --branch NAME     Branch to create. Default: add-agent/<name>.
#   --dry-run, -d     Print the prompt and the code-it command, and do nothing else.
#   --help, -h        Show this help message.
#
# The tool refuses to run if the repository has uncommitted changes, creates the
# branch, runs code-it headless with the prompt, and prints the branch and a diff
# summary at the end. It never commits to the current branch and never pushes.

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/code-it-common.sh
. "$script_dir/lib/code-it-common.sh"

name=""
url=""
repo="$script_dir"
code_it="$script_dir/code-it.sh"
branch=""
dry_run=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)
            url="$2"
            shift 2
            ;;
        --repo)
            repo="$2"
            shift 2
            ;;
        --code-it)
            code_it="$2"
            shift 2
            ;;
        --branch)
            branch="$2"
            shift 2
            ;;
        --dry-run|-d)
            dry_run=true
            shift
            ;;
        --help|-h)
            sed -n '2,/^$/{ s/^# \{0,1\}//; p; }' "$0"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Run $0 --help for usage." >&2
            exit 1
            ;;
        *)
            if [[ -n "$name" ]]; then
                echo "Only one agent name can be given." >&2
                exit 1
            fi
            name="$1"
            shift
            ;;
    esac
done

if [[ -z "$name" ]]; then
    echo "Usage: $0 NAME [--url URL] [--dry-run]" >&2
    exit 1
fi

if [[ ! "$name" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "Warning: '$name' is not a valid agent name; use lowercase letters, digits and dashes." >&2
    exit 1
fi

if [[ -z "$branch" ]]; then
    branch="add-agent/$name"
fi

if [[ ! -d "$repo/.git" && ! -f "$repo/.git" ]]; then
    echo "Warning: '$repo' is not a git repository." >&2
    exit 1
fi
repo=$(cd "$repo" && pwd)

# Build the prompt for the in-container agent.
url_line=""
if [[ -n "$url" ]]; then
    url_line="Official documentation URL: $url"
fi
prompt=$(cat <<EOF
You are adding a new coding agent to this ContainerCodeIt repository.

Agent to add: $name
$url_line

Gate first. Proceed ONLY if that agent is a reasonably well-known coding agent: an
established vendor or a widely used open-source project, actively maintained, with
official documentation and an official install channel. If it is not, stop, write
the reason to stdout, make no changes, and exit non-zero.

If it passes the gate:
1. Read the agent's official documentation: the install method, its binary path in
   the container, its config/state/auth locations, and its CLI flags for opening a
   prompt interactively and for non-interactive (headless) runs.
2. Add agents/$name/ following the format in README.md ("Agents") and the existing
   agents/opencode and agents/claude:
   - config (key=value): AGENT_NAME, AGENT_SHORT, AGENT_COMMAND, AGENT_BINARY,
     AGENT_INSTALL, AGENT_CONFIG_LABEL, AGENT_STATE_DIRS, AGENT_STATE_FILES and the
     four AGENT_CMD_* prompt-translation templates.
     If its state paths are the same as another agent's (as opencode-v2 shares
     opencode's), also set AGENT_SAVE_SUBDIR so its state is kept separately.
   - install.dockerfile: install from the official channel only, as user agent1,
     pinning versions where possible, keeping a "# last changed YYYY-MM-DD"
     cache-bust line. If the agent binary needs shared libraries the base image
     lacks, add them here (USER root, RUN apk add --no-cache ..., USER agent1):
     the base image installs tools only, not libraries.
   - default-config/: any configuration written on first run, with the layout the
     agent expects under the container home.
3. Add tests to tests/test-code-it.sh and tests/Test-CodeIt.ps1 (prompt translation
   in all modes, mounts, unknown agent), a README row, and completion entries.
4. Run ./tests/run-all-tests.sh and fix any failures.
5. Commit with a conventional commit message.

Do not push. Work only on the current branch.
EOF
)

ci_add_via_code_it "$name" "$branch" "$repo" "$code_it" "$dry_run" "$prompt" && exit 0
rc=$?
exit "$rc"

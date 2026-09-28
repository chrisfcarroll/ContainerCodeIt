#!/usr/bin/env bash
#
# Adds a new tool chain to this repository by running code-it headless with a built-in
# prompt. The in-container agent applies a security gate, then follows how bun was
# added, adds tests, and commits.
#
# Usage:
#   ./code-it-add-tool-chain.sh NAME [OPTIONS]
#
# Options:
#   --url URL         URL of the language/runtime's official documentation (optional).
#   --repo DIR        Repository to add the tool chain to. Default: this script's directory.
#   --code-it PATH    code-it launcher to invoke. Default: ./code-it.sh next to this
#                     script. Mainly useful for testing.
#   --branch NAME     Branch to create. Default: add-tool-chain/<name>.
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
                echo "Only one tool chain name can be given." >&2
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
    echo "Warning: '$name' is not a valid tool chain name; use lowercase letters, digits and dashes." >&2
    exit 1
fi

if [[ -z "$branch" ]]; then
    branch="add-tool-chain/$name"
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
You are adding a new tool chain to this ContainerCodeIt repository.

Tool chain to add: $name
$url_line

Gate first. Proceed ONLY if that name is a reasonably well-known language or runtime
AND its tool chain installs securely:
- from Alpine's own repositories, or from the vendor's official HTTPS distribution,
  with checksum or signature verification where one is published;
- ships musl builds for x86_64 and aarch64, or fails the build clearly on
  unsupported architectures;
- actively maintained with security updates.
Otherwise stop, write the reason to stdout, make no changes, and exit non-zero.

If it passes the gate, follow how bun was added (commit 49b3ee7) as the template:
1. Dockerfile: declare ARG <UPPER>=false, normalise it into /etc/code-it-tech.env,
   add an install layer guarded by it, and a minimal passwordless doas permit.
2. Add the known name and any aliases to the shared library (lib/code-it-common.sh
   and lib/CodeItCommon.ps1), so code-it-build, code-it and image naming all pick it
   up.
3. Add completions (bash, zsh, PowerShell) and the README tables and "Toolchains"
   section.
4. If the tool chain has a package manager with a well-known global cache, add it to
   --package-caches: find the host cache (environment variable, then config, then
   default path, as NuGet does), mount it read-only at ~/.<name>-host, and either
   seed the container's writable cache from it (as npm and bun do in go.sh) or
   register it as a read-only fallback (as NuGet does). Never let the container write
   to the host cache.
5. Add tests to tests/test-code-it.sh and tests/Test-CodeIt.ps1 mirroring the bun
   ones. Build the image and run the tool chain's --version headlessly.
6. Commit with a conventional commit message.

Do not push. Work only on the current branch.
EOF
)

ci_add_via_code_it "$name" "$branch" "$repo" "$code_it" "$dry_run" "$prompt" && exit 0
rc=$?
exit "$rc"

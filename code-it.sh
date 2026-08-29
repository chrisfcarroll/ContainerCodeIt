#!/usr/bin/env bash
#
# Launches a container with Alpine Linux, Claude Code AND OpenCode, and .NET development tools.
#
# Picks a container runtime automatically:
# - On macOS, uses the Apple container CLI (container) if installed
# - Otherwise uses Docker if installed
# - Otherwise suggests the best runtime to install for the current platform
# Use --runtime to force one.
#
# Creates and runs a container for development using Claude Code or OpenCode as an agent.
# The script recognises:
# - Volume mounts for code repositories and agent configuration
# - Git author environment variables or config settings (name and email)
# - Paths to preserve agent credentials, settings, and session data across container runs
# - Port mappings
#
# Usage:
#   ./code-it.sh [OPTIONS]
#
# Options:
#   --opencode, -o           Run OpenCode in the container (default).
#   --claude, -c             Run Claude Code in the container.
#   --work-dir DIR           Host directory path to mount as /repos in the container.
#                            Defaults to "."
#   --save-dir DIR           Host directory for storing agent configuration and state volumes.
#                            Created if missing. Defaults to ~/.config/code-it
#   --image NAME             Image name to run. Default: "code-it-alpine-dotnet"
#   --build-image            If specified, builds the image from the Dockerfile before running.
#   --dockerfile-dir DIR     Directory containing the Dockerfile. Used with --build-image.
#                            Defaults to this script's own directory.
#   --runtime NAME           Container runtime to use: "docker" or "container".
#                            Default: auto-detected as described above.
#   --ports PORT1 PORT2      Port mappings in "host:container" format. Default: "0:3000" "0:3001"
#                            for docker (0 auto-assigns a free host port), "3000:3000" "3001:3001"
#                            for the Apple container runtime.
#                            Maximum of 2 port mappings supported; additional mappings are ignored.
#   --agent-name NAME        Name of the agent running in the container. Used for Git author
#                            attribution and home directory naming. Must match the USER set in
#                            the Dockerfile. Default: "Agent1"
#   --dry-run                Print the run command without executing it.
#   --help                   Show this help message.
#
# Examples:
#   ./code-it.sh [-o]
#       Runs OpenCode in the default container mounting the current directory.
#
#   ./code-it.sh --claude --work-dir ~/my-repos
#       Runs Claude Code in the default container with a custom work directory.
#
#   ./code-it.sh --build-image
#       Builds the image from the Dockerfile next to this script, then runs it.
#
#   ./code-it.sh --ports "8000:3000" "8001:3001"
#       Runs the container with custom port mappings.
#
# Notes:
#   - Git author name and email are automatically captured from environment or git config
#   - Volume mounts preserve both Claude and OpenCode state between container runs, so you
#     can destroy the container and create a new one without logging in again
#   - Alternatively, use ANTHROPIC_API_KEY (claude) or a provider API key env var (opencode)
#     to avoid volume mounts for credentials
#
#   What each mount preserves:
#   ┌──────────────────────────┬────────────────────────────────────────────────────────────────┐
#   │          Mount           │                            Contains                            │
#   ├──────────────────────────┼────────────────────────────────────────────────────────────────┤
#   │ ~/.claude/               │ Credentials (.credentials.json), settings, permissions, memory │
#   ├──────────────────────────┼────────────────────────────────────────────────────────────────┤
#   │ ~/.claude.json           │ OAuth session data, MCP configs, theme/editor preferences      │
#   ├──────────────────────────┼────────────────────────────────────────────────────────────────┤
#   │ ~/.local/share/opencode/ │ OpenCode data and auth (auth.json, etc.)                       │
#   └──────────────────────────┴────────────────────────────────────────────────────────────────┘

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Absolute path of an existing directory, without realpath (absent on older macOS)
abs_dir() { (CDPATH= cd -- "$1" && pwd); }

# Defaults
code_agent="opencode"
work_dir_to_mount="."
save_dir="$HOME/.config/code-it"
image="code-it-alpine-dotnet"
build_image=false
dockerfile_dir="$script_dir"
runtime=""
ports=()
agent_name="Agent1"
dry_run=false
container_args=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --claude|-c)
            code_agent="claude"
            shift
            ;;
        --opencode|-o)
            code_agent="opencode"
            shift
            ;;
        --work-dir)
            work_dir_to_mount="$2"
            shift 2
            ;;
        --save-dir)
            save_dir="$2"
            shift 2
            ;;
        --image)
            image="$2"
            shift 2
            ;;
        --build-image)
            build_image=true
            shift
            ;;
        --dockerfile-dir)
            dockerfile_dir="$2"
            shift 2
            ;;
        --runtime)
            runtime="$2"
            shift 2
            ;;
        --ports)
            ports=()
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                ports+=("$1")
                shift
            done
            ;;
        --agent-name)
            agent_name="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        --help|-h)
            sed -n '2,/^$/{ s/^# \{0,1\}//; p; }' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run $0 --help for usage." >&2
            exit 1
            ;;
    esac
done

# Detect / validate the container runtime (after parsing, so --runtime is honoured).
# On macOS prefer the Apple container CLI if present; otherwise use docker if present;
# otherwise suggest what is best for the current platform.
platform=$(uname -s)
case "$runtime" in
    "")
        if [[ "$platform" == "Darwin" ]] && command -v container &>/dev/null; then
            runtime="container"
        elif command -v docker &>/dev/null; then
            runtime="docker"
        elif command -v container &>/dev/null; then
            runtime="container"
        else
            echo "Warning: No container runtime found." >&2
            case "$platform" in
                Darwin)
                    echo "On macOS, the best options are:" >&2
                    echo "  - Apple container CLI (native, lightweight):" >&2
                    echo "      https://github.com/apple/container/blob/main/docs/tutorials/start-here.md" >&2
                    echo "  - Docker Desktop: https://docs.docker.com/desktop/setup/install/mac-install/" >&2
                    ;;
                Linux)
                    echo "On Linux, the best option is Docker Engine:" >&2
                    echo "      https://docs.docker.com/engine/install/" >&2
                    echo "  e.g. Debian/Ubuntu: sudo apt-get install docker.io" >&2
                    echo "       Alpine:        doas apk add docker" >&2
                    echo "       Fedora:        sudo dnf install docker" >&2
                    ;;
                MINGW*|MSYS*|CYGWIN*)
                    echo "On Windows, the best option is Docker Desktop with WSL2:" >&2
                    echo "      https://docs.docker.com/desktop/setup/install/windows-install/" >&2
                    ;;
                *)
                    echo "On $platform, try Docker: https://docs.docker.com/engine/install/" >&2
                    ;;
            esac
            exit 1
        fi
        ;;
    docker|container)
        if ! command -v "$runtime" &>/dev/null; then
            echo "Warning: Requested runtime '$runtime' not found. Please install it and ensure it is in your PATH." >&2
            exit 1
        fi
        ;;
    *)
        echo "Warning: Unknown runtime '$runtime'. Valid values are 'docker' or 'container'." >&2
        exit 1
        ;;
esac
# Give the Apple container runtime enough memory for the agent to work with
if [[ "$runtime" == "container" ]]; then
    container_args="--memory 2g"
fi
echo "    Using container runtime: $runtime"
echo "    Using code agent: $code_agent"

# Ensure required commands
if ! command -v git &>/dev/null; then
    echo "Warning: Git command not found. Please install Git and ensure it is in your PATH." >&2
    exit 1
fi

# Default ports per runtime: docker supports host port 0 = auto-assign a free port
if [[ ${#ports[@]} -eq 0 ]]; then
    if [[ "$runtime" == "docker" ]]; then
        ports=("0:3000" "0:3001")
    else
        ports=("3000:3000" "3001:3001")
    fi
fi

# Ensure required paths exist
if [[ ! -d "$work_dir_to_mount" ]]; then
    echo "Warning: work-dir directory does not exist: $work_dir_to_mount." >&2
    echo "Please specify a directory where you have a git repo, or repos, you want the agent to work on." >&2
    exit 1
fi
work_dir_to_mount=$(abs_dir "$work_dir_to_mount")

# Create the save dir structure so mounts always work, even on first run.
# The .claude.json mount is a single file: pre-create it so the runtime does not
# create a directory in its place.
mkdir -p "$save_dir/.claude" "$save_dir/.local/share/opencode"
[[ -f "$save_dir/.claude.json" ]] || echo '{}' > "$save_dir/.claude.json"
save_dir=$(abs_dir "$save_dir")

echo "    Checking $image ..."

# List existing images in a runtime-appropriate way
if [[ "$runtime" == "docker" ]]; then
    valid_images=$(docker images --format "{{.Repository}}:{{.Tag}}")
else
    valid_images=$(container image ls)
fi

if [[ "$build_image" == true ]]; then
    if [[ ! -f "$dockerfile_dir/Dockerfile" ]]; then
        echo "Warning: You asked for --build-image, but Dockerfile not found at: $dockerfile_dir/Dockerfile" >&2
        exit 1
    fi
    dockerfile_dir=$(abs_dir "$dockerfile_dir")
elif ! echo "$valid_images" | grep -qE "^${image}([: ]|$)"; then
    echo "Warning: $runtime image '$image' does not exist and --build-image was not specified." >&2
    echo "Either build the image with the --build-image flag or ensure the image is available locally." >&2
    exit 1
fi

# Git author info
agent_name_lower=$(echo "$agent_name" | tr '[:upper:]' '[:lower:]')
on_behalf_of="${GIT_AUTHOR_NAME:-${GIT_COMMITTER_NAME:-$(git config --get user.name 2>/dev/null || echo "")}}"
git_author_name="$agent_name for $on_behalf_of"
git_author_email="${GIT_AUTHOR_EMAIL:-$(git config --get user.email 2>/dev/null || echo "")}"

# Build image if requested
if [[ "$build_image" == true ]]; then
    "$runtime" build -t "${image}:latest" "$dockerfile_dir"
fi

# Handle port mappings
if [[ ${#ports[@]} -gt 2 ]]; then
    echo "Warning: This script only handles two port mappings. Extra mappings will be ignored." >&2
fi

# Ensure at least 2 port mappings (docker: 0 auto-assigns a free host port;
# the Apple container runtime needs fixed ports)
if [[ "$runtime" == "docker" ]]; then
    pad_ports=("0:3000" "0:3001")
else
    pad_ports=("3000:3000" "3001:3001")
fi
while [[ ${#ports[@]} -lt 2 ]]; do
    ports+=("${pad_ports[${#ports[@]}]}")
done

# Print the command
cat <<EOF
    $runtime run -it --rm -p ${ports[0]} -p ${ports[1]} \\
                $container_args \\
                -e CODE_AGENT="$code_agent" \\
                -e GIT_AUTHOR_NAME="$git_author_name" \\
                -e GIT_AUTHOR_EMAIL="$git_author_email" \\
                -v "$work_dir_to_mount:/repos" \\
                -v "$save_dir/.claude:/home/$agent_name_lower/.claude" \\
                -v "$save_dir/.claude.json:/home/$agent_name_lower/.claude.json" \\
                -v "$save_dir/.local/share/opencode:/home/$agent_name_lower/.local/share/opencode" \\
            ${image}:latest
EOF

if [[ "$dry_run" == true ]]; then
    exit 0
fi

"$runtime" run -it --rm -p "${ports[0]}" -p "${ports[1]}" \
            $container_args \
            -e CODE_AGENT="$code_agent" \
            -e GIT_AUTHOR_NAME="$git_author_name" \
            -e GIT_AUTHOR_EMAIL="$git_author_email" \
            -v "$work_dir_to_mount:/repos" \
            -v "$save_dir/.claude:/home/$agent_name_lower/.claude" \
            -v "$save_dir/.claude.json:/home/$agent_name_lower/.claude.json" \
            -v "$save_dir/.local/share/opencode:/home/$agent_name_lower/.local/share/opencode" \
    "${image}:latest"

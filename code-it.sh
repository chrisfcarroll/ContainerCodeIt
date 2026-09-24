#!/usr/bin/env bash
#
# Launches an Alpine Linux container with OpenCode, Claude Code, and .NET development tools.
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
# - The host's NuGet package cache, mounted read-only as a fallback package folder
# - Port mappings
#
# Usage:
#   ./code-it.sh [OPTIONS] [PROMPT] [-- AGENT-ARGS...]
#
# Options:
#   --opencode, -o           Run OpenCode in the container (default).
#   --claude, -c             Run Claude Code in the container.
#   --prompt TEXT            Open the agent with TEXT as its first prompt. A single bare
#                            argument means the same thing, so these are equivalent:
#                              ./code-it.sh -c --prompt "explain this repo"
#                              ./code-it.sh -c "explain this repo"
#   --headless               Run the agent in the foreground rather than in tmux, with no
#                            TTY allocated. With --prompt the agent answers, exits, and the
#                            container shuts down, exiting with the agent's exit code.
#   -- AGENT-ARGS...         Everything after -- is passed to the coding agent verbatim,
#                            e.g. -- --model opus --continue. See
#                              https://code.claude.com/docs/en/cli-reference
#                              https://opencode.ai/docs/cli/
#   --work-dir DIR           Host directory path to mount as /work in the container.
#                            Defaults to "."
#   --save-dir DIR           Host directory for storing agent configuration and state volumes.
#                            Created if missing. Defaults to ~/.config/code-it
#   --image NAME             Image name to run. Default: "code-it-alpine-dotnet"
#   --build-image            If specified, builds the image from the Dockerfile before running.
#   --rebuild-image          Like --build-image, but first updates the "# last changed"
#                            cache-bust dates in the Dockerfile to today, forcing the
#                            agent install layers to rerun so the agents are updated.
#   --dockerfile-dir DIR     Directory containing the Dockerfile. Used with --build-image.
#                            Defaults to this script's own directory.
#   --runtime NAME           Container runtime to use: "docker" or "container".
#                            Default: auto-detected as described above.
#   --ports PORT1 PORT2      Port mappings in "host:container" format. Default: "0:3000" "0:3001"
#                            for docker (0 auto-assigns a free host port), "3000:3000" "3001:3001"
#                            for the Apple container runtime.
#                            Maximum of 2 port mappings supported; additional mappings are ignored.
#                            --ports consumes every following non-option argument, so give a
#                            bare PROMPT before it, or use --prompt.
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
#   ./code-it.sh -c "explain this repo"
#       Opens Claude Code with that opening prompt, and stays interactive.
#
#   ./code-it.sh -c --headless "run the tests and fix any failures"
#       Runs Claude Code headlessly: the agent works, prints its answer, and the
#       container shuts down.
#
#   ./code-it.sh -c -- --continue --model opus
#       Passes those flags straight through to Claude Code.
#
# Notes:
#   - The prompt and any pass-through arguments are translated into each agent's own
#     command line: --prompt becomes `claude PROMPT` or `opencode --prompt PROMPT`, and
#     with --headless it becomes `claude -p PROMPT` or `opencode run PROMPT`
#   - Git author name and email are automatically captured from environment or git config
#   - Volume mounts preserve both Claude and OpenCode state between container runs, so you
#     can destroy the container and create a new one without logging in again
#   - Alternatively, use ANTHROPIC_API_KEY (claude) or a provider API key env var (opencode)
#     to avoid volume mounts for credentials
#   - If a NuGet package cache is found on the host, it is mounted read-only at
#     ~/.nuget/packages-host, which the image's NuGet.Config registers as a fallback
#     package folder: restores reuse host-cached packages, and the container can
#     never write to the host cache. Looked up, in order, from: the NUGET_PACKAGES
#     environment variable, the globalPackagesFolder setting in the user-level
#     NuGet.Config, and the default ~/.nuget/packages
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

# The globalPackagesFolder value in a NuGet.Config's <config> section, like an XML
# parser would read it: ignores comments; attributes in any order, with either quote.
nuget_config_global_packages_folder() {
    awk '
        function attr(el, name,    v) {
            if (!match(el, "[ \t\n]" name "[ \t\n]*=[ \t\n]*(\"[^\"]*\"|\047[^\047]*\047)")) return ""
            v = substr(el, RSTART, RLENGTH)
            v = substr(v, index(v, "=") + 1)
            sub(/^[ \t\n]*/, "", v)
            return substr(v, 2, length(v) - 2)
        }
        { sub(/\r$/, ""); doc = doc $0 "\n" }
        END {
            while ((i = index(doc, "<!--")) > 0) {
                j = index(substr(doc, i + 4), "-->")
                doc = substr(doc, 1, i - 1) (j ? substr(doc, i + j + 6) : "")
            }
            if (!match(doc, /<config[ \t\n]*>/)) exit
            doc = substr(doc, RSTART + RLENGTH)
            if ((i = index(doc, "</config>")) > 0) doc = substr(doc, 1, i - 1)
            while (match(doc, /<add[ \t\n][^>]*>/)) {
                el = substr(doc, RSTART, RLENGTH)
                doc = substr(doc, RSTART + RLENGTH)
                if (tolower(attr(el, "key")) != "globalpackagesfolder") continue
                v = attr(el, "value")
                gsub(/&lt;/, "<", v); gsub(/&gt;/, ">", v)
                gsub(/&quot;/, "\"", v); gsub(/&apos;/, "\047", v); gsub(/&amp;/, "\\&", v)
                print v
                exit
            }
        }
    ' "$1"
}

# Defaults
code_agent="opencode"
work_dir_to_mount="."
save_dir="$HOME/.config/code-it"
image="code-it-alpine-dotnet"
build_image=false
rebuild_image=false
dockerfile_dir="$script_dir"
runtime=""
ports=()
agent_name="Agent1"
dry_run=false
container_args=""
prompt=""
prompt_set=false
headless=false
agent_args=()

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
        --rebuild-image)
            build_image=true
            rebuild_image=true
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
        --prompt)
            prompt="$2"
            prompt_set=true
            shift 2
            ;;
        --headless)
            headless=true
            shift
            ;;
        --)
            shift
            agent_args=("$@")
            break
            ;;
        --dry-run)
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
            # A bare argument is the agent's opening prompt
            if [[ "$prompt_set" == true ]]; then
                echo "Only one prompt can be given; use --prompt, or -- to pass arguments to the agent." >&2
                exit 1
            fi
            prompt="$1"
            prompt_set=true
            shift
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
    container_args="--memory 3g"
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
    valid_images=$(docker images --format "{{.Repository}}:{{.Tag}}") || images_rc=$?
else
    valid_images=$(container image ls) || images_rc=$?
fi
if [[ "${images_rc:-0}" != 0 ]]; then
    echo "Warning: Could not list $runtime images. Is the $runtime daemon or service running?" >&2
    exit 1
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
# Git takes the committer only from GIT_COMMITTER_* or user.name/user.email, never from
# GIT_AUTHOR_*, and the container has no user.name/user.email, so the run passes both.
on_behalf_of="${GIT_AUTHOR_NAME:-${GIT_COMMITTER_NAME:-$(git -C "$work_dir_to_mount" config --get user.name 2>/dev/null || echo "")}}"
# Inside an agent container GIT_AUTHOR_NAME is already "<agent> for <you>": keep only <you>
on_behalf_of=$(printf '%s' "$on_behalf_of" | sed -E 's/^([^[:space:]]+ for )+//')
git_author_name="$agent_name for $on_behalf_of"
git_author_email="${GIT_AUTHOR_EMAIL:-$(git -C "$work_dir_to_mount" config --get user.email 2>/dev/null || echo "")}"
if [[ -z "$on_behalf_of" || -z "$git_author_email" ]]; then
    echo "Warning: No git user.name or user.email found for $work_dir_to_mount. The agent will not be able to commit." >&2
    echo "    Set them with: git config --global user.name 'Your Name' ; git config --global user.email you@example.com" >&2
fi

# Locate the user's NuGet global packages cache (if any) to mount read-only.
# Precedence per https://learn.microsoft.com/en-us/nuget/consume-packages/managing-the-global-packages-and-cache-folders :
# the NUGET_PACKAGES environment variable, then the globalPackagesFolder setting in
# the user-level NuGet.Config, then the default ~/.nuget/packages.
nuget_packages=""
if [[ -n "${NUGET_PACKAGES:-}" && -d "$NUGET_PACKAGES" ]]; then
    nuget_packages="$NUGET_PACKAGES"
else
    nuget_configs=("$HOME/.nuget/NuGet/NuGet.Config" "$HOME/.config/NuGet/NuGet.Config")
    if [[ -n "${APPDATA:-}" ]]; then
        nuget_configs=("$APPDATA/NuGet/NuGet.Config" "${nuget_configs[@]}")
    fi
    for nuget_config in "${nuget_configs[@]}"; do
        if [[ -f "$nuget_config" ]]; then
            gpf=$(nuget_config_global_packages_folder "$nuget_config")
            if [[ -n "$gpf" && -d "$gpf" ]]; then
                nuget_packages="$gpf"
                break
            fi
        fi
    done
    if [[ -z "$nuget_packages" && -d "$HOME/.nuget/packages" ]]; then
        nuget_packages="$HOME/.nuget/packages"
    fi
fi

# If a cache was found, mount it read-only; the image's NuGet.Config registers the
# mount point as a fallback package folder, so restores reuse host-cached packages
# and the container can never write to the host cache.
nuget_mount=()
nuget_mount_print=""
if [[ -n "$nuget_packages" ]]; then
    nuget_packages=$(abs_dir "$nuget_packages")
    nuget_mount=(-v "$nuget_packages:/home/$agent_name_lower/.nuget/packages-host:ro")
    nuget_mount_print="
                -v \"$nuget_packages:/home/$agent_name_lower/.nuget/packages-host:ro\" \\"
    echo "    Mounting NuGet package cache read-only: $nuget_packages"
else
    echo "    No NuGet package cache found; restore will use package sources only"
fi

# Build image if requested
if [[ "$build_image" == true ]]; then
    # --rebuild-image: bump the "# last changed" cache-bust dates in the
    # Dockerfile to today, so the agent install layers rebuild and update the agents.
    # (Write to a temp file and move: portable in-place edit for BSD and GNU sed.)
    if [[ "$rebuild_image" == true ]]; then
        today=$(date +%Y-%m-%d)
        sed -E "s/# last changed [0-9]{4}-[0-9]{2}-[0-9]{2}/# last changed $today/" "$dockerfile_dir/Dockerfile" > "$dockerfile_dir/Dockerfile.tmp" \
            && mv "$dockerfile_dir/Dockerfile.tmp" "$dockerfile_dir/Dockerfile"
        echo "    Updated '# last changed' dates in $dockerfile_dir/Dockerfile to $today"
    fi
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

# Translate the prompt, and any -- pass-through arguments, into the chosen agent's own
# command line, which the container entrypoint hands to the agent. See
#   https://code.claude.com/docs/en/cli-reference
#   https://opencode.ai/docs/cli/
agent_cmd=()
if [[ "$code_agent" == "claude" ]]; then
    # claude [flags] [PROMPT], and -p answers the prompt without going interactive
    if [[ "$headless" == true && "$prompt_set" == true ]]; then
        agent_cmd+=(-p)
    fi
    agent_cmd+=(${agent_args[@]+"${agent_args[@]}"})
    if [[ "$prompt_set" == true ]]; then
        agent_cmd+=("$prompt")
    fi
elif [[ "$headless" == true ]]; then
    # opencode run [flags] [MESSAGE] answers without starting the TUI
    agent_cmd+=(run)
    agent_cmd+=(${agent_args[@]+"${agent_args[@]}"})
    if [[ "$prompt_set" == true ]]; then
        agent_cmd+=("$prompt")
    fi
else
    # opencode --prompt MESSAGE opens the TUI with the message already sent
    if [[ "$prompt_set" == true ]]; then
        agent_cmd+=(--prompt "$prompt")
    fi
    agent_cmd+=(${agent_args[@]+"${agent_args[@]}"})
fi

# Headless runs are one-shot: no tmux and no TTY, so the container exits when the
# agent does, and its output can be piped or redirected.
if [[ "$headless" == true ]]; then
    tty_args=(-i)
    headless_env=(-e CODE_AGENT_HEADLESS=1)
    headless_env_print="
                -e CODE_AGENT_HEADLESS=1 \\"
else
    tty_args=(-it)
    headless_env=()
    headless_env_print=""
fi

agent_cmd_print=""
for arg in ${agent_cmd[@]+"${agent_cmd[@]}"}; do
    agent_cmd_print+=" $(printf '%q' "$arg")"
done

# Print the command
cat <<EOF
    $runtime run ${tty_args[*]} --rm -p ${ports[0]} -p ${ports[1]} \\
                $container_args \\
                -e CODE_AGENT="$code_agent" \\$headless_env_print
                -e GIT_AUTHOR_NAME="$git_author_name" \\
                -e GIT_AUTHOR_EMAIL="$git_author_email" \\
                -e GIT_COMMITTER_NAME="$git_author_name" \\
                -e GIT_COMMITTER_EMAIL="$git_author_email" \\
                -v "$work_dir_to_mount:/work" \\
                -v "$save_dir/.claude:/home/$agent_name_lower/.claude" \\
                -v "$save_dir/.claude.json:/home/$agent_name_lower/.claude.json" \\
                -v "$save_dir/.local/share/opencode:/home/$agent_name_lower/.local/share/opencode" \\$nuget_mount_print
            ${image}:latest$agent_cmd_print
EOF

if [[ "$dry_run" == true ]]; then
    exit 0
fi

"$runtime" run "${tty_args[@]}" --rm -p "${ports[0]}" -p "${ports[1]}" \
            $container_args \
            ${headless_env[@]+"${headless_env[@]}"} \
            -e CODE_AGENT="$code_agent" \
            -e GIT_AUTHOR_NAME="$git_author_name" \
            -e GIT_AUTHOR_EMAIL="$git_author_email" \
            -e GIT_COMMITTER_NAME="$git_author_name" \
            -e GIT_COMMITTER_EMAIL="$git_author_email" \
            -v "$work_dir_to_mount:/work" \
            -v "$save_dir/.claude:/home/$agent_name_lower/.claude" \
            -v "$save_dir/.claude.json:/home/$agent_name_lower/.claude.json" \
            -v "$save_dir/.local/share/opencode:/home/$agent_name_lower/.local/share/opencode" \
            "${nuget_mount[@]+"${nuget_mount[@]}"}" \
    "${image}:latest" ${agent_cmd[@]+"${agent_cmd[@]}"}

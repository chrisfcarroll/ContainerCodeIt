#!/usr/bin/env bash
#
# Launches an Alpine Linux container with OpenCode, Claude Code, and a parameterisable tech stack.
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
#   --agent, -a NAME         Run the agent defined in agents/NAME. Only that agent's
#                            state is mounted.
#   --opencode, -o           Shortcut for --agent opencode (the default).
#   --claude, -c             Shortcut for --agent claude.
#   --list-agents            List the available agents and exit.
#   --prompt, -p TEXT        Open the agent with TEXT as its first prompt. A single bare
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
#   --work-dir, -w DIR       Host directory path to mount as /work in the container.
#                            Defaults to "."
#   --save-dir, -s DIR       Host directory for storing agent configuration and state volumes.
#                            Created if missing. Defaults to ~/.config/code-it
#   --image, -i NAME         Image name to run. Default: "code-it-alpine-<tech>", a
#                            slug of the resolved --tool-chains list, e.g. code-it-alpine-dotnet,
#                            code-it-alpine-node-bun. When that image does not exist, the
#                            most-recently built existing image whose code-it.tool-chains
#                            label contains every requested tool chain is used instead.
#                            Set it explicitly to force a particular image (an error if it
#                            does not exist).
#   --build-image, -b        If specified, builds the image from the Dockerfile before running.
#   --rebuild-image, -B      Like --build-image, but first updates the "# last changed"
#                            cache-bust dates in the Dockerfile to today, forcing the
#                            agent install layers to rerun so the agents are updated.
#   --dockerfile-dir DIR     Directory containing the Dockerfile. Used with --build-image.
#                            Defaults to this script's own directory.
#   --runtime, -r NAME       Container runtime to use: "docker" or "container".
#                            Default: auto-detected as described above.
#   --port PORT              Host port to map to the container's port 3000 (so it takes a
#                            single "host" value, not a "host:container" pair). Default: 0.
#                            With docker, 0 lets the runtime auto-assign a free host port.
#                            The Apple container CLI cannot, so on macOS 0 is resolved by
#                            this script to a free port, starting at 3000, then a random
#                            high port if 3000-3010 are all taken.
#   --agent-name NAME        Name of the agent running in the container. Used for Git author
#                            attribution and home directory naming. Must match the USER set in
#                            the Dockerfile. Default: "Agent1"
#
# Tech stack (used as Docker --build-arg when --build-image is given, and to
# decide which host package caches are mounted read-only). Passing a list
# REPLACES the default set, so there are no on/off flags to clash with future
# tech names:
#   --tool-chains, -t LIST   Comma-separated tech stacks to build. --stack is an alias.
#                            Default: dotnet,node.
#                            Known: dotnet, node (aliases js-node, ts-node), bun
#                            (aliases js-bun, ts-bun), python (alias uv).
#   --package-caches LIST    Comma-separated package repos whose host cache is mounted
#                            read-only. 
#                            Known: nuget, npm, bun.
#                            Default: the package repos implied by --tool-chains
#                            (dotnet->nuget, node->npm).
#                            If the given package manager has a well-known global 
#                            cache directory; and if that directory exists on the host 
#                            when the script runs; then that directory will be mounted 
#                            read-only in the virtual machine at the package manager's 
#                            default location on Alpine Linux.
#
#   --dry-run, -d            Print the run command without executing it.
#   --help, -h               Show this help message.
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
#   ./code-it.sh --port 8000
#       Maps host port 8000 to the container's port 3000.
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
#   - Host package caches are mounted read-only (never written) for the package
#     repos in --package-caches when a cache is found, so downloads are reused:
#       nuget: ~/.nuget/packages-host (a fallbackPackageFolder). Looked up, in order,
#              from the NUGET_PACKAGES env var, the globalPackagesFolder setting in
#              the user-level NuGet.Config, and the default ~/.nuget/packages
#       npm:   ~/.npm-host, seeded into the container's own ~/.npm at startup
#       bun:   ~/.bun-host, seeded into ~/.bun/install/cache at startup
#
#   What each mount preserves:
#   ┌──────────────────────────┬────────────────────────────────────────────────────────────────┐
#   │          Mount           │                            Contains                            │
#   ├──────────────────────────┼────────────────────────────────────────────────────────────────┤
#   │ ~/.claude/               │ Credentials (.credentials.json), settings, permissions, memory │
#   ├──────────────────────────┼────────────────────────────────────────────────────────────────┤
#   │ ~/.claude.json           │ OAuth session data, MCP configs, theme/editor preferences      │
#   ├──────────────────────────┼────────────────────────────────────────────────────────────────┤
#   │ ~/.config/opencode/      │ OpenCode configuration (opencode.json, etc.)                  │
#   │ ~/.local/share/opencode/ │ OpenCode data and auth (auth.json, etc.)                       │
#   └──────────────────────────┴────────────────────────────────────────────────────────────────┘

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/code-it-common.sh
. "$script_dir/lib/code-it-common.sh"

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
image=""
image_explicit=false
build_image=false
rebuild_image=false
dockerfile_dir="$script_dir"
runtime=""
port=0
agent_name="Agent1"
dry_run=false
container_args=""
prompt=""
prompt_set=false
headless=false
agent_args=()
list_agents=false

# Tech stack (see --help). Empty means "use the remembered image, else the defaults":
# dotnet,node and the package repos they imply (dotnet->nuget, node->npm).
tool_chains=""
tool_chains_explicit=false
package_caches=""

agents_dir="$script_dir/agents"

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
        --agent|-a)
            code_agent="$2"
            shift 2
            ;;
        --list-agents)
            list_agents=true
            shift
            ;;
        --work-dir|-w)
            work_dir_to_mount="$2"
            shift 2
            ;;
        --save-dir|-s)
            save_dir="$2"
            shift 2
            ;;
        --image|-i)
            image="$2"
            image_explicit=true
            shift 2
            ;;
        --build-image|-b)
            build_image=true
            shift
            ;;
        --rebuild-image|-B)
            build_image=true
            rebuild_image=true
            shift
            ;;
        --dockerfile-dir)
            dockerfile_dir="$2"
            shift 2
            ;;
        --runtime|-r)
            runtime="$2"
            shift 2
            ;;
        --port)
            port="$2"
            shift 2
            ;;
        --agent-name)
            agent_name="$2"
            shift 2
            ;;
        --tool-chains|--tech|--stack|-t)
            tool_chains="$2"
            tool_chains_explicit=true
            shift 2
            ;;
        --package-caches)
            package_caches="$2"
            shift 2
            ;;
        --prompt|-p)
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

# --list-agents lists the available agent definitions and exits.
if [[ "$list_agents" == true ]]; then
    while IFS= read -r name; do
        short=$(ci_agent_config "$agents_dir" "$name" AGENT_SHORT)
        if [[ -n "$short" ]]; then
            printf '  %-10s -%s\n' "$name" "$short"
        else
            printf '  %s\n' "$name"
        fi
    done < <(ci_list_agents "$agents_dir")
    exit 0
fi

# Load the chosen agent's definition. The agent name is data: shortcut flags are
# resolved here, but every other detail comes from agents/<name>/config.
if ! ci_agent_exists "$agents_dir" "$code_agent"; then
    echo "Warning: Unknown agent '$code_agent'. Known agents: $(ci_list_agents "$agents_dir" | tr '\n' ' ')" >&2
    echo "Run $0 --list-agents to see them." >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$agents_dir/$code_agent/config"

# Resolve --tool-chains / --package-caches into a set of known tech names (space-separated
# in $enabled_tool_chains) and known package repo names (in $enabled_package_caches).
# --tool-chains replaces the default {dotnet,node}; --package-caches replaces the set implied
# by --tool-chains (dotnet->nuget, node->npm). An unknown name is a hard error.
enabled_tool_chains=$(ci_resolve_tool_chains "$tool_chains") || exit 1
enabled_package_caches=$(ci_resolve_package_caches "$package_caches" "$enabled_tool_chains") || exit 1

tool_chain_has()    { ci_has "$enabled_tool_chains" "$1"; }
package_cache_has() { ci_has "$enabled_package_caches" "$1"; }

# Default image name from the tool-chain list, e.g. code-it-alpine-dotnet or
# code-it-alpine-node-bun. --image overrides it.
if [[ -z "$image" ]]; then
    image=$(ci_default_image_name "$enabled_tool_chains")
fi

# Detect / validate the container runtime (after parsing, so --runtime is honoured).
runtime=$(ci_detect_runtime "$runtime") || exit 1

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

# Port mapping. The container listens on 3000; --port is the host port to map to it.
# The default, 0, means "no host port chosen here": docker auto-assigns a free port,
# while the Apple container CLI (macOS only) cannot, so resolve 0 to a free port,
# starting at 3000, or a random high port if none of those are free.
container_port=3000

# port_in_use PORT: true if something is listening on the loopback port. Needs nc;
# if it is not available we cannot tell, so report the port as free.
port_in_use() {
    command -v nc &>/dev/null || return 1
    nc -z 127.0.0.1 "$1" &>/dev/null
}

if [[ "$port" == "0" && "$runtime" == "container" ]]; then
    resolved_port=""
    for candidate in 3000 3001 3002 3003 3004 3005 3006 3007 3008 3009 3010; do
        if ! port_in_use "$candidate"; then
            resolved_port="$candidate"
            break
        fi
    done
    if [[ -z "$resolved_port" ]]; then
        resolved_port=$(( (RANDOM % 10000) + 30000 ))
    fi
    port="$resolved_port"
fi
port_mapping="$port:$container_port"

# Ensure required paths exist
if [[ ! -d "$work_dir_to_mount" ]]; then
    echo "Warning: work-dir directory does not exist: $work_dir_to_mount." >&2
    echo "Please specify a directory where you have a git repo, or repos, you want the agent to work on." >&2
    exit 1
fi
work_dir_to_mount=$(abs_dir "$work_dir_to_mount")

# Create the save dir structure so mounts always work, even on first run. State
# paths come from the agent definition: directories are created; single files are
# pre-created so the runtime does not make a directory in their place.
agent_state_dirs=()
if [[ -n "${AGENT_STATE_DIRS:-}" ]]; then
    IFS=':' read -r -a agent_state_dirs <<< "$AGENT_STATE_DIRS"
fi
for d in ${agent_state_dirs[@]+"${agent_state_dirs[@]}"}; do
    [[ -n "$d" ]] && mkdir -p "$save_dir/$d"
done
agent_state_files=()
if [[ -n "${AGENT_STATE_FILES:-}" ]]; then
    IFS=':' read -r -a agent_state_files <<< "$AGENT_STATE_FILES"
fi
for f in ${agent_state_files[@]+"${agent_state_files[@]}"}; do
    [[ -n "$f" ]] || continue
    [[ -e "$save_dir/$f" ]] || echo '{}' > "$save_dir/$f"
done

# Write the agent's default configuration file(s) on first run, preserving layout.
default_config_dir="$agents_dir/$code_agent/default-config"
if [[ -d "$default_config_dir" ]]; then
    while IFS= read -r src; do
        rel=${src#"$default_config_dir"/}
        dest="$save_dir/$rel"
        if [[ ! -e "$dest" ]]; then
            mkdir -p "$(dirname "$dest")"
            cp "$src" "$dest"
            echo "    Created $AGENT_CONFIG_LABEL: $dest"
        fi
    done < <(find "$default_config_dir" -type f | sort)
fi
save_dir=$(abs_dir "$save_dir")
history_file="$save_dir/image-history"

# With no explicit --tool-chains or --image, default to the remembered image that
# covers at least 70% of the weighted recent usage (see Specs/09-image-memory.md).
if [[ "$tool_chains_explicit" == false && "$image_explicit" == false ]]; then
    memory_image=$(ci_history_choose_image "$runtime" "$history_file") || memory_image=""
    if [[ -n "$memory_image" ]]; then
        memory_chains=$(ci_image_tool_chains "$runtime" "$memory_image")
        if [[ -n "$memory_chains" ]]; then
            enabled_tool_chains=$(ci_resolve_tool_chains "$memory_chains") || exit 1
            if [[ -z "$package_caches" ]]; then
                enabled_package_caches=$(ci_resolve_package_caches "" "$enabled_tool_chains") || exit 1
            fi
            image="$memory_image"
            echo "    Using remembered image: $image"
        fi
    fi
fi

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

# An existing image is only required when we are not about to build one. If the exact
# image is missing and the user did not name one, use the most-recently built existing
# image whose recorded tool chains contain every requested chain.
if [[ "$build_image" == false ]]; then
    if ! echo "$valid_images" | grep -qE "^${image}([: ]|$)"; then
        if [[ "$image_explicit" == true ]]; then
            echo "Warning: $runtime image '$image' does not exist." >&2
            echo "Build it, or set --image to an image that exists." >&2
            exit 1
        fi
        superset_image=$(ci_find_superset_image "$runtime" "$enabled_tool_chains") || superset_image=""
        if [[ -n "$superset_image" ]]; then
            echo "    '$image' does not exist; using '$superset_image', which contains ${enabled_tool_chains// /,}"
            image="$superset_image"
        else
            echo "Warning: $runtime image '$image' does not exist and --build-image was not specified." >&2
            echo "Either build the image with the --build-image flag or ensure the image is available locally." >&2
            exit 1
        fi
    fi
fi

# Warn if the chosen image was built for a different tool-chain set than the one we
# are about to run. Prefer the label code-it-build stamped on the image; fall back to
# the name-based guess. A superset image is fine: only warn when it does not contain
# every requested chain.
image_tool_chains=$(ci_image_tool_chains "$runtime" "$image")
if [[ -n "$image_tool_chains" ]] && ! ci_tool_chains_include "$image_tool_chains" "$enabled_tool_chains"; then
    echo "Warning: image '$image' looks built for tech '$image_tool_chains' but --tool-chains is '$(ci_join , "$enabled_tool_chains")'." >&2
    echo "    Pass the same --tool-chains used to build the image, or set --image explicitly." >&2
elif [[ -n "$image_tool_chains" && "$image_tool_chains" != "$(ci_join , "$enabled_tool_chains")" ]]; then
    extras=""
    for c in ${image_tool_chains//,/ }; do
        ci_has "$enabled_tool_chains" "$c" || extras=$(ci_comma_list_add "$extras" "$c")
    done
    echo "    Note: image '$image' also contains ${extras// /,}."
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

# Locate the host package caches and mount the ones for the enabled package repos
# READ-ONLY, so the agent reuses downloads but can never write to the host cache.
# The image seeds its own writable caches from these mounts at startup.
cache_mounts=()
cache_mounts_print=""
add_cache_mount() {
    local host_path container_path label
    host_path=$(abs_dir "$1")
    container_path="$2"
    label="$3"
    cache_mounts+=(-v "$host_path:$container_path:ro")
    cache_mounts_print+="
                -v \"$host_path:$container_path:ro\" \\"
    echo "    Mounting $label read-only: $host_path"
}
container_home="/home/$agent_name_lower"

# NuGet. Precedence per https://learn.microsoft.com/en-us/nuget/consume-packages/managing-the-global-packages-and-cache-folders :
# the NUGET_PACKAGES environment variable, then the globalPackagesFolder setting in
# the user-level NuGet.Config, then the default ~/.nuget/packages.
if package_cache_has nuget; then
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
    if [[ -n "$nuget_packages" ]]; then
        add_cache_mount "$nuget_packages" "$container_home/.nuget/packages-host" "NuGet package cache"
    else
        echo "    No NuGet package cache found; restore will use package sources only"
    fi
fi

# npm: NPM_CONFIG_CACHE, then the platform default (~/.npm, or %LocalAppData%\npm-cache)
if package_cache_has npm; then
    npm_cache=""
    for candidate in "${NPM_CONFIG_CACHE:-}" "${LOCALAPPDATA:-}/npm-cache" "$HOME/.npm"; do
        if [[ -n "$candidate" && -d "$candidate" ]]; then
            npm_cache="$candidate"
            break
        fi
    done
    if [[ -n "$npm_cache" ]]; then
        add_cache_mount "$npm_cache" "$container_home/.npm-host" "npm package cache"
    else
        echo "    No npm package cache found; npm will download into the container"
    fi
fi

# Bun: BUN_INSTALL_CACHE_DIR, then the default ~/.bun/install/cache
if package_cache_has bun; then
    bun_cache=""
    for candidate in "${BUN_INSTALL_CACHE_DIR:-}" "$HOME/.bun/install/cache"; do
        if [[ -n "$candidate" && -d "$candidate" ]]; then
            bun_cache="$candidate"
            break
        fi
    done
    if [[ -n "$bun_cache" ]]; then
        add_cache_mount "$bun_cache" "$container_home/.bun-host" "Bun package cache"
    else
        echo "    No Bun package cache found; Bun will download into the container"
    fi
fi

# Build image if requested. This is a thin shim: code-it-build.sh owns building,
# the Dockerfile's "# last changed" bump and the image label.
if [[ "$build_image" == true ]]; then
    echo "    Note: --build-image is deprecated; use code-it-build.sh. Delegating."
    build_shim_args=(
        --tool-chains "$(ci_join , "$enabled_tool_chains")"
        --package-caches "$(ci_join , "$enabled_package_caches")"
        --agent "$code_agent"
        --image "$image"
        --dockerfile-dir "$dockerfile_dir"
        --runtime "$runtime"
    )
    if [[ "$rebuild_image" == true ]]; then
        build_shim_args+=(--rebuild)
    fi
    "$script_dir/code-it-build.sh" "${build_shim_args[@]}"
fi

# Translate the prompt, and any -- pass-through arguments, into the chosen agent's own
# command line, from the definition's cmd_* template, which the container entrypoint
# hands to the agent. {args} expands to the agent args, {prompt} to the opening prompt.
# See https://code.claude.com/docs/en/cli-reference and https://opencode.ai/docs/cli/
agent_cmd=()
if [[ "$headless" == true ]]; then
    if [[ "$prompt_set" == true ]]; then
        agent_cmd_template="$AGENT_CMD_HEADLESS_PROMPT"
    else
        agent_cmd_template="$AGENT_CMD_HEADLESS_NO_PROMPT"
    fi
elif [[ "$prompt_set" == true ]]; then
    agent_cmd_template="$AGENT_CMD_INTERACTIVE_PROMPT"
else
    agent_cmd_template="$AGENT_CMD_INTERACTIVE_NO_PROMPT"
fi
for token in $agent_cmd_template; do
    case "$token" in
        '{args}')   agent_cmd+=(${agent_args[@]+"${agent_args[@]}"}) ;;
        '{prompt}') [[ "$prompt_set" == true ]] && agent_cmd+=("$prompt") ;;
        *)          agent_cmd+=("$token") ;;
    esac
done

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

# Mount only the chosen agent's state, read from its definition.
agent_mounts=()
agent_mounts_print=""
for d in ${agent_state_dirs[@]+"${agent_state_dirs[@]}"}; do
    [[ -n "$d" ]] || continue
    agent_mounts+=(-v "$save_dir/$d:$container_home/$d")
    agent_mounts_print+="
                -v \"$save_dir/$d:$container_home/$d\" \\"
done
for f in ${agent_state_files[@]+"${agent_state_files[@]}"}; do
    [[ -n "$f" ]] || continue
    agent_mounts+=(-v "$save_dir/$f:$container_home/$f")
    agent_mounts_print+="
                -v \"$save_dir/$f:$container_home/$f\" \\"
done

# Print the command
cat <<EOF
    $runtime run ${tty_args[*]} --rm -p $port_mapping \\
                $container_args \\
                -e CODE_AGENT="$code_agent" \\$headless_env_print
                -e GIT_AUTHOR_NAME="$git_author_name" \\
                -e GIT_AUTHOR_EMAIL="$git_author_email" \\
                -e GIT_COMMITTER_NAME="$git_author_name" \\
                -e GIT_COMMITTER_EMAIL="$git_author_email" \\
                -v "$work_dir_to_mount:/work" \\$agent_mounts_print$cache_mounts_print
                ${image}:latest$agent_cmd_print
EOF

if [[ "$dry_run" == true ]]; then
    exit 0
fi

run_rc=0
"$runtime" run "${tty_args[@]}" --rm -p "$port_mapping" \
            $container_args \
            ${headless_env[@]+"${headless_env[@]}"} \
            -e CODE_AGENT="$code_agent" \
            -e GIT_AUTHOR_NAME="$git_author_name" \
            -e GIT_AUTHOR_EMAIL="$git_author_email" \
            -e GIT_COMMITTER_NAME="$git_author_name" \
            -e GIT_COMMITTER_EMAIL="$git_author_email" \
            -v "$work_dir_to_mount:/work" \
            "${agent_mounts[@]+"${agent_mounts[@]}"}" \
            "${cache_mounts[@]+"${cache_mounts[@]}"}" \
    "${image}:latest" ${agent_cmd[@]+"${agent_cmd[@]}"} || run_rc=$?

# Remember the image used, so later runs can default their tool chains to it.
ci_history_record "$history_file" "$image"
exit "$run_rc"

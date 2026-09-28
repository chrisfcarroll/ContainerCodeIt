#!/usr/bin/env bash
#
# Shared helpers for code-it.sh and code-it-build.sh. Source this file; it defines
# functions and constants only, and runs nothing on its own.
#
#   ci_comma_list_add LIST ITEM                       append ITEM to a space list
#   ci_tool_chain_alias NAME                          canonical name for an alias
#   ci_resolve_tool_chains RAW                        -> space-separated canonical list
#   ci_resolve_package_caches RAW TOOL_CHAINS         -> space-separated list
#   ci_default_image_name TOOL_CHAINS                 -> code-it-alpine-<chains>
#   ci_has LIST ITEM                                  return 0 if ITEM is in LIST
#   ci_detect_runtime REQUESTED                       -> docker|container, or return 1
#   ci_join COMMA LIST                                space list -> comma list
#
# Empty RAW means "use the defaults"; an unknown name prints a warning to stderr
# and returns 1, so the caller can exit.

CI_DEFAULT_TOOL_CHAINS="dotnet node"
CI_KNOWN_TOOL_CHAINS="dotnet node bun python"
CI_KNOWN_PACKAGE_CACHES="nuget npm bun"
CI_CONTAINER_PORT=3000
CI_DEFAULT_AGENTS="opencode claude"

ci_comma_list_add() {
    case " $1 " in
        *" $2 "*) printf '%s' "$1" ;;
        *)        printf '%s' "${1:+$1 }$2" ;;
    esac
}

ci_tool_chain_alias() {
    case "$1" in
        js-node|ts-node) printf 'node' ;;
        js-bun|ts-bun)   printf 'bun' ;;
        # uv is Python's package manager here, so it selects the python tool chain
        uv)              printf 'python' ;;
        *)               printf '%s' "$1" ;;
    esac
}

# ci_has LIST ITEM: true if the space-separated LIST contains ITEM
ci_has() {
    case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

# ci_join COMMA LIST: turn a space-separated list into a comma-separated one
ci_join() {
    printf '%s' "$2" | tr ' ' "${1:- }"
}

ci_resolve_tool_chains() {
    local raw="$1" out="" t
    local -a requested
    if [[ -n "$raw" ]]; then
        IFS=',' read -r -a requested <<< "$raw"
    else
        read -r -a requested <<< "$CI_DEFAULT_TOOL_CHAINS"
    fi
    for t in ${requested[@]+"${requested[@]}"}; do
        t=$(ci_tool_chain_alias "$t")
        case "$t" in
            "") ;;
            dotnet|node|bun|python) out=$(ci_comma_list_add "$out" "$t") ;;
            *)
                echo "Warning: Unknown tech stack '$t'. Known: dotnet, node (aliases js-node, ts-node), bun (aliases js-bun, ts-bun), python (alias uv)." >&2
                return 1
                ;;
        esac
    done
    printf '%s' "$out"
}

ci_resolve_package_caches() {
    local raw="$1" tool_chains="$2" out="" p
    local -a requested
    if [[ -n "$raw" ]]; then
        IFS=',' read -r -a requested <<< "$raw"
    else
        requested=()
        ci_has "$tool_chains" dotnet && requested+=(nuget)
        ci_has "$tool_chains" node   && requested+=(npm)
    fi
    for p in ${requested[@]+"${requested[@]}"}; do
        case "$p" in
            "") ;;
            nuget|npm|bun) out=$(ci_comma_list_add "$out" "$p") ;;
            *)
                echo "Warning: Unknown package repo '$p'. Known: nuget, npm, bun." >&2
                return 1
                ;;
        esac
    done
    printf '%s' "$out"
}

# ci_default_image_name TOOL_CHAINS: e.g. code-it-alpine-dotnet or code-it-alpine-node-bun
ci_default_image_name() {
    printf 'code-it-alpine-%s' "$(ci_join - "$1")"
}

# ci_agent_config AGENTS_DIR NAME KEY: the (unquoted) value of KEY in an agent's
# config, or return 1. Keys are uppercase and appear once per line.
ci_agent_config() {
    local file="$1/$2/config" line
    [[ -f "$file" ]] || return 1
    line=$(grep -m1 "^$3=" "$file" 2>/dev/null) || return 1
    [[ -n "$line" ]] || return 1
    line=${line#*=}
    case "$line" in
        \'*\') line=${line#\'}; line=${line%\'} ;;
        \"*\") line=${line#\"}; line=${line%\"} ;;
    esac
    printf '%s' "$line"
}

# ci_agent_exists AGENTS_DIR NAME
ci_agent_exists() { [[ -f "$1/$2/config" ]]; }

# ci_list_agents AGENTS_DIR: print one agent name per line
ci_list_agents() {
    local d
    for d in "$1"/*/; do
        [[ -f "$d/config" ]] || continue
        basename "$d"
    done
}

# ci_resolve_agents RAW AGENTS_DIR: canonical space-separated agent list, or return 1.
# An empty RAW means the default agents.
ci_resolve_agents() {
    local raw="$1" agents_dir="$2" out="" a
    local -a requested
    if [[ -n "$raw" ]]; then
        IFS=',' read -r -a requested <<< "$raw"
    else
        read -r -a requested <<< "$CI_DEFAULT_AGENTS"
    fi
    for a in ${requested[@]+"${requested[@]}"}; do
        if [[ -z "$a" ]]; then
            continue
        elif ci_agent_exists "$agents_dir" "$a"; then
            out=$(ci_comma_list_add "$out" "$a")
        else
            echo "Warning: Unknown agent '$a'. Known agents: $(ci_list_agents "$agents_dir" | tr '\n' ' ')" >&2
            return 1
        fi
    done
    printf '%s' "$out"
}

# ci_add_via_code_it NAME BRANCH REPO CODE_IT DRY_RUN PROMPT: the plumbing shared by
# code-it-add-agent and code-it-add-tool-chain. With DRY_RUN=true it prints the prompt
# and command and returns 0. Otherwise it refuses a dirty repo or an existing branch,
# creates BRANCH, runs CODE_IT headless with PROMPT, prints the branch and a diff
# summary, and returns code-it's exit code.
ci_add_via_code_it() {
    local name="$1" branch="$2" repo="$3" code_it="$4" dry_run="$5" prompt="$6"
    local cmd=("$code_it" --headless --work-dir "$repo" --prompt "$prompt")

    if [[ "$dry_run" == true ]]; then
        echo "Prompt:"
        printf '%s\n' "$prompt"
        echo
        echo "Command:"
        printf '%q ' "${cmd[@]}"
        printf '\n'
        return 0
    fi

    # Refuse a dirty tree, so checking out a new branch cannot lose work.
    if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then
        echo "Warning: '$repo' has uncommitted changes. Commit or stash them first." >&2
        return 1
    fi
    if git -C "$repo" rev-parse --verify --quiet "$branch" >/dev/null; then
        echo "Warning: branch '$branch' already exists in '$repo'." >&2
        return 1
    fi

    local base_rev rc=0
    base_rev=$(git -C "$repo" rev-parse HEAD)
    echo "    Creating branch $branch in $repo"
    git -C "$repo" checkout -b "$branch" || return 1

    echo "    Running: $code_it --headless --work-dir $repo"
    "${cmd[@]}" || rc=$?

    echo
    echo "    Branch: $branch"
    echo "    Changes:"
    git -C "$repo" log --oneline "$base_rev..HEAD" 2>/dev/null | sed 's/^/      /' || true
    git -C "$repo" diff --stat "$base_rev..HEAD" 2>/dev/null | sed 's/^/      /' || true

    if [[ "$rc" != "0" ]]; then
        echo "Warning: code-it exited $rc (the agent may have refused the gate or failed)." >&2
    fi
    return "$rc"
}

# ci_detect_runtime REQUESTED: echo the runtime to use, warning and returning 1 if
# none is found. On macOS prefer the Apple container CLI, then docker, then container.
ci_detect_runtime() {
    local runtime="$1" platform
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
                return 1
            fi
            ;;
        docker|container)
            if ! command -v "$runtime" &>/dev/null; then
                echo "Warning: Requested runtime '$runtime' not found. Please install it and ensure it is in your PATH." >&2
                return 1
            fi
            ;;
        *)
            echo "Warning: Unknown runtime '$runtime'. Valid values are 'docker' or 'container'." >&2
            return 1
            ;;
    esac
    printf '%s' "$runtime"
}

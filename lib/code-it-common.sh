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

# ci_tool_chains_include IMAGE_CHAINS_COMMA REQUESTED_SPACE: true if every requested
# tool chain is present in the image's comma-separated chain list.
ci_tool_chains_include() {
    local image_chains="${1//,/ }" req
    for req in $2; do
        ci_has "$image_chains" "$req" || return 1
    done
    return 0
}

# ci_image_tool_chains RUNTIME IMAGE: echo the comma-separated tool chains recorded on
# IMAGE (its code-it.tool-chains label, or the code-it-alpine-<chains> name), or
# nothing if it cannot be told.
ci_image_tool_chains() {
    local runtime="$1" image="$2" chains=""
    case "$runtime" in
        docker)    chains=$(docker image inspect --format '{{ index .Config.Labels "code-it.tool-chains" }}' "$image" 2>/dev/null || true) ;;
        container) chains=$(container image inspect --format '{{ index .Config.Labels "code-it.tool-chains" }}' "$image" 2>/dev/null || true) ;;
    esac
    # A runtime that does not know the format prints its own error text to stdout; keep
    # only a plausible comma-separated tool-chain list.
    case "$chains" in
        *[!a-z,]*|"") chains="" ;;
    esac
    if [[ -z "$chains" && "$image" == code-it-alpine-* ]]; then
        chains="${image#code-it-alpine-}"
        chains="${chains%%:*}"
        chains="${chains//-/,}"
    fi
    printf '%s' "$chains"
}

# ci_image_list RUNTIME: existing image "repo:tag" names, most-recently built first.
ci_image_list() {
    local runtime="$1"
    if [[ "$runtime" == "docker" ]]; then
        docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true
    else
        # Apple container's ls is newest first; NAME and TAG are the first two columns.
        # Skip a header row if there is one.
        container image ls 2>/dev/null | awk 'NF >= 2 && tolower($1) != "name" { print $1":"$2 }' || true
    fi
}

# ci_find_superset_image RUNTIME REQUESTED_SPACE: echo the repo name of the
# most-recently built image whose recorded tool chains contain every requested chain,
# or nothing. Only images whose label (or name) can be read are considered.
ci_find_superset_image() {
    local runtime="$1" requested="$2" image image_chains
    while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        [[ "$image" == *:* ]] || image="$image:latest"
        image_chains=$(ci_image_tool_chains "$runtime" "$image")
        [[ -n "$image_chains" ]] || continue
        if ci_tool_chains_include "$image_chains" "$requested"; then
            printf '%s' "${image%%:*}"
            return 0
        fi
    done < <(ci_image_list "$runtime")
    return 1
}

# ci_image_exists RUNTIME IMAGE: true if the runtime has the image.
ci_image_exists() {
    local runtime="$1" image="$2"
    case "$runtime" in
        docker)    docker image inspect "$image" >/dev/null 2>&1 ;;
        container) container image inspect "$image" >/dev/null 2>&1 ;;
        *)         return 1 ;;
    esac
}

# ci_history_choose_image RUNTIME FILE: echo the most-recently remembered image that
# still exists and whose tool chains cover >=70% of weighted usage, or nothing.
# Weights run from 1 (oldest remembered) to 15 (most recent). Spec 09.
ci_history_choose_image() {
    local runtime="$1" file="$2" l image i j c w cov
    [[ -f "$file" ]] || return 1
    local -a lines=() chains=()
    while IFS= read -r l; do
        [[ -n "$l" ]] && lines+=("$l")
    done < "$file"
    local n=${#lines[@]}
    (( n > 0 )) || return 1
    for ((i=0; i<n; i++)); do
        image="${lines[i]#* }"
        chains+=("$(ci_image_tool_chains "$runtime" "$image")")
    done
    local total=0
    for ((i=0; i<n; i++)); do
        total=$(( total + 15 - n + 1 + i ))
    done
    (( total > 0 )) || return 1
    local dotnet_w=0 node_w=0 bun_w=0 python_w=0
    for ((i=0; i<n; i++)); do
        w=$(( 15 - n + 1 + i ))
        for c in $CI_KNOWN_TOOL_CHAINS; do
            if ci_has "${chains[i]//,/ }" "$c"; then
                case "$c" in
                    dotnet) dotnet_w=$((dotnet_w + w)) ;;
                    node)   node_w=$((node_w + w)) ;;
                    bun)    bun_w=$((bun_w + w)) ;;
                    python) python_w=$((python_w + w)) ;;
                esac
            fi
        done
    done
    # Newest first: the first image whose chains cover >=70% of the weight wins.
    for ((j=n-1; j>=0; j--)); do
        cov=0
        for c in $CI_KNOWN_TOOL_CHAINS; do
            if ci_has "${chains[j]//,/ }" "$c"; then
                case "$c" in
                    dotnet) cov=$((cov + dotnet_w)) ;;
                    node)   cov=$((cov + node_w)) ;;
                    bun)    cov=$((cov + bun_w)) ;;
                    python) cov=$((cov + python_w)) ;;
                esac
            fi
        done
        if (( cov * 10 >= total * 7 )); then
            image="${lines[j]#* }"
            if ci_image_exists "$runtime" "$image"; then
                printf '%s' "$image"
                return 0
            fi
        fi
    done
    return 1
}

# ci_history_record FILE IMAGE: append "yyyymmdd IMAGE", keeping the newest 15 lines.
ci_history_record() {
    local file="$1" image="$2"
    [[ -n "$image" ]] || return 0
    mkdir -p "$(dirname "$file")"
    printf '%s %s\n' "$(date +%Y%m%d)" "$image" >> "$file"
    if [[ "$(wc -l < "$file")" -gt 15 ]]; then
        tail -n 15 "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    fi
}

# ci_choose_default_image RUNTIME HISTORY_FILE: echo the repo name of the default
# existing code-it image: the most recently used remembered one that still exists,
# else the most recently built. Nothing if there is no code-it image at all.
ci_choose_default_image() {
    local runtime="$1" file="$2" line image e i seen
    local -a existing=()
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        image="${line%%:*}"
        case "$image" in code-it-*) ;; *) continue ;; esac
        seen=false
        for e in ${existing[@]+"${existing[@]}"}; do
            [[ "$e" == "$image" ]] && { seen=true; break; }
        done
        [[ "$seen" == false ]] && existing+=("$image")
    done < <(ci_image_list "$runtime")
    (( ${#existing[@]} > 0 )) || return 1

    if [[ -f "$file" ]]; then
        local -a hist=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && hist+=("${line#* }")
        done < "$file"
        for ((i=${#hist[@]}-1; i>=0; i--)); do
            image="${hist[i]}"
            for e in "${existing[@]}"; do
                if [[ "$e" == "$image" ]]; then
                    printf '%s' "$image"
                    return 0
                fi
            done
        done
    fi
    printf '%s' "${existing[0]}"
    return 0
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

# ci_tool_chain_commands NAME: the host commands that reveal NAME is installed,
# one per line. A command in any line means "detected".
ci_tool_chain_commands() {
    case "$1" in
        dotnet) printf '%s\n' 'dotnet --version' ;;
        node)   printf '%s\n' 'node --version' 'volta --version' ;;
        bun)    printf '%s\n' 'bun --version' ;;
        python) printf '%s\n' 'python3 --version' 'uv --version' ;;
    esac
}

# ci_tool_chain_detected NAME: true if any of the tool chain's host commands works.
ci_tool_chain_detected() {
    local cmd
    while IFS= read -r cmd; do
        [[ -n "$cmd" ]] || continue
        # shellcheck disable=SC2086
        if $cmd >/dev/null 2>&1; then
            return 0
        fi
    done < <(ci_tool_chain_commands "$1")
    return 1
}

# ci_agent_detected AGENTS_DIR NAME: true if the agent's host command is on PATH, or
# any of its host state paths (HOME/<state path>) exists.
ci_agent_detected() {
    local agents_dir="$1" name="$2" cmd p
    cmd=$(ci_agent_config "$agents_dir" "$name" AGENT_COMMAND)
    if [[ -n "$cmd" ]] && command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi
    local dirs files
    dirs=$(ci_agent_config "$agents_dir" "$name" AGENT_STATE_DIRS)
    files=$(ci_agent_config "$agents_dir" "$name" AGENT_STATE_FILES)
    local IFS=':'
    for p in $dirs $files; do
        [[ -n "$p" && -e "$HOME/$p" ]] && return 0
    done
    return 1
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

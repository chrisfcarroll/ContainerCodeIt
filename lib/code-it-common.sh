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

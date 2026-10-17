#!/usr/bin/env bash
#
# Builds the code-it container image from the Dockerfile, selecting the toolchains,
# package caches and coding agents to include. code-it.sh runs the images this builds.
#
# The coding agents' install layers live in agents/<name>/install.dockerfile. This
# script assembles them into the Dockerfile (replacing the
# "# @@CODE_IT_AGENT_INSTALLS@@" marker) and writes /etc/code-it-agents, the
# name=binary map the container's go.sh reads. So agents are data, not branches.
#
# Usage:
#   ./code-it-build.sh [OPTIONS]
#
# Options:
#   --toolchain, -t LIST     Comma-separated toolchains to build. With none,
#                            interactive selection is used.
#                            Known: dotnet, node (aliases js-node, ts-node), bun
#                            (aliases js-bun, ts-bun), python (alias uv),
#                            powershell (alias pwsh).
#                            --stack is an alias for --toolchain.
#   --package-caches LIST    Comma-separated package repos to support, independent of
#                            --toolchain. Known: nuget, npm, bun.
#                            Default: the repos implied by --toolchain
#                            (dotnet->nuget, node->npm).
#   --agent, -a LIST         Comma-separated agents to install. Default: opencode,claude.
#                            --agents is an alias. Interactive mode preselects detected
#                            agents instead.
#   --list-agents            List the available agents and exit.
#   --rebuild                Bump the "# last changed" dates in the Dockerfile and the
#                            selected agents' install fragments to today first, so the
#                            agent install layers rerun and the agents update.
#   --locale, -l LOCALE      The container's locale (its LANG), e.g. en_GB.UTF-8 or en-GB.
#                            Default: like-host, the host's own locale, read from
#                            LC_ALL or LANG, else macOS's AppleLocale or the Windows
#                            user locale (also from Git Bash and WSL). Windows and
#                            macOS names are translated as best they can be, and the
#                            codeset is always UTF-8. C.UTF-8 if it cannot be told.
#   --image, -i NAME         Image name to build. Default: "code-it-alpine-<chains>",
#                            a slug of the resolved --toolchain list.
#   --dockerfile-dir DIR     Directory containing the Dockerfile.
#                            Defaults to this script's own directory.
#   --runtime, -r NAME       Container runtime to use: "docker" or "container".
#                            Default: auto-detected (Apple container on macOS, else docker).
#   --dry-run, -d            Print the build command without executing it.
#   --yes, -y                Accept detected/default selections and build without asking.
#   --interactive            Ask about any missing toolchain/agent selection.
#   --selection-file FILE    Internal: write selected toolchains and agents for first-run.
#   --help, -h               Show this help message.
#
# The image is labelled with its toolchains, package caches and locale
# (code-it.tool-chains=..., code-it.package-caches=..., code-it.locale=...), so
# code-it.sh can detect a mismatch between the image and the --toolchain it was
# asked to run.

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/code-it-common.sh
. "$script_dir/lib/code-it-common.sh"

# Absolute path of an existing directory, without realpath (absent on older macOS)
abs_dir() { (CDPATH= cd -- "$1" && pwd); }

toolchain=""
package_caches=""
package_caches_set=false
agents_raw=""
list_agents=false
rebuild=false
locale="$CI_LOCALE_LIKE_HOST"
image=""
dockerfile_dir="$script_dir"
runtime=""
dry_run=false
yes=false
interactive=false
selection_file=""

show_help() { sed -n '2,/^$/{ s/^# \{0,1\}//; p; }' "$0"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --toolchain|--tech|--stack|-t)
            toolchain="$2"
            shift 2
            ;;
        --package-caches)
            package_caches="$2"
            package_caches_set=true
            shift 2
            ;;
        --agent|--agents|-a)
            agents_raw="$2"
            shift 2
            ;;
        --list-agents)
            list_agents=true
            shift
            ;;
        --rebuild)
            rebuild=true
            shift
            ;;
        --locale|-l)
            locale="$2"
            shift 2
            ;;
        --image|-i)
            image="$2"
            shift 2
            ;;
        --dockerfile-dir)
            dockerfile_dir="$2"
            shift 2
            ;;
        --runtime|-r)
            runtime="$2"
            shift 2
            ;;
        --dry-run|-d)
            dry_run=true
            shift
            ;;
        --yes|-y)
            yes=true
            shift
            ;;
        --interactive)
            interactive=true
            shift
            ;;
        --selection-file)
            selection_file="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Run $0 --help for usage." >&2
            exit 1
            ;;
        *)
            echo "Unexpected argument: $1" >&2
            echo "Run $0 --help for usage." >&2
            exit 1
            ;;
    esac
done

# The agent definitions live next to the Dockerfile when it ships them, else next
# to this script.
agents_dir="$dockerfile_dir/agents"
[[ -d "$agents_dir" ]] || agents_dir="$script_dir/agents"

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

# With no toolchain, build is an interactive setup command. First-run also asks
# build to prompt for whichever of its selections were not supplied.
[[ -z "$toolchain" ]] && interactive=true

parse_selection() {
    local answer="$1"; shift
    local items=("$@") out="" tok it idx
    local IFS=', '
    for tok in $answer; do
        [[ -n "$tok" ]] || continue
        if [[ "$tok" =~ ^[0-9]+$ ]]; then
            idx="$tok"
            if (( idx >= 1 && idx <= ${#items[@]} )); then
                out=$(ci_comma_list_add "$out" "${items[$((idx-1))]}")
            fi
        else
            for it in "${items[@]}"; do
                [[ "$it" == "$tok" ]] && out=$(ci_comma_list_add "$out" "$it")
            done
        fi
    done
    printf '%s' "$out"
}

choose() {
    local label="$1" default="$2" detected="$3"; shift 3
    local items=("$@") i=1 item flag answer
    if [[ "$yes" == true ]]; then printf '%s' "$default"; return 0; fi
    printf '%s (detected marked *):\n' "$label" >&2
    for item in "${items[@]}"; do
        flag=""
        case " $detected " in *" $item "*) flag=" *" ;; esac
        printf '  %d) %s%s\n' "$i" "$item" "$flag" >&2
        i=$((i+1))
    done
    printf 'Choose %s [%s]: ' "$label" "$(ci_join , "${default:-none}")" >&2
    read -r answer || answer=""
    if [[ -z "$answer" ]]; then printf '%s' "$default"; else parse_selection "$answer" "${items[@]}"; fi
}

if [[ "$interactive" == true ]]; then
    toolchain_available=($CI_KNOWN_TOOLCHAIN)
    agents_available=()
    while IFS= read -r a; do agents_available+=("$a"); done < <(ci_list_agents "$agents_dir")
    detected_toolchain=""
    for t in "${toolchain_available[@]}"; do
        ci_toolchain_detected "$t" && detected_toolchain=$(ci_comma_list_add "$detected_toolchain" "$t")
    done
    detected_agents=""
    for a in "${agents_available[@]}"; do
        ci_agent_detected "$agents_dir" "$a" && detected_agents=$(ci_comma_list_add "$detected_agents" "$a")
    done

    if [[ -z "$toolchain" ]]; then
        preselected_toolchains="$detected_toolchain"
        ci_host_is_windows && preselected_toolchains=$(ci_comma_list_add "$preselected_toolchains" powershell)
        toolchain=$(ci_join , "$(choose "Toolchains to build" "$preselected_toolchains" "$detected_toolchain" "${toolchain_available[@]}")")
    fi
    if [[ -z "$agents_raw" ]]; then
        default_agents="$detected_agents"
        [[ -n "$default_agents" ]] || default_agents="$CI_DEFAULT_AGENTS"
        agents_raw=$(ci_join , "$(choose "Agents to install" "$default_agents" "$detected_agents" "${agents_available[@]}")")
    fi
fi

# There is no default toolchain: building one nobody asked for wastes a long build.
# The empty-list check also catches --toolchain ','.
# An explicit, empty --package-caches means "no package caches", not "use the implied ones".
enabled_toolchain=""
[[ -n "$toolchain" ]] && { enabled_toolchain=$(ci_resolve_toolchain "$toolchain") || exit 1; }
if [[ -z "$enabled_toolchain" ]]; then
    echo "Warning: no toolchains selected. Choose at least one, or pass --toolchain." >&2
    show_help
    exit 1
fi
if [[ "$package_caches_set" == true ]]; then
    enabled_package_caches=$(ci_resolve_package_caches "$package_caches" "$enabled_toolchain") || exit 1
else
    enabled_package_caches=$(ci_resolve_package_caches "" "$enabled_toolchain") || exit 1
fi
enabled_agents=$(ci_resolve_agents "$agents_raw" "$agents_dir") || exit 1
container_locale=$(ci_resolve_locale "$locale") || exit 1

if [[ -z "$image" ]]; then
    image=$(ci_default_image_name "$enabled_toolchain")
fi

# Detect / validate the container runtime
runtime=$(ci_detect_runtime "$runtime") || exit 1

if [[ ! -f "$dockerfile_dir/Dockerfile" ]]; then
    echo "Warning: Dockerfile not found at: $dockerfile_dir/Dockerfile" >&2
    exit 1
fi
dockerfile_dir=$(abs_dir "$dockerfile_dir")

# --rebuild: bump the "# last changed" cache-bust dates to today in the Dockerfile
# and in the selected agent install fragments, so those layers rebuild and update the
# agents. (Write to a temp file and move: portable in-place edit for BSD and GNU sed.)
bump_last_changed() {
    local file="$1" today
    [[ -f "$file" ]] || return 0
    today=$(date +%Y-%m-%d)
    sed -E "s/# last changed [0-9]{4}-[0-9]{2}-[0-9]{2}/# last changed $today/" "$file" > "$file.tmp" \
        && mv "$file.tmp" "$file"
}
if [[ "$rebuild" == true ]]; then
    bump_last_changed "$dockerfile_dir/Dockerfile"
    for a in $enabled_agents; do
        install_fragment=$(ci_agent_config "$agents_dir" "$a" AGENT_INSTALL)
        [[ -n "$install_fragment" ]] && bump_last_changed "$agents_dir/$a/$install_fragment"
    done
    echo "    Updated '# last changed' dates to $(date +%Y-%m-%d)"
fi

# Assemble the Dockerfile: replace the agent-install marker with the selected
# fragments plus the name=binary map go.sh reads.
marker='# @@CODE_IT_AGENT_INSTALLS@@'
agent_block="# --- coding agents: ${enabled_agents// /,} (assembled from agents/) ---"
for a in $enabled_agents; do
    install_fragment=$(ci_agent_config "$agents_dir" "$a" AGENT_INSTALL)
    fragment_path="$agents_dir/$a/$install_fragment"
    if [[ ! -f "$fragment_path" ]]; then
        echo "Warning: agent '$a' has no install fragment at $fragment_path" >&2
        exit 1
    fi
    agent_block+=$'\n'"$(cat "$fragment_path")"
done
agent_file_entries=""
for a in $enabled_agents; do
    agent_binary=$(ci_agent_config "$agents_dir" "$a" AGENT_BINARY)
    agent_file_entries+=" '$a=$agent_binary'"
done
# The marker sits after "USER agent1" (rightly: the install fragments above run as
# agent1, into its home). /etc is root-owned, so write the map as root and switch
# back for the rest of the file.
agent_block+=$'\n'"USER root"
agent_block+=$'\n'"RUN printf '%s\\n'$agent_file_entries > /etc/code-it-agents"
agent_block+=$'\n'"USER agent1"

build_context=$(mktemp -d)
trap 'rm -rf "$build_context"' EXIT
if grep -qF "$marker" "$dockerfile_dir/Dockerfile"; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$marker" ]]; then
            printf '%s\n' "$agent_block"
        else
            printf '%s\n' "$line"
        fi
    done < "$dockerfile_dir/Dockerfile" > "$build_context/Dockerfile"
else
    cp "$dockerfile_dir/Dockerfile" "$build_context/Dockerfile"
fi

# Keep the buildable Dockerfile small (Apple's builder fails above ~16 KB), without
# touching heredoc bodies such as go.sh.
ci_strip_dockerfile_comments < "$build_context/Dockerfile" > "$build_context/Dockerfile.stripped" \
    && mv "$build_context/Dockerfile.stripped" "$build_context/Dockerfile"

# Build args for the toolchains and package caches, spelled the way the
# Dockerfile's ARGs match them (uppercase).
build_args=()
for tc in $CI_KNOWN_TOOLCHAIN; do
    if ci_has "$enabled_toolchain" "$tc"; then v=true; else v=false; fi
    build_args+=(--build-arg "$(printf '%s' "$tc" | tr '[:lower:]' '[:upper:]')=$v")
done
for pc in nuget npm; do
    if ci_has "$enabled_package_caches" "$pc"; then v=true; else v=false; fi
    build_args+=(--build-arg "$(printf '%s' "$pc" | tr '[:lower:]' '[:upper:]')=$v")
done
build_args+=(--build-arg "LOCALE=$container_locale")

# Label the image with its resolution, so code-it.sh can check it rather than guess
# from the image name.
build_args+=(--label "code-it.tool-chains=$(ci_join , "$enabled_toolchain")")
build_args+=(--label "code-it.package-caches=$(ci_join , "$enabled_package_caches")")
build_args+=(--label "code-it.agents=$(ci_join , "$enabled_agents")")
build_args+=(--label "code-it.locale=$container_locale")
# Each agent's binary path, so code-it.sh can tell when an image predates a change to
# an agent's definition and would run the wrong binary.
agent_binaries=""
for a in $enabled_agents; do
    agent_binaries=$(ci_comma_list_add "$agent_binaries" "$a=$(ci_agent_config "$agents_dir" "$a" AGENT_BINARY)")
done
build_args+=(--label "code-it.agent-binaries=$(ci_join , "$agent_binaries")")

echo "    Building with toolchains ${enabled_toolchain// /,}; package repos ${enabled_package_caches// /,}; agents ${enabled_agents// /,}; locale $container_locale"

# Print the command
echo "    $runtime build ${build_args[*]} -t ${image}:latest $build_context"

if [[ "$interactive" == true && "$yes" != true ]]; then
    printf 'Build now? [Y/n]: ' >&2
    read -r answer || answer=""
    case "$answer" in [Nn]*) echo "Aborted."; exit 0 ;; esac
fi

if [[ -n "$selection_file" ]]; then
    printf 'toolchains=%s\nagents=%s\n' "$(ci_join , "$enabled_toolchain")" "$(ci_join , "$enabled_agents")" > "$selection_file"
fi

if [[ "$dry_run" == true ]]; then
    exit 0
fi

"$runtime" build "${build_args[@]}" -t "${image}:latest" "$build_context"

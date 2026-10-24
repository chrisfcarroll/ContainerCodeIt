#!/usr/bin/env bash
#
# Builds the code-it container image from the Dockerfile, selecting the toolchains,
# package caches and coding agents to include. code-it.sh runs the images this builds.
#
# Toolchains, package caches and agents are data, not branches: each is a directory
# with a config and an install fragment, and this script assembles only the selected
# fragments into the Dockerfile (replacing the markers), so unselected ones cost
# nothing in the size-limited buildable file. It also writes /etc/code-it-agents, the
# name=binary map the container's go.sh reads.
#
# Usage:
#   ./code-it-build.sh [OPTIONS]
#
# Options:
#   --toolchain, -t LIST     Comma-separated toolchains to build. With none,
#                            interactive selection is used.
#                            Known names and aliases come from toolchains/*/config
#                            (today: dotnet, node/js-node/ts-node, bun/js-bun/ts-bun,
#                            python/uv, powershell/pwsh). --stack is an alias.
#   --package-caches LIST    Comma-separated package repos to support, independent of
#                            --toolchain. Known: nuget, npm, bun.
#                            Default: the repos implied by --toolchain
#                            (dotnet->nuget, node->npm).
#   --agent, -a LIST         Comma-separated agents to install. Default: opencode,claude.
#                            --agents is an alias. Interactive mode preselects detected
#                            agents instead.
#   --list-agents            List the available agents and exit.
#   --list-toolchains        List the available toolchains (and their aliases) and exit.
#   --list-package-caches    List the available package caches and exit.
#   --rebuild                Bump the "# last changed" dates in the Dockerfile and the
#                            selected fragments to today first, so those layers rerun
#                            and the agents and toolchains update.
#   --locale, -l LOCALE      The container's locale (its LANG), e.g. en_GB.UTF-8 or en-GB.
#                            Default: like-host, the host's own locale, read from
#                            LC_ALL or LANG, else macOS's AppleLocale or the Windows
#                            user locale (also from Git Bash and WSL). Windows and
#                            macOS names are translated as best they can be, and the
#                            codeset is always UTF-8. C.UTF-8 if it cannot be told.
#   --image, -i NAME         Image name to build. Default: "code-it-alpine-<chains>",
#                            a slug of the resolved --toolchain list.
#   --dockerfile-dir DIR     Directory containing the Dockerfile and definitions.
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
# (code-it.toolchains=..., code-it.package-caches=..., code-it.locale=...), so
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
list_toolchains=false
list_package_caches=false
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
        --package-caches=*)
            package_caches="${1#--package-caches=}"
            package_caches_set=true
            shift
            ;;
        --agent|--agents|-a)
            agents_raw="$2"
            shift 2
            ;;
        --list-agents)
            list_agents=true
            shift
            ;;
        --list-toolchains)
            list_toolchains=true
            shift
            ;;
        --list-package-caches)
            list_package_caches=true
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

# The definitions live next to the Dockerfile when it ships them, else next to
# this script.
agents_dir="$dockerfile_dir/agents"
[[ -d "$agents_dir" ]] || agents_dir="$script_dir/agents"
toolchains_dir="$dockerfile_dir/toolchains"
[[ -d "$toolchains_dir" ]] || toolchains_dir="$script_dir/toolchains"
package_caches_dir="$dockerfile_dir/package-caches"
[[ -d "$package_caches_dir" ]] || package_caches_dir="$script_dir/package-caches"

if [[ "$list_agents" == true ]]; then
    while IFS= read -r name; do
        short=$(ci_agent_config "$agents_dir" "$name" AGENT_SHORT)
        if [[ -n "$short" ]]; then
            printf '  %-10s -%s\n' "$name" "$short"
        else
            printf '  %s\n' "$name"
        fi
    done < <(ci_list_definitions "$agents_dir")
    exit 0
fi
if [[ "$list_toolchains" == true ]]; then
    while IFS= read -r name; do
        aliases=$(ci_agent_config "$toolchains_dir" "$name" TOOLCHAIN_ALIASES) || aliases=""
        if [[ -n "$aliases" ]]; then
            printf '  %-12s (aliases: %s)\n' "$name" "${aliases// /, }"
        else
            printf '  %s\n' "$name"
        fi
    done < <(ci_list_definitions "$toolchains_dir")
    exit 0
fi
if [[ "$list_package_caches" == true ]]; then
    ci_list_definitions "$package_caches_dir" | sed 's/^/  /'
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
    toolchain_available=($(ci_list_definitions "$toolchains_dir"))
    agents_available=()
    while IFS= read -r a; do agents_available+=("$a"); done < <(ci_list_agents "$agents_dir")
    detected_toolchain=""
    for t in "${toolchain_available[@]}"; do
        ci_toolchain_detected "$toolchains_dir" "$t" && detected_toolchain=$(ci_comma_list_add "$detected_toolchain" "$t")
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
[[ -n "$toolchain" ]] && { enabled_toolchain=$(ci_resolve_toolchain "$toolchain" "$toolchains_dir") || exit 1; }
if [[ -z "$enabled_toolchain" ]]; then
    echo "Warning: no toolchains selected. Choose at least one, or pass --toolchain." >&2
    show_help
    exit 1
fi
if [[ "$package_caches_set" == true && -z "$package_caches" ]]; then
    enabled_package_caches=""
elif [[ "$package_caches_set" == true ]]; then
    enabled_package_caches=$(ci_resolve_package_caches "$package_caches" "$enabled_toolchain" "$toolchains_dir" "$package_caches_dir") || exit 1
else
    enabled_package_caches=$(ci_resolve_package_caches "" "$enabled_toolchain" "$toolchains_dir" "$package_caches_dir") || exit 1
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
# and in the selected fragments, so those layers rebuild and update the tools.
# (Write to a temp file and move: portable in-place edit for BSD and GNU sed.)
bump_last_changed() {
    local file="$1" today
    [[ -f "$file" ]] || return 0
    today=$(date +%Y-%m-%d)
    sed -E "s/# last changed [0-9]{4}-[0-9]{2}-[0-9]{2}/# last changed $today/" "$file" > "$file.tmp" \
        && mv "$file.tmp" "$file"
}
# fragment_path DEFS_DIR NAME KEY: echo the install fragment path for a definition
fragment_path() {
    local defs_dir="$1" name="$2" key="$3" fragment
    fragment=$(ci_agent_config "$defs_dir" "$name" "$key") || fragment=""
    [[ -n "$fragment" ]] || fragment="install.dockerfile"
    printf '%s/%s/%s' "$defs_dir" "$name" "$fragment"
}
if [[ "$rebuild" == true ]]; then
    bump_last_changed "$dockerfile_dir/Dockerfile"
    for a in $enabled_agents; do
        bump_last_changed "$(fragment_path "$agents_dir" "$a" AGENT_INSTALL)"
    done
    for t in $enabled_toolchain; do
        bump_last_changed "$(fragment_path "$toolchains_dir" "$t" TOOLCHAIN_INSTALL)"
    done
    for p in $enabled_package_caches; do
        bump_last_changed "$(fragment_path "$package_caches_dir" "$p" PACKAGE_CACHE_INSTALL)"
    done
    echo "    Updated '# last changed' dates to $(date +%Y-%m-%d)"
fi

# Assemble the blocks from the selected definitions, failing if one is missing.
definition_block() {
    local defs_dir="$1" names="$2" key="$3" name path
    for name in $names; do
        path=$(fragment_path "$defs_dir" "$name" "$key")
        if [[ ! -f "$path" ]]; then
            echo "Warning: '$name' has no install fragment at $path" >&2
            exit 1
        fi
        cat "$path"
    done
}

toolchain_block=$(definition_block "$toolchains_dir" "$enabled_toolchain" TOOLCHAIN_INSTALL)
package_cache_block=$(definition_block "$package_caches_dir" "$enabled_package_caches" PACKAGE_CACHE_INSTALL)

# The launcher bind-mounts each agent's state paths into the container home, and
# Docker creates a missing mount-point parent as root. A root-owned parent would
# then block the agent from writing beside the mount (a root-owned
# ~/.local/share stops the agent writing .local/share/powershell), so create each
# selected agent's state path here as agent1, before any mounts exist.
agent_state_paths=$(ci_agent_state_mkdir_paths "$agents_dir" "$enabled_agents")
agent_mkdir_block=""
if [[ -n "$agent_state_paths" ]]; then
    agent_state_args=""
    for p in $agent_state_paths; do
        agent_state_args+=" ~/$p"
    done
    agent_mkdir_block="# Pre-create the selected agents' state paths, agent1-owned."
    agent_mkdir_block+=$'\n'"RUN mkdir -p$agent_state_args"
fi

# Agents run as agent1, into its home. /etc/code-it-agents is root-owned, so write
# the map as root and switch back for the rest of the file.
agent_block="# --- coding agents: ${enabled_agents// /,} (assembled from agents/) ---"
[[ -n "$agent_mkdir_block" ]] && agent_block+=$'\n'"$agent_mkdir_block"
for a in $enabled_agents; do
    install_fragment=$(ci_agent_config "$agents_dir" "$a" AGENT_INSTALL)
    agent_fragment="$agents_dir/$a/${install_fragment:-install.dockerfile}"
    if [[ ! -f "$agent_fragment" ]]; then
        echo "Warning: agent '$a' has no install fragment at $agent_fragment" >&2
        exit 1
    fi
    agent_block+=$'\n'"$(cat "$agent_fragment")"
done
agent_file_entries=""
for a in $enabled_agents; do
    agent_binary=$(ci_agent_config "$agents_dir" "$a" AGENT_BINARY)
    agent_file_entries+=" '$a=$agent_binary'"
done
agent_block+=$'\n'"USER root"
agent_block+=$'\n'"RUN printf '%s\\n'$agent_file_entries > /etc/code-it-agents"
agent_block+=$'\n'"USER agent1"

# The markers the Dockerfile declares. The agents' default region is replaced
# wholesale, so the base file can carry the default agent (opencode) and still
# assemble into an image with exactly the selected agents.
toolchain_marker='# @@CODE_IT_TOOLCHAIN_INSTALLS@@'
package_cache_marker='# @@CODE_IT_PACKAGE_CACHE_INSTALLS@@'
agents_begin='# @@CODE_IT_AGENTS_BEGIN@@'
agents_end='# @@CODE_IT_AGENTS_END@@'

require_marker() {
    local marker="$1" what="$2"
    if ! grep -qF "$marker" "$dockerfile_dir/Dockerfile"; then
        echo "Warning: Dockerfile has no '$marker' marker, so $what cannot be selected." >&2
        exit 1
    fi
}
[[ -n "$enabled_toolchain" ]] && require_marker "$toolchain_marker" "toolchains"
[[ -n "$enabled_package_caches" ]] && require_marker "$package_cache_marker" "package caches"
require_marker "$agents_begin" "agents"

build_context=$(mktemp -d)
trap 'rm -rf "$build_context"' EXIT
in_agents=false
while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
        "$toolchain_marker")        printf '%s\n' "$toolchain_block"; continue ;;
        "$package_cache_marker")    printf '%s\n' "$package_cache_block"; continue ;;
        "$agents_begin")            in_agents=true; printf '%s\n' "$agent_block"; continue ;;
        "$agents_end")              in_agents=false; continue ;;
    esac
    [[ "$in_agents" == true ]] && continue
    printf '%s\n' "$line"
done < "$dockerfile_dir/Dockerfile" > "$build_context/Dockerfile"

# Keep the buildable Dockerfile small (Apple's builder fails above ~16 KB), without
# touching heredoc bodies such as go.sh.
ci_strip_dockerfile_comments < "$build_context/Dockerfile" > "$build_context/Dockerfile.stripped" \
    && mv "$build_context/Dockerfile.stripped" "$build_context/Dockerfile"

# Extra CA certificates (ca-certificates/ next to the Dockerfile) go into the
# context, so a corporate TLS proxy's CA is trusted from the first apk fetch. The
# Dockerfile always copies the folder, so it exists even when empty.
mkdir -p "$build_context/ca-certificates"
if [[ -d "$dockerfile_dir/ca-certificates" ]]; then
    cp -R "$dockerfile_dir/ca-certificates/." "$build_context/ca-certificates/"
fi
# A pattern that matches nothing stays literal, so test each name rather than
# passing them to ls, which would fail and, under pipefail, end the script.
ca_files=""
for f in "$build_context/ca-certificates"/*.[cC][rR][tT] \
         "$build_context/ca-certificates"/*.[cC][eE][rR] \
         "$build_context/ca-certificates"/*.[pP][eE][mM]; do
    if [[ -f "$f" ]]; then ca_files+="${f##*/} "; fi
done
if [[ -n "$ca_files" ]]; then
    echo "    Adding certificate trust from ca-certificates/: ${ca_files% }"
else
    echo "    No additional certificate trust was requested"
fi

# The fragments are the toolchain and package-cache selection, so the only build
# arg left is the locale.
build_args=(--build-arg "LOCALE=$container_locale")

# Label the image with its resolution, so code-it.sh can check it rather than guess
# from the image name.
build_args+=(--label "code-it.toolchains=$(ci_join , "$enabled_toolchain")")
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

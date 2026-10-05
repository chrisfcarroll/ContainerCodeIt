#!/usr/bin/env bash
#
# One interactive command that takes a new user from nothing to a built image with
# their agent logins carried over.
#
# It detects the container runtime, the host toolchains and agents, asks what to
# include, runs code-it-build, optionally copies agent state into the save dir, and
# prints the code-it command to start.
#
# Usage:
#   ./code-it-first-run.sh [OPTIONS]
#
# Options:
#   --save-dir, -s DIR       Where agent state is kept/copied. Default: ~/.config/code-it
#   --work-dir, -w DIR       Host directory mounted as /work. Default: .
#   --toolchain, -t LIST   Preselect toolchains (skips the question).
#   --agents, -a LIST        Preselect agents (skips the question).
#   --image, -i NAME         Image name to build.
#   --dockerfile-dir DIR     Directory containing the Dockerfile.
#   --runtime, -r NAME       docker or container. Default: auto-detected.
#   --code-it-build PATH     code-it-build launcher to invoke. Default: sibling.
#   --yes, -y                Accept the defaults: no questions.
#   --dry-run, -d            Do everything except build and copy; print what would happen.
#   --help, -h               Show this help message.

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/code-it-common.sh
. "$script_dir/lib/code-it-common.sh"

save_dir="$HOME/.config/code-it"
work_dir="."
toolchain_arg=""
agents_arg=""
image=""
dockerfile_dir="$script_dir"
runtime=""
code_it_build="$script_dir/code-it-build.sh"
yes=false
dry_run=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --save-dir|-s)      save_dir="$2"; shift 2 ;;
        --work-dir|-w)      work_dir="$2"; shift 2 ;;
        --toolchain|-t)   toolchain_arg="$2"; shift 2 ;;
        --agents|-a)        agents_arg="$2"; shift 2 ;;
        --image|-i)         image="$2"; shift 2 ;;
        --dockerfile-dir)   dockerfile_dir="$2"; shift 2 ;;
        --runtime|-r)       runtime="$2"; shift 2 ;;
        --code-it-build)    code_it_build="$2"; shift 2 ;;
        --yes|-y)           yes=true; shift ;;
        --dry-run|-d)       dry_run=true; shift ;;
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
            echo "Unexpected argument: $1" >&2
            echo "Run $0 --help for usage." >&2
            exit 1
            ;;
    esac
done

agents_dir="$script_dir/agents"

# 1. Container runtime and git, reusing code-it's detection and advice.
runtime=$(ci_detect_runtime "$runtime") || exit 1
if ! command -v git &>/dev/null; then
    echo "Warning: Git command not found. Please install Git and ensure it is in your PATH." >&2
    exit 1
fi

# 2. Detect host toolchains and agents.
toolchain_available=($CI_KNOWN_TOOLCHAIN)
agents_available=()
for a in $CI_DEFAULT_AGENTS; do
    ci_agent_exists "$agents_dir" "$a" && agents_available+=("$a")
done
while IFS= read -r a; do
    [[ " ${agents_available[*]:-} " == *" $a "* ]] || agents_available+=("$a")
done < <(ci_list_agents "$agents_dir")

detected_toolchain=""
for t in "${toolchain_available[@]}"; do
    if ci_toolchain_detected "$t"; then
        detected_toolchain=$(ci_comma_list_add "$detected_toolchain" "$t")
    fi
done
detected_agents=""
for a in "${agents_available[@]}"; do
    if ci_agent_detected "$agents_dir" "$a"; then
        detected_agents=$(ci_comma_list_add "$detected_agents" "$a")
    fi
done

# parse_selection ANSWER ITEMS...: map numbers (1-based) or names to a space list
parse_selection() {
    local answer="$1"; shift
    local items=("$@") out="" tok idx it
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

# choose LABEL DEFAULT ITEMS...: numbered prompt; prints the selection
choose() {
    local label="$1" default="$2"; shift 2
    local items=("$@") i=1 t flag answer
    if [[ "$yes" == true ]]; then
        printf '%s' "$default"
        return 0
    fi
    # The prompts go to stderr: only the selection is captured from stdout.
    echo "$label (detected marked *):" >&2
    for t in "${items[@]}"; do
        flag=""
        case " $detected_toolchain $detected_agents " in *" $t "*) flag=" *" ;; esac
        printf '  %d) %s%s\n' "$i" "$t" "$flag" >&2
        i=$((i+1))
    done
    printf 'Choose %s [%s]: ' "$label" "$(ci_join , "$default")" >&2
    read -r answer || answer=""
    if [[ -z "$answer" ]]; then
        printf '%s' "$default"
    else
        parse_selection "$answer" "${items[@]}"
    fi
}

echo "== ContainerCodeIt first run =="
echo "Using container runtime: $runtime"

if [[ -n "$toolchain_arg" ]]; then
    chosen_toolchain=$(ci_resolve_toolchain "$toolchain_arg") || exit 1
else
    default_tcs="$detected_toolchain"
    [[ -n "$default_tcs" ]] || default_tcs="$CI_DEFAULT_TOOLCHAIN"
    chosen_toolchain=$(choose "Toolchains to build" "$default_tcs" "${toolchain_available[@]}")
fi
if [[ -z "$chosen_toolchain" ]]; then
    echo "Warning: no toolchains selected." >&2
    exit 1
fi

if [[ -n "$agents_arg" ]]; then
    chosen_agents=$(ci_resolve_agents "$agents_arg" "$agents_dir") || exit 1
else
    default_agents="$detected_agents"
    [[ -n "$default_agents" ]] || default_agents="$CI_DEFAULT_AGENTS"
    chosen_agents=$(choose "Agents to install" "$default_agents" "${agents_available[@]}")
fi
if [[ -z "$chosen_agents" ]]; then
    echo "Warning: no agents selected." >&2
    exit 1
fi

# 3/4. Show the code-it-build command, confirm, run it.
build_cmd=("$code_it_build" --toolchain "$(ci_join , "$chosen_toolchain")" --agent "$(ci_join , "$chosen_agents")" --runtime "$runtime")
[[ -n "$image" ]] && build_cmd+=(--image "$image")
[[ "$dockerfile_dir" != "$script_dir" ]] && build_cmd+=(--dockerfile-dir "$dockerfile_dir")

echo
echo "Build command:"
echo "  ${build_cmd[*]}"

if [[ "$yes" != true ]]; then
    printf 'Build now? [Y/n]: '
    read -r answer || answer=""
    case "$answer" in
        [Nn]*) echo "Aborted."; exit 0 ;;
    esac
fi

if [[ "$dry_run" == true ]]; then
    echo "    (dry run: not building)"
else
    "${build_cmd[@]}"
fi

# 5. Copy agent host state into the save dir, preserving layout, never overwriting.
copy_tree_no_clobber() {
    local src="$1" dest="$2" rel d f
    mkdir -p "$dest"
    while IFS= read -r d; do
        rel=${d#"$src"/}
        mkdir -p "$dest/$rel"
    done < <(find "$src" -type d)
    while IFS= read -r f; do
        rel=${f#"$src"/}
        [[ -e "$dest/$rel" ]] && continue
        mkdir -p "$(dirname "$dest/$rel")"
        cp -p "$f" "$dest/$rel"
    done < <(find "$src" -type f)
}

copy_state_path() {
    local rel="$1" src="$HOME/$1" dest="$2/$1"
    if [[ "$dry_run" == true ]]; then
        echo "      would copy ~/$rel -> $dest (existing files kept)"
        return 0
    fi
    if [[ -d "$src" ]]; then
        copy_tree_no_clobber "$src" "$dest"
        echo "      copied ~/$rel -> $dest (existing files kept)"
    elif [[ -e "$dest" ]]; then
        echo "      exists, not overwritten: $dest"
    else
        mkdir -p "$(dirname "$dest")"
        cp -p "$src" "$dest"
        echo "      copied ~/$rel -> $dest"
    fi
}

for a in $chosen_agents; do
    host_paths=""
    dirs=$(ci_agent_config "$agents_dir" "$a" AGENT_STATE_DIRS)
    files=$(ci_agent_config "$agents_dir" "$a" AGENT_STATE_FILES)
    subdir=$(ci_agent_config "$agents_dir" "$a" AGENT_SAVE_SUBDIR) || subdir=""
    agent_save_dir="$save_dir${subdir:+/$subdir}"
    local_ifs_save="$IFS"; IFS=':'
    for p in $dirs $files; do
        [[ -n "$p" && -e "$HOME/$p" ]] && host_paths+=" $p"
    done
    IFS="$local_ifs_save"
    [[ -z "$host_paths" ]] && continue

    echo
    echo "Agent '$a' has host configuration that can be copied into $agent_save_dir:"
    for p in $host_paths; do echo "  ~/$p"; done
    echo "This copies credentials, which will be readable by the agent in the container."

    do_copy=true
    if [[ "$yes" != true && "$dry_run" != true ]]; then
        printf 'Copy them? [y/N]: '
        read -r answer || answer=""
        case "$answer" in
            [Yy]*) do_copy=true ;;
            *)     do_copy=false ;;
        esac
    fi
    if [[ "$do_copy" == true ]]; then
        for p in $host_paths; do copy_state_path "$p" "$agent_save_dir"; done
    fi
done

# 6. Print the code-it command to start.
echo
echo "Start an agent with:"
for a in $chosen_agents; do
    start_cmd=("$script_dir/code-it.sh" --agent "$a" --work-dir "$work_dir")
    [[ "$save_dir" != "$HOME/.config/code-it" ]] && start_cmd+=(--save-dir "$save_dir")
    echo "  ${start_cmd[*]}"
done

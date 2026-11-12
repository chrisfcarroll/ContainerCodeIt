#!/usr/bin/env bash
#
# One interactive command that takes a new user from nothing to a built image with
# their agent logins carried over.
#
# It asks which container runtime to use, showing which of docker, Apple's container
# and wslc are found and suggesting the platform's own (container on macOS, wslc on
# Windows, docker elsewhere) when it is found, and saves the answer as code-it's
# default runtime (code-it-defaults --runtime changes it later).
#
# It delegates toolchain/agent selection and image building to code-it-build, then
# optionally copies host agent state into the save dir, sets each agent's config there
# to run without permission prompts (AGENT_PERMISSIONS), and prints the run command.
#
# There is no default toolchain. The toolchains detected on the host are
# preselected, powershell among them when pwsh or powershell is found, and powershell
# on Windows (Git Bash, MSYS2, Cygwin or WSL) too. With none preselected, choose at
# least one, or pass --toolchain.
#
# Usage:
#   ./code-it-first-run.sh [OPTIONS]
#
# Options:
#   --save-dir, -s DIR       Where agent state is kept/copied. Default: ~/.config/code-it
#   --work-dir, -w DIR       Host directory to mount, at /work/<parent>/<name> (its
#                            parent's and its own names, for agents' per-directory
#                            memory). Default: .
#   --toolchain, -t LIST     Select toolchains (skips that question).
#   --agents, -a LIST        Select agents (skips that question).
#   --image, -i NAME         Image name to build.
#   --dockerfile-dir DIR     Directory containing the Dockerfile.
#   --runtime, -r NAME       docker, container or wslc (skips that question, and is
#                            saved as the default). Default: asked; with --yes, the
#                            platform's own if found, else auto-detected.
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
code_it_defaults="$script_dir/code-it-defaults.sh"
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

# Git configuration and agent-state copying remain first-run's responsibility.
if ! command -v git &>/dev/null; then
    echo "Warning: Git command not found. Please install Git and ensure it is in your PATH." >&2
    exit 1
fi

# The container runtime: asked, unless given, and saved as the default, so code-it,
# code-it-build and code-it-doctor use it from now on.
found_runtimes=$(ci_runtimes_found)
if [[ -z "$runtime" && -n "$found_runtimes" ]]; then
    runtime=$(ci_preferred_runtime)
    if [[ "$yes" != true ]]; then
        echo
        until ci_ask_runtime "$runtime"; do :; done
        runtime="$CI_CHOSEN_RUNTIME"
    fi
fi
if [[ -n "$runtime" ]]; then
    defaults_cmd=("$code_it_defaults" --save-dir "$save_dir" --runtime "$runtime")
    [[ "$dry_run" == true ]] && defaults_cmd+=(--dry-run)
    "${defaults_cmd[@]}" || exit 1
fi

# code-it-build owns host detection, selection, runtime detection and build confirmation.
selection_file=$(mktemp "${TMPDIR:-/tmp}/code-it-first-run-selection.XXXXXX")
rm -f "$selection_file"
trap 'rm -f "$selection_file"' EXIT
build_cmd=("$code_it_build" --interactive --selection-file "$selection_file")
[[ -n "$toolchain_arg" ]] && build_cmd+=(--toolchain "$toolchain_arg")
[[ -n "$agents_arg" ]] && build_cmd+=(--agent "$agents_arg")
[[ -n "$image" ]] && build_cmd+=(--image "$image")
[[ "$dockerfile_dir" != "$script_dir" ]] && build_cmd+=(--dockerfile-dir "$dockerfile_dir")
[[ -n "$runtime" ]] && build_cmd+=(--runtime "$runtime")
[[ "$save_dir" != "$HOME/.config/code-it" ]] && build_cmd+=(--save-dir "$save_dir")
[[ "$yes" == true ]] && build_cmd+=(--yes)
[[ "$dry_run" == true ]] && build_cmd+=(--dry-run)

echo
echo "  ${build_cmd[*]}"
"${build_cmd[@]}"

# No selection means the user declined the build.
[[ -f "$selection_file" ]] || exit 0
chosen_agents=""
while IFS= read -r line; do
    case "$line" in agents=*) chosen_agents="${line#agents=}" ;; esac
done < "$selection_file"
if [[ -z "$chosen_agents" ]]; then
    echo "Warning: no agents selected." >&2
    exit 1
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

for a in ${chosen_agents//,/ }; do
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

# 6. Whether or not host state was copied, fill in the agent's default configuration
# and set it to work free of permissions interruption: the container is the sandbox.
for a in ${chosen_agents//,/ }; do
    subdir=$(ci_agent_config "$agents_dir" "$a" AGENT_SAVE_SUBDIR) || subdir=""
    agent_save_dir="$save_dir${subdir:+/$subdir}"
    ci_agent_config "$agents_dir" "$a" AGENT_PERMISSIONS >/dev/null || continue
    echo
    echo "Setting agent '$a' to run without permission prompts in the container:"
    if [[ "$dry_run" != true && -d "$agents_dir/$a/default-config" ]]; then
        copy_tree_no_clobber "$agents_dir/$a/default-config" "$agent_save_dir"
    fi
    ci_agent_set_permissions "$agents_dir" "$a" "$agent_save_dir" "$dry_run" || true
done

# 7. Print the code-it command to start.
echo
echo "Start an agent with:"
for a in ${chosen_agents//,/ }; do
    start_cmd=("$script_dir/code-it.sh" --agent "$a" --work-dir "$work_dir")
    [[ "$save_dir" != "$HOME/.config/code-it" ]] && start_cmd+=(--save-dir "$save_dir")
    echo "  ${start_cmd[*]}"
done

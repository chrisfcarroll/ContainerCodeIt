#!/usr/bin/env bash
#
# Launches an Alpine Linux container with OpenCode, Claude Code, and a parameterisable set of toolchains.
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
#
# Usage:
#   ./code-it.sh [OPTIONS] [PROMPT] [-- AGENT-ARGS...]
#
# Arguments go to three places: code-it's own options; the container runtime, with
# --env, --env-file and --run-arg (each repeatable, one argument each, so nothing is
# word-split); and the coding agent, everything after --.
#
# Options:
#   --agent, -a NAME         Run the agent defined in agents/NAME. Only that agent's
#                            state is mounted. Default: opencode, or the agent saved
#                            by code-it-defaults.
#   --opencode, -o           Shortcut for --agent opencode.
#   --claude, -c             Shortcut for --agent claude.
#   --no-agent, --zsh        Run a plain interactive zsh instead of a coding agent:
#                            no agent state is mounted and no login is needed. A
#                            prompt or --headless would have no agent to run it,
#                            and is an error.
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
#   --env, -e NAME[=VALUE]   Set an environment variable in the container. Repeatable.
#                            A bare NAME passes the host's value of NAME, if it is set,
#                            e.g. --env HTTPS_PROXY --env NO_PROXY=localhost
#   --env-file FILE          Read environment variables from FILE, in the runtime's
#                            KEY=VALUE format. Repeatable.
#   --run-arg ARG            Pass ARG to `docker run` (or `container run`) verbatim.
#                            Repeatable; one argument each, so an option and its value
#                            are two --run-args, or one if joined with =, e.g.
#                              --run-arg --network=host --run-arg --dns --run-arg 10.0.0.2
#                            Ports work this way too: there is no --port option, and
#                            by default no port is mapped at all, e.g.
#                              --run-arg -p --run-arg 8000:3000
#                            The runtime's own flags differ, so these are not portable
#                            between docker and container. --docker-arg is an alias.
#                            Arguments in SAVE-DIR/run-args (see Notes) come first.
#   --work-dir, -w DIR       Host directory to mount in the container, at
#                            /work/<parent>/<name> (the names of DIR's parent
#                            directory and of DIR itself, so directories keep
#                            their names for agents' per-directory memory).
#                            DIR whose parent is / is mounted at /work/<name>;
#                            /, at /work. Defaults to "."
#   --save-dir, -s DIR       Host directory for storing agent configuration and state volumes.
#                            Created if missing. Defaults to ~/.config/code-it
#   --image, -i NAME         Image name to run. Default: "code-it-alpine-<toolchains>", a
#                            slug of the resolved --toolchain list, e.g. code-it-alpine-dotnet,
#                            code-it-alpine-node-bun. When that image does not exist, the
#                            most-recently built existing image whose code-it.toolchains
#                            label contains every requested toolchain is used instead;
#                            failing that, code-it-build.sh builds it first.
#                            Set it explicitly to force a particular image (an error if it
#                            does not exist).
#   --runtime, -r NAME       Container runtime to use: "docker" or "container".
#                            Default: auto-detected as described above.
#   --locale, -l LOCALE      The container's locale (its LANG), e.g. en_GB.UTF-8 or en-GB.
#                            Passed to the container when it runs, so it need not be
#                            the image's. Default: like-host, the host's own locale
#                            (see code-it-build.sh --help); C.UTF-8 if it cannot be told.
#   --agent-name NAME        Name of the agent running in the container. Used for Git author
#                            attribution and home directory naming. Must match the USER set in
#                            the Dockerfile. Default: "Agent1"
#
# Toolchains (used for the default image name, and to decide which host package
# caches are mounted read-only). Each option takes a list, so there are no on/off
# flags to clash with future toolchain names:
#   --toolchain, -t LIST     Comma-separated toolchains. --stack is an alias.
#                            There is no default list. Without --toolchain, they are
#                            those of the --image given; else of the saved default
#                            toolchain (see code-it-defaults); else of the remembered
#                            image, the most recent in SAVE-DIR/image-history whose
#                            toolchains cover 70% of your recent runs; else of the most
#                            recently used, or else built, code-it image. With no
#                            SAVE-DIR or no code-it image, code-it-first-run.sh runs
#                            instead.
#                            Known: dotnet, node (aliases js-node, ts-node), bun
#                            (aliases js-bun, ts-bun), python (alias uv),
#                            powershell (alias pwsh), rust, go, gcc, g++,
#                            clang (alias llvm).
#   --package-caches LIST    Comma-separated package repos whose host cache is mounted
#                            read-only. 
#                            Known: nuget, npm, bun.
#                            Default: the package repos implied by --toolchain
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
#   ./code-it.sh --toolchain python
#       Runs the code-it-alpine-python image, built by code-it-build.sh --toolchain python.
#
#   ./code-it.sh --run-arg -p --run-arg 8000:3000
#       Maps host port 8000 to the container's port 3000. No port is mapped by
#       default; --run-arg is how ports are mapped now.
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
#   - Defaults saved by code-it-defaults fill in whatever the command line does not
#     say: the agent (its options win over the default) and the toolchain (the
#     default beats the remembered-image heuristic; --toolchain and --image win over
#     it). Each agent's model comes from its own configuration under the save dir;
#     run code-it-defaults to set it there.
#   - The prompt and any pass-through arguments are translated into each agent's own
#     command line, from the AGENT_CMD_* templates in agents/NAME/config: --prompt
#     becomes `claude PROMPT` or `opencode mini --prompt PROMPT`, and with --headless it
#     becomes `claude -p PROMPT` or `opencode run PROMPT`
#   - SAVE-DIR/run-args (default ~/.config/code-it/run-args), if it exists, holds run
#     arguments for every run, like devcontainer.json's runArgs: one argument per line,
#     not quoted; blank lines and lines starting with # are ignored. e.g.
#         # Behind the office proxy
#         -e
#         HTTPS_PROXY
#         --dns=10.0.0.2
#     They come before --env, --env-file and --run-arg, which come after code-it's own,
#     so with docker a later -e of the same name wins.
#   - Git author name and email are automatically captured from environment or git config
#   - Volume mounts preserve the selected agent's state between container runs, so you
#     can destroy the container and create a new one without logging in again. Only
#     the paths in AGENT_STATE_DIRS and AGENT_STATE_FILES of agents/NAME/config are
#     mounted, under SAVE-DIR (or SAVE-DIR/AGENT_SAVE_SUBDIR, e.g. for opencode, v2,
#     whose state lives under opencode-v2/)
#   - Only one container at a time may use an agent's AGENT_EXCLUSIVE_DIRS (opencode's
#     session database, ~/.local/share/opencode, is corrupted if two share it). When
#     another code-it run is using them, code-it warns and mounts a copy of its own,
#     SAVE-DIR/.code-it-instances/AGENT/N/..., with the agent's credentials
#     (AGENT_EXCLUSIVE_CARRY) copied in. Sessions made there stay in that copy.
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
agent_explicit=false
no_agent=false
work_dir_to_mount="."
save_dir="$HOME/.config/code-it"
image=""
image_explicit=false
runtime=""
locale="$CI_LOCALE_LIKE_HOST"
agent_name="Agent1"
dry_run=false
container_args=""
prompt=""
prompt_set=false
headless=false
agent_args=()
list_agents=false
# --env, --env-file and --run-arg, in command-line order, as container run arguments
cli_run_args=()

# Toolchains (see --help). Empty means "those of --image, else of the remembered or
# an existing image"; the package caches default to the ones they imply.
toolchain=""
toolchain_explicit=false
package_caches=""
package_caches_explicit=false

agents_dir="$script_dir/agents"
toolchains_dir="$script_dir/toolchains"
package_caches_dir="$script_dir/package-caches"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --claude|-c)
            code_agent="claude"
            agent_explicit=true
            shift
            ;;
        --opencode|-o)
            code_agent="opencode"
            agent_explicit=true
            shift
            ;;
        --no-agent|--zsh)
            no_agent=true
            shift
            ;;
        --agent|-a)
            code_agent="$2"
            agent_explicit=true
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
        --build-image|-b|--rebuild-image|-B|--dockerfile-dir)
            echo "$1 has been removed: build images with code-it-build.sh, then run them." >&2
            exit 1
            ;;
        --runtime|-r)
            runtime="$2"
            shift 2
            ;;
        --locale|-l)
            locale="$2"
            shift 2
            ;;
        --agent-name)
            agent_name="$2"
            shift 2
            ;;
        --toolchain|--tech|--stack|-t)
            toolchain="$2"
            toolchain_explicit=true
            shift 2
            ;;
        --package-caches)
            package_caches="$2"
            package_caches_explicit=true
            shift 2
            ;;
        --package-caches=*)
            package_caches="${1#--package-caches=}"
            package_caches_explicit=true
            shift
            ;;
        --env|-e)
            if ! ci_valid_env_spec "$2"; then
                echo "Warning: --env needs NAME or NAME=VALUE, not '$2'." >&2
                exit 1
            fi
            cli_run_args+=(-e "$2")
            shift 2
            ;;
        --env-file)
            if [[ ! -f "$2" ]]; then
                echo "Warning: --env-file not found: $2" >&2
                exit 1
            fi
            cli_run_args+=(--env-file "$2")
            shift 2
            ;;
        --run-arg|--docker-arg)
            cli_run_args+=("$2")
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

# --no-agent runs a plain zsh: a prompt or --headless would have no agent to run it
if [[ "$no_agent" == true ]]; then
    if [[ "$prompt_set" == true ]]; then
        echo "--no-agent runs a plain zsh shell; there is no agent to give a prompt to." >&2
        exit 1
    fi
    if [[ "$headless" == true ]]; then
        echo "--no-agent runs an interactive zsh; --headless applies to agents." >&2
        exit 1
    fi
fi

# --list-agents lists the available agent definitions and exits.
if [[ "$list_agents" == true ]]; then
    ci_print_agents "$agents_dir"
    exit 0
fi

# Defaults saved by code-it-defaults (Spec 15) fill in whatever the command line
# does not say: the agent, and the toolchain, which then beats the remembered-image
# heuristic below. Explicit options always win over the saved defaults. --no-agent
# runs no agent, so no saved default agent applies.
saved_agent=""
saved_toolchain=""
if [[ "$no_agent" == false && "$agent_explicit" == false ]]; then
    saved_agent=$(ci_config_value "$save_dir/defaults" "default-agent") || saved_agent=""
    if [[ -n "$saved_agent" ]]; then
        code_agent="$saved_agent"
        # Say so: the agent's own state comes with it, and v2's login lives
        # elsewhere from v1's, so the switch is otherwise invisible
        echo "    Using saved default agent: $saved_agent"
    fi
fi
toolchain_from_defaults=false
if [[ "$toolchain_explicit" == false && "$image_explicit" == false ]]; then
    saved_toolchain=$(ci_config_value "$save_dir/defaults" "default-toolchain") || saved_toolchain=""
    if [[ -n "$saved_toolchain" ]]; then
        toolchain="$saved_toolchain"
        toolchain_explicit=true
        toolchain_from_defaults=true
        echo "    Using saved default toolchain: $saved_toolchain"
    fi
fi

# Load the chosen agent's definition. The agent name is data: shortcut flags are
# resolved here, but every other detail comes from agents/<name>/config. --no-agent
# loads nothing: no state to mount, no exclusive dirs to lock, no command templates.
AGENT_SAVE_SUBDIR=""
AGENT_EXCLUSIVE_DIRS=""
AGENT_EXCLUSIVE_CARRY=""
if [[ "$no_agent" == false ]]; then
    if ! ci_agent_exists "$agents_dir" "$code_agent"; then
        echo "Warning: Unknown agent '$code_agent'. The available agents are:" >&2
        ci_print_agents "$agents_dir" >&2
        echo "code-it-add-agent NAME adds a new one, if the agent has a recognised internet presence." >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    . "$agents_dir/$code_agent/config"
else
    AGENT_STATE_DIRS=""
    AGENT_STATE_FILES=""
    AGENT_CONFIG_LABEL=""
    AGENT_BINARY=""
fi

# Resolve --toolchain / --package-caches into a set of known toolchain names (space-
# separated in $enabled_toolchain) and known package repo names (in
# $enabled_package_caches). --package-caches replaces the set implied by the
# toolchains (dotnet->nuget, node->npm). An unknown name is a hard error. Without
# --toolchain the list stays empty until the image is chosen, below.
enabled_toolchain=$(ci_resolve_toolchain "$toolchain" "$toolchains_dir") || exit 1
if [[ "$toolchain_explicit" == true && -z "$enabled_toolchain" ]]; then
    echo "Warning: --toolchain needs at least one toolchain." >&2
    exit 1
fi
if [[ "$package_caches_explicit" == true && -z "$package_caches" ]]; then
    enabled_package_caches=""
else
    enabled_package_caches=$(ci_resolve_package_caches "$package_caches" "$enabled_toolchain" "$toolchains_dir" "$package_caches_dir") || exit 1
fi
container_locale=$(ci_resolve_locale "$locale") || exit 1

toolchain_has()    { ci_has "$enabled_toolchain" "$1"; }
package_cache_has() { ci_has "$enabled_package_caches" "$1"; }

# Default image name from the toolchain list, e.g. code-it-alpine-dotnet or
# code-it-alpine-node-bun. --image overrides it.
if [[ -z "$image" && -n "$enabled_toolchain" ]]; then
    image=$(ci_default_image_name "$enabled_toolchain")
fi

# Detect / validate the container runtime (after parsing, so --runtime is honoured).
runtime=$(ci_detect_runtime "$runtime") || exit 1

# Give the Apple container runtime enough memory for the agent to work with
if [[ "$runtime" == "container" ]]; then
    container_args="--memory 3g"
fi
echo "    Using container runtime: $runtime"
if [[ "$no_agent" == true ]]; then
    echo "    Using code agent: none (zsh shell)"
else
    echo "    Using code agent: $code_agent"
fi

# List existing images in a runtime-appropriate way. Done up front so the default
# selection below can use them, and a broken daemon is reported before first-run.
if [[ "$runtime" == "docker" ]]; then
    valid_images=$(docker images --format "{{.Repository}}:{{.Tag}}") || images_rc=$?
else
    valid_images=$(container image ls) || images_rc=$?
fi
if [[ "${images_rc:-0}" != 0 ]]; then
    echo "Warning: Could not list $runtime images. Is the $runtime daemon or service running?" >&2
    exit 1
fi

# Default selection, when neither --toolchain nor --image was given: with no save
# dir yet, or no code-it image at all, there is no setup, so run first-run. With a
# save dir and history, the 70% weighted rule of Spec 09 applies; without history (or
# if it selects nothing), the most recent existing code-it image. See Spec 10, which
# amends Spec 09's final paragraph.
first_run="${CODE_IT_FIRST_RUN:-$script_dir/code-it-first-run.sh}"
run_first_run() {
    echo "    No code-it image or setup found; running code-it-first-run."
    if [[ "$dry_run" == true ]]; then
        echo "    (dry run: would run $first_run)"
        exit 0
    fi
    "$first_run" --save-dir "$save_dir" --work-dir "$work_dir_to_mount" --runtime "$runtime"
    exit $?
}

if [[ "$toolchain_explicit" == false && "$image_explicit" == false ]]; then
    default_image=""
    default_label="existing image"
    if [[ ! -d "$save_dir" ]]; then
        run_first_run
    fi
    default_history="$save_dir/image-history"
    if [[ -f "$default_history" ]]; then
        default_image=$(ci_history_choose_image "$runtime" "$default_history" "$toolchains_dir") || default_image=""
        [[ -n "$default_image" ]] && default_label="remembered image"
    fi
    if [[ -z "$default_image" ]]; then
        default_image=$(ci_choose_default_image "$runtime" "$default_history") || default_image=""
    fi
    selected_chains=""
    [[ -n "$default_image" ]] && selected_chains=$(ci_image_toolchain "$runtime" "$default_image")
    if [[ -z "$selected_chains" ]]; then
        run_first_run
    else
        enabled_toolchain=$(ci_known_toolchain "$selected_chains" "$toolchains_dir")
        if [[ "$(ci_join , "$enabled_toolchain")" != "$selected_chains" ]]; then
            echo "    Note: image '$default_image' has toolchains this code-it does not know ($selected_chains); using $(ci_join , "${enabled_toolchain:-none}")."
        fi
        if [[ "$package_caches_explicit" == false ]]; then
            enabled_package_caches=$(ci_resolve_package_caches "" "$enabled_toolchain" "$toolchains_dir" "$package_caches_dir") || exit 1
        fi
        image="$default_image"
        echo "    Using $default_label: $image"
    fi
elif [[ "$toolchain_explicit" == false ]]; then
    # --image without --toolchain: the image's own toolchains (its label, else its
    # name) decide the package caches.
    enabled_toolchain=$(ci_known_toolchain "$(ci_image_toolchain "$runtime" "$image")" "$toolchains_dir")
    if [[ "$package_caches_explicit" == false ]]; then
        enabled_package_caches=$(ci_resolve_package_caches "" "$enabled_toolchain" "$toolchains_dir" "$package_caches_dir") || exit 1
    fi
fi

# Ensure required commands
if ! command -v git &>/dev/null; then
    echo "Warning: Git command not found. Please install Git and ensure it is in your PATH." >&2
    exit 1
fi

# Ensure required paths exist
if [[ ! -d "$work_dir_to_mount" ]]; then
    echo "Warning: work-dir directory does not exist: $work_dir_to_mount." >&2
    echo "Please specify a directory where you have a git repo, or repos, you want the agent to work on." >&2
    exit 1
fi
work_dir_to_mount=$(abs_dir "$work_dir_to_mount")
# The container path the work dir is mounted at, /work/<parent>/<name>: directory
# names matter for agents' per-directory memory, so no fixed /work. go.sh cds to
# it (CODE_IT_WORK_DIR), because the image's own WORKDIR /work is only a default.
container_work_dir=$(ci_work_mount_path "$work_dir_to_mount")

# Create the save dir structure so mounts always work, even on first run. State
# paths come from the agent definition: directories are created; single files are
# pre-created so the runtime does not make a directory in their place.
# An agent whose state would clash with another's (opencode-v2 reads the same
# paths as opencode, but rejects its config) keeps it under AGENT_SAVE_SUBDIR.
agent_save_dir="$save_dir${AGENT_SAVE_SUBDIR:+/$AGENT_SAVE_SUBDIR}"
mkdir -p "$agent_save_dir"
agent_state_dirs=()
if [[ -n "${AGENT_STATE_DIRS:-}" ]]; then
    IFS=':' read -r -a agent_state_dirs <<< "$AGENT_STATE_DIRS"
fi
for d in ${agent_state_dirs[@]+"${agent_state_dirs[@]}"}; do
    [[ -n "$d" ]] && mkdir -p "$agent_save_dir/$d"
done
agent_state_files=()
if [[ -n "${AGENT_STATE_FILES:-}" ]]; then
    IFS=':' read -r -a agent_state_files <<< "$AGENT_STATE_FILES"
fi
for f in ${agent_state_files[@]+"${agent_state_files[@]}"}; do
    [[ -n "$f" ]] || continue
    [[ -e "$agent_save_dir/$f" ]] || echo '{}' > "$agent_save_dir/$f"
done

# Write the agent's default configuration file(s) on first run, preserving layout.
default_config_dir="$agents_dir/$code_agent/default-config"
if [[ "$no_agent" == false && -d "$default_config_dir" ]]; then
    while IFS= read -r src; do
        rel=${src#"$default_config_dir"/}
        dest="$agent_save_dir/$rel"
        if [[ ! -e "$dest" ]]; then
            mkdir -p "$(dirname "$dest")"
            cp "$src" "$dest"
            echo "    Created $AGENT_CONFIG_LABEL: $dest"
        fi
    done < <(find "$default_config_dir" -type f | sort)
fi
save_dir=$(abs_dir "$save_dir")
agent_save_dir=$(abs_dir "$agent_save_dir")
history_file="$save_dir/image-history"
run_args_file="$save_dir/run-args"

echo "    Checking $image ..."

# If the exact image is missing and the user did not name one, use the most-recently
# built existing image whose recorded toolchains contain every requested chain.
if ! echo "$valid_images" | grep -qE "^${image}([: ]|$)"; then
    if [[ "$image_explicit" == true ]]; then
        echo "Warning: $runtime image '$image' does not exist." >&2
        echo "Build it, or set --image to an image that exists." >&2
        exit 1
    fi
    superset_image=$(ci_find_superset_image "$runtime" "$enabled_toolchain") || superset_image=""
    if [[ -n "$superset_image" ]]; then
        echo "    '$image' does not exist; using '$superset_image', which contains ${enabled_toolchain// /,}"
        image="$superset_image"
    else
        # Nothing to substitute, so build it: the toolchains, package caches and locale
        # asked for, and the default agents plus the one about to run.
        build_agents=$CI_DEFAULT_AGENTS
        [[ "$no_agent" == false ]] && build_agents=$(ci_comma_list_add "$build_agents" "$code_agent")
        build_args=(--toolchain "$(ci_join , "$enabled_toolchain")"
                    --package-caches "$(ci_join , "$enabled_package_caches")"
                    --agent "$(ci_join , "$build_agents")"
                    --locale "$locale" --runtime "$runtime" --image "$image" --yes)
        [[ "$dry_run" == true ]] && build_args+=(--dry-run)
        echo "Warning: $runtime image '$image' does not exist; building it with code-it-build.sh --toolchain ${build_args[1]} --agent ${build_args[5]}" >&2
        "${CODE_IT_BUILD:-$script_dir/code-it-build.sh}" "${build_args[@]}" || {
            rc=$?
            echo "Warning: building '$image' failed. Build it with code-it-build.sh, or set --image to an image that exists." >&2
            exit $rc
        }
    fi
fi

# Warn if the chosen image was built for a different toolchain set than the one we
# are about to run. Prefer the label code-it-build stamped on the image; fall back to
# the name-based guess. A superset image is fine: only warn when it does not contain
# every requested chain.
image_toolchain=$(ci_image_toolchain "$runtime" "$image")
if [[ -n "$image_toolchain" ]] && ! ci_toolchain_include "$image_toolchain" "$enabled_toolchain"; then
    echo "Warning: image '$image' looks built for toolchains '$image_toolchain' but --toolchain is '$(ci_join , "$enabled_toolchain")'." >&2
    echo "    Pass the same --toolchain used to build the image, or set --image explicitly." >&2
elif [[ -n "$image_toolchain" && "$image_toolchain" != "$(ci_join , "$enabled_toolchain")" ]]; then
    extras=""
    for c in ${image_toolchain//,/ }; do
        ci_has "$enabled_toolchain" "$c" || extras=$(ci_comma_list_add "$extras" "$c")
    done
    echo "    Note: image '$image' also contains ${extras// /,}."
fi

# The image must contain the chosen agent: go.sh cannot run one it lacks. Check here,
# where the error is readable, rather than in the container. --no-agent runs no agent,
# so neither check applies.
if [[ "$no_agent" == false ]]; then
image_agents=$(ci_image_agents "$runtime" "$image" "$agents_dir")
rebuild_toolchain=${image_toolchain:-$(ci_join , "$enabled_toolchain")}
if [[ -n "$image_agents" ]] && ! ci_has "${image_agents//,/ }" "$code_agent"; then
    echo "Warning: image '$image' does not contain agent '$code_agent'; it has: $image_agents." >&2
    echo "    Choose one of those with --agent, or rebuild with code-it-build.sh --toolchain $rebuild_toolchain --agent $code_agent,$image_agents" >&2
    exit 1
fi
# An image built before a change to the agent's definition may install it somewhere
# else, or run another agent's binary from a shared path, so check the binary the
# image recorded against the one the definition names now.
if [[ -n "$image_agents" ]]; then
    if image_agent_binary=$(ci_image_agent_binary "$runtime" "$image" "$code_agent"); then
        if [[ "$image_agent_binary" != "$AGENT_BINARY" ]]; then
            echo "Warning: image '$image' runs agent '$code_agent' from ${image_agent_binary:-an unrecorded path}, but agents/$code_agent/config now names $AGENT_BINARY." >&2
            echo "    The image is out of date; rebuild it with code-it-build.sh --toolchain $rebuild_toolchain --agent $image_agents" >&2
            exit 1
        fi
    else
        echo "Warning: image '$image' predates code-it recording its agents' binaries, so it may run an out-of-date '$code_agent'." >&2
        echo "    If the agent is not the one you expect, rebuild with code-it-build.sh --toolchain $rebuild_toolchain --agent $image_agents" >&2
    fi
fi
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

# Translate the prompt, and any -- pass-through arguments, into the chosen agent's own
# command line, from the definition's cmd_* template, which the container entrypoint
# hands to the agent. {args} expands to the agent args, {prompt} to the opening prompt.
# See https://code.claude.com/docs/en/cli-reference and https://opencode.ai/docs/cli/
agent_cmd=()
if [[ "$no_agent" == true ]]; then
    # A plain zsh: nothing is appended after the image, and CODE_AGENT_SHELL=1
    # (below) tells go.sh to run the shell instead of an agent.
    :
else
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

# The agent selector environment: CODE_AGENT names the agent for go.sh; --no-agent
# replaces it with CODE_AGENT_SHELL, which runs a plain interactive zsh.
if [[ "$no_agent" == true ]]; then
    agent_env=(-e CODE_AGENT_SHELL=1)
    agent_env_print="
                -e CODE_AGENT_SHELL=1 \\"
else
    agent_env=(-e "CODE_AGENT=$code_agent" ${headless_env[@]+"${headless_env[@]}"})
    agent_env_print="
                -e CODE_AGENT=\"$code_agent\"\\$headless_env_print"
fi

# Extra run arguments: SAVE-DIR/run-args, then --env, --env-file and --run-arg. They
# follow code-it's own, so they can override them. Docker reads a bare `-e NAME` from
# the host's environment itself; for the Apple container CLI, code-it does, keeping the
# printed command free of the value.
extra_run_args=()
while IFS= read -r arg; do
    extra_run_args+=("$arg")
done < <(ci_read_run_args "$run_args_file")
if [[ ${#extra_run_args[@]} -gt 0 ]]; then
    echo "    Using run arguments from $run_args_file"
fi
extra_run_args+=(${cli_run_args[@]+"${cli_run_args[@]}"})
# Printed one option per line: an argument starting with - begins a new line
extra_run_args_print=""
for arg in ${extra_run_args[@]+"${extra_run_args[@]}"}; do
    if [[ "$arg" == -* ]]; then
        [[ -n "$extra_run_args_print" ]] && extra_run_args_print+=" \\"
        extra_run_args_print+="
                $(printf '%q' "$arg")"
    else
        extra_run_args_print+=" $(printf '%q' "$arg")"
    fi
done
[[ -n "$extra_run_args_print" ]] && extra_run_args_print+=" \\"
run_extra_args=()
env_flag=""
for arg in ${extra_run_args[@]+"${extra_run_args[@]}"}; do
    if [[ -n "$env_flag" ]]; then
        if [[ "$runtime" == "container" && "$arg" != *=* ]] && ci_valid_env_spec "$arg"; then
            [[ -n "${!arg+set}" ]] && run_extra_args+=("$env_flag" "$arg=${!arg}")
        else
            run_extra_args+=("$env_flag" "$arg")
        fi
        env_flag=""
    elif [[ "$arg" == -e || "$arg" == --env ]]; then
        env_flag="$arg"
    else
        run_extra_args+=("$arg")
    fi
done
[[ -n "$env_flag" ]] && run_extra_args+=("$env_flag")

agent_cmd_print=""
for arg in ${agent_cmd[@]+"${agent_cmd[@]}"}; do
    agent_cmd_print+=" $(printf '%q' "$arg")"
done

# One container at a time may use the AGENT_EXCLUSIVE_DIRS (opencode's SQLite session
# database corrupts when containers in different VMs share it). Slot 1 is the usual
# directory; when its lock is held by a running code-it, take the next free slot, an
# empty copy under .code-it-instances/AGENT, carrying over AGENT_EXCLUSIVE_CARRY
# (credentials). A dry run takes no lock and copies nothing.
instance_root=""
exclusive_lock=""
if [[ -n "${AGENT_EXCLUSIVE_DIRS:-}" ]]; then
    lock_dir="$agent_save_dir/.code-it-instances/$code_agent"
    take_lock=true
    [[ "$dry_run" == true ]] && take_lock=false
    if slot=$(ci_claim_slot "$lock_dir" "$(ci_self_pid)" "$take_lock"); then
        [[ "$take_lock" == true ]] && exclusive_lock="$lock_dir/$slot.lock"
        if [[ "$slot" != 1 ]]; then
            instance_root="$lock_dir/$slot"
            new_copy=true
            [[ -d "$instance_root" ]] && new_copy=false
            IFS=':' read -r -a exclusive_dirs <<< "$AGENT_EXCLUSIVE_DIRS"
            for d in "${exclusive_dirs[@]}"; do
                [[ -n "$d" ]] || continue
                echo "Warning: Another $code_agent container is using $agent_save_dir/$d." >&2
                echo "    Containers cannot share it (its session database would be corrupted), so this one uses its own copy:" >&2
                echo "    $instance_root/$d" >&2
            done
            if [[ "$dry_run" != true ]]; then
                for d in "${exclusive_dirs[@]}"; do
                    [[ -n "$d" ]] && mkdir -p "$instance_root/$d"
                done
                IFS=':' read -r -a carry_files <<< "${AGENT_EXCLUSIVE_CARRY:-}"
                for f in ${carry_files[@]+"${carry_files[@]}"}; do
                    [[ -n "$f" && -f "$agent_save_dir/$f" ]] || continue
                    if [[ ! -e "$instance_root/$f" || "$agent_save_dir/$f" -nt "$instance_root/$f" ]]; then
                        mkdir -p "$(dirname "$instance_root/$f")"
                        cp -p "$agent_save_dir/$f" "$instance_root/$f"
                    fi
                done
            fi
            # A new copy with no credentials to carry (opencode-v2 keeps its login in
            # the database) starts logged out
            has_login=false
            IFS=':' read -r -a carry_files <<< "${AGENT_EXCLUSIVE_CARRY:-}"
            for f in ${carry_files[@]+"${carry_files[@]}"}; do
                [[ -n "$f" && ( -f "$agent_save_dir/$f" || -f "$instance_root/$f" ) ]] && has_login=true
            done
            if [[ "$new_copy" == true && "$has_login" == false ]]; then
                echo "    This copy has no saved login: log in again inside the container. Later runs" >&2
                echo "    that get this copy keep that login." >&2
            fi
        fi
    else
        echo "Warning: Could not lock $lock_dir; sharing $AGENT_EXCLUSIVE_DIRS with any other running container." >&2
    fi
fi
if [[ -n "$exclusive_lock" ]]; then
    trap 'rm -f "$exclusive_lock"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
fi

# state_dir_source DIR: the host directory mounted at ~/DIR, the instance copy for
# an exclusive directory when this run has one
state_dir_source() {
    if [[ -n "$instance_root" ]] && ci_has "$(printf '%s' "$AGENT_EXCLUSIVE_DIRS" | tr ':' ' ')" "$1"; then
        printf '%s' "$instance_root/$1"
    else
        printf '%s' "$agent_save_dir/$1"
    fi
}

# Mount only the chosen agent's state, read from its definition.
agent_mounts=()
agent_mounts_print=""
for d in ${agent_state_dirs[@]+"${agent_state_dirs[@]}"}; do
    [[ -n "$d" ]] || continue
    src=$(state_dir_source "$d")
    agent_mounts+=(-v "$src:$container_home/$d")
    agent_mounts_print+="
                -v \"$src:$container_home/$d\" \\"
done
for f in ${agent_state_files[@]+"${agent_state_files[@]}"}; do
    [[ -n "$f" ]] || continue
    agent_mounts+=(-v "$agent_save_dir/$f:$container_home/$f")
    agent_mounts_print+="
                -v \"$agent_save_dir/$f:$container_home/$f\" \\"
done

# Print the command
cat <<EOF
    $runtime run ${tty_args[*]} --rm \\$container_args \\$agent_env_print
                -e CODE_IT_WORK_DIR="$container_work_dir" \\
                -e LANG="$container_locale" \\
                -e GIT_AUTHOR_NAME="$git_author_name" \\
                -e GIT_AUTHOR_EMAIL="$git_author_email" \\
                -e GIT_COMMITTER_NAME="$git_author_name" \\
                -e GIT_COMMITTER_EMAIL="$git_author_email" \\
                -v "$work_dir_to_mount:$container_work_dir" \\$agent_mounts_print$cache_mounts_print$extra_run_args_print
                ${image}:latest$agent_cmd_print
EOF

if [[ "$dry_run" == true ]]; then
    exit 0
fi

run_rc=0
"$runtime" run "${tty_args[@]}" --rm \
            $container_args \
            "${agent_env[@]}" \
            -e CODE_IT_WORK_DIR="$container_work_dir" \
            -e LANG="$container_locale" \
            -e GIT_AUTHOR_NAME="$git_author_name" \
            -e GIT_AUTHOR_EMAIL="$git_author_email" \
            -e GIT_COMMITTER_NAME="$git_author_name" \
            -e GIT_COMMITTER_EMAIL="$git_author_email" \
            -v "$work_dir_to_mount:$container_work_dir" \
            "${agent_mounts[@]+"${agent_mounts[@]}"}" \
            "${cache_mounts[@]+"${cache_mounts[@]}"}" \
            ${run_extra_args[@]+"${run_extra_args[@]}"} \
    "${image}:latest" ${agent_cmd[@]+"${agent_cmd[@]}"} || run_rc=$?

# Remember the image used, so later runs can take their toolchains from it.
ci_history_record "$history_file" "$image"
exit "$run_rc"

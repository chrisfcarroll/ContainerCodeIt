#!/usr/bin/env bash
#
# code-it XS: run a coding agent in a container that can see only one directory.
#
# Usage: ./code-it.sh [OPTIONS] [PROMPT] [-- AGENT-ARGS...]
#
#   -o, --opencode        Run OpenCode (the default)
#   -c, --claude          Run Claude Code
#   -a, --agent NAME      Run agent NAME, e.g. codex once snippets/codex.dockerfile is added
#   --zsh                 Run zsh instead of an agent
#   -w, --work-dir DIR    The host directory the agent can see. Default: .
#                         It is mounted at /work/<parent>/<name>, so it keeps its name.
#   -s, --save-dir DIR    Where agent logins and state are kept. Default: ~/.config/code-it-xs
#   -i, --image NAME      Image to run, built from the Dockerfile here if missing. Default: code-it-xs
#   -b, --build           Build the image even if it exists
#   -r, --runtime NAME    docker, container (Apple's) or wslc (WSL's). Default: container
#                         on macOS if installed, else docker, else wslc on Windows
#   -l, --locale LOCALE   The container's LANG, e.g. en_GB.UTF-8 or en-GB. Default: the host's
#   -D:ARG, --D:ARG       Pass ARG to `docker run` / `container run`, e.g. -D:-p -D:8080:3000
#   --no-wait             If the agent fails, close at once instead of waiting for Enter
#   -d, --dry-run         Print the commands without running them
#   -h, --help            Show this help
#   PROMPT                Open the agent with this as its first prompt
#   -- AGENT-ARGS...      Pass everything after -- to the agent
#
# First run (no save dir yet) offers to copy your existing Claude and OpenCode config
# into the save dir, so the containerised agents can use your current logins.

set -eo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(dirname "$script_dir")

agent=opencode
work_dir=.
save_dir=$HOME/.config/code-it-xs
image=code-it-xs
build=false
runtime=""
locale=""
dry_run=false
no_wait=false
run_args=()
agent_args=()
prompt=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--opencode) agent=opencode ;;
        -c|--claude)   agent=claude ;;
        -a|--agent)    agent=${2:?"$1 needs a value"}; shift ;;
        --zsh)         agent=zsh ;;
        -w|--work-dir) work_dir=${2:?"$1 needs a value"}; shift ;;
        -s|--save-dir) save_dir=${2:?"$1 needs a value"}; shift ;;
        -i|--image)    image=${2:?"$1 needs a value"}; shift ;;
        -b|--build)    build=true ;;
        -r|--runtime)  runtime=${2:?"$1 needs a value"}; shift ;;
        -l|--locale)   locale=${2:?"$1 needs a value"}; shift ;;
        -D:*|--D:*)    run_args+=("${1#*D:}") ;;
        --no-wait)     no_wait=true ;;
        -d|--dry-run)  dry_run=true ;;
        -h|--help)     sed -n '3,/^$/{ s/^# \{0,1\}//; p; }' "$0"; exit 0 ;;
        --)            shift; agent_args=("$@"); break ;;
        -*)            echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
        *)             [[ -z "$prompt" ]] || { echo "Only one prompt, please: quote it" >&2; exit 1; }
                       prompt=$1 ;;
    esac
    shift
done

# Each agent sees only its own state, kept under the save dir. A new agent needs a line here.
case "$agent" in
    opencode) state=(.config/opencode .local/share/opencode .local/state/opencode) ;;
    claude)   state=(.claude .claude.json) ;;
    codex)    state=(.codex) ;;
    zsh)      state=() ;;
    *)        echo "Unknown agent '$agent': add its state paths to $0" >&2; exit 1 ;;
esac

# The prompt goes first to the agent. OpenCode reads a bare argument as a project
# directory, so it needs --prompt.
if [[ -n "$prompt" ]]; then
    if [[ "$agent" == opencode ]]; then agent_args=(--prompt "$prompt" "${agent_args[@]}")
    else agent_args=("$prompt" "${agent_args[@]}")
    fi
fi

if [[ -z "$runtime" ]]; then
    if [[ "$(uname -s)" == Darwin ]] && command -v container >/dev/null; then runtime=container
    elif command -v docker >/dev/null; then runtime=docker
    elif command -v wslc >/dev/null; then runtime=wslc
    elif command -v container >/dev/null; then runtime=container
    else echo "No container runtime found: install Docker, or on macOS Apple's container, or on Windows WSL's wslc" >&2; exit 1
    fi
fi
if [[ "$runtime" != docker && "$runtime" != container && "$runtime" != wslc ]]; then
    echo "Unknown runtime '$runtime': use docker, container or wslc" >&2; exit 1
fi

# The container's LANG: --locale, else the host's LC_ALL or LANG.
# en-GB, en_GB.UTF-8 and en_GB@euro all become en_GB.UTF-8.
lang=${locale:-${LC_ALL:-$LANG}}
lang=${lang%%[.@]*}
lang=${lang//-/_}
if [[ "$lang" =~ ^[a-z]{2,3}(_[A-Z]{2})?$ ]]; then
    lang=$lang.UTF-8
elif [[ -n "$locale" && "$locale" != C.UTF-8 ]]; then
    echo "Unknown locale '$locale': use a name like en_GB.UTF-8 or en-GB" >&2; exit 1
else
    lang=C.UTF-8
fi

# Mount the work dir at /work/<parent>/<name>, so agents' per-directory memory sees
# its real name. A ':' would split the -v argument, so it becomes '-'.
[[ -d "$work_dir" ]] || { echo "Work dir not found: $work_dir" >&2; exit 1; }
work_dir=$(cd "$work_dir" && pwd)
case "$work_dir" in
    /)    mount=/work ;;
    /*/*) mount=/work/$(basename "$(dirname "$work_dir")")/$(basename "$work_dir") ;;
    *)    mount=/work/$(basename "$work_dir") ;;
esac
mount=${mount//:/-}
[[ "$save_dir" == /* ]] || save_dir=$PWD/$save_dir

if [[ "$dry_run" == false ]]; then
    # First run: offer to copy the host's agent config into the new save dir.
    if [[ ! -d "$save_dir" ]]; then
        answer=""
        read -r -p "Shall I copy your existing Claude and OpenCode config so that your containerised agents can use your current logins? [y/N] " answer || true
        mkdir -p "$save_dir"
        if [[ "$answer" == [Yy]* ]]; then
            for p in .claude .claude.json .config/opencode .local/share/opencode .local/state/opencode; do
                [[ -e "$HOME/$p" ]] || continue
                mkdir -p "$(dirname "$save_dir/$p")"
                cp -Rp "$HOME/$p" "$save_dir/$p"
                echo "    copied ~/$p to $save_dir/$p"
            done
        fi
    fi
    # Create the agent's state so the mounts work. A missing .json file is created
    # as a file, or the runtime would create a directory in its place.
    for p in "${state[@]}"; do
        if [[ "$p" == *.json ]]; then
            [[ -f "$save_dir/$p" ]] || echo '{}' > "$save_dir/$p"
        else
            mkdir -p "$save_dir/$p"
        fi
    done
fi

# run COMMAND...: print it, then run it unless --dry-run
run() {
    printf '   '; printf ' %q' "$@"; echo
    [[ "$dry_run" == true ]] || "$@"
}

if [[ "$build" == true ]] || ! "$runtime" image inspect "$image" >/dev/null 2>&1; then
    # Stage XS and the shared top-level CA directory. This preserves local XS COPY
    # inputs while keeping unrelated repository files out of the build context.
    build_context=$(mktemp -d "${TMPDIR:-/tmp}/code-it-xs-build.XXXXXX")
    trap 'rm -rf "$build_context"' EXIT
    cp -R "$script_dir/." "$build_context/"
    mkdir -p "$build_context/ca-certificates"
    if [[ -d "$repo_dir/ca-certificates" ]]; then
        cp -R "$repo_dir/ca-certificates/." "$build_context/ca-certificates/"
    fi
    run "$runtime" build -t "$image" "$build_context"
fi

user=${GIT_AUTHOR_NAME:-$(git config --get user.name || true)}
email=${GIT_AUTHOR_EMAIL:-$(git config --get user.email || true)}

cmd=("$runtime" run -it --rm)
# Apple's container gives too little memory by default for an agent
[[ "$runtime" == container ]] && cmd+=(--memory 3g)
cmd+=(-e CODE_AGENT="$agent" -e CODE_IT_WORK_DIR="$mount" -e LANG="$lang"
      -e GIT_AUTHOR_NAME="Agent1 for $user" -e GIT_AUTHOR_EMAIL="$email"
      -e GIT_COMMITTER_NAME="Agent1 for $user" -e GIT_COMMITTER_EMAIL="$email"
      -v "$work_dir:$mount")
[[ "$no_wait" == true ]] && cmd+=(-e CODE_IT_NO_WAIT=1)
for p in "${state[@]}"; do cmd+=(-v "$save_dir/$p:/home/agent1/$p"); done
cmd+=("${run_args[@]}" "$image" "${agent_args[@]}")
run "${cmd[@]}"

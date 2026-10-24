#!/usr/bin/env bash
#
# Checks your code-it setup for known problems and says how to fix each one. The
# first of them is copying to the host clipboard from the agent in the container,
# which has to pass from the agent, through tmux in the container, the container
# runtime, any tmux on the host, to your terminal, which must accept OSC 52.
#
# With --fix, or a PROBLEM described in words, it then runs code-it headless on this
# repository with that problem and the report, so the in-container agent investigates
# and fixes it, on a new branch, or tells you what to change on the host.
#
# Usage:
#   ./code-it-doctor.sh [OPTIONS] [PROBLEM]
#
# Options:
#   --runtime, -r NAME   docker or container. Default: auto-detect, as code-it does.
#   --image, -i NAME     Image to check. Default: the most recently used existing
#                        code-it image, else the most recently built.
#   --save-dir, -s DIR   code-it's save dir. Default: ~/.config/code-it
#   --no-live-test       Skip the clipboard round trip (below).
#   --yes, -y            Run the clipboard round trip without asking first.
#   --fix                After the checks, run code-it headless on this repository with
#                        the report (and PROBLEM, if given) to investigate and fix it.
#                        A PROBLEM implies --fix.
#   --repo DIR           Repository for --fix. Default: this script's directory.
#   --code-it PATH       code-it launcher for --fix. Default: ./code-it.sh next to this
#                        script. Mainly useful for testing.
#   --branch NAME        Branch for --fix. Default: doctor/<yyyymmdd-HHMMSS>.
#   --dry-run, -d        With --fix, print the prompt and code-it command, run nothing.
#   --help, -h           Show this help message.
#
# The clipboard round trip briefly puts a marker on your clipboard with OSC 52, first
# from this shell and then from tmux inside the image, and reads it back with the
# host's clipboard tool (pbpaste, wl-paste, xclip, xsel or PowerShell). Text that was
# on the clipboard is restored afterwards; anything else (an image, say) is not.
#
# Exit code: 0 if no problem was found, 1 if one was; with --fix, code-it's exit code.

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/code-it-common.sh
. "$script_dir/lib/code-it-common.sh"

runtime=""
image=""
save_dir="$HOME/.config/code-it"
live_test=true
assume_yes=false
fix=false
repo="$script_dir"
code_it="$script_dir/code-it.sh"
branch=""
dry_run=false
problem_text=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runtime|-r)  runtime="$2"; shift 2 ;;
        --image|-i)    image="$2"; shift 2 ;;
        --save-dir|-s) save_dir="$2"; shift 2 ;;
        --no-live-test) live_test=false; shift ;;
        --yes|-y)      assume_yes=true; shift ;;
        --fix)         fix=true; shift ;;
        --repo)        repo="$2"; shift 2 ;;
        --code-it)     code_it="$2"; shift 2 ;;
        --branch)      branch="$2"; shift 2 ;;
        --dry-run|-d)  dry_run=true; shift ;;
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
            # Words after the options describe the problem, quoted or not
            problem_text="${problem_text:+$problem_text }$1"
            fix=true
            shift
            ;;
    esac
done

# The report is printed as it is made, and kept, so --fix can hand it to the agent.
report=""
problems=0
say()     { printf '%s\n' "$*"; report+="$*"$'\n'; }
section() { say ""; say "$*"; }
ok()      { say "  ok:      $*"; }
problem() { say "  PROBLEM: $*"; problems=$((problems + 1)); }
warning() { say "  warning: $*"; }
unknown() { say "  unknown: $*"; }
detail()  { say "           $*"; }

platform=$(uname -s)
container_home="/home/agent1"

# ---------------------------------------------------------------------------
section "Host"
say "  $platform $(uname -m), bash $BASH_VERSION"
if [[ -f /etc/code-it-agents ]]; then
    warning "this looks like the inside of a code-it container; run code-it-doctor on the host"
fi
# code-it takes the git identity from GIT_AUTHOR_* if set, else from git config.
git_name="${GIT_AUTHOR_NAME:-$(git config --get user.name 2>/dev/null || true)}"
git_email="${GIT_AUTHOR_EMAIL:-$(git config --get user.email 2>/dev/null || true)}"
if [[ -n "$git_name" && -n "$git_email" ]]; then
    ok "git user.name and user.email are set, so the agent can commit"
else
    problem "git user.name or user.email is not set, so the agent cannot commit"
    detail "fix: git config --global user.name 'Your Name' ; git config --global user.email you@example.com"
fi

# ---------------------------------------------------------------------------
section "Container runtime"
runtime_ok=false
if detected=$(ci_detect_runtime "$runtime" 2>&1); then
    runtime="$detected"
    say "  $runtime: $("$runtime" --version 2>/dev/null | head -n 1 || true)"
    if [[ "$runtime" == container ]]; then
        if container system status >/dev/null 2>&1; then
            ok "the container system service is running"
            runtime_ok=true
        else
            problem "the container system service is not running"
            detail "fix: container system start"
        fi
    elif docker info >/dev/null 2>&1; then
        ok "the docker daemon is reachable"
        runtime_ok=true
    else
        problem "the docker daemon is not reachable"
        detail "fix: start Docker Desktop, or the docker service"
    fi
else
    problem "no usable container runtime"
    while IFS= read -r line; do detail "$line"; done <<< "$detected"
fi

# ---------------------------------------------------------------------------
section "Image"
image_ok=false
if [[ "$runtime_ok" == true ]]; then
    if [[ -z "$image" ]]; then
        image=$(ci_choose_default_image "$runtime" "$save_dir/image-history") || image=""
    fi
    image="${image%:latest}"
    # code-it-build needs the toolchains: take them from the image's label or name
    image_chains=""
    [[ -n "$image" ]] && image_chains=$(ci_image_toolchain "$runtime" "$image:latest")
    rebuild_cmd="$script_dir/code-it-build.sh --toolchain ${image_chains:-<toolchains>} --image $image"
    if [[ -z "$image" ]]; then
        problem "there is no code-it image"
        detail "fix: $script_dir/code-it-first-run.sh"
    elif ! ci_image_exists "$runtime" "$image:latest"; then
        problem "image $image does not exist"
        detail "fix: $rebuild_cmd"
    else
        ok "image $image exists"
        image_ok=true
        # tmux in the container must accept OSC 52 from the agent and pass it on.
        tmux_conf=$("$runtime" run --rm --entrypoint cat "$image:latest" "$container_home/.tmux.conf" 2>/dev/null || true)
        if [[ -z "$tmux_conf" ]]; then
            unknown "could not read ~/.tmux.conf from $image"
        elif printf '%s\n' "$tmux_conf" | grep -Eq '^[[:space:]]*set(-option)?[[:space:]]+(-[a-z]+[[:space:]]+)*set-clipboard[[:space:]]+on'; then
            ok "tmux in the image passes the agent's clipboard (OSC 52) on (set-clipboard on)"
        else
            problem "tmux in $image does not pass the agent's clipboard on (no 'set-clipboard on')"
            detail "fix: rebuild the image: $rebuild_cmd --rebuild"
        fi
    fi
else
    unknown "skipped: no running container runtime"
fi

# ---------------------------------------------------------------------------
section "Save dir"
if [[ -d "$save_dir" ]]; then
    ok "$save_dir exists"
else
    warning "$save_dir does not exist yet; code-it will run first-run"
fi
# opencode's session databases: opencode-v1's at the save dir root, opencode (v2)'s
# under opencode-v2/, and the copies a second container gets (Spec 12). A corrupt one
# gives "can't create session".
opencode_dbs=()
if [[ -d "$save_dir" ]]; then
    while IFS= read -r db; do
        opencode_dbs+=("$db")
    done < <(find "$save_dir" -maxdepth 8 -path '*/.local/share/opencode/opencode.db' 2>/dev/null)
fi
if (( ${#opencode_dbs[@]} > 0 )) && ! command -v sqlite3 >/dev/null 2>&1; then
    unknown "no sqlite3 on the host to check opencode's database"
elif (( ${#opencode_dbs[@]} > 0 )); then
    for db in "${opencode_dbs[@]}"; do
        check=$(sqlite3 "$db" 'pragma quick_check;' 2>&1 | head -n 1 || true)
        if [[ "$check" == ok ]]; then
            ok "opencode's database passes quick_check: ${db#"$save_dir"/}"
        else
            problem "opencode's database fails quick_check: ${db#"$save_dir"/}: $check"
            detail "fix: with no code-it running, move $(dirname "$db") aside (you may need to log in again)"
        fi
    done
fi

# ---------------------------------------------------------------------------
section "Clipboard"

# Which terminal is this? Ask tmux on the host first, as it knows the terminal that is
# attached now, then the variables terminals set (some of which survive into tmux).
host_tmux_termtype=""
if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
    host_tmux_termtype=$(tmux display-message -p '#{client_termtype}' 2>/dev/null || true)
fi
detect_terminal() {
    case "$host_tmux_termtype" in
        iTerm2*)             echo iterm2;   return ;;
        ghostty*)            echo ghostty;  return ;;
        WezTerm*)            echo wezterm;  return ;;
        kitty*)              echo kitty;    return ;;
        xterm.js*)           echo vscode;   return ;;
    esac
    case "${TERM_PROGRAM:-}" in
        iTerm.app)           echo iterm2;   return ;;
        ghostty)             echo ghostty;  return ;;
        WezTerm)             echo wezterm;  return ;;
        vscode)              echo vscode;   return ;;
        mintty)              echo mintty;   return ;;
        WarpTerminal)        echo warp;     return ;;
        Apple_Terminal)      echo apple-terminal; return ;;
    esac
    if [[ "${LC_TERMINAL:-}" == iTerm2 || -n "${ITERM_SESSION_ID:-}" ]]; then echo iterm2
    elif [[ -n "${GHOSTTY_RESOURCES_DIR:-}" || "${TERM:-}" == xterm-ghostty ]]; then echo ghostty
    elif [[ -n "${WEZTERM_PANE:-}" ]]; then echo wezterm
    elif [[ -n "${KITTY_WINDOW_ID:-}" || "${TERM:-}" == xterm-kitty ]]; then echo kitty
    elif [[ -n "${ALACRITTY_WINDOW_ID:-}" || "${TERM:-}" == alacritty ]]; then echo alacritty
    elif [[ -n "${WT_SESSION:-}" ]]; then echo windows-terminal
    else echo unknown
    fi
}
terminal=$(detect_terminal)

# The terminal is the last link: it must accept OSC 52.
case "$terminal" in
    apple-terminal)
        problem "macOS Terminal.app ignores OSC 52, the escape sequence tmux and the agents"
        detail "use to set the clipboard from the container, so nothing copied there arrives."
        detail "fix: turn mouse reporting off with View > Allow Mouse Reporting (⌘R), so a drag"
        detail "makes Terminal.app's own selection, not tmux's; ⌘C, then ⌘R to turn it back on;"
        detail "or turn tmux's mouse off in the container: Ctrl-B then :set mouse off;"
        detail "or use a terminal that supports OSC 52: iTerm2, Ghostty, WezTerm or kitty."
        ;;
    iterm2)
        allowed=""
        if [[ "$platform" == Darwin ]]; then
            allowed=$(defaults read com.googlecode.iterm2 AllowClipboardAccess 2>/dev/null || true)
        fi
        if [[ "$allowed" == 1 ]]; then
            ok "iTerm2 lets applications set the clipboard (AllowClipboardAccess)"
        elif [[ "$platform" == Darwin ]]; then
            problem "iTerm2 is not letting applications set the clipboard, so OSC 52 is ignored"
            detail "fix: iTerm2 > Settings > General > Selection > tick 'Applications in terminal"
            detail "may access clipboard', or run, then restart iTerm2:"
            detail "     defaults write com.googlecode.iterm2 AllowClipboardAccess -bool true"
        else
            unknown "iTerm2 over ssh: tick 'Applications in terminal may access clipboard' in"
            detail "iTerm2 > Settings > General > Selection on your Mac"
        fi
        detail "tip: hold ⌥ (Option) while dragging to make iTerm2's own selection instead of tmux's"
        ;;
    ghostty)
        denied=false
        for f in "${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config" \
                 "${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config.ghostty" \
                 "$HOME/Library/Application Support/com.mitchellh.ghostty/config" \
                 "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty"; do
            [[ -f "$f" ]] || continue
            if grep -Eq '^[[:space:]]*clipboard-write[[:space:]]*=[[:space:]]*deny' "$f"; then
                denied=true
                problem "Ghostty's clipboard-write = deny in $f, so OSC 52 is ignored"
                detail "fix: set clipboard-write = allow in $f, then reload Ghostty's config"
            fi
        done
        [[ "$denied" == true ]] || ok "Ghostty accepts OSC 52 (clipboard-write is not deny)"
        ;;
    kitty)
        conf="${XDG_CONFIG_HOME:-$HOME/.config}/kitty/kitty.conf"
        line=""
        [[ -f "$conf" ]] && line=$(grep -E '^[[:space:]]*clipboard_control' "$conf" | tail -n 1 || true)
        if [[ -n "$line" && "$line" != *write-clipboard* ]]; then
            problem "kitty's clipboard_control in $conf lacks write-clipboard, so OSC 52 is ignored"
            detail "fix: add write-clipboard to clipboard_control in $conf"
        else
            ok "kitty accepts OSC 52 (clipboard_control allows write-clipboard)"
        fi
        ;;
    mintty)
        if grep -Eqi '^[[:space:]]*AllowSetSelection[[:space:]]*=[[:space:]]*(yes|true|1)' "$HOME/.minttyrc" 2>/dev/null; then
            ok "mintty accepts OSC 52 (AllowSetSelection=yes)"
        else
            problem "mintty ignores OSC 52 unless AllowSetSelection=yes"
            detail "fix: add AllowSetSelection=yes to ~/.minttyrc, then open a new window"
        fi
        ;;
    wezterm|alacritty|vscode|windows-terminal)
        ok "$terminal accepts OSC 52"
        ;;
    *)
        unknown "terminal '$terminal' (TERM_PROGRAM=${TERM_PROGRAM:-}, TERM=${TERM:-}): it must accept OSC 52"
        detail "for copying from the container; the round trip below tests that"
        ;;
esac

# A tmux on the host sees the container as one more application: with its default
# set-clipboard (external) it drops the OSC 52 that arrives from it.
if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
    host_clipboard=$(tmux show-options -sv set-clipboard 2>/dev/null || true)
    if [[ "$host_clipboard" == on ]]; then
        ok "tmux on the host passes OSC 52 on (set-clipboard on)"
    else
        problem "tmux on the host has set-clipboard ${host_clipboard:-unset}, so it drops the"
        detail "container's OSC 52 (it only passes on OSC 52 from applications when 'on')"
        detail "fix: echo 'set -s set-clipboard on' >> ~/.tmux.conf && tmux source-file ~/.tmux.conf"
    fi
    features=$(tmux display-message -p '#{client_termfeatures}' 2>/dev/null || true)
    if [[ -n "$features" && "$features" != *clipboard* ]]; then
        client_term=$(tmux display-message -p '#{client_termname}' 2>/dev/null || true)
        problem "tmux on the host does not think your terminal ($client_term) has a clipboard"
        detail "fix: echo \"set -as terminal-features ',${client_term:-*}:clipboard'\" >> ~/.tmux.conf && tmux source-file ~/.tmux.conf"
    fi
fi
if [[ -n "${STY:-}" ]]; then
    warning "GNU screen on the host does not reliably pass OSC 52 on; run code-it outside"
    detail "screen, or in tmux with set-clipboard on"
fi
over_ssh=false
if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]]; then
    over_ssh=true
    say "  note:    over ssh, the clipboard is your local terminal's; the checks above are"
    detail "only as good as the variables ssh passed on"
fi

# Clipboard round trip: OSC 52 out, the host clipboard tool back in.
clip_read() {
    case "$platform" in
        Darwin) pbpaste ;;
        MINGW*|MSYS*|CYGWIN*) powershell.exe -NoProfile -Command Get-Clipboard | tr -d '\r' ;;
        *)
            if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-paste >/dev/null 2>&1; then wl-paste --no-newline
            elif [[ -n "${DISPLAY:-}" ]] && command -v xclip >/dev/null 2>&1; then xclip -selection clipboard -o
            elif [[ -n "${DISPLAY:-}" ]] && command -v xsel >/dev/null 2>&1; then xsel --clipboard --output
            else return 1
            fi
            ;;
    esac
}
clip_write() {
    case "$platform" in
        Darwin) pbcopy ;;
        MINGW*|MSYS*|CYGWIN*) clip.exe ;;
        *)
            if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null 2>&1; then wl-copy
            elif [[ -n "${DISPLAY:-}" ]] && command -v xclip >/dev/null 2>&1; then xclip -selection clipboard -i
            elif [[ -n "${DISPLAY:-}" ]] && command -v xsel >/dev/null 2>&1; then xsel --clipboard --input
            else return 1
            fi
            ;;
    esac
}
clip_has_tool() {
    case "$platform" in
        Darwin) command -v pbpaste >/dev/null 2>&1 ;;
        MINGW*|MSYS*|CYGWIN*) command -v powershell.exe >/dev/null 2>&1 ;;
        *) clip_read >/dev/null 2>&1 ;;
    esac
}
# clip_wait_for MARKER: true once the clipboard holds MARKER, polling for ~2s
clip_wait_for() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [[ "$(clip_read 2>/dev/null || true)" == "$1" ]] && return 0
        sleep 0.2
    done
    return 1
}

# Where the escape sequences go: the controlling terminal. Tests point this at a file.
tty_path="${CODE_IT_DOCTOR_TTY:-/dev/tty}"
run_live=false
if [[ "$live_test" != true ]]; then
    say "  skipped: the clipboard round trip (--no-live-test)"
elif [[ "$over_ssh" == true ]]; then
    say "  skipped: the clipboard round trip, as this host's clipboard is not yours over ssh"
elif ! { : >> "$tty_path"; } 2>/dev/null; then
    say "  skipped: the clipboard round trip, as there is no terminal"
elif ! clip_has_tool; then
    unknown "no clipboard tool on the host to read back; skipped the clipboard round trip"
elif [[ "$assume_yes" == true ]]; then
    run_live=true
elif [[ -t 0 ]]; then
    printf '  Run the clipboard round trip? It briefly replaces your clipboard (text is restored) [Y/n] '
    read -r answer || answer=n
    case "$answer" in [nN]*) say "  skipped: the clipboard round trip" ;; *) run_live=true ;; esac
else
    say "  skipped: the clipboard round trip (not interactive; --yes runs it)"
fi

if [[ "$run_live" == true ]]; then
    saved_clipboard=$(clip_read 2>/dev/null || true)
    marker="code-it-doctor-host-$$-$RANDOM"
    b64=$(printf '%s' "$marker" | base64 | tr -d '\n')
    printf '\033]52;c;%s\007' "$b64" >> "$tty_path"
    host_live=false
    if clip_wait_for "$marker"; then
        host_live=true
        ok "round trip: OSC 52 from this shell reached the clipboard"
    else
        problem "round trip: OSC 52 from this shell did not reach the clipboard, so your"
        detail "terminal${TMUX:+ or the tmux on the host} ignores it: see the fix above"
    fi

    if [[ "$host_live" == true && "$image_ok" == true ]]; then
        marker="code-it-doctor-container-$$-$RANDOM"
        b64=$(printf '%s' "$marker" | base64 | tr -d '\n')
        # The same path as the agent: an application in tmux, in the container.
        inner=$(printf 'tmux -u new-session "printf %s; sleep 1"' "'\\033]52;c;$b64\\007'")
        say "  running: $runtime run --rm -it --entrypoint /bin/sh $image:latest -c '<tmux, printf OSC 52>'"
        "$runtime" run --rm -it --entrypoint /bin/sh "$image:latest" -c "$inner" \
            < "$tty_path" >> "$tty_path" 2>&1 || true
        if clip_wait_for "$marker"; then
            ok "round trip: OSC 52 from tmux in the container reached the clipboard"
            detail "copying works: in the container, drag to select and tmux copies on release;"
            detail "an agent's own copy command (Claude Code /copy, opencode's select) works too"
        else
            problem "round trip: your terminal accepts OSC 52, but none arrived from tmux in $image"
            detail "fix: rebuild the image: $rebuild_cmd --rebuild"
            detail "and if that does not cure it, run: $0 --fix 'clipboard from the container'"
        fi
    fi
    printf '%s' "$saved_clipboard" | clip_write 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
section "Summary"
if (( problems == 0 )); then
    say "  No problems found."
else
    say "  $problems problem(s) found; each PROBLEM above says how to fix it."
fi

if [[ "$fix" != true ]]; then
    (( problems == 0 )) && exit 0
    say "  To have an agent investigate and fix them: $0 --fix [PROBLEM]"
    exit 1
fi

if [[ -z "$problem_text" && "$problems" == 0 ]]; then
    echo "  Nothing to fix: describe the problem, e.g. $0 \"opencode can't create a session\""
    exit 0
fi

# ---------------------------------------------------------------------------
# --fix: hand the report to an agent in code-it, working on this repository.
if [[ ! -d "$repo/.git" && ! -f "$repo/.git" ]]; then
    echo "Warning: '$repo' is not a git repository." >&2
    exit 1
fi
repo=$(cd "$repo" && pwd)
[[ -n "$branch" ]] || branch="doctor/$(date +%Y%m%d-%H%M%S)"

IFS= read -r -d '' prompt <<EOF || true
You are diagnosing and fixing a problem with ContainerCodeIt (code-it), the repository
in /work, for a user who ran code-it-doctor on their host.

The user's problem: ${problem_text:-none described; fix the problems the doctor found below}

code-it-doctor's report from the host. You are inside a code-it container and cannot
see the host, so treat this as your evidence about it:
$report
Investigate:
- Read HumansAndAgents.md, README.md and Specs/ to see how code-it is meant to work.
- You run in a code-it container like the user's: inspect it (tmux and its options,
  the environment, ~/.tmux.conf, ~/go.sh, /etc/code-it-agents, the mounted state)
  to reproduce the problem where you can.
- Decide whether the cause is in this repository (scripts, Dockerfile, definitions)
  or on the host (terminal, container runtime, save dir, settings).

Then:
1. If the fix belongs in this repository, make it, keeping the bash and PowerShell
   scripts in step; add tests, run ./tests/run-all-tests.sh until it passes, and
   commit with a conventional commit message. If code-it-doctor could have detected
   the problem, add that check to code-it-doctor.sh and Code-It-Doctor.ps1, with tests.
2. If the fix is on the host, change nothing for it here; write the exact steps or
   commands for the user to run, and why, to stdout.
3. Finish with a short summary: the cause, what you changed, what the user must do.

Do not push. Work only on the current branch.
EOF

ci_add_via_code_it "doctor" "$branch" "$repo" "$code_it" "$dry_run" "$prompt" && exit 0
rc=$?
exit "$rc"

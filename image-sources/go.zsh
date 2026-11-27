#!/usr/bin/env zsh
# Arguments given to the container after the image name are passed straight to the
# coding agent, so the launcher scripts can hand it a prompt or its own flags.
# With CODE_AGENT_HEADLESS=1 the agent runs in the foreground instead of in tmux:
# it answers, exits, and the container exits with the agent's exit code.
# The launcher mounts the host's work dir at /work/<parent>/<name>
# (CODE_IT_WORK_DIR), so directories keep their names for agents' per-directory
# memory. The image's own WORKDIR /work is only the container's default: go.zsh
# must cd to the mounted path, or the agent starts in the wrong directory.
work_dir=${CODE_IT_WORK_DIR:-/work}
cd "$work_dir" 2>/dev/null || {
    echo "CODE_IT_WORK_DIR '$work_dir' does not exist in the container. Mount the work dir there, or run without it to start in /work." >&2
    exit 1
}
# (N): a work dir with no subdirectories matches nothing, and zsh would otherwise
# abort go.zsh with "no matches found" before the agent starts.
git config --global --add safe.directory "$work_dir"
for d in "$work_dir"/*/(N) ; do git config --global --add safe.directory "$d" ; done
# Index format is repository-local, so upgrade each mounted repository once at
# startup. Skip nested directories that resolve to the same repository root.
for repo in "$work_dir" "$work_dir"/*/(N) ; do
    [ -d "$repo" ] || continue
    if [ -z "$(git -C "$repo" rev-parse --show-prefix 2>/dev/null)" ] &&
       git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "$repo" update-index --index-version 4
    fi
done
# Seed the writable package caches from the launcher's read-only host-cache
# mounts (if any), so downloads are reused without writing to the host caches.
if [ -d "$HOME/.npm-host" ] ; then
    mkdir -p "$HOME/.npm"
    cp -a -n "$HOME/.npm-host/." "$HOME/.npm/" 2>/dev/null || true
fi
if [ -d "$HOME/.bun-host" ] ; then
    mkdir -p "$HOME/.bun/install/cache"
    cp -a -n "$HOME/.bun-host/." "$HOME/.bun/install/cache/" 2>/dev/null || true
fi
# The build wrote the selected agents to /etc/code-it-agents as name=binary lines,
# so the binary is data, not a hardcoded case. With no CODE_AGENT, use the first one
# listed. A CODE_AGENT the image lacks is an error, not a fallback: another agent
# would get this agent's arguments and exit, and tmux would hide why.
# CODE_AGENT_SHELL=1 (code-it --no-agent) skips the map entirely: it runs a plain
# interactive zsh in tmux, so the image need not contain any agent at all.
agent_file=/etc/code-it-agents
agent_bin=""
if [ "${CODE_AGENT_SHELL:-}" = "1" ] ; then
    agent_bin=zsh
elif [ -f "$agent_file" ] && [ -n "${CODE_AGENT:-}" ] ; then
    agent_bin=$(sed -n "s/^${CODE_AGENT}=//p" "$agent_file" | head -n 1)
    if [ -z "$agent_bin" ] ; then
        echo "Agent '$CODE_AGENT' is not installed in this image. It has: $(cut -d= -f1 "$agent_file" | tr '\n' ' ')" >&2
        echo "Rebuild the image with code-it-build --agent including $CODE_AGENT, or choose an installed agent." >&2
        exit 1
    fi
fi
if [ -z "$agent_bin" ] && [ -f "$agent_file" ] ; then
    agent_bin=$(head -n 1 "$agent_file" | cut -d= -f2-)
fi
if [ -z "$agent_bin" ] ; then
    echo "No coding agent configured in $agent_file" >&2
    exit 1
fi
if [ "${CODE_AGENT_SHELL:-}" != "1" ] && [ ! -x "$agent_bin" ] ; then
    echo "Agent binary $agent_bin is missing from this image: its install step failed. Rebuild with code-it-build --toolchain <chains> --rebuild." >&2
    exit 1
fi
if [ "${CODE_AGENT_HEADLESS:-}" = "1" ] ; then
    exec "$agent_bin" "$@"
fi
# tmux takes one shell-command string, so quote the agent and its arguments into one
agent_cmd=${(q)agent_bin}
for arg in "$@" ; do agent_cmd="$agent_cmd ${(q)arg}" ; done
# The container stops when the agent's session ends, so if the agent fails, keep its
# error on screen until Enter. CODE_IT_NO_WAIT=1 (code-it --no-wait) closes at once.
# A plain zsh never waits: it exits with its last command's status, not a failure.
if [ -z "${CODE_IT_NO_WAIT:-}" ] && [ "${CODE_AGENT_SHELL:-}" != "1" ] ; then
    agent_cmd="$agent_cmd || { printf '\n%s exited with status %s. Press Enter to close. ' ${(q)agent_bin:t} \$?; read -r _; }"
fi
# Keep the agent's last screen before its pane is destroyed. TUI agents use the
# terminal's alternate screen, which would otherwise restore the old pane on exit.
# Replay the captured screen after tmux exits, when it can be seen in the host terminal.
if [ "${CODE_AGENT_SHELL:-}" != "1" ] ; then
    agent_cmd="tmux set-window-option -t \$TMUX_PANE alternate-screen off; $agent_cmd; agent_rc=\$?; tmux capture-pane -p -t \$TMUX_PANE > /tmp/code-it-agent-exit-screen 2>/dev/null || true; exit \$agent_rc"
fi
tmux -u new-session -d
tmux -u new-session "$agent_cmd"
tmux_rc=$?
if [ "${CODE_AGENT_SHELL:-}" != "1" ] && [ -s /tmp/code-it-agent-exit-screen ] ; then
    printf '\n\n\n--- Agent screen at exit ---\n'
    cat /tmp/code-it-agent-exit-screen
    rm -f /tmp/code-it-agent-exit-screen
fi
exit "$tmux_rc"

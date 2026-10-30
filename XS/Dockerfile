FROM alpine:3.23
# code-it XS: one user-maintained Dockerfile. Edit it freely.
# code-it.sh / Code-It.ps1 build it as image code-it-xs if that image is missing,
# or when given --build / -build.

# Tools for the agent and for you: shells, git, an editor, tmux.
# libgcc and libstdc++ are needed by the Claude Code and OpenCode binaries.
RUN apk add --no-cache ca-certificates zsh bash curl doas git openssh-client ripgrep \
    vim less tmux oh-my-zsh ncurses-terminfo tzdata musl-locales libgcc libstdc++

# The agent's user. Passwordless doas for apk only, so the agent can install tools.
RUN adduser -S -s /bin/zsh agent1 -G wheel \
    && mkdir -p /etc/doas.d \
    && echo 'permit nopass agent1 as root cmd apk' > /etc/doas.d/doas.conf

# --- Toolchains: paste toolchain snippets (e.g. snippets/python-uv.dockerfile) here ---

USER agent1
ENV PATH=/home/agent1/.local/bin:/home/agent1/.opencode/bin:$PATH

# Coding agents. Each installer is downloaded before it runs, so a failed download
# fails the build instead of running an empty script. Change the "last changed"
# date to make the layer rerun and fetch the latest version.
RUN curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh \
    && bash /tmp/claude-install.sh && rm -f /tmp/claude-install.sh \
    && test -x ~/.local/bin/claude # last changed 2026-10-30
RUN curl -fsSL https://opencode.ai/v2/install -o /tmp/opencode-install.sh \
    && bash /tmp/opencode-install.sh --version 2.0.6 --no-modify-path \
    && rm -f /tmp/opencode-install.sh \
    && test -x ~/.opencode/bin/opencode # last changed 2026-10-30

# --- Agents: paste agent snippets (e.g. snippets/codex.dockerfile) here ---

RUN git config --global core.autocrlf input \
    && printf '%s\n' 'plugins=(git)' 'ZSH_THEME="robbyrussell"' \
       'source /usr/share/oh-my-zsh/oh-my-zsh.sh' >> ~/.zshrc \
    && printf '%s\n' 'set -g default-terminal "tmux-256color"' \
       'set -g mouse on' 'set -g set-clipboard on' >> ~/.tmux.conf

# go.sh starts a tmux session with a shell, and one with the agent ($CODE_AGENT,
# or zsh) given the container's arguments. Ctrl-B S switches between them.
# The launcher mounts the work dir at $CODE_IT_WORK_DIR and tells git to trust it.
RUN cat <<'EOF' > ~/go.sh && chmod +x ~/go.sh
#!/bin/zsh
cd "${CODE_IT_WORK_DIR:-/work}" || exit 1
for d in "$PWD" "$PWD"/*/(N) ; do git config --global --add safe.directory "$d" ; done
set -- "${CODE_AGENT:-opencode}" "$@"
tmux -u new-session -d
exec tmux -u new-session "${(j: :)${(q)@}}"
EOF

WORKDIR /work
ENTRYPOINT ["/home/agent1/go.sh"]

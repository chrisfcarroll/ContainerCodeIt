FROM alpine:3.24
# ===========================================================================
# Base image
# Tool chains and package caches are assembled from the selected
# toolchains/<name>/ and package-caches/<name>/ into the markers below. 
# Coding agents work the same way (agents/<name>/), except that
# this file carries the default agent (opencode) in a marked region that
# code-it-build replaces. Built directly, with no args, this file yields a base
# image with zsh, vim, tmux, git, the default agent, and no toolchains.
# ===========================================================================
RUN apk add --no-cache zsh curl doas vim tmux git docs oh-my-zsh
RUN apk add --no-cache ca-certificates less ripgrep bash
RUN apk add --no-cache libgcc libstdc++ # Claude Code & OpenCode native dependencies
RUN apk add --no-cache musl-locales ncurses-terminfo ncurses-terminfo-base
RUN apk add --no-cache openssh-client
RUN touch /etc/rc.conf
RUN sed -i 's/#unicode="NO"/#unicode="NO"\nunicode="YES"/' /etc/rc.conf

# Passwordless doas lets the agent install further tools itself. apk is always
# allowed; each selected tool chain and package cache appends its own permit
# from its fragment, which code-it-build assembles above this line.
RUN mkdir -p /etc/doas.d
RUN printf '%s\n' 'permit nopass agent1 as root cmd apk' > /etc/doas.d/doas.conf

# ===========================================================================
# User and permissions
# ===========================================================================
RUN adduser -S agent1 -G wheel
RUN sed -i 's#^\(agent1:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\)/sbin/nologin$#\1/bin/zsh#' /etc/passwd

# ===========================================================================
# Tool chains and package caches
#
# code-it-build replaces these markers with the selected toolchains/<name>/ and
# package-caches/<name>/ fragments. Each fragment is a root-run layer that is
# self-contained: its own packages, its own doas permits. Unselected tool chains
# cost nothing in the assembled (size-limited) Dockerfile. Spec 11.
# ===========================================================================
# @@CODE_IT_TOOLCHAIN_INSTALLS@@
# @@CODE_IT_PACKAGE_CACHE_INSTALLS@@

# The fragments above run as root and may create directories under the agent's
# home, so hand the whole home to agent1 before switching to it. Doing it here
# (rather than per fragment) means every part of ~ is agent1-owned, including
# intermediate directories that fragments did not anticipate: a root-owned
# /home/agent1/.local/share, for instance, would stop the agent writing
# .local/share/powershell and would also stop Docker binding a state dir below it.
RUN chown -R agent1:wheel /home/agent1

# ===========================================================================
# Coding agents and user environment
# ===========================================================================
USER agent1
RUN mkdir -p ~/.local/bin ~/.local/share
RUN echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.zshrc

# The default agent: opencode. code-it-build replaces this whole marked region
# with the selected agents' install fragments (agents/<name>/install.dockerfile)
# plus the /etc/code-it-agents name=binary map go.sh reads, so an assembled image
# contains exactly the agents it was asked for. Built directly, this region
# installs the default agent and the map for it.
# @@CODE_IT_AGENTS_BEGIN@@
RUN curl -fsSL https://opencode.ai/install | bash # last changed 2026-09-26
USER root
RUN printf '%s\n' 'opencode=/home/agent1/.opencode/bin/opencode' > /etc/code-it-agents
USER agent1
# @@CODE_IT_AGENTS_END@@

RUN git config --global rerere.enabled true
RUN git config --global alias.root 'rev-parse --show-toplevel'
RUN git config --global alias.lg  "log --color --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit --graph"
RUN git config --global alias.glog "log --color --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit"
RUN git config --global core.autocrlf input
RUN cat <<'EOF' >> ~/.zshrc
export PS1='%2~]'
alias glogg='git log --color --pretty=format:"%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset" --abbrev-commit --graph'
alias glog='git log --color --pretty=format:"%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset" --abbrev-commit'
alias gco='git checkout'
alias gaa='git add -A'
alias gitacom='git commit -am'
alias gb='git branch'
alias grv='git remote -v'
alias gs='git status'
alias la='ls -A'
alias ll='ls -alF'
alias tms='tmux switch'
alias tml='tmux ls'
alias tma='tmux a'
export LESS="-FRX"
plugins=(git)
ZSH_THEME="robbyrussell"
source /usr/share/oh-my-zsh/oh-my-zsh.sh
EOF
RUN cat <<'EOF' >> ~/.tmux.conf
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",tmux-256color:RGB"
set -ga terminal-overrides ",xterm-256color:RGB"
set -g set-clipboard on
set -g mouse on
set -g focus-events on
set -g history-limit 50000
setw -g aggressive-resize on
EOF
RUN cat <<'EOF' >> ~/go.sh
#!/usr/bin/env zsh
# Arguments given to the container after the image name are passed straight to the
# coding agent, so the launcher scripts can hand it a prompt or its own flags.
# With CODE_AGENT_HEADLESS=1 the agent runs in the foreground instead of in tmux:
# it answers, exits, and the container exits with the agent's exit code.
git config --global --add safe.directory /work
for d in /work/*/ ; do git config --global --add safe.directory "$d" ; done
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
# so the binary is data, not a hardcoded case. Fall back to the first one listed.
agent_file=/etc/code-it-agents
agent_bin=""
if [ -f "$agent_file" ] && [ -n "${CODE_AGENT:-}" ] ; then
    agent_bin=$(sed -n "s/^${CODE_AGENT}=//p" "$agent_file" | head -n 1)
fi
if [ -z "$agent_bin" ] && [ -f "$agent_file" ] ; then
    agent_bin=$(head -n 1 "$agent_file" | cut -d= -f2-)
fi
if [ -z "$agent_bin" ] ; then
    echo "No coding agent configured in $agent_file" >&2
    exit 1
fi
if [ "${CODE_AGENT_HEADLESS:-}" = "1" ] ; then
    exec "$agent_bin" "$@"
fi
# tmux takes one shell-command string, so quote the agent and its arguments into one
agent_cmd=${(q)agent_bin}
for arg in "$@" ; do agent_cmd="$agent_cmd ${(q)arg}" ; done
tmux -u new-session -d ; tmux -u new-session "$agent_cmd"
EOF
RUN chmod a+x ~/go.sh
RUN mkdir -p ~/.config/opencode
WORKDIR /work
# --------------------------------
# Repos to work on can be mounted at runtime under /work.
# Also mount the state directories for whichever agent(s) you use, for up to 7 mounts:
# 1. Repos directory
# 2. ~/.claude directory (claude credentials, settings & memory)
# 3. ~/.claude.json file (claude OAuth session data & MCP configs)
# 4. ~/.config/opencode directory (opencode configuration)
# 5. ~/.local/share/opencode directory (opencode data & auth)
# 6. Host package caches, READ-ONLY, for the package repos selected at build time:
#    ~/.nuget/packages-host (NuGet, a fallbackPackageFolder)
#    ~/.npm-host           (npm cache, seeded into ~/.npm at startup)
#    ~/.bun-host           (Bun cache, seeded into ~/.bun/install/cache at startup)
# Choose the agent with -e CODE_AGENT=opencode (default) or -e CODE_AGENT=claude
# Example :
#     docker run -it --rm \
#                -e CODE_AGENT=claude \
#                -e GIT_AUTHOR_NAME="Agent1 for $(git config --get user.name)" \
#                -e GIT_AUTHOR_EMAIL="$(git config --get user.email)" \
#                -e GIT_COMMITTER_NAME="Agent1 for $(git config --get user.name)" \
#                -e GIT_COMMITTER_EMAIL="$(git config --get user.email)" \
#                -v ~/repos:/work \
#                -v ~/.config/code-it/.claude:/home/agent1/.claude \
#                -v ~/.config/code-it/.claude.json:/home/agent1/.claude.json \
#                -v ~/.config/code-it/.config/opencode:/home/agent1/.config/opencode \
#                -v ~/.config/code-it/.local/share/opencode:/home/agent1/.local/share/opencode \
#                -v ~/.nuget/packages:/home/agent1/.nuget/packages-host:ro \
#        code-it-alpine-dotnet-node:latest
# --------------------------------
ARG GIT_AUTHOR_NAME
ARG GIT_AUTHOR_EMAIL
ENV GIT_AUTHOR_NAME=$GIT_AUTHOR_NAME
ENV GIT_AUTHOR_EMAIL=$GIT_AUTHOR_EMAIL
# --------------------------------
#
RUN if [ -n "$GIT_AUTHOR_NAME"  ] ; then git config --global user.name "Agent1 for $GIT_AUTHOR_NAME" ; fi
RUN if [ -n "$GIT_AUTHOR_EMAIL" ] ; then git config --global user.email "$GIT_AUTHOR_EMAIL" ; fi
# Run go.sh directly, not via `zsh -c`, so that arguments passed to the container
# after the image name arrive as "$@" and can be forwarded to the coding agent.
ENTRYPOINT ["/home/agent1/go.sh"]

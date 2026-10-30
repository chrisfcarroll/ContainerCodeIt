FROM alpine:3.23
# ===========================================================================
# Allow for additional certificates needed by user for .e.g. corporate 
# TLS-intercepting proxy. Any *.crt, *.cer or *.pem in ca-certificates/ is 
# trusted before the first apk fetch.
# ===========================================================================
COPY ca-certificates/ /tmp/ca-certificates/
RUN mkdir -p /usr/local/share/ca-certificates && found=0 && \
    for f in /tmp/ca-certificates/*.crt /tmp/ca-certificates/*.cer /tmp/ca-certificates/*.pem; do \
        [ -f "$f" ] || continue; \
        found=$((found + 1)); \
        echo "Processing CA certificate file $(basename "$f")"; \
        crt="/usr/local/share/ca-certificates/$(basename "${f%.*}").crt"; \
        if grep -q -- '-----BEGIN CERTIFICATE-----' "$f"; then tr -d '\r' < "$f" > "$crt"; \
        else { echo '-----BEGIN CERTIFICATE-----'; base64 "$f" | tr -d '\n' | fold -w 64; echo; echo '-----END CERTIFICATE-----'; } > "$crt"; fi; \
        { echo; cat "$crt"; } >> /etc/ssl/certs/ca-certificates.crt; \
        echo "  trusting $(grep -c -- '-----BEGIN CERTIFICATE-----' "$crt") certificate(s) as $(basename "$crt")"; \
    done; \
    [ "$found" -gt 0 ] || echo "No additional certificate trust was requested"; \
    rm -rf /tmp/ca-certificates
RUN apk add --no-cache ca-certificates && update-ca-certificates

# ===========================================================================
# Base image
# Toolchains and package caches are assembled from the selected
# toolchains/<name>/ and package-caches/<name>/ into the markers below.
# Coding agents work the same way (agents/<name>/), except that
# this file carries the default agent (opencode) in a marked region that
# code-it-build replaces. Built directly, with no args, this file yields a base
# image with zsh, vim, tmux, git, the default agent, and no toolchains.
# ===========================================================================
# Only tools here: each toolchain and agent brings its own libraries. The apk
# packages a toolchain installs declare their library dependencies; the
# PowerShell tarball and the opencode agents do not, so their fragments add theirs.
RUN apk add --no-cache zsh bash curl doas
RUN apk add --no-cache git openssh-client ripgrep
RUN apk add --no-cache vim less tmux oh-my-zsh ncurses-terminfo tzdata musl-locales

# Passwordless doas lets the agent install further tools itself. apk is always
# allowed; each selected toolchain and package cache appends its own permit
# from its fragment, which code-it-build assembles above this line.
RUN mkdir -p /etc/doas.d
RUN printf '%s\n' 'permit nopass agent1 as root cmd apk' > /etc/doas.d/doas.conf

# ===========================================================================
# User and permissions
# ===========================================================================
RUN adduser -S agent1 -G wheel
RUN sed -i 's#^\(agent1:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\)/sbin/nologin$#\1/bin/zsh#' /etc/passwd

# ===========================================================================
# Toolchains and package caches
#
# code-it-build replaces these markers with the selected toolchains/<name>/ and
# package-caches/<name>/ fragments. Each fragment is a root-run layer that is
# self-contained: its own packages, its own doas permits. Unselected toolchains
# cost nothing in the assembled (size-limited) Dockerfile. Spec 13.
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

# The default agent: opencode (v2). code-it-build replaces this whole marked region
# with the selected agents' install fragments (agents/<name>/install.dockerfile)
# plus the /etc/code-it-agents name=binary map go.sh reads, so an assembled image
# contains exactly the agents it was asked for. Built directly, this region
# installs the default agent and the map for it.
# @@CODE_IT_AGENTS_BEGIN@@
# Its musl build links libgcc and libstdc++, which apk does not know about.
USER root
RUN apk add --no-cache libgcc libstdc++
USER agent1
# Its installer writes ~/.opencode/bin/opencode, so install into a scratch HOME and
# move the binary to ~/.opencode-v2/bin, the AGENT_BINARY existing images record.
# Download the installer before running it: with "curl | bash" a failed download
# runs an empty script and the layer succeeds without the agent. The final test
# fails the build if the binary still is not there.
RUN curl -fsSL https://opencode.ai/v2/install -o /tmp/opencode-v2-install.sh \
    && HOME=/tmp/opencode-v2 bash /tmp/opencode-v2-install.sh --version 2.0.6 --no-modify-path \
    && mkdir -p ~/.opencode-v2/bin && mv /tmp/opencode-v2/.opencode/bin/opencode ~/.opencode-v2/bin/opencode \
    && rm -rf /tmp/opencode-v2 /tmp/opencode-v2-install.sh \
    && test -x ~/.opencode-v2/bin/opencode # last changed 2026-10-30
USER root
RUN printf '%s\n' 'opencode=/home/agent1/.opencode-v2/bin/opencode' > /etc/code-it-agents
USER agent1
# Each installed agent's binary directory goes on zsh's PATH, so a --no-agent
# shell can invoke it (Spec 18): the default agent is opencode (v2)
RUN echo 'export PATH="/home/agent1/.opencode-v2/bin:$PATH"' >> ~/.zshrc
# @@CODE_IT_AGENTS_END@@

RUN git config --global rerere.enabled true
RUN git config --global alias.root 'rev-parse --show-toplevel'
RUN git config --global alias.lg  "log --color --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit --graph"
RUN git config --global alias.glog "log --color --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit"
RUN git config --global core.autocrlf input
RUN git config --global feature.manyFiles true
RUN git config --global core.fsmonitor true
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
# The launcher mounts the host's work dir at /work/<parent>/<name>
# (CODE_IT_WORK_DIR), so directories keep their names for agents' per-directory
# memory. The image's own WORKDIR /work is only the container's default: go.sh
# must cd to the mounted path, or the agent starts in the wrong directory.
work_dir=${CODE_IT_WORK_DIR:-/work}
cd "$work_dir" 2>/dev/null || {
    echo "CODE_IT_WORK_DIR '$work_dir' does not exist in the container. Mount the work dir there, or run without it to start in /work." >&2
    exit 1
}
git config --global --add safe.directory "$work_dir"
for d in "$work_dir"/*/ ; do git config --global --add safe.directory "$d" ; done
# Index format is repository-local, so upgrade each mounted repository once at
# startup. Skip nested directories that resolve to the same repository root.
for repo in "$work_dir" "$work_dir"/*/ ; do
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
tmux -u new-session -d ; tmux -u new-session "$agent_cmd"
EOF
RUN chmod a+x ~/go.sh
RUN mkdir -p ~/.config/opencode
WORKDIR /work
# --------------------------------
# The host's work directory is mounted at runtime at /work/<parent>/<name> (the
# names of its parent directory and of itself, so directories keep their names
# for agents' per-directory memory); CODE_IT_WORK_DIR tells go.sh the path, and
# go.sh cds to it, so the agent starts in the mounted directory.
# Also mount the state directories for whichever agent(s) you use, for up to 7 mounts:
# 1. Work directory, at /work/<parent>/<name> (CODE_IT_WORK_DIR)
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
#                -e CODE_IT_WORK_DIR=/work/repos/my-repos \
#                -e GIT_AUTHOR_NAME="Agent1 for $(git config --get user.name)" \
#                -e GIT_AUTHOR_EMAIL="$(git config --get user.email)" \
#                -e GIT_COMMITTER_NAME="Agent1 for $(git config --get user.name)" \
#                -e GIT_COMMITTER_EMAIL="$(git config --get user.email)" \
#                -v ~/repos/my-repos:/work/repos/my-repos \
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
# Locale. code-it-build sets LOCALE to the host's locale by default (--locale
# like-host), always a UTF-8 one; musl-locales, in the base layer, supplies the
# translations it has. Declared this low so changing it rebuilds only this layer.
ARG LOCALE=C.UTF-8
ENV LANG=$LOCALE
# Run go.sh directly, not via `zsh -c`, so that arguments passed to the container
# after the image name arrive as "$@" and can be forwarded to the coding agent.
ENTRYPOINT ["/home/agent1/go.sh"]

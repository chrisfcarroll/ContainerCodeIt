FROM alpine:3.24

# ===========================================================================
# Base image: tools every sandbox needs, whatever the tech stack
# ===========================================================================
# Only tools here: each toolchain and agent brings its own libraries. The apk
# toolchain packages (dotnet*, nodejs, python3, ...) declare their library
# dependencies, so apk pulls them in; the PowerShell tarball and the opencode
# agents do not, so their layers add theirs.
RUN apk add --no-cache zsh bash curl doas
RUN apk add --no-cache git openssh-client ripgrep
RUN apk add --no-cache uv
RUN apk add --no-cache vim less tmux oh-my-zsh ncurses-terminfo tzdata musl-locales

# ===========================================================================
# Tech stack selection
#
# These build switches are declared as low in the file as the layers that use
# them allow, so changing one only invalidates the layers below it. Each is a
# boolean, and each switched off skips its install layer entirely:
#
#   DOTNET   .NET SDK + Mono                 (implies NUGET)
#   NODE     Node.js                         (implies NPM)
#   BUN      Bun, the all-in-one JS runtime  (implies nothing: it bundles its
#                                             own runtime, bundler and package
#                                             manager)
#   PYTHON   Python 3 (uv is installed for every image, see the base layer)
#   NUGET    NuGet package cache support      (may be selected without DOTNET)
#   NPM      npm package cache support        (may be selected without NODE)
#
# NUGET and NPM may be left empty to follow DOTNET and NODE respectively. The
# effective values are normalised once into /etc/code-it-tech.env so the later
# layers can read them.
# ===========================================================================
ARG DOTNET=true
ARG NODE=true
ARG BUN=false
ARG PYTHON=false
ARG NUGET=
ARG NPM=
RUN set -e; \
    case "$NUGET" in true|false) ;; *) NUGET=$DOTNET ;; esac; \
    case "$NPM"   in true|false) ;; *) NPM=$NODE   ;; esac; \
    printf 'DOTNET=%s\nNODE=%s\nBUN=%s\nPYTHON=%s\nNUGET=%s\nNPM=%s\n' \
        "$DOTNET" "$NODE" "$BUN" "$PYTHON" "$NUGET" "$NPM" > /etc/code-it-tech.env

# --- .NET ------------------------------------------------------------------
RUN . /etc/code-it-tech.env; if [ "$DOTNET" = true ]; then \
        apk add --no-cache dotnet10-sdk dotnet8-sdk mono; \
        dotnet workload update; \
    fi

# --- Node.js ---------------------------------------------------------------
RUN . /etc/code-it-tech.env; if [ "$NODE" = true ]; then \
        apk add --no-cache nodejs; \
    fi

# --- npm -------------------------------------------------------------------
# Selecting npm without Node.js still works: the apk package pulls nodejs in.
RUN . /etc/code-it-tech.env; if [ "$NPM" = true ]; then \
        apk add --no-cache npm; \
    fi

# --- Bun -------------------------------------------------------------------
# Bun ships musl builds and its installer already picks the right architecture
# for Alpine. Install into /usr/local so every user finds it on PATH; unzip is
# its only requirement.
RUN . /etc/code-it-tech.env; if [ "$BUN" = true ]; then \
        apk add --no-cache unzip; \
        curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash; \
        /usr/local/bin/bun --version; \
    fi

# --- Python ----------------------------------------------------------------
# Python 3 from Alpine's own repos. uv (installed for every image in the base
# layer) is the package manager: the system Python is externally managed, so
# never pip-install into it. uv fetches musl CPython builds on x86_64/aarch64.
RUN . /etc/code-it-tech.env; if [ "$PYTHON" = true ]; then \
        apk add --no-cache python3; \
        python3 --version; \
    fi

# ===========================================================================
# PowerShell
# ===========================================================================
# Microsoft only ships musl (Alpine) builds for x64, so on other architectures
# install it as a dotnet tool instead, with gcompat plus a tiny shim for two
# glibc-only symbols its native library needs (verified on aarch64). That path
# needs the .NET SDK, so it is skipped when DOTNET is switched off.
# The x64 tarball is not an apk package, so add the libraries it links
# (libgcc, libstdc++) and loads at runtime (icu-libs for globalization, libssl3
# for TLS) ourselves.
RUN set -e; \
    if [ "$(uname -m)" = "x86_64" ]; then \
        apk add --no-cache libgcc libstdc++ icu-libs libssl3 && \
        curl -L https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/powershell-7.6.6-linux-musl-x64.tar.gz -o /tmp/powershell.tar.gz && \
        mkdir -p /opt/microsoft/powershell/7 && \
        tar zxf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7 && \
        chmod +x /opt/microsoft/powershell/7/pwsh && \
        ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh && \
        rm -rf /tmp/powershell*; \
    elif . /etc/code-it-tech.env && [ "$DOTNET" = true ]; then \
        apk add --no-cache gcompat && \
        apk add --no-cache --virtual .pwsh-build build-base && \
        dotnet tool install --tool-path /opt/microsoft/powershell PowerShell && \
        echo '#include <stdlib.h>'  >  /tmp/chk_shim.c && \
        echo '#include <limits.h>' >> /tmp/chk_shim.c && \
        echo '#include <stdarg.h>' >> /tmp/chk_shim.c && \
        echo '#include <syslog.h>' >> /tmp/chk_shim.c && \
        echo 'char *__realpath_chk(const char *p, char *r, size_t l) { if (l < PATH_MAX) abort(); return realpath(p, r); }' >> /tmp/chk_shim.c && \
        echo 'void __syslog_chk(int pri, int flag, const char *fmt, ...) { va_list ap; va_start(ap, fmt); vsyslog(pri, fmt, ap); va_end(ap); }' >> /tmp/chk_shim.c && \
        gcc -shared -fPIC -o /usr/lib/libpsl-chk-shim.so /tmp/chk_shim.c && \
        rm -f /tmp/chk_shim.c && \
        apk del .pwsh-build && \
        printf '#!/bin/sh\nLD_PRELOAD=/usr/lib/libpsl-chk-shim.so exec /opt/microsoft/powershell/pwsh "$@"\n' > /usr/bin/pwsh && \
        chmod +x /usr/bin/pwsh; \
    else \
        echo "Skipping PowerShell: it needs the .NET SDK on non-x86_64"; \
    fi

# ===========================================================================
# User and permissions
# ===========================================================================
RUN adduser -S agent1 -G wheel
RUN sed -i 's#^\(agent1:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\)/sbin/nologin$#\1/bin/zsh#' /etc/passwd
# Passwordless doas lets the agent install further tools itself. apk is always
# allowed; each enabled tech adds its own command(s), mirroring the switches in
# the tech stack section above.
RUN mkdir -p /etc/doas.d
RUN . /etc/code-it-tech.env; { \
        echo "permit nopass agent1 as root cmd apk"; \
        if [ "$DOTNET" = true ]; then echo "permit nopass agent1 as root cmd dotnet"; fi; \
        if [ "$NUGET" = true ]; then echo "permit nopass agent1 as root cmd nuget"; fi; \
        if [ "$NODE" = true ] || [ "$NPM" = true ]; then echo "permit nopass agent1 as root cmd node"; fi; \
        if [ "$NPM" = true ]; then echo "permit nopass agent1 as root cmd npm"; fi; \
        if [ "$BUN" = true ]; then echo "permit nopass agent1 as root cmd bun"; fi; \
        if [ "$PYTHON" = true ]; then echo "permit nopass agent1 as root cmd python3"; fi; \
    } > /etc/doas.d/doas.conf

# ===========================================================================
# Package caches
# ===========================================================================
# The launcher bind-mounts the host package caches READ-ONLY at the "-host"
# paths below, so the agent reuses downloads without ever writing to the host.
# The container keeps its own writable cache alongside. /home/agent1/go.sh
# seeds the writable cache from the read-only mount at startup.
#
# NuGet uses a fallbackPackageFolder, so dotnet restore reads the host cache
# directly (packages not found there are downloaded into ~/.nuget/packages).
USER agent1
RUN . /etc/code-it-tech.env; if [ "$NUGET" = true ]; then \
        mkdir -p ~/.nuget/packages-host ~/.nuget/NuGet; \
        printf '%s\n' \
            '<?xml version="1.0" encoding="utf-8"?>' \
            '<configuration>' \
            '  <fallbackPackageFolders>' \
            '    <add key="host-nuget-cache" value="/home/agent1/.nuget/packages-host" />' \
            '  </fallbackPackageFolders>' \
            '  <packageSources>' \
            '    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />' \
            '    <add key="host-nuget-cache" value="/home/agent1/.nuget/packages-host" />' \
            '  </packageSources>' \
            '</configuration>' > ~/.nuget/NuGet/NuGet.Config; \
    fi
# npm and Bun use their default writable caches; create both them and the
# read-only host mount points so the launcher always has somewhere to mount.
RUN . /etc/code-it-tech.env; if [ "$NPM" = true ]; then \
        mkdir -p ~/.npm ~/.npm-host; \
    fi
RUN . /etc/code-it-tech.env; if [ "$BUN" = true ]; then \
        mkdir -p ~/.bun/install/cache ~/.bun-host; \
    fi

# ===========================================================================
# Coding agents and user environment
# ===========================================================================
# The coding agents' install layers are assembled into this file at build time by
# code-it-build from agents/<name>/install.dockerfile for the --agent list, which
# also writes /etc/code-it-agents (name=binary per line) for go.sh to read. The
# marker below is where that block goes; building this file directly would leave
# the image without agents, so use code-it-build.
RUN mkdir -p ~/.local/bin
RUN echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.zshrc
# uv keeps its cache and tool installs inside the agent's home. It is never the
# host cache, which the launcher does not mount (uv needs to write to its cache).
RUN mkdir -p ~/.cache/uv
RUN echo "export UV_CACHE_DIR=\"\$HOME/.cache/uv\"" >> ~/.zshrc
ENV UV_CACHE_DIR=/home/agent1/.cache/uv
# @@CODE_IT_AGENT_INSTALLS@@
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
# so the binary is data, not a hardcoded case. With no CODE_AGENT, use the first one
# listed. A CODE_AGENT the image lacks is an error, not a fallback: another agent
# would get this agent's arguments and exit, and tmux would hide why.
agent_file=/etc/code-it-agents
agent_bin=""
if [ -f "$agent_file" ] && [ -n "${CODE_AGENT:-}" ] ; then
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
if [ ! -x "$agent_bin" ] ; then
    echo "Agent binary $agent_bin is missing from this image: its install step failed. Rebuild with code-it-build --rebuild." >&2
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

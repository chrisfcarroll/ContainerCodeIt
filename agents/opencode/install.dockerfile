# OpenCode CLI, installed into the agent's home. Keep the "# last changed" line:
# code-it-build --rebuild bumps it to force this layer to rerun.
# Its musl build links libgcc and libstdc++, which apk does not know about.
USER root
RUN apk add --no-cache libgcc libstdc++
USER agent1
RUN curl -fsSL https://opencode.ai/install | bash # last changed 2026-09-26

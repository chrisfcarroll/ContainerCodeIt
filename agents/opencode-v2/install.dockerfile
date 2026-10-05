# OpenCode v2 CLI, installed into the agent's home. Keep the "# last changed" line:
# code-it-build --rebuild bumps it to force this layer to rerun.
# Its musl build links libgcc and libstdc++, which apk does not know about.
USER root
RUN apk add --no-cache libgcc libstdc++
USER agent1
RUN curl -fsSL https://opencode.ai/v2/install | bash -s -- --version 2.0.6 --no-modify-path # last changed 2026-10-04

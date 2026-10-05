# OpenCode CLI, installed into the agent's home. Keep the "# last changed" line:
# code-it-build --rebuild bumps it to force this layer to rerun.
# Its musl build links libgcc and libstdc++, which apk does not know about.
USER root
RUN apk add --no-cache libgcc libstdc++
USER agent1
# Download the installer before running it: with "curl | bash" a failed download
# runs an empty script and the layer succeeds without the agent. The final test
# fails the build if the binary still is not there.
RUN curl -fsSL https://opencode.ai/install -o /tmp/opencode-install.sh \
    && bash /tmp/opencode-install.sh && rm -f /tmp/opencode-install.sh \
    && test -x ~/.opencode/bin/opencode # last changed 2026-10-05

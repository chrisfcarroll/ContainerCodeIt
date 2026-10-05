# OpenCode v2 CLI, installed into the agent's home. Keep the "# last changed" line:
# code-it-build --rebuild bumps it to force this layer to rerun.
# Its musl build links libgcc and libstdc++, which apk does not know about.
USER root
RUN apk add --no-cache libgcc libstdc++
USER agent1
# Its installer always writes ~/.opencode/bin/opencode, where opencode (v1) lives, so
# install into a scratch HOME and move the binary to its own directory.
# Download the installer before running it: with "curl | bash" a failed download
# runs an empty script and the layer succeeds without the agent. The final test
# fails the build if the binary still is not there.
RUN curl -fsSL https://opencode.ai/v2/install -o /tmp/opencode-v2-install.sh \
    && HOME=/tmp/opencode-v2 bash /tmp/opencode-v2-install.sh --version 2.0.6 --no-modify-path \
    && mkdir -p ~/.opencode-v2/bin && mv /tmp/opencode-v2/.opencode/bin/opencode ~/.opencode-v2/bin/opencode \
    && rm -rf /tmp/opencode-v2 /tmp/opencode-v2-install.sh \
    && test -x ~/.opencode-v2/bin/opencode # last changed 2026-10-05

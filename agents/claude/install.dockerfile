# Claude Code CLI, installed into the agent's home. Keep the "# last changed" line:
# code-it-build --rebuild bumps it to force this layer to rerun.
# Download the installer before running it: with "curl | bash" a failed download
# runs an empty script and the layer succeeds without the agent. The final test
# fails the build if the binary still is not there.
RUN curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh \
    && bash /tmp/claude-install.sh && rm -f /tmp/claude-install.sh \
    && test -x ~/.local/bin/claude # last changed 2026-10-06

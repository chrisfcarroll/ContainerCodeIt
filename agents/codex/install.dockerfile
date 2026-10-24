# OpenAI Codex CLI, installed into the agent's home. Keep the "# last changed" line:
# code-it-build --rebuild bumps it to force this layer to rerun.
# Its musl build is fully statically linked, so no shared libraries are needed.
USER agent1
# Download the tarball before unpacking it, and pin the version: the release
# tarball holds a single file named for its platform, which is moved onto the
# agent's PATH. The final test fails the build if the binary still is not there.
RUN case "$(uname -m)" in \
        x86_64)  arch=x86_64 ;; \
        aarch64) arch=aarch64 ;; \
        *)       echo "codex: unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/openai/codex/releases/download/rust-v0.164.0/codex-${arch}-unknown-linux-musl.tar.gz" -o /tmp/codex.tar.gz && \
    mkdir -p ~/.local/bin && \
    tar xzf /tmp/codex.tar.gz -C /tmp && \
    mv "/tmp/codex-${arch}-unknown-linux-musl" ~/.local/bin/codex && \
    rm -f /tmp/codex.tar.gz && \
    test -x ~/.local/bin/codex # last changed 2026-10-24

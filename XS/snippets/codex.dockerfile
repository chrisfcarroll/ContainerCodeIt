# OpenAI Codex CLI, a statically linked musl build. Paste into the Dockerfile at
# "--- Agents", which runs as agent1, then rebuild with code-it --build.
# Run it with: code-it --agent codex -- --dangerously-bypass-approvals-and-sandbox
RUN case "$(uname -m)" in \
        x86_64|aarch64) arch=$(uname -m) ;; \
        *) echo "codex: unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/openai/codex/releases/download/rust-v0.164.0/codex-${arch}-unknown-linux-musl.tar.gz" -o /tmp/codex.tar.gz \
    && tar xzf /tmp/codex.tar.gz -C /tmp \
    && mkdir -p ~/.local/bin && mv "/tmp/codex-${arch}-unknown-linux-musl" ~/.local/bin/codex \
    && rm -f /tmp/codex.tar.gz \
    && test -x ~/.local/bin/codex # last changed 2026-10-30

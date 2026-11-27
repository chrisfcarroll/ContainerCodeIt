# Google Antigravity CLI (agy), a fully statically linked musl build. Paste into the
# Dockerfile at "--- Agents", which runs as agent1, then rebuild with code-it --build.
# The download is pinned and checked against the SHA-512 in Google's release manifest,
# as the official installer (https://antigravity.google/cli/install.sh) checks it.
# With no OS keyring in a container it keeps its Google login in files: sign in by
# pasting the code its login URL gives you. Run it without permission prompts with:
#   code-it --agent agy -- --dangerously-skip-permissions
# For a Gemini API key instead, add -D:-e -D:GEMINI_API_KEY and, after the --,
# --settings '{"modelProvider":"gemini"}' (agy will not start with it and no key).
RUN case "$(uname -m)" in \
        x86_64)  url="https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-6386224290725888/linux-x64-musl/cli_linux_x64_musl.tar.gz" \
                 sha=938cc71c609ecaaa53588db9ebe93720591ed977f8d3c9e862a302c266ff0068dc1992722aac01fe5b45ce23f772265980e6df2b193048b93bbd947a433bae2b ;; \
        aarch64) url="https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-6386224290725888/linux-arm-musl/cli_linux_arm64_musl.tar.gz" \
                 sha=744da8e3c0135ab80705b10e621b7164e27d5dc30c58f75497ca0f94aabe9fa7e77731c00fda28f0f08ef3dbb130a11a730172d5088218e6e3665319629a9311 ;; \
        *)       echo "agy: unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "$url" -o /tmp/agy.tar.gz \
    && echo "$sha  /tmp/agy.tar.gz" | sha512sum -c - \
    && tar xzf /tmp/agy.tar.gz -C /tmp \
    && mkdir -p ~/.local/bin && mv /tmp/antigravity ~/.local/bin/agy \
    && rm -f /tmp/agy.tar.gz \
    && test -x ~/.local/bin/agy # last changed 2026-11-27

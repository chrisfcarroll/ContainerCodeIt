# Google Antigravity CLI (agy), installed into the agent's home. Keep the
# "# last changed" line: code-it-build --rebuild bumps it to force this layer to
# rerun.
# Its musl build is fully statically linked, so no shared libraries are needed.
USER agent1
# Download the tarball for this architecture before unpacking it, and pin the
# version. The URLs and SHA512 checksums are those of Google's official release
# manifest (the one the official installer, https://antigravity.google/cli/install.sh,
# fetches and verifies the same way). The tarball holds a single file named
# antigravity, moved onto the agent's PATH as agy. The final test fails the build
# if the binary still is not there.
RUN case "$(uname -m)" in \
        x86_64)  url="https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-6386224290725888/linux-x64-musl/cli_linux_x64_musl.tar.gz" \
                 sha=938cc71c609ecaaa53588db9ebe93720591ed977f8d3c9e862a302c266ff0068dc1992722aac01fe5b45ce23f772265980e6df2b193048b93bbd947a433bae2b ;; \
        aarch64) url="https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-6386224290725888/linux-arm-musl/cli_linux_arm64_musl.tar.gz" \
                 sha=744da8e3c0135ab80705b10e621b7164e27d5dc30c58f75497ca0f94aabe9fa7e77731c00fda28f0f08ef3dbb130a11a730172d5088218e6e3665319629a9311 ;; \
        *)       echo "antigravity-cli: unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "$url" -o /tmp/agy.tar.gz && \
    echo "$sha  /tmp/agy.tar.gz" | sha512sum -c - && \
    mkdir -p ~/.local/bin && \
    tar xzf /tmp/agy.tar.gz -C /tmp && \
    mv /tmp/antigravity ~/.local/bin/agy && \
    rm -f /tmp/agy.tar.gz && \
    test -x ~/.local/bin/agy # last changed 2026-11-26

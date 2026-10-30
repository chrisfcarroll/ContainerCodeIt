# Python 3 and uv, from Alpine's own repos. Paste into the Dockerfile at
# "--- Toolchains", which runs as root, then rebuild with code-it --build.
# The system Python is externally managed: use uv venv / uv tool, not pip install.
RUN apk add --no-cache python3 uv # last changed 2026-10-30

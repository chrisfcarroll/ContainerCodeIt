# Python 3 from Alpine's own repos, plus uv as the package manager. The system
# Python is externally managed, so never pip-install into it; use uv venv/uv tool.
# uv keeps its cache inside the agent's home and fetches musl CPython builds for
# x86_64 and aarch64.
RUN apk add --no-cache python3 uv # last changed 2026-09-26
RUN python3 --version
ENV UV_CACHE_DIR=/home/agent1/.cache/uv
RUN mkdir -p /home/agent1/.cache/uv && chown -R agent1:wheel /home/agent1/.cache
RUN printf '%s\n' 'permit nopass agent1 as root cmd python3' >> /etc/doas.d/doas.conf

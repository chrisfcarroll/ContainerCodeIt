# Bun uses its default writable cache (~/.bun/install/cache); the read-only host
# mount point .bun-host is seeded into it by the container's go.sh at startup.
RUN mkdir -p /home/agent1/.bun/install/cache /home/agent1/.bun-host && chown -R agent1:wheel /home/agent1/.bun
RUN printf '%s\n' 'permit nopass agent1 as root cmd bun' >> /etc/doas.d/doas.conf

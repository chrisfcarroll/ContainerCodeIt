# npm uses its default writable cache (~/.npm); the read-only host mount point
# .npm-host is seeded into it by the container's go.sh at startup.
RUN mkdir -p /home/agent1/.npm /home/agent1/.npm-host && chown -R agent1:wheel /home/agent1/.npm /home/agent1/.npm-host
RUN printf '%s\n' 'permit nopass agent1 as root cmd node' >> /etc/doas.d/doas.conf
RUN printf '%s\n' 'permit nopass agent1 as root cmd npm' >> /etc/doas.d/doas.conf

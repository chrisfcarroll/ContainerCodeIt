RUN apk add --no-cache nodejs # last changed 2026-10-30
RUN printf '%s\n' 'permit nopass agent1 as root cmd node' >> /etc/doas.d/doas.conf

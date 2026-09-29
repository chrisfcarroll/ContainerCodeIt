# Bun ships musl builds and its installer already picks the right architecture
# for Alpine. Install into /usr/local so every user finds it on PATH; unzip is
# its only requirement.
RUN apk add --no-cache unzip
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash # last changed 2026-09-26
RUN /usr/local/bin/bun --version
RUN printf '%s\n' 'permit nopass agent1 as root cmd bun' >> /etc/doas.d/doas.conf

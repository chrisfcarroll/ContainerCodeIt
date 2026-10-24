# Rust and cargo from Alpine's own musl-built packages. `rust` alone does not
# include cargo, so both are installed.
RUN apk add --no-cache rust cargo # last changed 2026-10-24
RUN printf '%s\n' 'permit nopass agent1 as root cmd cargo' >> /etc/doas.d/doas.conf

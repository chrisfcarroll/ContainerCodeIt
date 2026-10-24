# gcc from Alpine's own musl-built packages. It does not depend on musl-dev, so
# the C headers are installed with it.
RUN apk add --no-cache gcc musl-dev # last changed 2026-10-24
RUN printf '%s\n' 'permit nopass agent1 as root cmd gcc' >> /etc/doas.d/doas.conf

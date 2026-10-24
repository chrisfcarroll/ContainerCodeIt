# clang from Alpine's own musl-built packages (the branch's versioned clangN,
# which pulls in the C headers and its gcc dependencies by itself).
RUN apk add --no-cache clang # last changed 2026-10-24
RUN printf '%s\n' 'permit nopass agent1 as root cmd clang' >> /etc/doas.d/doas.conf

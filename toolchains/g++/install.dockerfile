# g++ from Alpine's own musl-built packages (it pulls in gcc, musl-dev and the
# C++ headers by itself).
RUN apk add --no-cache g++ # last changed 2026-10-24
RUN printf '%s\n' 'permit nopass agent1 as root cmd g++' >> /etc/doas.d/doas.conf

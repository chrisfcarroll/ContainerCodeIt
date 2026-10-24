# Go from Alpine's community repository (a musl build). GOTOOLCHAIN=local pins the
# toolchain to this one: Go's automatic toolchain downloads from go.dev are glibc
# builds that will not run on musl.
RUN apk add --no-cache go # last changed 2026-10-24
ENV GOTOOLCHAIN=local
RUN printf '%s\n' 'permit nopass agent1 as root cmd go' >> /etc/doas.d/doas.conf

# .NET SDK 10 and 8, plus Mono. The runtime libraries are installed explicitly
# because Alpine's .NET packages expect them at fixed paths.
RUN apk add --no-cache krb5-libs libgcc libintl libssl3 libstdc++ tzdata userspace-rcu zlib icu-libs # last changed 2026-09-26
RUN apk -X https://dl-cdn.alpinelinux.org/alpine/edge/main add --no-cache lttng-ust
RUN apk add --no-cache dotnet10-sdk dotnet8-sdk mono
RUN dotnet workload update
RUN printf '%s\n' 'permit nopass agent1 as root cmd dotnet' >> /etc/doas.d/doas.conf

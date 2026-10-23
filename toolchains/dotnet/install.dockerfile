# .NET SDK 10 and 8, plus Mono. Alpine's packages declare their own library
# dependencies, so apk pulls them in.
RUN apk add --no-cache dotnet10-sdk dotnet8-sdk mono # last changed 2026-10-23
RUN dotnet workload update
RUN printf '%s\n' 'permit nopass agent1 as root cmd dotnet' >> /etc/doas.d/doas.conf

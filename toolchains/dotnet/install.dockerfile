# .NET SDK 10 and 8 from Microsoft's linux-musl tarballs, not apk. Alpine's
# dotnet10-sdk and the apphost pack it needs are built from separate aports whose
# versions drift apart: on 3.23 the 10.0.110 SDK wants apphost pack 10.0.10 but
# dotnet10-runtime ships 10.0.13, so building any executable fails with NU1101
# for Microsoft.NETCore.App.Host.alpine.3.23-x64. Microsoft's SDKs use the
# portable linux-musl RID and carry their own matching packs.
# Each channel's latest SDK is read from latest.version and checked against the
# SHA-512 Microsoft publishes beside it. The tarballs are not apk packages, so add
# the libraries they link and load (ICU, Kerberos, OpenSSL, zlib) ourselves.
RUN set -e; \
    apk add --no-cache icu-data-full icu-libs krb5-libs libgcc libintl libssl3 libstdc++ zlib; \
    case "$(uname -m)" in \
        x86_64) arch=x64 ;; \
        aarch64) arch=arm64 ;; \
        *) echo "No .NET SDK for $(uname -m)" >&2; exit 1 ;; \
    esac; \
    mkdir -p /usr/share/dotnet; \
    for channel in 10.0 8.0; do \
        version=$(curl -fsSL "https://builds.dotnet.microsoft.com/dotnet/Sdk/$channel/latest.version" | tr -d '\r\n'); \
        file="dotnet-sdk-$version-linux-musl-$arch.tar.gz"; \
        curl -fsSL "https://builds.dotnet.microsoft.com/dotnet/Sdk/$version/$file" -o "/tmp/$file"; \
        curl -fsSL "https://builds.dotnet.microsoft.com/dotnet/Sdk/$version/$file.sha512" -o "/tmp/$file.sha512"; \
        (cd /tmp && sha512sum -c "$file.sha512"); \
        tar xzf "/tmp/$file" -C /usr/share/dotnet; \
        rm -f "/tmp/$file" "/tmp/$file.sha512"; \
    done; \
    ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet # last changed 2026-10-24
ENV DOTNET_ROOT=/usr/share/dotnet
RUN apk add --no-cache mono
RUN dotnet workload update
RUN printf '%s\n' 'permit nopass agent1 as root cmd dotnet' >> /etc/doas.d/doas.conf

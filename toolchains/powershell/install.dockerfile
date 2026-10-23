# Microsoft only ships musl (Alpine) builds for x64, so on other architectures
# install it as a dotnet tool instead, with gcompat plus a tiny shim for two
# glibc-only symbols its native library needs (verified on aarch64). That path
# needs the .NET SDK, installed here so this fragment stands alone. PowerShell
# 7.6 is built on .NET 10 (its tool package only carries tools/net10.0), so the
# SDK and the pinned tool version must match; on .NET 8 the installer reports a
# misleading "DotnetToolSettings.xml was not found" error.
# The SDK is Microsoft's linux-musl tarball rather than Alpine's dotnet10-sdk,
# whose apphost pack version drifts from the SDK's (see toolchains/dotnet), and
# goes to /usr/share/dotnet unless the dotnet toolchain has already put a 10.0
# SDK there. It is checked against the SHA-512 Microsoft publishes beside it.
# The x64 tarball is not an apk package, so add the libraries it links
# (libgcc, libstdc++) and loads at runtime (icu-libs for globalization, libssl3
# for TLS) ourselves.
RUN set -e; \
    if [ "$(uname -m)" = "x86_64" ]; then \
        apk add --no-cache libgcc libstdc++ icu-libs libssl3 && \
        curl -L https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/powershell-7.6.6-linux-musl-x64.tar.gz -o /tmp/powershell.tar.gz && \
        mkdir -p /opt/microsoft/powershell/7 && \
        tar zxf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7 && \
        chmod +x /opt/microsoft/powershell/7/pwsh && \
        ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh && \
        rm -rf /tmp/powershell*; \
    else \
        apk add --no-cache icu-data-full icu-libs krb5-libs libgcc libintl libssl3 libstdc++ zlib gcompat && \
        if ! ls /usr/share/dotnet/sdk 2>/dev/null | grep -q '^10\.'; then \
            version=$(curl -fsSL https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0/latest.version | tr -d '\r\n') && \
            file="dotnet-sdk-$version-linux-musl-arm64.tar.gz" && \
            curl -fsSL "https://builds.dotnet.microsoft.com/dotnet/Sdk/$version/$file" -o "/tmp/$file" && \
            curl -fsSL "https://builds.dotnet.microsoft.com/dotnet/Sdk/$version/$file.sha512" -o "/tmp/$file.sha512" && \
            (cd /tmp && sha512sum -c "$file.sha512") && \
            mkdir -p /usr/share/dotnet && \
            tar xzf "/tmp/$file" -C /usr/share/dotnet && \
            rm -f "/tmp/$file" "/tmp/$file.sha512" && \
            ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet; \
        fi && \
        apk add --no-cache --virtual .pwsh-build build-base && \
        DOTNET_ROOT=/usr/share/dotnet dotnet tool install --tool-path /opt/microsoft/powershell PowerShell --version 7.6.6 && \
        echo '#include <stdlib.h>'  >  /tmp/chk_shim.c && \
        echo '#include <limits.h>' >> /tmp/chk_shim.c && \
        echo '#include <stdarg.h>' >> /tmp/chk_shim.c && \
        echo '#include <syslog.h>' >> /tmp/chk_shim.c && \
        echo 'char *__realpath_chk(const char *p, char *r, size_t l) { if (l < PATH_MAX) abort(); return realpath(p, r); }' >> /tmp/chk_shim.c && \
        echo 'void __syslog_chk(int pri, int flag, const char *fmt, ...) { va_list ap; va_start(ap, fmt); vsyslog(pri, fmt, ap); va_end(ap); }' >> /tmp/chk_shim.c && \
        gcc -shared -fPIC -o /usr/lib/libpsl-chk-shim.so /tmp/chk_shim.c && \
        rm -f /tmp/chk_shim.c && \
        apk del .pwsh-build && \
        printf '#!/bin/sh\nDOTNET_ROOT=${DOTNET_ROOT:-/usr/share/dotnet} LD_PRELOAD=/usr/lib/libpsl-chk-shim.so exec /opt/microsoft/powershell/pwsh "$@"\n' > /usr/bin/pwsh && \
        chmod +x /usr/bin/pwsh; \
    fi # last changed 2026-10-23
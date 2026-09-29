# Microsoft only ships musl (Alpine) builds for x64, so on other architectures
# install it as a dotnet tool instead, with gcompat plus a tiny shim for two
# glibc-only symbols its native library needs (verified on aarch64). That path
# needs the .NET SDK, installed here so this fragment stands alone. PowerShell
# 7.6 is built on .NET 10 (its tool package only carries tools/net10.0), so the
# SDK and the pinned tool version must match; on .NET 8 the installer reports a
# misleading "DotnetToolSettings.xml was not found" error.
RUN set -e; \
    if [ "$(uname -m)" = "x86_64" ]; then \
        curl -L https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/powershell-7.6.6-linux-musl-x64.tar.gz -o /tmp/powershell.tar.gz && \
        mkdir -p /opt/microsoft/powershell/7 && \
        tar zxf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7 && \
        chmod +x /opt/microsoft/powershell/7/pwsh && \
        ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh && \
        rm -rf /tmp/powershell*; \
    else \
        apk add --no-cache dotnet10-sdk gcompat && \
        apk add --no-cache --virtual .pwsh-build build-base && \
        dotnet tool install --tool-path /opt/microsoft/powershell PowerShell --version 7.6.6 && \
        echo '#include <stdlib.h>'  >  /tmp/chk_shim.c && \
        echo '#include <limits.h>' >> /tmp/chk_shim.c && \
        echo '#include <stdarg.h>' >> /tmp/chk_shim.c && \
        echo '#include <syslog.h>' >> /tmp/chk_shim.c && \
        echo 'char *__realpath_chk(const char *p, char *r, size_t l) { if (l < PATH_MAX) abort(); return realpath(p, r); }' >> /tmp/chk_shim.c && \
        echo 'void __syslog_chk(int pri, int flag, const char *fmt, ...) { va_list ap; va_start(ap, fmt); vsyslog(pri, fmt, ap); va_end(ap); }' >> /tmp/chk_shim.c && \
        gcc -shared -fPIC -o /usr/lib/libpsl-chk-shim.so /tmp/chk_shim.c && \
        rm -f /tmp/chk_shim.c && \
        apk del .pwsh-build && \
        printf '#!/bin/sh\nLD_PRELOAD=/usr/lib/libpsl-chk-shim.so exec /opt/microsoft/powershell/pwsh "$@"\n' > /usr/bin/pwsh && \
        chmod +x /usr/bin/pwsh; \
    fi # last changed 2026-09-29
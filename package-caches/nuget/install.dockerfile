# NuGet uses a fallbackPackageFolder, so dotnet restore reads the read-only host
# cache mounted at packages-host directly; packages not found there are
# downloaded into ~/.nuget/packages.
RUN mkdir -p /home/agent1/.nuget/packages-host /home/agent1/.nuget/NuGet && \
    printf '%s\n' \
        '<?xml version="1.0" encoding="utf-8"?>' \
        '<configuration>' \
        '  <fallbackPackageFolders>' \
        '    <add key="host-nuget-cache" value="/home/agent1/.nuget/packages-host" />' \
        '  </fallbackPackageFolders>' \
        '  <packageSources>' \
        '    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />' \
        '    <add key="host-nuget-cache" value="/home/agent1/.nuget/packages-host" />' \
        '  </packageSources>' \
        '</configuration>' > /home/agent1/.nuget/NuGet/NuGet.Config && \
    chown -R agent1:wheel /home/agent1/.nuget
RUN printf '%s\n' 'permit nopass agent1 as root cmd nuget' >> /etc/doas.d/doas.conf

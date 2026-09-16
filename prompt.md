The scripts code-it.sh and code-it.ps1 run a container with volume mounts for the working repo directory and for the claude and opencode agent's home or config directory. But the VM also needs access to package caches of packages that can't be obtained from the public internet.

1. Nuget

The VM sandbox prevents the agent from doing nuget restore from local network sources. The User on the host machine can do a restore, and they are then stored to nuget package cache. I'd like the VM to be able to read that, but if the VM can also write to there, that would be a breach of the sandbox. The VM should only be able to write to its given working directory.

- Review https://learn.microsoft.com/en-us/nuget/consume-packages/managing-the-global-packages-and-cache-folders which explains the default locations and overrides for nuget package cache.
- Add a section to the script to identify the user's nuget \packages\ directory if any. 
- If one is found, then in the printout before running the container, and in the line that runs the container add the necessary code to mount it read only.
- A Nuget.config will be needed to work with this. Add lines to the Dockerfile to create a NuGet config, in the default place for Alpine linux, which will be include this source before the default local package cache.
  - Review this attempt at the config, and see if it works.



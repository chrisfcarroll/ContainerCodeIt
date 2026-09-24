It should be possible to add parameter(s) to Code-It.ps1 and code-it.sh which will be passed through to the agent.

In some cases, this could mean that the container runs, the agent runs the prompt, exits, then the container shuts down, which is good.

Consider what changes are needed to the container entrypoint and scripts to make this work, then implement it.

It might be tricky to get a good DevUI for this. There are the opencode parameters at https://opencode.ai/docs/cli/ and the claude code parameters at https://code.claude.com/docs/en/cli-reference . They both talk about flags as well as commands.

One option could be that the code-it scripts know how to pass args through to the agent, and that the claude-it and opencode-it scripts know the detail of each coding agent. Does that seem a good plan? But it would still be good that the code-it script itself knows how to pass a _prompt_ straight through to each agent.

It would be great to get good tab expansion working on people's favourite parameters.



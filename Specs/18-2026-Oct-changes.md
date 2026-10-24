Work through this list and commit after each bullet point.

1. It is a problem that the working directory is always mapped with the name ‘work’. We want directory names to work well for agent's per-directory memory.
Instead of mounting with the fixed path '/work', let's always mount with the path '/work/parent/workdir', using the parent of the workdir provided. Cope with the cases where there is no parentdir, and where workdir is /.
This also means that although the dockerfile has WORKDIR /work, go.sh will have to cd to the /parent/workdir, otherwise we are in the wrong directory

2. A change. Opencode v2 is now GA, so from now on take opencode to mean v2. Change opencode v1 into an agent option with the name opencode-v1

3. A change.

If code-it is run with an unrecognised agent name, then (1) list the current agents instead of telling the user to list them and (2) explain that code-it-add-agent can be used to add new a new agent if the agent has a recognised internet presence

4. Typo

Everywhere that tool-chain is spelt as two words, correct it to one word, toolchain.

5. A change

The build adds /etc/code-it-agents listing paths to the agents. Also add the paths to the zsh path during the build so that a --no-agent user can easily invoke one of them

6. tidy

Let's stop handling ports and don't set any ports by default. (--run-args still enables the use case).

7. Add codex as an agent option

8. Add these toolchains: rust, go, swift

9. Add these toolchains: gcc, g++ and clang

10. Add a subdirectory under news/ and move the opencode summary page into it. Then write a pwsh script in the news/ directory update-opencode-news.ps1 to update the page. The script should update the model list and the pricings in the html with the up-to-date values. The -help for the scripts should include a link to the source of the data. And, add a link to the page itself indicating its source

Finally. Review all these changes and make sure that all documentation (help, readme,comments) are up to date.


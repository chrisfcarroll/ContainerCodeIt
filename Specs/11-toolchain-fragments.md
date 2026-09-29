# 11 — Tool chains and package caches as fragments, not ARG switches

See 00-conventions.md. Supersedes the ARG-switch design of 02 and the
"uv is installed for every image" rule of 03. Updates the template in 06.

## Goal

Tool chains, package caches and agents are all data. Adding a tool chain (or, later, a
version of one) must not grow the buildable Dockerfile, which is capped: Apple's
`container` builder sends it in a gRPC header and fails above ~16 KB
(apple/container#735). The base Dockerfile, built directly with no args, must also be a
usable image rather than a file that only `code-it-build` can finish.

## Definitions

Each definition is one directory, readable from bash and PowerShell:

- `toolchains/<name>/config`
  - `TOOLCHAIN_INSTALL=install.dockerfile` (fragment file name)
  - `TOOLCHAIN_DETECT=<host command>[:<host command>...]` (first found means detected)
  - `TOOLCHAIN_ALIASES=<space-separated aliases>` (optional)
  - `TOOLCHAIN_PACKAGE_CACHE=<cache name>` (optional; implied by this tool chain)
- `toolchains/<name>/install.dockerfile`: a root-run, self-contained layer: its own
  packages, its own `doas` permit appended to `/etc/doas.d/doas.conf`, and a
  `# last changed YYYY-MM-DD` cache-bust line for `--rebuild`.
- `package-caches/<name>/config` (same install key, no detect/aliases needed) and
  `install.dockerfile`: root-run, creating `/home/agent1/...` and `chown`ing it to
  `agent1`, plus its `doas` permits.

Known names come from the directory listing; aliases and host detection come from each
`config`. No script (neither bash nor PowerShell) holds a name or alias list.
`code-it-build --list-toolchains` / `--list-package-caches` print them.

## Assembly

`code-it-build` replaces, in the Dockerfile:

- `# @@CODE_IT_TOOLCHAIN_INSTALLS@@` with the selected `toolchains/*/install.dockerfile`
  fragments, in the requested order (empty when none);
- `# @@CODE_IT_PACKAGE_CACHE_INSTALLS@@` with the selected `package-caches/*` fragments;
- the region `# @@CODE_IT_AGENTS_BEGIN@@` ... `# @@CODE_IT_AGENTS_END@@` with the
  selected agents' fragments plus `/etc/code-it-agents` (written as root, then back to
  `agent1`).

The base file carries the default agent (opencode) inside that region, so a direct
build is a working image; an assembled image contains exactly the selected agents. No
`--build-arg` is emitted for tool chains or caches: the fragments *are* the selection.

Below the two install markers the base file runs `chown -R agent1:wheel /home/agent1`,
normalising anything the root-run fragments left in the agent's home. `code-it-build`
also prepends to the agents region a `RUN mkdir -p` for every selected agent's
`AGENT_STATE_DIRS` and the parent of each `AGENT_STATE_FILES`, run as `agent1`, so the
launcher's bind mounts always have an agent1-owned parent inside the image (Docker
otherwise creates a missing mount-point parent as root, leaving it unwritable).

## Base image

Alpine 3.24 plus zsh, vim, tmux, git, ripgrep, bash, curl, doas, openssh-client,
ca-certificates, less, docs, oh-my-zsh, musl-locales and the UTF-8 console
(`/etc/rc.conf`), and the default agent. Deliberately **not** in the base:

- chromium, ttf-freefont, freetype-dev — GUI/browser only; these agents are CLI.
- krb5/krb5-libs and the other .NET runtime libraries — they belong to the `dotnet`
  fragment, which also carries PowerShell's arm64 dependency.
- uv — it belongs to the `python` tool chain, with `UV_CACHE_DIR` in the agent's home.
- PowerShell — its own tool chain (`powershell`, alias `pwsh`), detected from
  `pwsh --version` / `powershell --version` so first-run offers it when the host has it.

## Done when

- The default build assembles only the selected fragments; unselected ones are absent.
- The stripped base and the assembled Dockerfiles stay under Apple's 16 KB limit.
- `docker build .` with no args yields zsh, vim, tmux, git and opencode.
- Tests capture the assembled build context and assert present/absent fragments instead
  of asserting build args.

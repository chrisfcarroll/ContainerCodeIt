# 04 — Parameterise agents like toolchains

See 00-conventions.md. Depends on 01.

## Goal
Agents become data, not `if claude / else opencode` branches. Adding an agent means adding one definition, not editing five scripts.

## Agent definition (`agents/<name>/`)
One definition per agent, readable from bash and PowerShell (e.g. a simple `key=value` file plus a Dockerfile fragment). It declares:
- install fragment (`agents/<name>.dockerfile`, run as `agent1`, keeps a `# last changed YYYY-MM-DD` cache-bust line)
- binary path in the container
- state paths to mount from `--save-dir` (dirs and single files; files are pre-created so the runtime doesn't make a directory)
- default config file(s) written on first run (today: opencode `config.json` with `"permission": "allow"`; claude `settings.json` with `defaultMode: auto`)
- prompt translation: interactive-with-prompt, headless-with-prompt, headless-without-prompt (today's "Translate the prompt" block in code-it.sh, and its Code-It.ps1 twin)
- host config/state locations (for 07) and a host detect command
- short flag (`-c`, `-o`) if any

## Changes
- `code-it-build --agent NAME[,NAME...]`, default `opencode,claude`.
- `code-it --agent NAME`; keep `-c` / `-o` / `--claude` / `--opencode` as shortcuts.
- `go.sh` resolves the binary from a file written at build time, not a hardcoded `case`.
- Mount only the chosen agent's state, not every agent's.
- `--list-agents` on both scripts.

## Done when
- Behaviour and `--dry-run` output for `-c` and `-o` match today's, apart from mounting only that agent's state.
- claude and opencode are defined purely as definitions; no agent names remain in script logic beyond shortcut flags.
- Tests cover each agent's prompt translation (all three modes), unknown agent error, and mounts.

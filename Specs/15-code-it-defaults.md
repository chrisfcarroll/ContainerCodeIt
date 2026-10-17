# 15 — `code-it-defaults`: saved default agent, model and toolchain

See 00-conventions.md. Amends the heuristic of Specs 09/10.

## Goal

One command that saves your usual choices so plain `code-it` (no arguments) does what
you mean: which agent to run, which model each agent uses, and which toolchain image
to prefer. Without it, the agent defaults to opencode and the toolchain comes from
the remembered/existing-image heuristic; a saved default overrides the heuristic.

## Storage

Defaults live in `<save-dir>/defaults` (default `~/.config/code-it/defaults`), written
by `code-it-defaults` and read by `code-it`. Same conventions as agent configs:
`KEY=value` lines, one per line, quoted values unquoted on read, `#` comments:

```
default-agent=claude
default-toolchain=node,bun        # canonical names, as code-it --toolchain resolves them
model.opencode=anthropic/claude-sonnet-4-5
model.claude=opus
```

`model.<agent>` records what `code-it-defaults` wrote into that agent's own config
under the save dir; the agent picks it up from there, so it applies to every run
without the launcher's involvement. Clearing a model removes the line and the key
from the agent's config.

## The default model mechanism

Agent definitions gain a key, so agents are data, not branches:

- `AGENT_MODEL_FILE=<path>:<json-key>` — a JSON file relative to the agent's save dir
  (including any `AGENT_SAVE_SUBDIR`), and the top-level key to set. Opencode v1:
  `.config/opencode/config.json:model`; opencode-v2: `.config/opencode/opencode.json:model`;
  claude: `.claude/settings.json:model`. An agent without the key has no known model
  mechanism; `code-it-defaults` says so and moves on.

The model catalog is best-effort and always incomplete, and free text is always
accepted. Sources, in order:

1. `<save-dir>/model-catalog.txt` if present (user-editable cache, same format).
2. The bundled `lib/models.txt` (`provider/model` lines, `#` comments).

`code-it-defaults --refresh-models` rebuilds the cache from
`https://models.dev/api.json` (the registry OpenCode itself uses), extracting
`provider/model` ids. Needs `curl` and `jq` (bash) or `Invoke-RestMethod` (PowerShell);
on failure it says so and changes nothing. Claude's list also offers Claude Code's
aliases (`opus`, `sonnet`, `haiku`) and Anthropic models without the provider prefix.

## Parameters

| bash | PowerShell | Meaning |
|---|---|---|
| `--agent, -a NAME` | `-agent NAME` | Set the default agent (must exist in `agents/`) |
| `--model AGENT=MODEL` | `-model AGENT=MODEL` | Set AGENT's model in its own config; `AGENT=` clears it. Repeatable |
| `--toolchain, -t LIST` | `-toolchain LIST` | Set the default toolchain list (aliases resolved) |
| `--show` | `-show` | Print the current defaults and exit |
| `--refresh-models` | `-refreshModels` | Refresh the model catalog cache from models.dev |
| `--save-dir, -s DIR` | `-saveDir DIR` | Default `~/.config/code-it` |
| `--dry-run, -d` | `-dryRun` | Print what would be written; change nothing |
| `--help, -h` | `-help` | Usage |

With no parameters: interactive. Questions, reading answers from stdin, blank keeps
the current value:

1. **Default agent** — known agents, detected marked `*`, current default first shown;
   `none` clears.
2. **Default model, for each agent** (skipped when the agent has no
   `AGENT_MODEL_FILE`) — the catalog grouped by provider and numbered, current model
   marked; pick a number, type any `provider/model` (or, for claude, an alias), or
   `none` to clear.
3. **Default toolchain** — as `code-it-build`'s interactive selection: known
   toolchains, detected marked `*`, multi-select by number or name, detected
   preselected (powershell too on Windows); `none` clears.

With any of `--agent`/`--model`/`--toolchain`, nothing is asked: exactly those values
are set, the rest are left alone.

## `code-it` changes

After parsing its own arguments, before the agent/toolchain resolution:

- `--agent`, `-c`, `-o` not given and `default-agent` is set: run that agent, and say
  so (`Using saved default agent: …`), since the agent's state — its sessions and
  login — comes with it: each agent keeps them in its own directory under the save
  dir.
- `--toolchain` and `--image` not given and `default-toolchain` is set: use it
  (resolved like an explicit `--toolchain`: image name derived, superset fallback,
  package caches implied). This overrides the image-history heuristic of Specs 09/10,
  which still applies when no default is saved.

Explicit command-line options always beat the saved defaults.

`--show` reads each agent's model from its own config (the live value) and names the
file it was set in. Interactive runs say when the default agent changes that the
agent's own state, and login, travel with it — e.g. opencode-v2 keeps its login in
its own state directory, so a first run there can need a fresh login. `defaults_set`
creates the save dir if it does not exist yet.

## Done when

- `code-it-defaults` with no arguments runs the questions and writes `defaults`
  (and the agents' model configs); `--show` prints them; `--dry-run` writes nothing.
- `code-it --dry-run` with a saved default-agent runs that agent; with a saved
  default-toolchain it derives that image name; explicit flags still win; with no
  defaults, behaviour is unchanged.
- Models are written to each agent's config (created if absent) and survive a
  round-trip; `--model agent=` removes the key.
- Tests in `tests/test-code-it-defaults.sh` / `tests/Test-CodeItDefaults.ps1` (wired
  into `run-all-tests.sh`), launcher override tests in both suites; README and
  completions updated.

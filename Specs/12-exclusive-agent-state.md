# 12 — Containers must not share an agent's session database

See 00-conventions.md. Depends on 04.

## Problem
OpenCode keeps its sessions in a SQLite database in WAL mode
(`~/.local/share/opencode/opencode.db`, with `-wal` and `-shm` files). WAL mode
coordinates readers and writers through shared memory, which only works on one
kernel. Apple `container` gives each container its own VM, so two code-it runs that
mount the same save dir can each write the database without seeing the other's locks.
The database is then corrupted, and OpenCode fails with "can't create session"
(`SQLiteError: database disk image is malformed`). With docker, all containers share
one VM, but a host process writing the database at the same time could also corrupt it.

## Goal
Detect when another code-it run is already using an agent's exclusive state. Warn, and
give the new container a copy of its own instead of the shared directory. The copy
still has the agent's credentials, so it needs no new login.

## Agent definition
Two new optional keys in `agents/<name>/config`, so the logic stays agent-neutral:
- `AGENT_EXCLUSIVE_DIRS`: `:`-separated directories, relative to home, from
  `AGENT_STATE_DIRS`, that one container at a time may use.
- `AGENT_EXCLUSIVE_CARRY`: `:`-separated files, relative to home, inside those
  directories, copied into a new copy (credentials).

OpenCode (v1) sets `AGENT_EXCLUSIVE_DIRS='.local/share/opencode'` and
`AGENT_EXCLUSIVE_CARRY='.local/share/opencode/auth.json'`. Agents without the keys
behave as today. opencode-v2 sets
`AGENT_EXCLUSIVE_DIRS='.local/share/opencode:.local/state/opencode'`: besides the
database, its `.local/state/opencode/service.json` records its background service (URL,
pid, password), which in another container's VM is unreachable. It carries nothing:
checked against 2.0.6, v2 keeps credentials in the database (`credential`, `account`
tables) and does not import a v1 `auth.json` into a new one. Reading them out of the
live database would be the very cross-VM access this avoids, so a new v2 copy starts
logged out.

## Slots
- Slot 1 is the usual location, `<agent save dir>/<dir>`. Slot N (N ≥ 2) is
  `<agent save dir>/.code-it-instances/<agent>/N/<dir>`. The agent name keeps agents
  that share a save dir from sharing slots.
- A run takes the lowest-numbered free slot. Its lock is
  `<agent save dir>/.code-it-instances/<agent>/N.lock`, holding the launcher's process id. It is
  created atomically (bash `noclobber`, PowerShell `FileMode.CreateNew`), so two runs
  starting together cannot take the same slot.
- A lock whose process is no longer running is stale. It is removed and the slot
  reused, so a crashed run never blocks a slot for good.
- The launcher removes its lock when the container exits, including on Ctrl-C (bash
  `trap … EXIT`, PowerShell `try`/`finally`).
- Process ids: on Windows the lock holds the Windows pid (Git Bash reads
  `/proc/$$/winpid`) and liveness is checked with `tasklist`. Elsewhere it is the
  plain pid, checked with `kill -0` / `Get-Process`. A reused pid only causes a
  needless copy, never sharing.

## A new copy
- Slot directories are created empty, not copied from slot 1. Copying a database that
  another container is writing could copy it mid-write, the very corruption this
  avoids. Sessions made in a copy stay in that copy, and later runs that get the
  same slot reuse them.
- Each `AGENT_EXCLUSIVE_CARRY` file is copied from slot 1 when the slot lacks it or
  slot 1's is newer, so a login refreshed in the main slot reaches the copies.
- Warning, to stderr, naming the agent, the directory and the copy, e.g.
  `Warning: Another opencode container is using …/.local/share/opencode. Containers
  cannot share it (its session database would be corrupted), so this one uses its own
  copy: …/.code-it-instances/opencode/2/.local/share/opencode`.
- A new copy with no carry file to copy prints a note that it has no saved login, and
  that later runs given the same copy keep the login made in it.
- The mount for that directory points at the copy; every other state path is mounted
  as before.

## Dry run
`--dry-run` (`-dryRun`) detects a clash, warns, and prints the mount from the copy, but
takes no lock and copies nothing.

## Docs
Help in both scripts, the README agent definition table, and a short README note on
running several opencode containers at once.

## Done when
Tests in both suites, using `--dry-run` and the stub runtimes, cover:
- no lock: slot 1 is mounted and there is no warning;
- a lock held by a live process (the test's own): a warning, slot 2 is mounted, and
  `auth.json` is in it after a real (stub) run;
- a stale lock: slot 1, with no warning;
- slots 1 and 2 held: slot 3;
- a real (stub runtime) run holds the lock while the container runs and removes it
  afterwards;
- an agent without `AGENT_EXCLUSIVE_DIRS` (claude) takes no lock.

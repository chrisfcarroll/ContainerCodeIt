# 14 — `code-it-doctor`: find, explain, and hand off problems

See 00-conventions.md. Reuses the code-it-headless plumbing of 05.

## Goal

"I can't copy" from the agent in the container on macOS. Find the cause, then give
users a tool that detects it on their own setup and says how to fix it, and that can
hand any problem to code-it to investigate and fix.

## Cause (clipboard)

A copy from the container travels as OSC 52: agent or tmux mouse selection -> tmux in
the container -> the runtime's terminal stream -> any tmux on the host -> the terminal.
Inside the image this already works: `set-clipboard on`, the runtime sets `TERM=xterm`
so tmux gives the client its `clipboard` feature, and Claude Code (`tmux load-buffer -w`
plus raw OSC 52) and opencode (raw plus DCS-wrapped OSC 52) both emit what tmux passes
on. `allow-passthrough` is not needed and stays off. The failures are at the host end:

- macOS Terminal.app does not implement OSC 52, and with tmux's mouse mode a drag makes
  a tmux selection, not a Terminal.app one, so ⌘C copies nothing. Workaround: toggle mouse
  reporting off (⌘R) to select natively, or `set mouse off` in tmux; or another terminal.
- iTerm2 ignores OSC 52 until *Applications in terminal may access clipboard* is on.
- tmux on the host defaults to `set-clipboard external`, dropping OSC 52 from the
  container; it needs `on`.
- Less common: Ghostty `clipboard-write = deny`, kitty `clipboard_control` without
  `write-clipboard`, mintty without `AllowSetSelection=yes`, GNU screen.

## Behaviour

- `code-it-doctor.sh` / `Code-It-Doctor.ps1`, same logical parameters (README table).
- Sections: Host (git identity; warns if run inside a container), Container runtime
  (found; service or daemon up), Image (exists; `~/.tmux.conf` has `set-clipboard on`),
  Save dir (exists; several code-it containers running; opencode db `quick_check`),
  Clipboard (terminal, from host tmux's `client_termtype` then terminal variables; its
  OSC 52 setting; host tmux `set-clipboard` and `clipboard` feature; screen; ssh).
- Each finding is `ok`, `PROBLEM` (with a `fix:` line), `warning` or `unknown`. Exit 0
  with no PROBLEM, else 1.
- Clipboard round trip, when there is a terminal and a clipboard tool, after asking
  (or `--yes`), never over ssh: OSC 52 from the shell, then from `tmux` run in the image
  (`run --rm -it --entrypoint /bin/sh IMAGE -c 'tmux new-session "printf OSC52"'`), each
  read back from the host clipboard. Clipboard text is restored. `CODE_IT_DOCTOR_TTY`
  redirects the escape sequences (for tests).
- `--fix`, or a PROBLEM in words: the report and problem go into a prompt for code-it
  headless on the repo, on branch `doctor/<timestamp>`, via the 05 plumbing (refuses a
  dirty repo or existing branch, never pushes, propagates code-it's exit code). The
  prompt asks the agent to reproduce in its container, fix in the repo with tests and a
  commit (adding a doctor check if one would have caught it), or else print host steps.
  `--fix` with no problem found and none described has nothing to do and exits 0.

## Done when

- Tests (stubbed runtime, tmux, clipboard tools; a file as the terminal) cover each
  terminal verdict, host tmux, runtime/image/save-dir findings, the round trip passing,
  failing at the terminal, failing at the container, clipboard restore, non-interactive
  skip, and `--fix` prompt, branch, dirty refusal and exit code.

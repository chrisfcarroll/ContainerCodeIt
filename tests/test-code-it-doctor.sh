#!/usr/bin/env bash
#
# Tests for code-it-doctor.sh.
#
# No container runtime or terminal is required: stub `uname`, `container`, `tmux`,
# `defaults`, `pbpaste` and `pbcopy` go on the PATH, and CODE_IT_DOCTOR_TTY points the
# doctor's escape sequences at a file. A stub "terminal that accepts OSC 52" is
# pbpaste decoding the last OSC 52 written to that file. Run with:
#   ./tests/test-code-it-doctor.sh

set -uo pipefail

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script_dir=$(dirname "$tests_dir")
doctor="$script_dir/code-it-doctor.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

assert() {
    local desc="$1"; local ok="$2"
    if [[ "$ok" == "0" ]]; then
        echo "  ok: $desc"
        pass=$((pass+1))
    else
        echo "  FAIL: $desc"
        fail=$((fail+1))
    fi
}

assert_contains() {
    local desc="$1"; local haystack="$2"; local needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        assert "$desc" 0
    else
        assert "$desc (missing: $needle)" 1
    fi
}

assert_not_contains() {
    local desc="$1"; local haystack="$2"; local needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        assert "$desc" 0
    else
        assert "$desc (unexpected: $needle)" 1
    fi
}

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
bin="$tmp/bin"
mkdir -p "$bin"

cat > "$bin/uname" <<'EOF'
#!/bin/sh
case "$1" in -m) echo arm64 ;; *) echo "${STUB_UNAME:-Darwin}" ;; esac
EOF

# Apple container CLI. run with cat prints the image's tmux.conf; run with -c is the
# round trip, so it prints the OSC 52 tmux in the container would pass on.
cat > "$bin/container" <<'EOF'
#!/bin/sh
case "$1" in
    --version) echo "container CLI version 0.0.0-stub" ;;
    system)    [ -z "${STUB_SYSTEM_DOWN:-}" ] ;;
    image)
        case "$2" in
            ls)      [ -z "${STUB_NO_IMAGE:-}" ] && echo "code-it-alpine-dotnet-node  latest" ; exit 0 ;;
            inspect) [ -z "${STUB_NO_IMAGE:-}" ] ;;
        esac ;;
    ls)        [ -n "${STUB_RUNNING:-}" ] && printf '%s\n' "$STUB_RUNNING" ; exit 0 ;;
    run)
        for a in "$@"; do last="$a"; done
        case " $* " in
            *" cat "*) printf '%s\n' "${STUB_TMUX_CONF-set -g mouse on
set -g set-clipboard on}" ;;
            *" -c "*)
                echo "STUB-CONTAINER-RUN $*" >> "$STUB_LOG"
                [ -n "${STUB_CONTAINER_NO_OSC:-}" ] && exit 0
                b64=$(printf '%s' "$last" | grep -o '52;c;[A-Za-z0-9+/=]*' | sed 's/.*;//')
                printf '\033]52;c;%s\007' "$b64" ;;
        esac ;;
esac
EOF

cat > "$bin/defaults" <<'EOF'
#!/bin/sh
echo "${STUB_ITERM_ALLOW:-0}"
EOF

# The host's tmux, when TMUX is set
cat > "$bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
    *set-clipboard*)        echo "${STUB_HOST_CLIPBOARD:-external}" ;;
    *client_termtype*)      echo "${STUB_TERMTYPE:-}" ;;
    *client_termfeatures*)  echo "${STUB_FEATURES-clipboard,focus,title}" ;;
    *client_termname*)      echo "xterm-256color" ;;
esac
EOF

# The clipboard. With STUB_TERMINAL_OSC52 the "terminal" accepts OSC 52: pbpaste reads
# the last one written to the tty file. pbcopy sets the clipboard and clears the tty.
cat > "$bin/pbpaste" <<'EOF'
#!/bin/sh
if [ -n "${STUB_TERMINAL_OSC52:-}" ] && [ -f "$CODE_IT_DOCTOR_TTY" ]; then
    b64=$(grep -ao ']52;c;[A-Za-z0-9+/=]*' "$CODE_IT_DOCTOR_TTY" | tail -n 1 | sed 's/.*;//')
    if [ -n "$b64" ]; then
        printf '%s' "$b64" | base64 -d 2>/dev/null || printf '%s' "$b64" | base64 -D
        exit 0
    fi
fi
cat "$STUB_CLIPBOARD" 2>/dev/null
EOF
cat > "$bin/pbcopy" <<'EOF'
#!/bin/sh
cat > "$STUB_CLIPBOARD"
: > "$CODE_IT_DOCTOR_TTY"
EOF
chmod +x "$bin"/*

home="$tmp/home"
mkdir -p "$home/.config/code-it"
git config --file "$home/.gitconfig" user.name "Test User"
git config --file "$home/.gitconfig" user.email "test@example.com"

tty="$tmp/tty"
clipboard="$tmp/clipboard"
log="$tmp/log"

# run_doctor [VAR=VALUE...] -- [ARGS...]: run the doctor with a clean environment, so
# the terminal and tmux this suite runs in cannot leak into the results.
run_doctor() {
    local -a vars=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do vars+=("$1"); shift; done
    shift
    : > "$tty"; : > "$log"
    printf 'precious' > "$clipboard"
    env -i HOME="$home" PATH="$bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=xterm-256color \
        CODE_IT_DOCTOR_TTY="$tty" STUB_CLIPBOARD="$clipboard" STUB_LOG="$log" \
        ${vars[@]+"${vars[@]}"} bash "$doctor" "$@" < /dev/null 2>&1
}

# ---------------------------------------------------------------------------
echo "1. Syntax and help"
bash -n "$doctor"; assert "bash -n code-it-doctor.sh" "$?"
bash -n "$script_dir/completions/code-it-doctor.bash"; assert "bash -n completions/code-it-doctor.bash" "$?"
if command -v zsh &>/dev/null; then
    zsh -n "$script_dir/completions/_code-it-doctor"; assert "zsh -n completions/_code-it-doctor" "$?"
fi
out=$("$doctor" --help); assert "--help exit code" "$?"
assert_contains "--help shows usage" "$out" "Usage:"
assert_contains "--help documents --fix" "$out" "--fix"
assert_contains "--help documents --no-live-test" "$out" "--no-live-test"

# ---------------------------------------------------------------------------
echo "2. Terminal.app cannot take the clipboard from the container"
out=$(run_doctor TERM_PROGRAM=Apple_Terminal -- --no-live-test); rc=$?
[[ "$rc" == 1 ]]; assert "a problem exits 1" "$?"
assert_contains "runtime is the Apple container CLI" "$out" "container: container CLI version"
assert_contains "the service is running" "$out" "ok:      the container system service is running"
assert_contains "the default image is found" "$out" "ok:      image code-it-alpine-dotnet-node exists"
assert_contains "the image's tmux passes OSC 52 on" "$out" "(set-clipboard on)"
assert_contains "Terminal.app is the problem" "$out" "PROBLEM: macOS Terminal.app ignores OSC 52"
assert_contains "says to select natively" "$out" "makes Terminal.app's own selection"
assert_contains "says how to toggle mouse reporting" "$out" "Allow Mouse Reporting"
assert_contains "names terminals that work" "$out" "iTerm2, Ghostty, WezTerm or kitty"
assert_contains "live test can be skipped" "$out" "skipped: the clipboard round trip (--no-live-test)"
assert_contains "offers --fix" "$out" "--fix [PROBLEM]"

# ---------------------------------------------------------------------------
echo "3. iTerm2's clipboard permission"
out=$(run_doctor TERM_PROGRAM=iTerm.app STUB_ITERM_ALLOW=0 -- --no-live-test)
assert_contains "iTerm2 without permission is a problem" "$out" "PROBLEM: iTerm2 is not letting applications set the clipboard"
assert_contains "gives the defaults command" "$out" "defaults write com.googlecode.iterm2 AllowClipboardAccess -bool true"
assert_contains "gives the settings path" "$out" "Applications in terminal"
out=$(run_doctor TERM_PROGRAM=iTerm.app STUB_ITERM_ALLOW=1 -- --no-live-test); rc=$?
assert_contains "iTerm2 with permission is ok" "$out" "ok:      iTerm2 lets applications set the clipboard"
[[ "$rc" == 0 ]]; assert "no problems exits 0" "$?"
assert_contains "no problems is summarised" "$out" "No problems found."
out=$(run_doctor LC_TERMINAL=iTerm2 STUB_ITERM_ALLOW=1 -- --no-live-test)
assert_contains "LC_TERMINAL=iTerm2 is iTerm2" "$out" "iTerm2 lets applications"

# ---------------------------------------------------------------------------
echo "4. Ghostty, kitty, and terminals that just work"
mkdir -p "$home/.config/ghostty"
echo "clipboard-write = deny" > "$home/.config/ghostty/config"
out=$(run_doctor TERM_PROGRAM=ghostty -- --no-live-test)
assert_contains "Ghostty denying writes is a problem" "$out" "PROBLEM: Ghostty's clipboard-write = deny"
rm "$home/.config/ghostty/config"
out=$(run_doctor TERM_PROGRAM=ghostty -- --no-live-test)
assert_contains "Ghostty by default is ok" "$out" "ok:      Ghostty accepts OSC 52"
mkdir -p "$home/.config/kitty"
echo "clipboard_control read-clipboard" > "$home/.config/kitty/kitty.conf"
out=$(run_doctor KITTY_WINDOW_ID=1 -- --no-live-test)
assert_contains "kitty without write-clipboard is a problem" "$out" "lacks write-clipboard"
out=$(run_doctor TERM_PROGRAM=WezTerm -- --no-live-test)
assert_contains "WezTerm is ok" "$out" "ok:      wezterm accepts OSC 52"
out=$(run_doctor TERM_PROGRAM=SomethingElse -- --no-live-test)
assert_contains "an unknown terminal is reported" "$out" "unknown: terminal 'unknown' (TERM_PROGRAM=SomethingElse"

# ---------------------------------------------------------------------------
echo "5. tmux on the host"
out=$(run_doctor TMUX=/tmp/tmux-1/default,1,0 TERM_PROGRAM=tmux STUB_TERMTYPE="iTerm2 3.5.4" STUB_ITERM_ALLOW=1 -- --no-live-test)
assert_contains "the terminal behind host tmux is found" "$out" "iTerm2 lets applications"
assert_contains "host tmux with set-clipboard external is a problem" "$out" "PROBLEM: tmux on the host has set-clipboard external"
assert_contains "says to set set-clipboard on" "$out" "set -s set-clipboard on"
out=$(run_doctor TMUX=/tmp/tmux-1/default,1,0 TERM_PROGRAM=WezTerm STUB_HOST_CLIPBOARD=on -- --no-live-test)
assert_contains "host tmux with set-clipboard on is ok" "$out" "ok:      tmux on the host passes OSC 52 on"
out=$(run_doctor TMUX=/tmp/tmux-1/default,1,0 TERM_PROGRAM=WezTerm STUB_HOST_CLIPBOARD=on STUB_FEATURES=focus,title -- --no-live-test)
assert_contains "host tmux without the clipboard feature is a problem" "$out" "terminal-features ',xterm-256color:clipboard'"
out=$(run_doctor TERM_PROGRAM=WezTerm STY=1.pts-0.host -- --no-live-test)
assert_contains "GNU screen is warned about" "$out" "warning: GNU screen"

# ---------------------------------------------------------------------------
echo "6. Runtime, image and save dir"
out=$(run_doctor TERM_PROGRAM=WezTerm STUB_TMUX_CONF="set -g mouse on" -- --no-live-test)
assert_contains "an image without set-clipboard on is a problem" "$out" "PROBLEM: tmux in code-it-alpine-dotnet-node does not pass"
assert_contains "says to rebuild, with the image's toolchains" "$out" "code-it-build.sh --toolchain dotnet,node --image code-it-alpine-dotnet-node --rebuild"
out=$(run_doctor TERM_PROGRAM=WezTerm STUB_SYSTEM_DOWN=1 -- --no-live-test)
assert_contains "a stopped container service is a problem" "$out" "PROBLEM: the container system service is not running"
assert_contains "says to start it" "$out" "container system start"
assert_contains "the image check is skipped" "$out" "skipped: no running container runtime"
out=$(run_doctor TERM_PROGRAM=WezTerm STUB_NO_IMAGE=1 -- --no-live-test)
assert_contains "no code-it image is a problem" "$out" "PROBLEM: there is no code-it image"
out=$(run_doctor TERM_PROGRAM=WezTerm -- --no-live-test --image code-it-alpine-missing)
assert_contains "a named image is checked" "$out" "code-it-alpine-missing"
out=$(run_doctor TERM_PROGRAM=WezTerm -- --no-live-test --save-dir "$tmp/nosave")
assert_contains "a missing save dir is warned about" "$out" "does not exist yet"
out=$(run_doctor TERM_PROGRAM=WezTerm GIT_AUTHOR_NAME= HOME="$tmp/nohome" -- --no-live-test --save-dir "$home/.config/code-it")
assert_contains "a missing git identity is a problem" "$out" "PROBLEM: git user.name or user.email is not set"

# ---------------------------------------------------------------------------
echo "7. The clipboard round trip"
out=$(run_doctor TERM_PROGRAM=WezTerm STUB_TERMINAL_OSC52=1 -- --yes); rc=$?
assert_contains "OSC 52 from the shell arrives" "$out" "ok:      round trip: OSC 52 from this shell reached the clipboard"
assert_contains "OSC 52 from tmux in the container arrives" "$out" "ok:      round trip: OSC 52 from tmux in the container reached the clipboard"
assert_contains "runs tmux in the image" "$(cat "$log")" "--entrypoint /bin/sh code-it-alpine-dotnet-node:latest -c tmux -u new-session"
[[ "$rc" == 0 ]]; assert "a working clipboard exits 0" "$?"
[[ "$(cat "$clipboard")" == precious ]]; assert "the clipboard is restored" "$?"

out=$(run_doctor TERM_PROGRAM=SomethingElse -- --yes)
assert_contains "a terminal ignoring OSC 52 is a problem" "$out" "PROBLEM: round trip: OSC 52 from this shell did not reach the clipboard"
[[ ! -s "$log" ]]; assert "the container leg is not tried when the terminal fails" "$?"
[[ "$(cat "$clipboard")" == precious ]]; assert "the clipboard is restored after a failure" "$?"

out=$(run_doctor TERM_PROGRAM=WezTerm STUB_TERMINAL_OSC52=1 STUB_CONTAINER_NO_OSC=1 -- --yes)
assert_contains "nothing from the container is a problem" "$out" "PROBLEM: round trip: your terminal accepts OSC 52, but none arrived from tmux"

out=$(run_doctor TERM_PROGRAM=WezTerm STUB_TERMINAL_OSC52=1 --)
assert_contains "not interactive without --yes skips the round trip" "$out" "not interactive; --yes runs it"
out=$(run_doctor TERM_PROGRAM=WezTerm STUB_TERMINAL_OSC52=1 SSH_CONNECTION="1 2 3 4" -- --yes)
assert_contains "over ssh skips the round trip" "$out" "not yours over ssh"

# ---------------------------------------------------------------------------
echo "8. --fix hands the report to code-it"
stub_ci="$tmp/stub-code-it.sh"
cat > "$stub_ci" <<'EOF'
#!/bin/sh
echo "STUB-CODE-IT $*"
exit "${STUB_CODE_IT_EXIT:-0}"
EOF
chmod +x "$stub_ci"
mkrepo() {
    mkdir -p "$1"
    git -C "$1" init -q
    git -C "$1" config user.email a@b.c
    git -C "$1" config user.name T
    echo x > "$1/x"
    git -C "$1" add -A
    git -C "$1" commit -qm init
}
repo_a="$tmp/repo-a"; mkrepo "$repo_a"

out=$(run_doctor TERM_PROGRAM=Apple_Terminal -- --no-live-test --repo "$repo_a" --code-it "$stub_ci" --dry-run "copy does not work"); rc=$?
[[ "$rc" == 0 ]]; assert "--fix --dry-run exit code" "$?"
assert_contains "the prompt carries the problem" "$out" "The user's problem: copy does not work"
assert_contains "the prompt carries the report" "$out" "PROBLEM: macOS Terminal.app ignores OSC 52"
assert_contains "the prompt asks for tests" "$out" "./tests/run-all-tests.sh"
assert_contains "the prompt separates host fixes" "$out" "If the fix is on the host"
assert_contains "dry-run prints code-it --headless" "$out" "--headless"
[[ -z "$(git -C "$repo_a" branch --list 'doctor/*')" ]]; assert "--dry-run creates no branch" "$?"

out=$(run_doctor TERM_PROGRAM=WezTerm -- --no-live-test --repo "$repo_a" --code-it "$stub_ci" --dry-run copy is broken)
assert_contains "bare words are the problem, and imply --fix" "$out" "The user's problem: copy is broken"

out=$(run_doctor TERM_PROGRAM=WezTerm -- --no-live-test --repo "$repo_a" --code-it "$stub_ci" --fix); rc=$?
assert_contains "--fix with nothing wrong has nothing to fix" "$out" "Nothing to fix"
[[ "$rc" == 0 ]]; assert "nothing to fix exits 0" "$?"

out=$(run_doctor TERM_PROGRAM=WezTerm -- --no-live-test --repo "$repo_a" --code-it "$stub_ci" --branch doctor/test "it broke"); rc=$?
[[ "$rc" == 0 ]]; assert "--fix run exit code" "$?"
assert_contains "--fix runs code-it headless" "$out" "STUB-CODE-IT --headless --work-dir $repo_a"
[[ "$(git -C "$repo_a" rev-parse --abbrev-ref HEAD)" == doctor/test ]]; assert "--fix works on its own branch" "$?"

repo_b="$tmp/repo-b"; mkrepo "$repo_b"
run_doctor TERM_PROGRAM=WezTerm STUB_CODE_IT_EXIT=3 -- --no-live-test --repo "$repo_b" --code-it "$stub_ci" "it broke" >/dev/null
[[ "$?" == 3 ]]; assert "--fix propagates code-it's exit code" "$?"

echo y > "$repo_b/dirty"
run_doctor TERM_PROGRAM=WezTerm -- --no-live-test --repo "$repo_b" --code-it "$stub_ci" --branch doctor/other "it broke" >/dev/null
[[ "$?" != 0 ]]; assert "--fix refuses a dirty repo" "$?"

out=$(run_doctor -- --bogus); rc=$?
[[ "$rc" != 0 ]]; assert "an unknown option fails" "$?"

# ---------------------------------------------------------------------------
echo
echo "Results: $pass passed, $fail failed"
[[ "$fail" == "0" ]] || exit 1

#!/usr/bin/env bash
#
# Tests for XS/code-it.sh.
#
# No container runtime is required: the tests put stub `docker`, `container` and
# `uname` executables on the PATH, and assert on the arguments the stubs receive.
# HOME is a temporary directory, so the default save dir and first run are isolated.
# Run with:
#   ./tests/xs/test-code-it-xs.sh

set -uo pipefail

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
code_it="$(dirname "$(dirname "$tests_dir")")/XS/code-it.sh"

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
# Stubs. Each runtime prints the arguments it was run with, one [arg] each.
# `image inspect` succeeds unless STUB_NO_IMAGE is set.
# ---------------------------------------------------------------------------
for rt in docker container; do
    mkdir -p "$tmp/stub-$rt"
    cat > "$tmp/stub-$rt/$rt" <<EOF
#!/bin/sh
[ "\$1" = image ] && { [ -n "\${STUB_NO_IMAGE:-}" ] && exit 1; exit 0; }
printf 'STUB-$rt'; printf ' [%s]' "\$@"; echo
EOF
    chmod +x "$tmp/stub-$rt/$rt"
done
mkdir -p "$tmp/stub-darwin"
printf '#!/bin/sh\necho Darwin\n' > "$tmp/stub-darwin/uname"
chmod +x "$tmp/stub-darwin/uname"

home="$tmp/home"
work="$tmp/projects/my-proj"
mkdir -p "$home" "$work"
save="$home/.config/code-it-xs"

# run_xs ARGS...: run code-it.sh with docker stubbed, in the work dir, answering
# "n" to first run, with a known git identity and locale.
run_xs() {
    (cd "$work" && echo n | HOME="$home" PATH="$tmp/stub-docker:$PATH" \
        GIT_AUTHOR_NAME="Ada L" GIT_AUTHOR_EMAIL=ada@example.com LC_ALL="" LANG=en_GB.UTF-8 \
        bash "$code_it" "$@" 2>&1)
}

# ---------------------------------------------------------------------------
echo "Help"
out=$(run_xs --help)
assert_contains "--help prints usage" "$out" "Usage: ./code-it.sh"
assert_contains "--help documents -D:" "$out" "-D:ARG, --D:ARG"
out=$(run_xs --bogus); rc=$?
assert "an unknown option fails" "$([[ $rc -ne 0 ]]; echo $?)"
assert_contains "an unknown option is named" "$out" "Unknown option: --bogus"

# ---------------------------------------------------------------------------
echo "First run"
mkdir -p "$home/.claude" "$home/.config/opencode"
echo secret > "$home/.claude/.credentials.json"
echo '{"a":1}' > "$home/.claude.json"
echo '{}' > "$home/.config/opencode/opencode.json"
out=$(cd "$work" && echo y | HOME="$home" PATH="$tmp/stub-docker:$PATH" bash "$code_it" 2>&1)
assert_contains "y copies ~/.claude" "$out" "copied ~/.claude to $save/.claude"
assert "the copied ~/.claude keeps its files" "$([[ -f "$save/.claude/.credentials.json" ]]; echo $?)"
assert "~/.claude.json is copied as a file" "$([[ "$(cat "$save/.claude.json")" == '{"a":1}' ]]; echo $?)"
assert "~/.config/opencode is copied" "$([[ -f "$save/.config/opencode/opencode.json" ]]; echo $?)"
assert_not_contains "a missing host path is skipped" "$out" "copied ~/.local/share/opencode"
assert_contains "the agent still runs after first run" "$out" "STUB-docker [run]"
out=$(cd "$work" && echo y | HOME="$home" PATH="$tmp/stub-docker:$PATH" bash "$code_it" 2>&1)
assert_not_contains "an existing save dir is not first run" "$out" "copied"
rm -rf "$save"
out=$(run_xs -c)
assert_not_contains "n copies nothing" "$out" "copied"
assert "n still creates the save dir" "$([[ -d "$save" ]]; echo $?)"
assert "n leaves the save dir without host credentials" "$([[ ! -e "$save/.claude/.credentials.json" ]]; echo $?)"
assert "a missing .claude.json is created as a file" "$([[ -f "$save/.claude.json" && "$(cat "$save/.claude.json")" == '{}' ]]; echo $?)"
rm -rf "$save"
out=$(run_xs -d)
assert "--dry-run makes no save dir" "$([[ ! -e "$save" ]]; echo $?)"
assert_not_contains "--dry-run runs nothing" "$out" "STUB-docker"
assert_contains "--dry-run prints the run command" "$out" "docker run -it --rm"

# ---------------------------------------------------------------------------
echo "Agents and their state"
out=$(run_xs)
assert_contains "opencode is the default agent" "$out" "[CODE_AGENT=opencode]"
assert_contains "opencode's config is mounted" "$out" "[$save/.config/opencode:/home/agent1/.config/opencode]"
assert_contains "opencode's data is mounted" "$out" "[$save/.local/share/opencode:/home/agent1/.local/share/opencode]"
assert_contains "opencode's state is mounted" "$out" "[$save/.local/state/opencode:/home/agent1/.local/state/opencode]"
assert_not_contains "opencode does not see claude's state" "$out" ".claude"
out=$(run_xs -c)
assert_contains "-c runs claude" "$out" "[CODE_AGENT=claude]"
assert_contains "claude's dir is mounted" "$out" "[$save/.claude:/home/agent1/.claude]"
assert_contains "claude's json is mounted" "$out" "[$save/.claude.json:/home/agent1/.claude.json]"
assert_not_contains "claude does not see opencode's state" "$out" "opencode:"
out=$(run_xs --agent codex)
assert_contains "--agent codex runs codex" "$out" "[CODE_AGENT=codex]"
assert_contains "codex's state is mounted" "$out" "[$save/.codex:/home/agent1/.codex]"
out=$(run_xs --zsh)
assert_contains "--zsh runs zsh" "$out" "[CODE_AGENT=zsh]"
assert_not_contains "--zsh mounts no agent state" "$out" "/home/agent1/"
out=$(run_xs -a cursor); rc=$?
assert "an unknown agent fails" "$([[ $rc -ne 0 ]]; echo $?)"
assert_contains "an unknown agent says where to add it" "$out" "Unknown agent 'cursor'"

# ---------------------------------------------------------------------------
echo "Pass-through"
out=$(run_xs -c -D:-p --D:8080:3000 -- --model "two words")
assert_contains "-D: and --D: go to the runtime, before the image" "$out" "[-p] [8080:3000] [code-it-xs]"
assert_contains "-- passes the rest to the agent, after the image" "$out" "[code-it-xs] [--model] [two words]"
out=$(run_xs -- -c)
assert_contains "options after -- are the agent's" "$out" "[CODE_AGENT=opencode]"
assert_contains "options after -- are passed on" "$out" "[code-it-xs] [-c]"

# ---------------------------------------------------------------------------
echo "Work dir"
out=$(run_xs)
assert_contains "the work dir mounts at /work/<parent>/<name>" "$out" "[$work:/work/projects/my-proj]"
assert_contains "go.sh is told the mount path" "$out" "[CODE_IT_WORK_DIR=/work/projects/my-proj]"
mkdir -p "$tmp/a:b/c"
out=$(run_xs -w "$tmp/a:b/c")
assert_contains "a ':' in the mount path becomes '-'" "$out" "[CODE_IT_WORK_DIR=/work/a-b/c]"
out=$(run_xs -w /)
assert_contains "/ mounts at /work" "$out" "[/:/work]"
out=$(run_xs -w /tmp)
assert_contains "a dir under / mounts at /work/<name>" "$out" "[/tmp:/work/tmp]"
out=$(run_xs -w "$tmp/nope"); rc=$?
assert "a missing work dir fails" "$([[ $rc -ne 0 ]]; echo $?)"
out=$(run_xs -s rel-save -d)
assert_contains "a relative save dir is made absolute" "$out" "$work/rel-save/.config/opencode:"

# ---------------------------------------------------------------------------
echo "Locale"
out=$(run_xs)
assert_contains "the host's LANG is used" "$out" "[LANG=en_GB.UTF-8]"
out=$(run_xs -l de-AT)
assert_contains "--locale de-AT becomes de_AT.UTF-8" "$out" "[LANG=de_AT.UTF-8]"
out=$(run_xs -l fr_FR.ISO-8859-1)
assert_contains "--locale always gives UTF-8" "$out" "[LANG=fr_FR.UTF-8]"
out=$(run_xs -l C.UTF-8)
assert_contains "--locale C.UTF-8 is kept" "$out" "[LANG=C.UTF-8]"
out=$(run_xs -l nonsense); rc=$?
assert "an unreadable --locale fails" "$([[ $rc -ne 0 ]]; echo $?)"
out=$(cd "$work" && echo n | HOME="$home" PATH="$tmp/stub-docker:$PATH" LC_ALL=pt_BR.UTF-8 LANG=en_GB.UTF-8 bash "$code_it" 2>&1)
assert_contains "LC_ALL wins over LANG" "$out" "[LANG=pt_BR.UTF-8]"
out=$(cd "$work" && echo n | HOME="$home" PATH="$tmp/stub-docker:$PATH" LC_ALL="" LANG=C bash "$code_it" 2>&1)
assert_contains "a host locale of C gives C.UTF-8" "$out" "[LANG=C.UTF-8]"

# ---------------------------------------------------------------------------
echo "Runtime and image"
out=$(run_xs)
assert_contains "docker is used when present" "$out" "STUB-docker [run] [-it] [--rm]"
assert_not_contains "an existing image is not rebuilt" "$out" "[build]"
out=$(STUB_NO_IMAGE=1 run_xs)
assert_contains "a missing image is built from the XS dir" "$out" "[build] [-t] [code-it-xs] [$(dirname "$code_it")]"
out=$(run_xs -b -i my-image)
assert_contains "--build rebuilds, with --image's name" "$out" "[build] [-t] [my-image]"
assert_contains "--image is run" "$out" "[my-image]"
out=$(cd "$work" && echo n | HOME="$home" PATH="$tmp/stub-darwin:$tmp/stub-container:$tmp/stub-docker:$PATH" bash "$code_it" 2>&1)
assert_contains "macOS prefers Apple's container" "$out" "STUB-container [run]"
assert_contains "Apple's container gets 3g of memory" "$out" "[--memory] [3g]"
out=$(cd "$work" && echo n | HOME="$home" PATH="$tmp/stub-darwin:$tmp/stub-container:$tmp/stub-docker:$PATH" bash "$code_it" -r docker 2>&1)
assert_contains "--runtime docker overrides" "$out" "STUB-docker [run]"
assert_not_contains "docker gets no --memory" "$out" "--memory"
out=$(run_xs -r podman); rc=$?
assert "an unknown runtime fails" "$([[ $rc -ne 0 ]]; echo $?)"

# ---------------------------------------------------------------------------
echo "Git identity"
out=$(run_xs)
assert_contains "the author is the agent on the user's behalf" "$out" "[GIT_AUTHOR_NAME=Agent1 for Ada L]"
assert_contains "the committer is too" "$out" "[GIT_COMMITTER_NAME=Agent1 for Ada L]"
assert_contains "the user's email is used" "$out" "[GIT_AUTHOR_EMAIL=ada@example.com] [-e] [GIT_COMMITTER_NAME=Agent1 for Ada L] [-e] [GIT_COMMITTER_EMAIL=ada@example.com]"

echo
echo "Passed: $pass, Failed: $fail"
[[ $fail -eq 0 ]]

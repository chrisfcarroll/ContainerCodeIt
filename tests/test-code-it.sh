#!/usr/bin/env bash
#
# Tests for code-it.sh and its alias scripts.
#
# No container runtime is required: the tests place stub `docker`, `container` and
# `uname` executables on the PATH and run the scripts with --dry-run, asserting on
# the printed run command. Run with:
#   ./tests/test-code-it.sh

set -uo pipefail

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script_dir=$(dirname "$tests_dir")
code_it="$script_dir/code-it.sh"
# shellcheck source=../lib/code-it-common.sh
. "$script_dir/lib/code-it-common.sh"

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

# ---------------------------------------------------------------------------
# Stub runtimes
# ---------------------------------------------------------------------------
stub_docker="$tmp/stub-docker"
mkdir -p "$stub_docker"
cat > "$stub_docker/docker" <<'EOF'
#!/bin/sh
case "$1" in
    images) [ -n "${STUB_IMAGES_FAIL:-}" ] && exit 1; echo "code-it-alpine-dotnet-node:latest" ;;
    image)  case "$2" in inspect) case "$*" in *code-it.agent-binaries*) echo "${STUB_IMAGE_AGENT_BINARIES-}" ;; *code-it.agents*) echo "${STUB_IMAGE_AGENTS-}" ;; *) echo "${STUB_IMAGE_TOOLCHAINS-dotnet,node}" ;; esac ;; *) echo "stub docker: $*" ;; esac ;;
    build)  [ -n "${STUB_BUILD_FAIL:-}" ] && exit 3; echo "STUB-DOCKER-BUILD $*" ;;
    run)    echo "STUB-DOCKER-RUN $*" ;;
    *)      echo "stub docker: $*" ;;
esac
EOF
chmod +x "$stub_docker/docker"

stub_container="$tmp/stub-container"
mkdir -p "$stub_container"
cat > "$stub_container/container" <<'EOF'
#!/bin/sh
case "$1" in
    image)  case "$2" in
                ls)      echo "code-it-alpine-dotnet-node  latest" ;;
                inspect) case "$*" in *code-it.agent-binaries*) echo "${STUB_IMAGE_AGENT_BINARIES-}" ;; *code-it.agents*) echo "${STUB_IMAGE_AGENTS-}" ;; *) echo "${STUB_IMAGE_TOOLCHAINS-dotnet,node}" ;; esac ;;
                *)       echo "stub container: $*" ;;
            esac ;;
    build)  echo "STUB-CONTAINER-BUILD $*" ;;
    run)    echo "STUB-CONTAINER-RUN $*"; printf '[%s]' "$@"; echo ;;
    *)      echo "stub container: $*" ;;
esac
EOF
chmod +x "$stub_container/container"

stub_darwin="$tmp/stub-darwin"
mkdir -p "$stub_darwin"
cat > "$stub_darwin/uname" <<'EOF'
#!/bin/sh
echo Darwin
EOF
chmod +x "$stub_darwin/uname"

# A minimal PATH with the tools the script needs but no container runtime,
# to test the "suggest what to install" branch hermetically even on machines
# where docker is installed.
cleanbin="$tmp/cleanbin"
mkdir -p "$cleanbin"
for cmd in bash sh sed grep tr uname realpath dirname mkdir cat git touch echo; do
    src=$(command -v "$cmd" 2>/dev/null) && ln -s "$src" "$cleanbin/$cmd"
done

save="$tmp/save"
# Pre-create the save dir: code-it now runs first-run when the save dir is missing.
mkdir -p "$save"
common_args=(--dry-run --work-dir "$script_dir" --save-dir "$save")

# ---------------------------------------------------------------------------
echo "1. Syntax checks (bash -n)"
for f in code-it.sh code-it-build.sh code-it-first-run.sh code-it-add-agent.sh \
         code-it-add-toolchain.sh code-it-defaults.sh lib/code-it-common.sh claude-it.sh opencode-it.sh \
         tests/test-code-it.sh tests/test-code-it-defaults.sh \
         completions/code-it.bash completions/code-it-build.bash \
         completions/code-it-add-agent.bash completions/code-it-add-toolchain.bash \
         completions/code-it-first-run.bash completions/code-it-defaults.bash; do
    bash -n "$script_dir/$f"
    assert "bash -n $f" "$?"
done
if command -v zsh &>/dev/null; then
    for f in completions/_code-it completions/_code-it-build completions/_code-it-add-agent \
             completions/_code-it-add-toolchain completions/_code-it-first-run \
             completions/_code-it-defaults; do
        zsh -n "$script_dir/$f"
        assert "zsh -n $f" "$?"
    done
else
    echo "  skip: zsh -n completions (no zsh)"
fi
# Files the bash scripts read or source must check out as LF even where Git
# converts text to CRLF (Windows), or every value read carries a trailing \r
if git -C "$script_dir" rev-parse --git-dir &>/dev/null; then
    for f in "$script_dir"/agents/*/config "$script_dir"/toolchains/*/config \
             "$script_dir"/package-caches/*/config "$script_dir"/lib/models.txt \
             "$script_dir"/completions/_code-it*; do
        f=${f#"$script_dir/"}
        [[ "$(git -C "$script_dir" check-attr eol -- "$f")" == *": eol: lf" ]]
        assert "checks out LF: $f" "$?"
    done
else
    echo "  skip: LF checkout attributes (not a git checkout)"
fi

# ---------------------------------------------------------------------------
echo "2. --help exits 0 and prints usage"
out=$(PATH="$stub_docker:$PATH" "$code_it" --help)
assert "--help exit code" "$?"
assert_contains "--help shows usage" "$out" "Usage:"
assert_contains "--help documents -c" "$out" "--claude, -c"
assert_contains "--help documents -o" "$out" "--opencode, -o"
assert_contains "--help documents --prompt" "$out" "--prompt, -p TEXT"
assert_contains "--help documents --headless" "$out" "--headless"
assert_contains "--help documents the -- separator" "$out" "-- AGENT-ARGS..."
assert_contains "--help documents --locale" "$out" "--locale, -l LOCALE"
[[ "$out" != *--build-image* && "$out" != *--dockerfile-dir* ]]; assert "--help no longer offers building" "$?"
assert_contains "--help documents the remembered toolchain default" "$out" "SAVE-DIR/image-history"
out=$(PATH="$stub_docker:$PATH" "$script_dir/code-it-build.sh" --help)
assert_contains "code-it-build --help describes interactive selection" "$out" "interactive selection is used"

# ---------------------------------------------------------------------------
echo "3. Default dry-run with docker: opencode agent, only its state mounted"
out=$(PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}")
assert "dry-run exit code" "$?"
assert_contains "reports OpenCode config creation" "$out" "Created OpenCode configuration"
assert_contains "uses docker runtime" "$out" "Using container runtime: docker"
assert_contains "defaults to opencode" "$out" 'CODE_AGENT="opencode"'
assert_contains "docker run command" "$out" "docker run -it"
assert_contains "image name" "$out" "code-it-alpine-dotnet-node:latest"
expected_work=$(ci_work_mount_path "$script_dir")
assert_contains "work dir mount" "$out" "$script_dir:$expected_work"
assert_contains "work dir env tells go.sh where to cd" "$out" "CODE_IT_WORK_DIR=\"$expected_work\""
assert_contains "opencode config mount" "$out" "/.config/opencode:/home/agent1/.config/opencode"
assert_contains "opencode data mount" "$out" "/.local/share/opencode:/home/agent1/.local/share/opencode"
case "$out" in
    *"/home/agent1/.claude"*) assert "opencode run mounts no claude state" 1 ;;
    *)                        assert "opencode run mounts no claude state" 0 ;;
esac
case "$out" in
    *" -p "*) assert "no port is mapped by default" 1 ;;
    *)        assert "no port is mapped by default" 0 ;;
esac

# ---------------------------------------------------------------------------
echo "4. Save dir structure is created for first run"
# The default agent is opencode, which since v2's GA is v2: its state lives under
# save/opencode-v2/ (AGENT_SAVE_SUBDIR), where it has always lived
[[ -d "$save/opencode-v2/.config/opencode" ]];      assert "save/opencode-v2/.config/opencode created" "$?"
[[ -d "$save/opencode-v2/.local/share/opencode" ]]; assert "save/opencode-v2/.local/share/opencode created" "$?"
[[ -d "$save/opencode-v2/.local/state/opencode" ]]; assert "save/opencode-v2/.local/state/opencode created" "$?"
[[ "$(tr -d '[:space:]' < "$save/opencode-v2/.config/opencode/opencode.json")" == '{"$schema":"https://opencode.ai/config.json","permissions":[{"action":"*","resource":"*","effect":"allow"}]}' ]]
assert "OpenCode v2 config allows actions without prompts" "$?"
out=$(PATH="$stub_docker:$PATH" "$code_it" --agent opencode-v1 "${common_args[@]}")
assert_contains "reports OpenCode v1 config creation" "$out" "Created OpenCode v1 configuration"
[[ "$(tr -d '[:space:]' < "$save/.config/opencode/config.json")" == '{"$schema":"https://opencode.ai/config.json","permission":"allow"}' ]]
assert "OpenCode v1 config permits all actions" "$?"
# opencode-v1 reads the same paths as opencode (v2), so it keeps its state at the
# save-dir root while v2's stays under save/opencode-v2/
[[ ! -e "$save/opencode-v2/.config/opencode/config.json" ]]; assert "opencode-v1 config is not written where opencode (v2) reads it" "$?"
assert_contains "opencode-v1 mounts config" "$out" "$save/.config/opencode:/home/agent1/.config/opencode"
assert_contains "opencode-v1 mounts data and auth" "$out" "$save/.local/share/opencode:/home/agent1/.local/share/opencode"
case "$out" in
    *"/home/agent1/.local/state/opencode"*) assert "opencode-v1 mounts no v2 shared-service state" 1 ;;
    *)                                      assert "opencode-v1 mounts no v2 shared-service state" 0 ;;
esac
case "$out" in
    *"/home/agent1/.claude"*) assert "opencode-v1 mounts no claude state" 1 ;;
    *)                        assert "opencode-v1 mounts no claude state" 0 ;;
esac
[[ ! -e "$save/.claude" ]];               assert "opencode run creates no claude state" "$?"

# ---------------------------------------------------------------------------
echo "5. Agent selection switches"
out=$(PATH="$stub_docker:$PATH" "$code_it" --opencode "${common_args[@]}")
assert_contains "--opencode selects opencode" "$out" 'CODE_AGENT="opencode"'
out=$(PATH="$stub_docker:$PATH" "$code_it" -o "${common_args[@]}")
assert_contains "-o selects opencode" "$out" 'CODE_AGENT="opencode"'
out=$(PATH="$stub_docker:$PATH" "$code_it" --claude "${common_args[@]}")
assert_contains "--claude selects claude" "$out" 'CODE_AGENT="claude"'
assert_contains "reports Claude settings creation" "$out" "Created Claude Code settings"
[[ "$(tr -d '[:space:]' < "$save/.claude/settings.json")" == '{"permissions":{"defaultMode":"auto"},"skipDangerousModePermissionPrompt":true}' ]]
assert "Claude settings enable auto mode and skip prompt" "$?"
[[ -f "$save/.claude.json" ]];            assert "save/.claude.json pre-created as a file" "$?"
assert_contains "claude dir mount" "$out" "/.claude:/home/agent1/.claude"
assert_contains "claude.json mount" "$out" "/.claude.json:/home/agent1/.claude.json"
case "$out" in
    *"/home/agent1/.config/opencode"*) assert "claude run mounts no opencode state" 1 ;;
    *)                                 assert "claude run mounts no opencode state" 0 ;;
esac
out=$(PATH="$stub_docker:$PATH" "$code_it" -c "${common_args[@]}")
assert_contains "-c selects claude" "$out" 'CODE_AGENT="claude"'
out=$(PATH="$stub_docker:$PATH" "$code_it" --agent claude "${common_args[@]}")
assert_contains "--agent claude selects claude" "$out" 'CODE_AGENT="claude"'
out=$(PATH="$stub_docker:$PATH" "$code_it" --agent opencode "${common_args[@]}")
assert_contains "--agent opencode selects opencode" "$out" 'CODE_AGENT="opencode"'
out=$(PATH="$stub_docker:$PATH" "$code_it" --agent opencode-v1 "${common_args[@]}")
assert_contains "--agent opencode-v1 selects v1" "$out" 'CODE_AGENT="opencode-v1"'
out=$(PATH="$stub_docker:$PATH" "$code_it" --list-agents)
assert "--list-agents exit code" "$?"
assert_contains "--list-agents lists claude" "$out" "claude"
assert_contains "--list-agents lists opencode" "$out" "opencode"
assert_contains "--list-agents lists opencode-v1" "$out" "opencode-v1"
assert_contains "--list-agents shows the short flag" "$out" "-o"
out=$(PATH="$stub_docker:$PATH" "$code_it" --agent nosuchagent "${common_args[@]}" 2>&1)
[[ "$?" != "0" ]]; assert "unknown --agent fails" "$?"
assert_contains "unknown agent lists the available agents" "$out" "The available agents are:"
assert_contains "the agent list includes a short flag" "$out" "  opencode   -o"
assert_contains "unknown agent explains code-it-add-agent" "$out" "code-it-add-agent NAME adds a new one, if the agent has a recognised internet presence"

# ---------------------------------------------------------------------------
echo "6. Alias scripts"
out=$(PATH="$stub_docker:$PATH" "$script_dir/claude-it.sh" "${common_args[@]}")
assert "claude-it.sh exit code" "$?"
assert_contains "claude-it.sh selects claude" "$out" 'CODE_AGENT="claude"'
out=$(PATH="$stub_docker:$PATH" "$script_dir/opencode-it.sh" "${common_args[@]}")
assert "opencode-it.sh exit code" "$?"
assert_contains "opencode-it.sh selects opencode" "$out" 'CODE_AGENT="opencode"'
out=$(PATH="$stub_docker:$PATH" "$script_dir/claude-it.sh" -o "${common_args[@]}")
assert_contains "claude-it.sh: later -o wins over the alias" "$out" 'CODE_AGENT="opencode"'

# ---------------------------------------------------------------------------
echo "7. Runtime detection"
# On (stubbed) macOS with the Apple container CLI present, prefer it over docker
out=$(PATH="$stub_darwin:$stub_container:$stub_docker:$PATH" "$code_it" "${common_args[@]}")
assert_contains "macOS prefers apple container" "$out" "Using container runtime: container"
assert_contains "container run command" "$out" "container run -it"
case "$out" in
    *" -p "*) assert "the Apple container runtime maps no port by default" 1 ;;
    *)         assert "the Apple container runtime maps no port by default" 0 ;;
esac
# On non-macOS with both available, prefer docker
out=$(PATH="$stub_container:$stub_docker:$PATH" "$code_it" "${common_args[@]}")
assert_contains "non-macOS prefers docker" "$out" "Using container runtime: docker"
# Forced runtime
out=$(PATH="$stub_container:$stub_docker:$PATH" "$code_it" --runtime container "${common_args[@]}")
assert_contains "--runtime container forces apple container" "$out" "Using container runtime: container"
out=$(PATH="$stub_container:$stub_docker:$PATH" "$code_it" --runtime container --work-dir "$script_dir" --save-dir "$save")
assert_contains "container run gets --memory and 3g as separate arguments" "$out" "[--memory][3g]"
# Invalid runtime
PATH="$stub_docker:$PATH" "$code_it" --runtime bogus "${common_args[@]}" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "--runtime bogus fails" "$?"

# ---------------------------------------------------------------------------
echo "8. No runtime found: fails and suggests an install for the platform"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        # Git Bash turns ln -s into DLL-less file copies, so the restricted-PATH
        # sandbox does not work there; run the bash suite under WSL for full coverage.
        echo "  skip: hermetic no-runtime tests (not supported on Windows bash)"
        ;;
    *)
        out=$(PATH="$cleanbin" "$code_it" "${common_args[@]}" 2>&1)
        rc="$?"
        [[ "$rc" != "0" ]]; assert "no runtime exits non-zero" "$?"
        assert_contains "no runtime warns" "$out" "No container runtime found"
        assert_contains "suggests an install link" "$out" "docs.docker.com"
        out=$(PATH="$stub_darwin:$cleanbin" "$code_it" "${common_args[@]}" 2>&1)
        assert_contains "macOS suggestion mentions Apple container" "$out" "Apple container"
        ;;
esac

# ---------------------------------------------------------------------------
echo "9. Error handling"
PATH="$stub_docker:$PATH" "$code_it" --nonsense >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "unknown option fails" "$?"
PATH="$stub_docker:$PATH" "$code_it" --dry-run --work-dir "$tmp/does-not-exist" --save-dir "$save" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "missing work dir fails" "$?"
PATH="$stub_docker:$PATH" "$code_it" --image no-such-image "${common_args[@]}" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "unknown explicit image fails" "$?"
out=$(STUB_IMAGES_FAIL=1 PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}" 2>&1)
[[ "$?" != "0" ]]; assert "failure to list images fails" "$?"
assert_contains "failure to list images asks if the runtime is running" "$out" "Could not list docker images"

# ---------------------------------------------------------------------------
echo "10. code-it does not build"
for opt in --build-image -b --rebuild-image -B "--dockerfile-dir $tmp"; do
    # shellcheck disable=SC2086
    out=$(PATH="$stub_docker:$PATH" "$code_it" $opt "${common_args[@]}" 2>&1)
    [[ "$?" != "0" ]]; assert "removed ${opt%% *} fails" "$?"
    assert_contains "removed ${opt%% *} points to code-it-build" "$out" "has been removed: build images with code-it-build.sh"
    [[ "$out" != *STUB-DOCKER-BUILD* ]]; assert "removed ${opt%% *} does not build" "$?"
done

# ---------------------------------------------------------------------------
echo "10c. code-it-build: assembles fragments, labels, --tech, --rebuild"
build_it="$script_dir/code-it-build.sh"

# A stub docker that also copies the assembled build-context Dockerfile, so the
# tests can assert exactly which fragments were assembled.
capture="$tmp/captured.Dockerfile"
capturebin="$tmp/capturebin"; mkdir -p "$capturebin"
cat > "$capturebin/docker" <<EOF
#!/bin/sh
case "\$1" in
    build)
        for a in "\$@"; do last="\$a"; done
        cp "\$last/Dockerfile" "$capture"
        ls "\$last/ca-certificates" > "$capture.ca" 2>&1
        echo "STUB-DOCKER-BUILD \$*" ;;
    images) echo "code-it-alpine-dotnet-node:latest" ;;
    image)  echo dotnet,node ;;
    run)    echo "STUB-DOCKER-RUN \$*" ;;
    *)      echo "stub docker: \$*" ;;
esac
EOF
chmod +x "$capturebin/docker"
# do_capture ARGS...: build with the capture stub; the assembled file lands in $capture
do_capture() {
    rm -f "$capture"
    PATH="$capturebin:$PATH" "$build_it" "$@" >/dev/null 2>&1
}
assert_in_df() {
    local desc="$1" needle="$2"
    if grep -q -- "$needle" "$capture" 2>/dev/null; then assert "$desc" 0; else assert "$desc (missing: $needle)" 1; fi
}
assert_not_in_df() {
    local desc="$1" needle="$2"
    if grep -q -- "$needle" "$capture" 2>/dev/null; then assert "$desc (found: $needle)" 1; else assert "$desc" 0; fi
}

# With no toolchain, build asks interactively; menu numbers select the requested items.
out=$(printf '2\n1\ny\n' | PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" 2>&1)
assert "code-it-build without parameters offers interactive selection" "$?"
assert_contains "interactive build asks about toolchains" "$out" "Toolchains to build"
assert_contains "interactive build asks about agents" "$out" "Agents to install"
assert_contains "interactive build selects the numbered toolchain" "$out" "toolchains dotnet"
assert_contains "interactive build selects the numbered agent" "$out" "agents claude"
[[ "$out" != *STUB-DOCKER-BUILD* ]]; assert "interactive build dry-run does not build" "$?"
PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --toolchain , >/dev/null 2>&1
[[ "$?" == "1" ]]; assert "code-it-build with an empty --toolchain list exits 1" "$?"
do_capture --toolchain dotnet --dockerfile-dir "$script_dir" --runtime docker
assert_in_df "code-it-build assembles the toolchain given" 'dotnet-sdk-$version-linux-musl'
assert_not_in_df "code-it-build builds only the toolchain given" "apk add --no-cache nodejs"

# --dry-run prints the build command (the same args code-it passes) without executing
out=$(PATH="$stub_docker:$PATH" "$build_it" --toolchain dotnet,node --dry-run --dockerfile-dir "$script_dir" 2>&1)
assert "code-it-build --dry-run exit code" "$?"
assert_contains "build dry-run prints the build command" "$out" "docker build"
assert_contains "build dry-run labels the toolchains" "$out" "--label code-it.toolchains=dotnet,node"
assert_contains "build dry-run labels the package caches" "$out" "--label code-it.package-caches=nuget,npm"
assert_contains "build dry-run derives the default image name" "$out" "-t code-it-alpine-dotnet-node:latest"
case "$out" in
    *STUB-DOCKER-BUILD*) assert "code-it-build --dry-run does not execute the build" 1 ;;
    *)                   assert "code-it-build --dry-run does not execute the build" 0 ;;
esac

# The build assembles the selected toolchains and their implied caches only
do_capture --toolchain dotnet,node --dockerfile-dir "$script_dir" --runtime docker
assert "code-it-build capture exit code" "$?"
assert_in_df "build assembles dotnet" 'dotnet-sdk-$version-linux-musl'
assert_in_df "dotnet SDKs are verified against Microsoft's SHA-512" 'sha512sum -c "$file.sha512"'
assert_in_df "dotnet installs both the 10.0 and 8.0 SDKs" 'for channel in 10.0 8.0'
assert_not_in_df "dotnet does not use Alpine's mismatched dotnet10-sdk apk" 'apk add --no-cache dotnet10-sdk dotnet8-sdk'
assert_in_df "build assembles node" "apk add --no-cache nodejs"
assert_in_df "dotnet implies the nuget package cache" "fallbackPackageFolders"
assert_in_df "node implies the npm package cache" "/home/agent1/.npm-host"
assert_not_in_df "build leaves bun out" "bun.sh/install"
assert_not_in_df "build leaves python out" "apk add --no-cache python3 uv"
assert_not_in_df "build leaves powershell out" "PowerShell/releases/download"
assert_not_in_df "build has no toolchain build switches" "ARG DOTNET"

# --tech is the kept alias of --toolchain
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --tech bun 2>&1)
assert_contains "build --tech alias derives the image name" "$out" "-t code-it-alpine-bun:latest"
do_capture --dockerfile-dir "$script_dir" --tech bun --runtime docker
assert_in_df "build --tech alias assembles bun" "bun.sh/install"
assert_not_in_df "build --tech bun leaves dotnet out" 'dotnet-sdk-$version-linux-musl'

# --package-caches replaces the implied set
do_capture --dockerfile-dir "$script_dir" --toolchain bun --package-caches nuget --runtime docker
assert_in_df "build --package-caches nuget without dotnet assembles the cache" "fallbackPackageFolders"
assert_in_df "build --package-caches nuget adds its doas permit" "cmd nuget"
assert_not_in_df "build --package-caches nuget excludes npm" "/home/agent1/.npm-host"
do_capture --dockerfile-dir "$script_dir" --toolchain node --package-caches= --runtime docker
assert_in_df "empty --package-caches still assembles node" "apk add --no-cache nodejs"
assert_not_in_df "empty --package-caches assembles no cache" "/home/agent1/.npm-host"

# A Dockerfile without the assembly markers is a hard error
nomarker="$tmp/nomarker"; mkdir -p "$nomarker"
printf 'FROM alpine:3.24\n' > "$nomarker/Dockerfile"
cp -R "$script_dir/agents" "$nomarker/agents"
PATH="$capturebin:$PATH" "$build_it" --toolchain dotnet --dockerfile-dir "$nomarker" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "code-it-build without assembly markers fails" "$?"

# Unknown names are hard errors
PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --toolchain cobol >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "code-it-build unknown toolchain fails" "$?"
PATH="$stub_docker:$PATH" "$build_it" --toolchain dotnet,node --dry-run --dockerfile-dir "$script_dir" --package-caches pip >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "code-it-build unknown package cache fails" "$?"

# --rebuild bumps the dates and then really builds; a plain build leaves them alone
today=$(date +%Y-%m-%d)
bdfdir="$tmp/build-dfdir"; mkdir -p "$bdfdir"
cp "$script_dir/Dockerfile" "$bdfdir/Dockerfile"
cp -R "$script_dir/agents" "$script_dir/toolchains" "$script_dir/package-caches" "$bdfdir/"
sed -i -E "s/# last changed [0-9]{4}-[0-9]{2}-[0-9]{2}/# last changed 2000-01-01/" "$bdfdir/agents/"*/install.dockerfile "$bdfdir/toolchains/"*/install.dockerfile
out=$(PATH="$stub_docker:$PATH" "$build_it" --toolchain dotnet,node --dockerfile-dir "$bdfdir" --runtime docker 2>&1)
assert_contains "code-it-build invokes docker build" "$out" "STUB-DOCKER-BUILD"
grep -q "# last changed 2000-01-01" "$bdfdir/agents/opencode/install.dockerfile"
assert "code-it-build without --rebuild leaves the dates unchanged" "$?"
STUB_BUILD_FAIL=1 PATH="$stub_docker:$PATH" "$build_it" --toolchain dotnet,node --dockerfile-dir "$bdfdir" --runtime docker >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "code-it-build failed build exits non-zero" "$?"
out=$(PATH="$stub_docker:$PATH" "$build_it" --toolchain dotnet,node --rebuild --dockerfile-dir "$bdfdir" --runtime docker 2>&1)
assert "code-it-build --rebuild exit code" "$?"
assert_contains "code-it-build --rebuild invokes docker build" "$out" "STUB-DOCKER-BUILD"
grep -q "# last changed $today" "$bdfdir/agents/opencode/install.dockerfile"
assert "code-it-build --rebuild bumps the opencode fragment" "$?"
grep -q "# last changed $today" "$bdfdir/agents/claude/install.dockerfile"
assert "code-it-build --rebuild bumps the claude fragment" "$?"
grep -q "# last changed $today" "$bdfdir/toolchains/dotnet/install.dockerfile"
assert "code-it-build --rebuild bumps the selected toolchain fragment" "$?"
grep -q "# last changed 2000-01-01" "$bdfdir/toolchains/bun/install.dockerfile"
assert "code-it-build --rebuild leaves unselected toolchain fragments alone" "$?"
# A missing Dockerfile is an error
PATH="$stub_docker:$PATH" "$build_it" --toolchain dotnet,node --dry-run --dockerfile-dir "$tmp" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "code-it-build without a Dockerfile fails" "$?"
# Extra CA certificates next to the Dockerfile reach the build context, and the
# assembled Dockerfile trusts them before its first apk fetch. With no
# ca-certificates/ folder, the context still has an empty one for COPY.
out=$(PATH="$capturebin:$PATH" "$build_it" --toolchain dotnet --dockerfile-dir "$bdfdir" --runtime docker 2>&1)
[[ -f "$capture.ca" && ! -s "$capture.ca" ]]
assert "code-it-build without ca-certificates/ gives the context an empty one" "$?"
assert_contains "code-it-build says when no certificate trust was requested" "$out" "No additional certificate trust was requested"
mkdir -p "$bdfdir/ca-certificates"
printf -- '-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n' > "$bdfdir/ca-certificates/test-proxy-ca.crt"
out=$(PATH="$capturebin:$PATH" "$build_it" --toolchain dotnet --dockerfile-dir "$bdfdir" --runtime docker 2>&1)
assert_contains "code-it-build lists the certificate files it adds trust for" "$out" "Adding certificate trust from ca-certificates/: test-proxy-ca.crt"
grep -qx "test-proxy-ca.crt" "$capture.ca" 2>/dev/null
assert "code-it-build copies ca-certificates/ into the build context" "$?"
assert_in_df "assembled Dockerfile copies the extra CA certificates" "COPY ca-certificates/"
awk '/COPY ca-certificates\//{c=NR} /apk add/{if(!a)a=NR} END{exit !(c && a && c<a)}' "$capture"
assert "extra CA certificates are trusted before the first apk add" "$?"
printf -- '-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n' > "$bdfdir/ca-certificates/corp-root.cer"
out=$(PATH="$capturebin:$PATH" "$build_it" --toolchain dotnet --dockerfile-dir "$bdfdir" --runtime docker 2>&1)
assert "code-it-build with .crt and .cer but no .pem certificates succeeds" "$?"
assert_contains "code-it-build lists .crt and .cer certificates together" "$out" "test-proxy-ca.crt corp-root.cer"
rm -rf "$bdfdir/ca-certificates"

# The /etc/code-it-agents write happens after "USER agent1"; it is root-owned, so
# the assembled Dockerfile must switch to root for that write (and back to agent1).
do_capture --toolchain dotnet,node --dockerfile-dir "$script_dir" --runtime docker
assert "code-it-build captured the assembled Dockerfile" "$([[ -s "$capture" ]]; echo $?)"
[[ "$(wc -c < "$capture")" -lt 16384 ]]
assert "assembled Dockerfile is under Apple's 16KB limit" "$?"
# Docker creates a missing bind-mount parent as root, so the selected agents' state
# paths are pre-created agent-owned in the image before the launcher mounts them. A
# state file is not created as a directory: its parent (the home) exists.
assert_in_df "agent state dirs are pre-created for mounts" "~/.local/share/opencode"
do_capture --toolchain dotnet --agent claude --dockerfile-dir "$script_dir" --runtime docker
assert_in_df "claude state dir is pre-created for mounts" "~/.claude"
assert_not_in_df "claude state file is not created as a directory" "~/.claude.json"
assert_not_in_df "an assembled image has only the selected agents" "opencode.ai/install"
do_capture --toolchain dotnet,node --dockerfile-dir "$script_dir" --runtime docker
[[ "$(awk '/^USER /{u=$2} /printf .* > \/etc\/code-it-agents/{print u; exit}' "$capture")" == "root" ]]
assert "assembled Dockerfile writes /etc/code-it-agents as root" "$?"
[[ "$(awk '/printf .* > \/etc\/code-it-agents/{found=1; next} found && /^USER /{print $2; exit}' "$capture")" == "agent1" ]]
assert "assembled Dockerfile drops back to agent1 after the root write" "$?"
# Each installed agent's binary directory goes on zsh's PATH, so a --no-agent
# shell can invoke any of them (Spec 18)
assert_in_df "each installed agent's binary dir goes on zsh's PATH" 'export PATH="/home/agent1/.opencode-v2/bin:/home/agent1/.local/bin:$PATH"'
do_capture --toolchain dotnet --agent claude --dockerfile-dir "$script_dir" --runtime docker
assert_in_df "a single agent's binary dir goes on zsh's PATH" 'export PATH="/home/agent1/.local/bin:$PATH"'

echo "10f. code-it-build agents"
out=$(PATH="$stub_docker:$PATH" "$build_it" --toolchain dotnet,node --dry-run --dockerfile-dir "$script_dir" 2>&1)
assert_contains "default build installs opencode and claude" "$out" "agents opencode,claude"
assert_contains "default build labels the agents" "$out" "--label code-it.agents=opencode,claude"
out=$(PATH="$stub_docker:$PATH" "$build_it" --toolchain dotnet,node --dry-run --dockerfile-dir "$script_dir" --agent opencode 2>&1)
assert_contains "--agent opencode selects only opencode" "$out" "agents opencode"
case "$out" in
    *"agents opencode,claude"*) assert "--agent opencode excludes claude" 1 ;;
    *)                         assert "--agent opencode excludes claude" 0 ;;
esac
out=$(PATH="$stub_docker:$PATH" "$build_it" --toolchain dotnet,node --dry-run --dockerfile-dir "$script_dir" --agent opencode-v1 2>&1)
assert_contains "--agent opencode-v1 selects the v1 installer" "$out" "agents opencode-v1"
assert_contains "opencode-v1 image label records the agent" "$out" "--label code-it.agents=opencode-v1"
assert_contains "opencode-v1 image label records its binary" "$out" "--label code-it.agent-binaries=opencode-v1=/home/agent1/.opencode/bin/opencode"
out=$(PATH="$stub_docker:$PATH" "$build_it" --toolchain dotnet,node --dry-run --dockerfile-dir "$script_dir" --agent claude,opencode 2>&1)
assert_contains "agent-binaries label lists every agent" "$out" "--label code-it.agent-binaries=claude=/home/agent1/.local/bin/claude,opencode=/home/agent1/.opencode-v2/bin/opencode"
grep -q 'bash /tmp/opencode-v2-install.sh --version 2.0.6' "$script_dir/agents/opencode/install.dockerfile"
assert "opencode (v2) uses the official installer with a pinned version" "$?"
[[ "$(grep '^AGENT_BINARY=' "$script_dir/agents/opencode/config")" != "$(grep '^AGENT_BINARY=' "$script_dir/agents/opencode-v1/config")" ]]
assert "opencode and opencode-v1 binaries do not overwrite each other" "$?"
grep -q 'mv .*/\.opencode/bin/opencode ~/\.opencode-v2/bin/opencode' "$script_dir/agents/opencode/install.dockerfile"
assert "opencode (v2) installs to its own AGENT_BINARY path" "$?"
out=$(PATH="$stub_docker:$PATH" "$build_it" --toolchain dotnet,node --dry-run --dockerfile-dir "$script_dir" --agent claude,opencode 2>&1)
assert_contains "--agent accepts a list" "$out" "agents claude,opencode"
out=$(PATH="$stub_docker:$PATH" "$build_it" --list-agents)
assert "--list-agents exit code" "$?"
assert_contains "code-it-build --list-agents lists claude" "$out" "claude"
assert_contains "code-it-build --list-agents lists opencode" "$out" "opencode"
out=$(PATH="$stub_docker:$PATH" "$build_it" --list-toolchains)
assert "--list-toolchains exit code" "$?"
assert_contains "code-it-build --list-toolchains lists dotnet" "$out" "dotnet"
assert_contains "code-it-build --list-toolchains lists powershell" "$out" "powershell"
assert_contains "code-it-build --list-toolchains shows the pwsh alias" "$out" "aliases: pwsh"
out=$(PATH="$stub_docker:$PATH" "$build_it" --list-package-caches)
assert "--list-package-caches exit code" "$?"
assert_contains "code-it-build --list-package-caches lists nuget" "$out" "nuget"
PATH="$stub_docker:$PATH" "$build_it" --toolchain dotnet,node --dry-run --dockerfile-dir "$script_dir" --agent nosuch >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "code-it-build unknown agent fails" "$?"

echo "10d. code-it reads the image label"
out=$(STUB_IMAGE_TOOLCHAINS=node,bun PATH="$stub_docker:$PATH" "$code_it" --toolchain dotnet,node --image code-it-alpine-dotnet-node "${common_args[@]}" 2>&1)
assert_contains "warns when the image label disagrees with --toolchain" "$out" "looks built for toolchains 'node,bun'"
# There is no default toolchain: --image alone takes the image's own toolchains
out=$(STUB_IMAGE_TOOLCHAINS=node,bun PATH="$stub_docker:$PATH" "$code_it" --image code-it-alpine-dotnet-node "${common_args[@]}" 2>&1)
assert "--image without --toolchain runs" "$?"
[[ "$out" != *"looks built for"* ]]; assert "--image without --toolchain does not assume dotnet,node" "$?"
[[ "$out" != *NuGet* ]]; assert "--image without --toolchain mounts the caches of the image's toolchains" "$?"
PATH="$stub_docker:$PATH" "$code_it" --toolchain , "${common_args[@]}" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "an empty --toolchain list fails" "$?"
grep -qE '^ARG (DOTNET|NODE|BUN|PYTHON|POWERSHELL)=' "$script_dir/Dockerfile"
[[ "$?" != "0" ]]; assert "the base Dockerfile has no toolchain switches" "$?"
grep -q '^# @@CODE_IT_TOOLCHAIN_INSTALLS@@$' "$script_dir/Dockerfile"
assert "the base Dockerfile has the toolchain marker" "$?"

echo "10g. PowerShell toolchain (powershell / pwsh)"
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --toolchain dotnet,node,powershell 2>&1)
assert_contains "--toolchain powershell derives the image name" "$out" "-t code-it-alpine-dotnet-node-powershell:latest"
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --toolchain pwsh 2>&1)
assert_contains "pwsh aliases powershell" "$out" "-t code-it-alpine-powershell:latest"
do_capture --toolchain powershell,pwsh --dockerfile-dir "$script_dir" --runtime docker
assert_in_df "powershell toolchain assembles pwsh" "PowerShell/releases/download"
assert_not_in_df "powershell does not drag the dotnet toolchain in" "dotnet workload update"
assert_in_df "powershell on aarch64 uses Microsoft's musl .NET SDK" 'dotnet-sdk-$version-linux-musl-arm64'
assert_in_df "powershell verifies the .NET SDK against Microsoft's SHA-512" 'sha512sum -c "$file.sha512"'
assert_not_in_df "powershell does not use Alpine's mismatched dotnet10-sdk apk" 'apk add --no-cache dotnet10-sdk'
assert_in_df "powershell reuses a 10.0 SDK the dotnet toolchain installed" 'ls /usr/share/dotnet/sdk'
do_capture --toolchain dotnet,node --dockerfile-dir "$script_dir" --runtime docker
assert_not_in_df "a build without powershell leaves it out" "PowerShell/releases/download"

echo "10e. Python toolchain (python / uv / --stack)"
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --stack python 2>&1)
assert_contains "--stack python derives the image name" "$out" "-t code-it-alpine-python:latest"
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --toolchain uv 2>&1)
assert_contains "uv canonical image name" "$out" "-t code-it-alpine-python:latest"
do_capture --toolchain uv --dockerfile-dir "$script_dir" --runtime docker
assert_in_df "uv aliases python and assembles both" "apk add --no-cache python3 uv"
assert_in_df "python sets UV_CACHE_DIR in the agent home" "UV_CACHE_DIR=/home/agent1/.cache/uv"
assert_in_df "python adds its doas permit" "cmd python3"
do_capture --toolchain dotnet,node --dockerfile-dir "$script_dir" --runtime docker
assert_not_in_df "a build without python leaves it out" "python3"
out=$(PATH="$stub_docker:$PATH" "$code_it" --stack python "${common_args[@]}" 2>&1)
assert_contains "code-it --stack python looks for the python image" "$out" "image 'code-it-alpine-python' does not exist; building it"
# Python and uv are installed together, by the Python toolchain's fragment only.
grep -q "apk add --no-cache python3 uv" "$script_dir/toolchains/python/install.dockerfile"
assert "the python fragment installs uv with Python" "$?"
! grep -qE '^RUN apk add --no-cache uv[[:space:]]*$' "$script_dir/Dockerfile"
assert "Dockerfile does not install uv in the base image" "$?"
# The base layer installs tools only: no GUI packages, no Kerberos, no edge repo.
# Libraries come with the toolchain or agent that needs them.
! grep -qE 'apk .*(chromium|ttf-freefont|freetype-dev|krb5|[[:space:]]docs[[:space:]])' "$script_dir/Dockerfile"
assert "Dockerfile base installs no GUI, Kerberos or docs packages" "$?"
! grep -q 'edge/main' "$script_dir/Dockerfile"
assert "Dockerfile does not mix in the edge repository" "$?"
grep -qE 'apk add --no-cache .*musl-locales' "$script_dir/Dockerfile"
assert "Dockerfile base keeps musl-locales for international text" "$?"
grep -q '^RUN git config --global feature.manyFiles true$' "$script_dir/Dockerfile"
assert "Dockerfile enables Git's many-files feature globally" "$?"
grep -q '^RUN git config --global core.fsmonitor true$' "$script_dir/Dockerfile"
assert "Dockerfile enables Git filesystem monitoring globally" "$?"
grep -q 'apk add --no-cache libgcc libstdc++ icu-libs libssl3 && ' "$script_dir/toolchains/powershell/install.dockerfile"
assert "PowerShell tarball layer adds the libraries it needs" "$?"
for a in opencode opencode-v1; do
    grep -q '^RUN apk add --no-cache libgcc libstdc++$' "$script_dir/agents/$a/install.dockerfile"
    assert "$a install fragment adds libgcc and libstdc++" "$?"
done

# ---------------------------------------------------------------------------
echo "10g. Choosing an existing image that contains the requested toolchains"
superbin="$tmp/superbin"; mkdir -p "$superbin"
cat > "$superbin/docker" <<'EOF'
#!/bin/sh
case "$1" in
    images) printf '%s\n' $STUB_IMAGES ;;
    image)
        for a in "$@"; do last="$a"; done
        case "$last" in
            code-it-alpine-dotnet-bun*)  echo dotnet,bun ;;
            code-it-alpine-dotnet-node*) echo dotnet,node ;;
            code-it-alpine-dotnet*)      echo dotnet ;;
            *)                           echo "" ;;
        esac ;;
    *) echo "STUB $*" ;;
esac
EOF
chmod +x "$superbin/docker"
super_args=(--dry-run --work-dir "$script_dir" --save-dir "$save")

# The exact image, when it exists, is used unchanged
out=$(STUB_IMAGES="code-it-alpine-dotnet-bun:latest code-it-alpine-dotnet:latest" PATH="$superbin:$PATH" \
        "$code_it" --toolchain dotnet "${super_args[@]}")
assert_contains "uses the exact image when it exists" "$out" "code-it-alpine-dotnet:latest"
case "$out" in
    *"does not exist; using"*) assert "no substitution when the exact image exists" 1 ;;
    *)                         assert "no substitution when the exact image exists" 0 ;;
esac

# The exact image missing: the most-recently listed image containing the chain wins
out=$(STUB_IMAGES="code-it-alpine-dotnet-bun:latest code-it-alpine-dotnet-node:latest" PATH="$superbin:$PATH" \
        "$code_it" --toolchain dotnet "${super_args[@]}")
assert_contains "substitutes a superset image" "$out" "does not exist; using 'code-it-alpine-dotnet-bun'"
assert_contains "runs the superset image" "$out" "code-it-alpine-dotnet-bun:latest"
assert_contains "notes the extra toolchains" "$out" "also contains bun"

# Order decides: whichever qualifying image is listed first (most recently built)
out=$(STUB_IMAGES="code-it-alpine-dotnet-node:latest code-it-alpine-dotnet-bun:latest" PATH="$superbin:$PATH" \
        "$code_it" --toolchain dotnet "${super_args[@]}")
assert_contains "picks the most recent qualifying image" "$out" "using 'code-it-alpine-dotnet-node'"

# Every requested chain must be present: dotnet-node does not contain bun
out=$(PATH="$superbin:$PATH" STUB_IMAGES="code-it-alpine-dotnet-node:latest" \
    "$code_it" --toolchain dotnet,bun "${super_args[@]}" 2>&1)
assert_contains "requires every requested chain to be present" "$out" "'code-it-alpine-dotnet-bun' does not exist; building it"

# No image contains the requested chain: warn, then build it and run it
out=$(PATH="$superbin:$PATH" STUB_IMAGES="code-it-alpine-dotnet-node:latest code-it-alpine-dotnet-bun:latest" \
    "$code_it" --toolchain python "${super_args[@]}" 2>&1)
assert "builds when no image contains the requested chain" "$?"
assert_contains "warns that the image is missing" "$out" "image 'code-it-alpine-python' does not exist; building it with code-it-build.sh --toolchain python"
assert_contains "builds the missing image" "$out" "-t code-it-alpine-python:latest"
assert_contains "builds the default agents and the chosen one" "$out" "code-it.agents=opencode,claude "
assert_contains "then runs the built image" "$out" "docker run"
case "$out" in
    *"STUB build"*) assert "--dry-run passes --dry-run to the build" 1 ;;
    *)              assert "--dry-run passes --dry-run to the build" 0 ;;
esac

# The build is given the run's toolchains, package caches, locale, runtime and image,
# with the chosen agent added to the defaults
stub_build="$tmp/stub-build.sh"
printf '#!/bin/sh\necho "STUB-BUILD $*"\nexit ${STUB_BUILD_RC:-0}\n' > "$stub_build"; chmod +x "$stub_build"
out=$(CODE_IT_BUILD="$stub_build" PATH="$superbin:$PATH" STUB_IMAGES="code-it-alpine-dotnet:latest" \
    "$code_it" --toolchain python --package-caches npm --locale en-GB --agent opencode-v1 "${super_args[@]}" 2>&1)
assert_contains "build gets the toolchains and package caches" "$out" "STUB-BUILD --toolchain python --package-caches npm"
assert_contains "build gets the defaults plus the chosen agent" "$out" "--agent opencode,claude,opencode-v1"
assert_contains "build gets the locale, runtime and image" "$out" "--locale en-GB --runtime docker --image code-it-alpine-python --yes --dry-run"
out=$(CODE_IT_BUILD="$stub_build" PATH="$superbin:$PATH" STUB_IMAGES="code-it-alpine-dotnet:latest" \
    "$code_it" --toolchain python --agent claude "${super_args[@]}" 2>&1)
assert_contains "an agent already in the defaults is not repeated" "$out" "--agent opencode,claude --locale"
out=$(CODE_IT_BUILD="$stub_build" PATH="$superbin:$PATH" STUB_IMAGES="code-it-alpine-dotnet:latest" \
    "$code_it" --toolchain python --no-agent "${super_args[@]}" 2>&1)
assert_contains "--no-agent builds the default agents" "$out" "--agent opencode,claude --locale"
out=$(STUB_BUILD_RC=3 CODE_IT_BUILD="$stub_build" PATH="$superbin:$PATH" STUB_IMAGES="code-it-alpine-dotnet:latest" \
    "$code_it" --toolchain python "${super_args[@]}" 2>&1)
[[ "$?" == "3" ]]; assert "a failed build exits with its code" "$?"
assert_contains "a failed build says so" "$out" "building 'code-it-alpine-python' failed"
case "$out" in
    *"docker run"*) assert "a failed build does not run" 1 ;;
    *)              assert "a failed build does not run" 0 ;;
esac

# An explicit --image is never substituted or built, and errors if missing
out=$(CODE_IT_BUILD="$stub_build" PATH="$superbin:$PATH" STUB_IMAGES="code-it-alpine-dotnet-bun:latest" \
    "$code_it" --toolchain dotnet --image code-it-alpine-nope "${super_args[@]}" 2>&1)
[[ "$?" != "0" ]]; assert "explicit --image is used as-is and errors if missing" "$?"
case "$out" in
    *STUB-BUILD*) assert "explicit --image is not built" 1 ;;
    *)            assert "explicit --image is not built" 0 ;;
esac

# ---------------------------------------------------------------------------
echo "10h. Dockerfile comment stripping keeps the buildable Dockerfile small"
. "$script_dir/lib/code-it-common.sh"
stripped_df="$tmp/stripped.Dockerfile"
ci_strip_dockerfile_comments < "$script_dir/Dockerfile" > "$stripped_df"
stripped_size=$(wc -c < "$stripped_df")
[[ "$stripped_size" -lt 16384 ]]; assert "stripped Dockerfile is under Apple's 16KB limit ($stripped_size bytes)" "$?"
grep -q "# Arguments given to the container" "$stripped_df"
assert "stripping preserves heredoc bodies" "$?"
grep -q "apk add --no-cache git" "$stripped_df"
assert "stripping keeps RUN lines" "$?"
# The base file builds, with no args, into zsh/vim/tmux/git plus the default agent
# (opencode, which since v2's GA is v2)
grep -q "opencode.ai/v2/install" "$script_dir/Dockerfile"
assert "base Dockerfile carries the default opencode agent" "$?"
# Keep the default region in sync with the opencode definition (no drift)
grep -qF "$(grep -m1 'opencode.ai/v2/install' "$script_dir/agents/opencode/install.dockerfile")" "$script_dir/Dockerfile"
assert "base default agent region matches the opencode fragment" "$?"
grep -qF "'opencode=/home/agent1/.opencode-v2/bin/opencode'" "$script_dir/Dockerfile"
assert "base default agent region writes the opencode map" "$?"
grep -qF "RUN echo 'export PATH=\"/home/agent1/.opencode-v2/bin:\$PATH\"' >> ~/.zshrc" "$script_dir/Dockerfile"
assert "base Dockerfile puts the default agent's binary dir on zsh's PATH" "$?"

# ---------------------------------------------------------------------------
echo "11. Custom options"
# --port is gone: no port is mapped by default, and --run-arg is how ports are
# mapped now (Spec 18)
out=$(PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}")
case "$out" in
    *" -p "*) assert "no port is mapped by default" 1 ;;
    *)         assert "no port is mapped by default" 0 ;;
esac
out=$(PATH="$stub_docker:$PATH" "$code_it" --run-arg -p --run-arg 8000:3000 "${common_args[@]}" 2>&1)
assert "--run-arg maps a port exit code" "$?"
assert_contains "ports are mapped with --run-arg" "$out" "-p 8000:3000"
out=$(PATH="$stub_docker:$PATH" "$code_it" --port 8000 -o "${common_args[@]}" 2>&1)
[[ "$?" != "0" ]]; assert "--port is no longer an option" "$?"
assert_contains "--port says it is unknown" "$out" "Unknown option: --port"
out=$(PATH="$stub_docker:$PATH" "$code_it" --agent-name "MyAgent" "${common_args[@]}")
assert_contains "agent name lowercased in mounts" "$out" "/home/myagent/.config/opencode"
assert_contains "agent name in git author" "$out" 'GIT_AUTHOR_NAME="MyAgent for'
assert_contains "agent name in git committer" "$out" 'GIT_COMMITTER_NAME="MyAgent for'
assert_contains "git committer email passed" "$out" 'GIT_COMMITTER_EMAIL='
out=$(GIT_AUTHOR_NAME="Agent1 for Some One" PATH="$stub_docker:$PATH" "$code_it" --agent-name "MyAgent" "${common_args[@]}")
assert_contains "run inside an agent container does not repeat the agent prefix" "$out" 'GIT_AUTHOR_NAME="MyAgent for Some One"'

# ---------------------------------------------------------------------------
echo "11b. Short-form aliases"
out=$(PATH="$stub_docker:$PATH" "$code_it" -p "explain this" "${common_args[@]}")
assert_contains "-p is --prompt" "$out" '--prompt explain\ this'
out=$(PATH="$stub_docker:$PATH" "$code_it" -t node "${common_args[@]}")
assert_contains "-t is --toolchain" "$out" "'code-it-alpine-node' does not exist; using 'code-it-alpine-dotnet-node'"
out=$(PATH="$stub_container:$stub_docker:$PATH" "$code_it" -r container -i code-it-alpine-dotnet-node -w "$script_dir" -s "$save" -d)
assert_contains "-r is --runtime" "$out" "Using container runtime: container"
assert_contains "-i is --image" "$out" "code-it-alpine-dotnet-node:latest"
case "$out" in
    *STUB-DOCKER-RUN*) assert "-d is --dry-run (no run)" 1 ;;
    *)                 assert "-d is --dry-run (no run)" 0 ;;
esac

# ---------------------------------------------------------------------------
echo "12. NuGet package cache: detection and read-only mount"
fakehome="$tmp/fakehome"; mkdir -p "$fakehome"
nuget_cache="$tmp/nuget-cache"; mkdir -p "$nuget_cache"

# (a) NUGET_PACKAGES override: mounted read-only, in both printout and run command
out=$(HOME="$fakehome" NUGET_PACKAGES="$nuget_cache" PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}")
assert_contains "NUGET_PACKAGES cache mounted read-only (printout)" "$out" "-v \"$nuget_cache:/home/agent1/.nuget/packages-host:ro\""
out=$(HOME="$fakehome" NUGET_PACKAGES="$nuget_cache" PATH="$stub_docker:$PATH" "$code_it" --work-dir "$script_dir" --save-dir "$save")
assert_contains "run command runs the stub" "$out" "STUB-DOCKER-RUN"
assert_contains "NUGET_PACKAGES cache mounted read-only (run)" "$out" "-v $nuget_cache:/home/agent1/.nuget/packages-host:ro"

# (b) globalPackagesFolder from the user-level NuGet.Config
mkdir -p "$fakehome/.nuget/NuGet"
cat > "$fakehome/.nuget/NuGet/NuGet.Config" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <config>
    <add key="globalPackagesFolder" value="$nuget_cache" />
  </config>
</configuration>
EOF
out=$(HOME="$fakehome" NUGET_PACKAGES= PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}")
assert_contains "globalPackagesFolder from NuGet.Config mounted" "$out" "$nuget_cache:/home/agent1/.nuget/packages-host:ro"

# ... read as XML: attributes in any order or quote style, across lines, CRLF, entities
mkdir -p "$tmp/nuget & cache"
printf '<configuration>\r\n  <config>\r\n    <add\r\n      value='"'"'%s'"'"'\r\n      key="globalPackagesFolder" />\r\n  </config>\r\n</configuration>\r\n' \
    "$tmp/nuget &amp; cache" > "$fakehome/.nuget/NuGet/NuGet.Config"
out=$(HOME="$fakehome" NUGET_PACKAGES= PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}")
assert_contains "globalPackagesFolder read like XML" "$out" "$tmp/nuget & cache:/home/agent1/.nuget/packages-host:ro"

# ... but not from a comment, nor from outside the <config> section
cat > "$fakehome/.nuget/NuGet/NuGet.Config" <<EOF
<configuration>
  <packageSources>
    <add key="globalPackagesFolder" value="$nuget_cache" />
  </packageSources>
  <config>
    <!-- <add key="globalPackagesFolder" value="$nuget_cache" /> -->
  </config>
</configuration>
EOF
out=$(HOME="$fakehome" NUGET_PACKAGES= PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}")
[[ "$out" != *packages-host* ]]; assert "globalPackagesFolder ignored in comments and outside <config>" "$?"
rm -f "$fakehome/.nuget/NuGet/NuGet.Config"

# (c) default ~/.nuget/packages
mkdir -p "$fakehome/.nuget/packages"
out=$(HOME="$fakehome" NUGET_PACKAGES= PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}")
assert_contains "default ~/.nuget/packages mounted" "$out" "$fakehome/.nuget/packages:/home/agent1/.nuget/packages-host:ro"

# (d) no cache found: no mount, and a note is printed
emptyhome="$tmp/emptyhome"; mkdir -p "$emptyhome"
out=$(HOME="$emptyhome" NUGET_PACKAGES= PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}")
assert_contains "no cache: note printed" "$out" "No NuGet package cache found"
case "$out" in
    *packages-host*) assert "no cache: no nuget mount line" 1 ;;
    *)               assert "no cache: no nuget mount line" 0 ;;
esac

# ---------------------------------------------------------------------------
echo "12b. Toolchain: --toolchain / --package-caches fragment assembly and read-only caches"
npm_cache="$tmp/npm-cache"; mkdir -p "$npm_cache"
bun_cache="$tmp/bun-cache"; mkdir -p "$bun_cache"

# dotnet,node and the package repos they imply (nuget, npm)
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --toolchain dotnet,node)
do_capture --toolchain dotnet,node --dockerfile-dir "$script_dir" --runtime docker
assert_in_df "dotnet,node assembles dotnet" 'dotnet-sdk-$version-linux-musl'
assert_in_df "dotnet,node assembles node" "apk add --no-cache nodejs"
assert_not_in_df "dotnet,node leaves bun out" "bun.sh/install"
assert_in_df "dotnet implies the nuget cache" "fallbackPackageFolders"
assert_in_df "node implies the npm cache" "/home/agent1/.npm-host"
assert_contains "reports the resolved toolchains" "$out" "toolchains dotnet,node; package repos nuget,npm"

# --toolchain replaces the default set
do_capture --toolchain node,bun --dockerfile-dir "$script_dir" --runtime docker
assert_in_df "--toolchain node,bun assembles node" "apk add --no-cache nodejs"
assert_in_df "--toolchain node,bun assembles bun" "bun.sh/install"
assert_not_in_df "--toolchain node,bun drops dotnet" 'dotnet-sdk-$version-linux-musl'
assert_not_in_df "--toolchain node,bun drops nuget (dotnet gone)" "fallbackPackageFolders"
assert_in_df "--toolchain node,bun keeps npm (node present)" "/home/agent1/.npm-host"

# --package-caches replaces the implied set, independently of --toolchain
do_capture --toolchain node,bun --package-caches npm --dockerfile-dir "$script_dir" --runtime docker
assert_in_df "--package-caches npm keeps npm" "/home/agent1/.npm-host"
assert_not_in_df "--package-caches npm excludes the bun cache" "/home/agent1/.bun-host"
do_capture --toolchain node,bun --package-caches bun --dockerfile-dir "$script_dir" --runtime docker
assert_in_df "--package-caches bun assembles the bun cache" "/home/agent1/.bun-host"
assert_not_in_df "--package-caches bun excludes npm" "/home/agent1/.npm-host"

# --package-caches nuget with no dotnet still assembles the NuGet cache
do_capture --toolchain bun --package-caches nuget --dockerfile-dir "$script_dir" --runtime docker
assert_in_df "nuget package cache without dotnet" "fallbackPackageFolders"

# The default image name follows --toolchain, so the built and run images agree
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --toolchain node,bun)
assert_contains "image name derives from --toolchain" "$out" "-t code-it-alpine-node-bun:latest"

# The old --tech spelling is kept as a hidden alias
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --tech bun)
assert_contains "--tech alias derives the bun image" "$out" "-t code-it-alpine-bun:latest"

# Toolchain aliases resolve to the canonical name: js-node/ts-node -> node, js-bun/ts-bun -> bun
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --toolchain js-node)
assert_contains "js-node canonical image name" "$out" "-t code-it-alpine-node:latest"
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --toolchain ts-node)
assert_contains "ts-node canonical image name" "$out" "-t code-it-alpine-node:latest"
assert_contains "ts-node implies the npm package cache" "$out" "package repos npm"
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --toolchain js-bun)
assert_contains "js-bun canonical image name" "$out" "-t code-it-alpine-bun:latest"
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --toolchain ts-bun,bun)
assert_contains "ts-bun aliases bun and dedupes with bun" "$out" "-t code-it-alpine-bun:latest"

# The old --packages spelling is gone, not an alias
PATH="$stub_docker:$PATH" "$code_it" --packages npm "${common_args[@]}" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "removed --packages spelling fails" "$?"

# An image label that disagrees with --toolchain is called out
out=$(STUB_IMAGE_TOOLCHAINS=dotnet PATH="$stub_docker:$PATH" "$code_it" --toolchain node,bun --image code-it-alpine-dotnet-node "${common_args[@]}" 2>&1)
assert_contains "warns when the image label disagrees with --toolchain" "$out" "looks built for toolchains 'dotnet'"
# An image whose agents label lacks the chosen agent stops before docker run, readably
# (the stub answers the agents label lookup with STUB_IMAGE_AGENTS)
out=$(STUB_IMAGE_AGENTS=claude PATH="$stub_docker:$PATH" "$code_it" --agent opencode "${common_args[@]}" 2>&1)
[[ "$?" != "0" ]]; assert "image without the chosen agent fails" "$?"
assert_contains "names the agents the image has" "$out" "does not contain agent 'opencode'; it has: claude"
[[ "$out" != *STUB-DOCKER-RUN* ]]; assert "image without the chosen agent is not run" "$?"
out=$(STUB_IMAGE_AGENTS=claude PATH="$stub_docker:$PATH" "$code_it" --agent claude "${common_args[@]}" 2>&1)
assert "image with the chosen agent runs" "$?"
# An image whose recorded agent binary differs from the agent's definition is out of
# date (e.g. opencode-v1 built when it shared opencode, v2's, path): stop before docker run
out=$(STUB_IMAGE_AGENTS=opencode,opencode-v1 STUB_IMAGE_AGENT_BINARIES=opencode=/home/agent1/.opencode-v2/bin/opencode,opencode-v1=/home/agent1/.opencode-v2/bin/opencode \
    PATH="$stub_docker:$PATH" "$code_it" --agent opencode-v1 "${common_args[@]}" 2>&1)
[[ "$?" != "0" ]]; assert "image with an out-of-date agent binary fails" "$?"
assert_contains "names the recorded and expected binaries" "$out" "runs agent 'opencode-v1' from /home/agent1/.opencode-v2/bin/opencode, but agents/opencode-v1/config now names /home/agent1/.opencode/bin/opencode"
assert_contains "out-of-date agent binary suggests the rebuild" "$out" "code-it-build.sh --toolchain dotnet,node --agent opencode,opencode-v1"
[[ "$out" != *STUB-DOCKER-RUN* ]]; assert "image with an out-of-date agent binary is not run" "$?"
out=$(STUB_IMAGE_AGENTS=opencode,opencode-v1 STUB_IMAGE_AGENT_BINARIES=opencode=/home/agent1/.opencode-v2/bin/opencode,opencode-v1=/home/agent1/.opencode/bin/opencode \
    PATH="$stub_docker:$PATH" "$code_it" --agent opencode-v1 "${common_args[@]}" 2>&1)
assert "image with the current agent binary runs" "$?"
[[ "$out" != *"out of date"* && "$out" != *predates* ]]; assert "current agent binary gives no out-of-date warning" "$?"
out=$(STUB_IMAGE_AGENTS=opencode,opencode-v1 PATH="$stub_docker:$PATH" "$code_it" --agent opencode-v1 "${common_args[@]}" 2>&1)
assert "image without agent-binaries label still runs" "$?"
assert_contains "image without agent-binaries label warns it may be out of date" "$out" "predates code-it recording its agents' binaries"
# Without a label (older images), fall back to the name-based guess
out=$(STUB_IMAGE_TOOLCHAINS="" PATH="$stub_docker:$PATH" "$code_it" --toolchain node,bun --image code-it-alpine-dotnet-node "${common_args[@]}" 2>&1)
assert_contains "falls back to the image-name guess without a label" "$out" "looks built for toolchains 'dotnet,node'"

# Unknown names are hard errors
PATH="$stub_docker:$PATH" "$code_it" --toolchain cobol "${common_args[@]}" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "--toolchain with an unknown name fails" "$?"
PATH="$stub_docker:$PATH" "$code_it" --package-caches pip "${common_args[@]}" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "--package-caches with an unknown name fails" "$?"

# Host caches for enabled package repos are mounted read-only
out=$(HOME="$fakehome" NPM_CONFIG_CACHE="$npm_cache" PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}")
assert_contains "npm cache mounted read-only" "$out" "-v \"$npm_cache:/home/agent1/.npm-host:ro\""
out=$(HOME="$fakehome" BUN_INSTALL_CACHE_DIR="$bun_cache" PATH="$stub_docker:$PATH" "$code_it" --package-caches bun "${common_args[@]}")
assert_contains "bun cache mounted read-only" "$out" "-v \"$bun_cache:/home/agent1/.bun-host:ro\""

# Omitting a package repo from --package-caches suppresses its mount entirely
out=$(HOME="$fakehome" NPM_CONFIG_CACHE="$npm_cache" PATH="$stub_docker:$PATH" "$code_it" --toolchain node --package-caches= "${common_args[@]}")
case "$out" in
    *.npm-host*) assert "empty --package-caches: no npm mount" 1 ;;
    *)           assert "empty --package-caches: no npm mount" 0 ;;
esac
out=$(HOME="$fakehome" NUGET_PACKAGES="$nuget_cache" PATH="$stub_docker:$PATH" "$code_it" --toolchain dotnet --package-caches npm "${common_args[@]}")
case "$out" in
    *packages-host*) assert "packages without nuget: no nuget mount" 1 ;;
    *)               assert "packages without nuget: no nuget mount" 0 ;;
esac

# ---------------------------------------------------------------------------
echo "13. Prompt and agent arguments"
# A bare argument, or --prompt, is the agent's opening prompt, spelled each agent's way
out=$(PATH="$stub_docker:$PATH" "$code_it" -c "explain this repo" "${common_args[@]}")
assert_contains "claude: bare prompt appended to the image" "$out" 'code-it-alpine-dotnet-node:latest explain\ this\ repo'
out=$(PATH="$stub_docker:$PATH" "$code_it" -c --prompt "explain this repo" "${common_args[@]}")
assert_contains "claude: --prompt is the same as a bare prompt" "$out" 'code-it-alpine-dotnet-node:latest explain\ this\ repo'
out=$(PATH="$stub_docker:$PATH" "$code_it" -o "explain this repo" "${common_args[@]}")
assert_contains "opencode (v2): prompt becomes mini --prompt" "$out" 'code-it-alpine-dotnet-node:latest mini --prompt explain\ this\ repo'
out=$(PATH="$stub_docker:$PATH" "$code_it" --agent opencode-v1 "explain this repo" "${common_args[@]}")
assert_contains "opencode-v1: interactive prompt uses --prompt" "$out" 'code-it-alpine-dotnet-node:latest --prompt explain\ this\ repo'
# No prompt and no agent args: nothing is appended, and the run stays interactive
out=$(PATH="$stub_docker:$PATH" "$code_it" -o "${common_args[@]}")
[[ "$out" == *"code-it-alpine-dotnet-node:latest" ]]; assert "opencode (v2): no prompt appends nothing" "$?"
assert_contains "opencode (v2): no-prompt run remains interactive" "$out" "docker run -it"
# No prompt and no agent args: nothing is appended, and the run stays interactive
out=$(PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}")
[[ "$out" == *"code-it-alpine-dotnet-node:latest" ]]; assert "no prompt appends nothing" "$?"
assert_contains "interactive runs allocate a TTY" "$out" "docker run -it"
[[ "$out" != *CODE_AGENT_HEADLESS* ]]; assert "interactive runs are not headless" "$?"

# --headless: one-shot, no TTY, and the agent's non-interactive form
out=$(PATH="$stub_docker:$PATH" "$code_it" -c --headless "fix the build" "${common_args[@]}")
assert_contains "claude --headless uses -p" "$out" 'code-it-alpine-dotnet-node:latest -p fix\ the\ build'
assert_contains "--headless passes CODE_AGENT_HEADLESS" "$out" "-e CODE_AGENT_HEADLESS=1"
assert_contains "--headless allocates no TTY" "$out" "docker run -i --rm"
out=$(PATH="$stub_docker:$PATH" "$code_it" -o --headless "fix the build" "${common_args[@]}")
assert_contains "opencode (v2) --headless uses standalone run" "$out" 'code-it-alpine-dotnet-node:latest run --standalone fix\ the\ build'
out=$(PATH="$stub_docker:$PATH" "$code_it" --agent opencode-v1 --headless "fix the build" "${common_args[@]}")
assert_contains "opencode-v1 --headless uses run" "$out" 'code-it-alpine-dotnet-node:latest run fix\ the\ build'
out=$(PATH="$stub_docker:$PATH" "$code_it" -o --headless "${common_args[@]}" -- --session abc)
assert_contains "opencode (v2) headless no-prompt still runs headless" "$out" 'code-it-alpine-dotnet-node:latest run --standalone --session abc'

# -- passes the rest to the agent verbatim
out=$(PATH="$stub_docker:$PATH" "$code_it" -c "${common_args[@]}" -- --continue --model opus)
assert_contains "-- passes agent flags through" "$out" "code-it-alpine-dotnet-node:latest --continue --model opus"
out=$(PATH="$stub_docker:$PATH" "$code_it" -c --headless --prompt "tidy" "${common_args[@]}" -- --max-turns 5)
assert_contains "agent flags precede the prompt for claude" "$out" "code-it-alpine-dotnet-node:latest -p --max-turns 5 tidy"
out=$(PATH="$stub_docker:$PATH" "$code_it" --agent opencode-v1 --headless --prompt "tidy" "${common_args[@]}" -- --model opus)
assert_contains "agent flags follow run for opencode-v1" "$out" "code-it-alpine-dotnet-node:latest run --model opus tidy"
out=$(PATH="$stub_docker:$PATH" "$code_it" -o --headless --prompt "tidy" "${common_args[@]}" -- --model example/coder)
assert_contains "opencode (v2) headless flags precede the prompt" "$out" "code-it-alpine-dotnet-node:latest run --standalone --model example/coder tidy"
out=$(PATH="$stub_docker:$PATH" "$code_it" -o --headless "${common_args[@]}" -- --session abc)
assert_contains "opencode (v2) headless with no prompt still uses run" "$out" "code-it-alpine-dotnet-node:latest run --standalone --session abc"
# --headless without a prompt leaves the agent command to the caller
out=$(PATH="$stub_docker:$PATH" "$code_it" -c --headless "${common_args[@]}" -- -p "count the files")
assert_contains "--headless with no prompt adds no -p of its own" "$out" 'code-it-alpine-dotnet-node:latest -p count\ the\ files'

# The prompt reaches the container as a single argument
out=$(PATH="$stub_darwin:$stub_container:$PATH" "$code_it" -c "explain this repo" --work-dir "$script_dir" --save-dir "$save")
assert_contains "prompt is passed as one argument" "$out" "[code-it-alpine-dotnet-node:latest][explain this repo]"
out=$(PATH="$stub_darwin:$stub_container:$PATH" "$code_it" -c --headless "fix it" --work-dir "$script_dir" --save-dir "$save")
assert_contains "headless run passes -i and the agent args" "$out" "[-i][--rm]"
assert_contains "headless run passes the prompt after -p" "$out" "[code-it-alpine-dotnet-node:latest][-p][fix it]"

# Two bare prompts is a mistake worth reporting
out=$(PATH="$stub_docker:$PATH" "$code_it" -c "one" "two" "${common_args[@]}" 2>&1)
[[ "$?" != "0" ]]; assert "two bare prompts fails" "$?"
assert_contains "two bare prompts explains itself" "$out" "Only one prompt"

# ---------------------------------------------------------------------------
echo "13b. --no-agent: a plain zsh shell instead of a coding agent"
out=$(PATH="$stub_docker:$PATH" "$code_it" --no-agent "${common_args[@]}")
assert_contains "--no-agent passes CODE_AGENT_SHELL" "$out" "-e CODE_AGENT_SHELL=1"
[[ "$out" != *CODE_AGENT=* ]]; assert "--no-agent passes no CODE_AGENT" "$?"
[[ "$out" == *"code-it-alpine-dotnet-node:latest" ]]; assert "--no-agent appends nothing after the image" "$?"
assert_contains "--no-agent stays interactive" "$out" "docker run -it"
assert_contains "--no-agent says it runs no agent" "$out" "Using code agent: none (zsh shell)"
case "$out" in
    *.config/opencode*) assert "--no-agent mounts no agent state" 1 ;;
    *)                  assert "--no-agent mounts no agent state" 0 ;;
esac
out=$(PATH="$stub_docker:$PATH" "$code_it" --zsh "${common_args[@]}")
assert_contains "--zsh is --no-agent" "$out" "-e CODE_AGENT_SHELL=1"
# No agent to give a prompt to, and nothing to run headlessly
out=$(PATH="$stub_docker:$PATH" "$code_it" --no-agent "explain this repo" "${common_args[@]}" 2>&1)
[[ "$?" != "0" ]]; assert "--no-agent with a prompt fails" "$?"
out=$(PATH="$stub_docker:$PATH" "$code_it" --no-agent --headless "${common_args[@]}" 2>&1)
[[ "$?" != "0" ]]; assert "--no-agent with --headless fails" "$?"

# ---------------------------------------------------------------------------
echo "14. Bash tab completion"
completions_out=$(
    source "$script_dir/completions/code-it.bash"
    comp() {
        COMP_WORDS=("$@")
        COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
        COMPREPLY=()
        _code_it
        (( ${#COMPREPLY[@]} )) && printf '%s\n' "${COMPREPLY[@]}"
    }
    echo "OPTS:$(comp ./code-it.sh --he | tr '\n' ' ')"
    echo "RUNTIME:$(comp ./code-it.sh --runtime '' | tr '\n' ' ')"
    echo "FREETEXT:$(comp ./code-it.sh --prompt '' | tr '\n' ' ')"
    echo "RUNOPTS:$(comp ./code-it.sh --env | tr '\n' ' ')"
    echo "ENVNAME:$(PATH_FOR_COMPLETION_TEST=1 comp ./code-it.sh -e PATH_FOR_COMP | tr '\n' ' ')"
    echo "RUNARG:$(comp ./code-it.sh --run-arg '' | tr '\n' ' ')"
    echo "CLAUDEALIAS:$(comp ./claude-it.sh -- --mod | tr '\n' ' ')"
    echo "CLAUDEFLAG:$(comp ./code-it.sh -c -- --perm | tr '\n' ' ')"
    echo "CLAUDEMODE:$(comp ./code-it.sh -c -- --permission-mode '' | tr '\n' ' ')"
    echo "OPENCODEDEF:$(comp ./code-it.sh -- --sta | tr '\n' ' ')"
    echo "OPENCODEALIAS:$(comp ./opencode-it.sh -- --se | tr '\n' ' ')"
    echo "OPENCODEV1:$(comp ./code-it.sh --agent opencode-v1 -- --th | tr '\n' ' ')"
    echo "NOAGENT:$(comp ./code-it.sh --no- | tr '\n' ' ')"
)
assert_contains "completes launcher options" "$completions_out" "OPTS:--headless"
assert_contains "completes --no-agent and --zsh" "$completions_out" "NOAGENT:--no-agent"
assert_contains "completes --runtime values" "$completions_out" "RUNTIME:docker container"
assert_contains "offers nothing for a free-text --prompt" "$completions_out" "FREETEXT:
"
assert_contains "completes --env and --env-file" "$completions_out" "RUNOPTS:--env --env-file"
assert_contains "completes --env with environment variable names" "$completions_out" "ENVNAME:PATH_FOR_COMPLETION_TEST"
assert_contains "offers nothing for a free-text --run-arg" "$completions_out" "RUNARG:
"
assert_contains "claude-it.sh completes claude flags after --" "$completions_out" "CLAUDEALIAS:--model"
assert_contains "-c completes claude flags after --" "$completions_out" "CLAUDEFLAG:--permission-mode"
assert_contains "completes claude --permission-mode values" "$completions_out" "CLAUDEMODE:default acceptEdits"
assert_contains "defaults to opencode (v2) flags after --" "$completions_out" "OPENCODEDEF:--standalone"
assert_contains "opencode-it.sh completes opencode (v2) flags after --" "$completions_out" "OPENCODEALIAS:--server"
assert_contains "opencode-v1 completes v1 flags after --" "$completions_out" "OPENCODEV1:--thinking"

# ---------------------------------------------------------------------------
echo "15. Container entrypoint (go.sh) passes its arguments to the agent"
if command -v zsh &>/dev/null; then
    # Lift go.sh out of the Dockerfile and point it at stubs instead of the image's
    # own paths, so the entrypoint's argument handling can be tested on the host.
    gowork="$tmp/gowork"; gobin="$tmp/gobin"
    mkdir -p "$gowork/repo" "$gobin"
    sed -n "/^RUN cat <<'EOF' >> ~\/go.sh$/,/^EOF$/p" "$script_dir/Dockerfile" \
        | sed '1d;$d' \
        | sed -e "s#/etc/code-it-agents#$gobin/agents#" \
              -e "s#/work#$gowork#g" > "$tmp/go.sh"
    chmod +x "$tmp/go.sh"
    [[ -s "$tmp/go.sh" ]]; assert "go.sh extracted from the Dockerfile" "$?"

    for agent in claude opencode opencode-v1; do
        cat > "$gobin/$agent" <<EOF
#!/bin/sh
printf 'AGENT-$agent'
printf '[%s]' "\$@"
echo
EOF
        chmod +x "$gobin/$agent"
    done
    # go.sh resolves the agent binary from the build-time name=binary map
    printf 'opencode=%s/opencode\nclaude=%s/claude\nopencode-v1=%s/opencode-v1\n' "$gobin" "$gobin" "$gobin" > "$gobin/agents"
    # tmux takes the command as one string: run it, so what the agent receives is visible
    cat > "$gobin/tmux" <<'EOF'
#!/bin/sh
case "$*" in *" -d"*) exit 0 ;; esac
for a in "$@"; do last="$a"; done
eval "$last"
EOF
    chmod +x "$gobin/tmux"
    cat > "$gobin/git" <<'EOF'
#!/bin/sh
if [ -n "${GIT_CALLS:-}" ]; then printf '%s\n' "$*" >> "$GIT_CALLS"; fi
exit 0
EOF
    chmod +x "$gobin/git"

    git_calls="$tmp/git-calls"
    : > "$git_calls"
    out=$(PATH="$gobin:$PATH" GIT_CALLS="$git_calls" CODE_AGENT=claude zsh "$tmp/go.sh" 2>&1)
    assert_contains "go.sh upgrades mounted repo indexes to version 4" "$(<"$git_calls")" "-C $gowork/repo/ update-index --index-version 4"
    assert_contains "go.sh runs the chosen agent in tmux" "$out" "AGENT-claude"
    out=$(PATH="$gobin:$PATH" CODE_AGENT=opencode zsh "$tmp/go.sh" --prompt "explain this repo" 2>&1)
    assert_contains "go.sh forwards arguments through tmux, unsplit" "$out" "AGENT-opencode[--prompt][explain this repo]"
    out=$(PATH="$gobin:$PATH" CODE_AGENT=opencode CODE_AGENT_HEADLESS=1 zsh "$tmp/go.sh" run --standalone "fix the build" 2>&1)
    assert_contains "go.sh runs opencode (v2) with translated arguments" "$out" "AGENT-opencode[run][--standalone][fix the build]"
    out=$(PATH="$gobin:$PATH" CODE_AGENT=opencode-v1 zsh "$tmp/go.sh" --prompt "explain this repo" 2>&1)
    assert_contains "go.sh runs opencode-v1 with its arguments" "$out" "AGENT-opencode-v1[--prompt][explain this repo]"
    out=$(PATH="$gobin:$PATH" CODE_AGENT=claude CODE_AGENT_HEADLESS=1 zsh "$tmp/go.sh" -p "fix it; rm -rf /" 2>&1)
    assert_contains "headless go.sh runs the agent directly" "$out" "AGENT-claude[-p][fix it; rm -rf /]"
    [[ "$out" != *AGENT-claude*AGENT-claude* ]]; assert "headless go.sh does not also start tmux" "$?"
    # CODE_AGENT_SHELL=1 (code-it --no-agent) runs a plain zsh, never an installed agent.
    # This tmux stub prints the shell command instead of running it.
    shellstub="$tmp/goshell"; mkdir -p "$shellstub"
    cat > "$shellstub/tmux" <<'EOF'
#!/bin/sh
for a in "$@"; do last="$a"; done
printf 'TMUX-CMD:%s\n' "$last"
EOF
    chmod +x "$shellstub/tmux"
    out=$(PATH="$shellstub:$gobin:$PATH" CODE_AGENT_SHELL=1 zsh "$tmp/go.sh" 2>&1)
    assert_contains "go.sh --no-agent runs zsh in tmux" "$out" "TMUX-CMD:zsh"
    [[ "$out" != *AGENT-* ]]; assert "go.sh --no-agent runs no agent" "$?"
    # an agent missing from the image is an error, never another agent given its arguments
    printf 'claude=%s/claude\n' "$gobin" > "$gobin/agents"
    out=$(PATH="$gobin:$PATH" CODE_AGENT=opencode zsh "$tmp/go.sh" --prompt "hi" 2>&1)
    [[ "$?" != "0" ]]; assert "go.sh fails for an agent the image lacks" "$?"
    assert_contains "go.sh names the missing agent" "$out" "Agent 'opencode' is not installed in this image. It has: claude"
    [[ "$out" != *AGENT-claude* ]]; assert "go.sh does not fall back to another agent" "$?"
    printf 'claude=%s/no-such-claude\n' "$gobin" > "$gobin/agents"
    out=$(PATH="$gobin:$PATH" CODE_AGENT=claude zsh "$tmp/go.sh" 2>&1)
    [[ "$?" != "0" ]]; assert "go.sh fails when the agent binary is missing" "$?"
    assert_contains "go.sh reports the missing binary" "$out" "no-such-claude is missing from this image"
else
    echo "  skip: go.sh tests (no zsh)"
fi

# ---------------------------------------------------------------------------
echo "16. code-it-add-agent"
add_agent="$script_dir/code-it-add-agent.sh"
stub_ci="$tmp/stub-code-it.sh"
cat > "$stub_ci" <<'EOF'
#!/bin/sh
echo "STUB-CODE-IT $*"
exit "${STUB_CODE_IT_EXIT:-0}"
EOF
chmod +x "$stub_ci"

mkrepo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" config user.email a@b.c
    git -C "$d" config user.name T
    echo x > "$d/x"
    git -C "$d" add -A
    git -C "$d" commit -qm init
}

# (a) --dry-run prints the prompt and the command, and changes nothing
repo_a="$tmp/addagent-a"; mkrepo "$repo_a"
out=$(PATH="$stub_docker:$PATH" "$add_agent" cursor --repo "$repo_a" --code-it "$stub_ci" --dry-run 2>&1)
assert "add-agent --dry-run exit code" "$?"
assert_contains "add-agent prompt names the agent" "$out" "Agent to add: cursor"
assert_contains "add-agent prompt includes the gate" "$out" "Gate first"
assert_contains "add-agent prompt requires an official install channel" "$out" "official install channel"
assert_contains "add-agent dry-run prints the command" "$out" "code-it.sh"
assert_contains "add-agent dry-run prints code-it --headless" "$out" "--headless"
[[ -z "$(git -C "$repo_a" branch --list 'add-agent/*')" ]]; assert "add-agent --dry-run creates no branch" "$?"

# (b) --url is included in the prompt
out=$(PATH="$stub_docker:$PATH" "$add_agent" cursor --url "https://docs.example/cursor" --repo "$repo_a" --code-it "$stub_ci" --dry-run 2>&1)
assert_contains "add-agent prompt includes the docs URL" "$out" "https://docs.example/cursor"

# (c) a dirty repo is refused
printf 'y\n' >> "$repo_a/x"
PATH="$stub_docker:$PATH" "$add_agent" cursor --repo "$repo_a" --code-it "$stub_ci" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "add-agent refuses a dirty repo" "$?"
git -C "$repo_a" checkout -q -- .

# (d) it creates the branch, runs code-it, and prints the branch and summary
out=$(PATH="$stub_docker:$PATH" "$add_agent" cursor --repo "$repo_a" --code-it "$stub_ci" 2>&1)
assert "add-agent run exit code" "$?"
assert_contains "add-agent runs code-it headless" "$out" "STUB-CODE-IT"
[[ "$(git -C "$repo_a" rev-parse --abbrev-ref HEAD)" == "add-agent/cursor" ]]
assert "add-agent checks out the new branch" "$?"
assert_contains "add-agent prints the branch" "$out" "Branch: add-agent/cursor"
assert_contains "add-agent prints a changes summary" "$out" "Changes:"

# (e) a non-zero code-it exit (the gate refusal) is propagated
repo_b="$tmp/addagent-b"; mkrepo "$repo_b"
STUB_CODE_IT_EXIT=3 PATH="$stub_docker:$PATH" "$add_agent" cursor --repo "$repo_b" --code-it "$stub_ci" >/dev/null 2>&1
[[ "$?" == "3" ]]; assert "add-agent propagates a non-zero gate refusal" "$?"

# (f) an existing branch is refused
repo_c="$tmp/addagent-c"; mkrepo "$repo_c"
git -C "$repo_c" branch "add-agent/cursor"
PATH="$stub_docker:$PATH" "$add_agent" cursor --repo "$repo_c" --code-it "$stub_ci" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "add-agent refuses an existing branch" "$?"

# ---------------------------------------------------------------------------
echo "17. code-it-add-toolchain"
add_tc="$script_dir/code-it-add-toolchain.sh"

# (a) --dry-run prints the prompt (with the security gate) and the command
repo_d="$tmp/addtc-a"; mkrepo "$repo_d"
out=$(PATH="$stub_docker:$PATH" "$add_tc" java --repo "$repo_d" --code-it "$stub_ci" --dry-run 2>&1)
assert "add-toolchain --dry-run exit code" "$?"
assert_contains "add-toolchain prompt names the toolchain" "$out" "Toolchain to add: java"
assert_contains "add-toolchain prompt includes the gate" "$out" "Gate first"
assert_contains "add-toolchain prompt requires a secure install" "$out" "installs securely"
assert_contains "add-toolchain prompt requires musl builds" "$out" "musl builds for x86_64 and aarch64"
assert_contains "add-toolchain dry-run prints the command" "$out" "--headless"
[[ -z "$(git -C "$repo_d" branch --list 'add-toolchain/*')" ]]; assert "add-toolchain --dry-run creates no branch" "$?"

# (b) --url is included
out=$(PATH="$stub_docker:$PATH" "$add_tc" java --url "https://openjdk.org/install/" --repo "$repo_d" --code-it "$stub_ci" --dry-run 2>&1)
assert_contains "add-toolchain prompt includes the docs URL" "$out" "https://openjdk.org/install/"

# (c) dirty repo refusal
printf 'y\n' >> "$repo_d/x"
PATH="$stub_docker:$PATH" "$add_tc" java --repo "$repo_d" --code-it "$stub_ci" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "add-toolchain refuses a dirty repo" "$?"
git -C "$repo_d" checkout -q -- .

# (d) branch creation and summary
out=$(PATH="$stub_docker:$PATH" "$add_tc" java --repo "$repo_d" --code-it "$stub_ci" 2>&1)
assert "add-toolchain run exit code" "$?"
[[ "$(git -C "$repo_d" rev-parse --abbrev-ref HEAD)" == "add-toolchain/java" ]]
assert "add-toolchain checks out the new branch" "$?"
assert_contains "add-toolchain prints the branch" "$out" "Branch: add-toolchain/java"

# (e) gate refusal exit code is propagated
repo_e="$tmp/addtc-b"; mkrepo "$repo_e"
STUB_CODE_IT_EXIT=4 PATH="$stub_docker:$PATH" "$add_tc" java --repo "$repo_e" --code-it "$stub_ci" >/dev/null 2>&1
[[ "$?" == "4" ]]; assert "add-toolchain propagates a gate refusal" "$?"

# ---------------------------------------------------------------------------
echo "18. code-it-first-run"
first_run="$script_dir/code-it-first-run.sh"
stub_first_build="$tmp/stub-first-build.sh"
cat > "$stub_first_build" <<'EOF'
#!/bin/sh
selection_file="" toolchain=node agents=opencode dry_run=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --selection-file) selection_file="$2"; shift 2 ;;
        --toolchain) toolchain="$2"; shift 2 ;;
        --agent) agents="$2"; shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        *) shift ;;
    esac
done
printf 'toolchains=%s\nagents=%s\n' "$toolchain" "$agents" > "$selection_file"
[ "$dry_run" = true ] || touch "$STUB_FIRST_BUILD_MARKER"
echo "STUB-FIRST-BUILD"
EOF
chmod +x "$stub_first_build"

firsthome="$tmp/firsthome"; mkdir -p "$firsthome"

out=$(HOME="$firsthome" STUB_FIRST_BUILD_MARKER="$tmp/first-build-ran" PATH="$stub_docker:$PATH" \
        bash "$first_run" --yes --dry-run --toolchain node --agents opencode \
        --code-it-build "$stub_first_build" 2>&1)
assert "first-run delegation exit code" "$?"
assert_contains "first-run asks build to own selection" "$out" "--interactive"
assert_contains "first-run forwards the explicit toolchain" "$out" "--toolchain node"
assert_contains "first-run forwards the explicit agent" "$out" "--agent opencode"
assert_contains "first-run forwards yes and dry-run" "$out" "--yes --dry-run"
[[ ! -e "$tmp/first-build-ran" ]]; assert "first-run dry-run does not build" "$?"

# (d) copy carries state over but never overwrites
fh="$tmp/firstcopy-home"; fs="$tmp/firstcopy-save"
mkdir -p "$fh/.config/opencode" "$fs/.config/opencode"
echo ORIGINAL > "$fh/.config/opencode/config.json"
echo NEW > "$fh/.config/opencode/new.json"
echo KEEP > "$fs/.config/opencode/config.json"
out=$(HOME="$fh" STUB_FIRST_BUILD_MARKER="$tmp/first-build-ran" PATH="$stub_docker:$PATH" bash "$first_run" --yes --toolchain node --agents opencode-v1 \
        --save-dir "$fs" --code-it-build "$stub_first_build" 2>&1)
assert "first-run copy exit code" "$?"
assert_contains "first-run invoked the build" "$out" "STUB-FIRST-BUILD"
[[ "$(cat "$fs/.config/opencode/config.json")" == "KEEP" ]]; assert "first-run never overwrites existing state" "$?"
[[ "$(cat "$fs/.config/opencode/new.json")" == "NEW" ]]; assert "first-run copies missing state" "$?"
assert_contains "first-run warns that credentials are copied" "$out" "credentials"
assert_contains "first-run prints the start command" "$out" "code-it.sh --agent opencode-v1"
# an agent with AGENT_SAVE_SUBDIR (opencode, v2, whose state lives under opencode-v2/)
# gets its copy in that subdirectory
out=$(HOME="$fh" STUB_FIRST_BUILD_MARKER="$tmp/first-build-ran" PATH="$stub_docker:$PATH" bash "$first_run" --yes --toolchain node --agents opencode \
        --save-dir "$fs" --code-it-build "$stub_first_build" 2>&1)
[[ "$(cat "$fs/opencode-v2/.config/opencode/config.json")" == "ORIGINAL" ]]
assert "first-run copies opencode (v2) state into its save subdir" "$?"

# (e) --dry-run makes no changes and copies nothing
rm -f "$tmp/first-build-ran"
fd="$tmp/firstdry"; mkdir -p "$fd"
out=$(HOME="$fh" STUB_FIRST_BUILD_MARKER="$tmp/first-build-ran" PATH="$stub_docker:$PATH" bash "$first_run" --yes --dry-run --toolchain node --agents opencode \
        --save-dir "$fd/save" --code-it-build "$stub_first_build" 2>&1)
[[ ! -e "$fd/save" ]]; assert "first-run --dry-run creates no save dir" "$?"
assert_contains "first-run --dry-run says build was delegated" "$out" "--dry-run"
assert_contains "first-run --dry-run says what it would copy" "$out" "would copy"
[[ ! -e "$tmp/first-build-ran" ]]; assert "first-run --dry-run ran no build" "$?"

# ---------------------------------------------------------------------------
echo "19. Image memory and default toolchains"
histbin="$tmp/histbin"; mkdir -p "$histbin"
cat > "$histbin/docker" <<'EOF'
#!/bin/sh
case "$1" in
    images) printf '%s\n' code-it-alpine-dotnet:latest code-it-alpine-dotnet-node:latest code-it-alpine-python:latest code-it-alpine-dotnet-node-cobol:latest code-it-alpine-dotnet-node-powershell:latest ;;
    image)
        for a in "$@"; do last="$a"; done
        case "$last" in
            *python*)      echo python ;;
            *cobol*)       echo dotnet,node,cobol ;;
            *powershell*)  echo dotnet,node,powershell ;;
            *dotnet-node*) echo dotnet,node ;;
            *dotnet*)      echo dotnet ;;
            *)             echo "" ;;
        esac ;;
    run)   echo "HIST-RUN $*" ;;
    build) echo "HIST-BUILD $*" ;;
    *)     echo "STUB $*" ;;
esac
EOF
chmod +x "$histbin/docker"

stub_first_run="$tmp/stub-first-run.sh"
cat > "$stub_first_run" <<'EOF'
#!/bin/sh
echo "STUB-FIRST-RUN $*"
exit 0
EOF
chmod +x "$stub_first_run"

# (a) save dir exists with history: the 70% weighted rule (Spec 09) chooses
hsel="$tmp/histselect"; mkdir -p "$hsel"
printf '20260101 code-it-alpine-dotnet-node\n20260102 code-it-alpine-python\n20260103 code-it-alpine-python\n20260104 code-it-alpine-python\n20260105 code-it-alpine-python\n' > "$hsel/image-history"
out=$(PATH="$histbin:$PATH" "$code_it" --dry-run --work-dir "$script_dir" --save-dir "$hsel" 2>&1)
assert "default selection exit code" "$?"
assert_contains "uses the remembered image (70% rule)" "$out" "Using remembered image: code-it-alpine-python"
assert_contains "runs that image" "$out" "code-it-alpine-python:latest"

# (b) explicit --toolchain bypasses the default selection
out=$(PATH="$histbin:$PATH" "$code_it" --dry-run --work-dir "$script_dir" --save-dir "$hsel" --toolchain dotnet 2>&1)
case "$out" in
    *"Using remembered image"*|*"Using existing image"*) assert "explicit --toolchain bypasses the default" 1 ;;
    *)                                                   assert "explicit --toolchain bypasses the default" 0 ;;
esac
assert_contains "explicit --toolchain is honoured" "$out" "code-it-alpine-dotnet:latest"

# (c) explicit --image bypasses the default selection
out=$(PATH="$histbin:$PATH" "$code_it" --dry-run --work-dir "$script_dir" --save-dir "$hsel" --image code-it-alpine-dotnet-node 2>&1)
case "$out" in
    *"Using remembered image"*|*"Using existing image"*) assert "explicit --image bypasses the default" 1 ;;
    *)                                                   assert "explicit --image bypasses the default" 0 ;;
esac

# (k) a remembered image labelled with a toolchain this checkout does not know (built
# by another branch) is still used, for the chains that are known
hunk="$tmp/histunknown"; mkdir -p "$hunk"
printf '20260101 code-it-alpine-dotnet-node-cobol\n' > "$hunk/image-history"
out=$(PATH="$histbin:$PATH" "$code_it" --dry-run --work-dir "$script_dir" --save-dir "$hunk" 2>&1)
assert "an unknown chain in the remembered image's label is not an error" "$?"
[[ "$out" != *"Unknown toolchain"* ]]; assert "an unknown label chain gives no unknown-toolchain warning" "$?"
assert_contains "notes the unknown label chain" "$out" "has toolchains this code-it does not know (dotnet,node,cobol); using dotnet,node"
assert_contains "runs the image with the unknown label chain" "$out" "code-it-alpine-dotnet-node-cobol:latest"
assert_contains "the known label chains decide the package caches" "$out" "NuGet package cache"

# (l) powershell is a known chain: its remembered image is used with no note
hpwsh="$tmp/histpwsh"; mkdir -p "$hpwsh"
printf '20260101 code-it-alpine-dotnet-node-powershell\n20260102 code-it-alpine-dotnet-node-powershell\n' > "$hpwsh/image-history"
out=$(PATH="$histbin:$PATH" "$code_it" --dry-run --work-dir "$script_dir" --save-dir "$hpwsh" 2>&1)
assert_contains "uses the remembered powershell image" "$out" "Using remembered image: code-it-alpine-dotnet-node-powershell"
[[ "$out" != *"does not know"* ]]; assert "powershell in a label is known" "$?"

# (d) save dir exists but no history: the most recently built existing code-it image
hnone="$tmp/histnone"; mkdir -p "$hnone"
out=$(PATH="$histbin:$PATH" "$code_it" --dry-run --work-dir "$script_dir" --save-dir "$hnone" 2>&1)
assert_contains "no history: uses the most recently built existing image" "$out" "Using existing image: code-it-alpine-dotnet"
assert_contains "no history: runs that image" "$out" "code-it-alpine-dotnet:latest"

# (j) history exists but no remembered image covers 70%: fall back to the most recent
# existing code-it image
hfall="$tmp/histfallback"; mkdir -p "$hfall"
printf '20260101 code-it-alpine-dotnet\n20260102 code-it-alpine-node\n20260103 code-it-alpine-bun\n20260104 code-it-alpine-python\n20260105 code-it-alpine-dotnet\n' > "$hfall/image-history"
out=$(PATH="$histbin:$PATH" "$code_it" --dry-run --work-dir "$script_dir" --save-dir "$hfall" 2>&1)
assert_contains "no 70% cover: falls back to an existing image" "$out" "Using existing image: code-it-alpine-dotnet"
assert_contains "no 70% cover: runs that image" "$out" "code-it-alpine-dotnet:latest"

# (g) save dir missing: run first-run
ns="$tmp/nosave-first-run"
out=$(CODE_IT_FIRST_RUN="$stub_first_run" PATH="$histbin:$PATH" "$code_it" --work-dir "$script_dir" --save-dir "$ns" 2>&1)
assert "missing save dir exits 0 via first-run" "$?"
assert_contains "missing save dir runs first-run" "$out" "STUB-FIRST-RUN"
assert_contains "first-run is given --save-dir" "$out" "--save-dir"

# (h) save dir exists but no code-it image: run first-run
emptybin="$tmp/emptybin"; mkdir -p "$emptybin"
# docker images succeeds with no output, but image inspect fails (no such image)
printf '#!/bin/sh\ncase "$1" in image) exit 1;; esac\nexit 0\n' > "$emptybin/docker"; chmod +x "$emptybin/docker"
out=$(CODE_IT_FIRST_RUN="$stub_first_run" PATH="$emptybin:$PATH" "$code_it" --work-dir "$script_dir" --save-dir "$hsel" 2>&1)
assert_contains "no code-it image runs first-run" "$out" "STUB-FIRST-RUN"

# (i) --dry-run with a missing save dir: report, do not run first-run
out=$(CODE_IT_FIRST_RUN="$stub_first_run" PATH="$histbin:$PATH" "$code_it" --dry-run --work-dir "$script_dir" --save-dir "$tmp/nosave-first-run2" 2>&1)
assert_contains "dry-run says it would run first-run" "$out" "would run"
case "$out" in
    *STUB-FIRST-RUN*) assert "dry-run does not run first-run" 1 ;;
    *)                assert "dry-run does not run first-run" 0 ;;
esac

# (e) every non-dry-run invocation is recorded, keeping only the newest 15
hrec="$tmp/histrecord"; mkdir -p "$hrec"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    printf '202601%02d code-it-alpine-dotnet-node\n' "$i" >> "$hrec/image-history"
done
oldest_before=$(head -1 "$hrec/image-history")
PATH="$histbin:$PATH" "$code_it" --work-dir "$script_dir" --save-dir "$hrec" --toolchain dotnet,node >/dev/null 2>&1
assert "history recording run exit code" "$?"
[[ "$(wc -l < "$hrec/image-history")" == "15" ]]; assert "history keeps only 15 lines" "$?"
grep -qE "^[0-9]{8} code-it-alpine-dotnet-node$" "$hrec/image-history"
assert "history records 'yyyymmdd image-name'" "$?"
[[ "$(head -1 "$hrec/image-history")" != "$oldest_before" ]]; assert "history forgets the oldest line" "$?"

# (f) --dry-run records nothing
hdry="$tmp/histdry"; mkdir -p "$hdry"
PATH="$histbin:$PATH" "$code_it" --dry-run --work-dir "$script_dir" --save-dir "$hdry" --toolchain dotnet,node >/dev/null 2>&1
[[ ! -e "$hdry/image-history" ]]; assert "--dry-run records no history" "$?"

# ---------------------------------------------------------------------------
echo "20. Locale: --locale, defaulting to the host's"
common_lib="$script_dir/lib/code-it-common.sh"
# Run a command with LC_ALL and LANG unset, so only the ones it is given apply
no_locale_env() { env -u LC_ALL -u LANG "$@"; }

# Windows, macOS and POSIX spellings all become a POSIX UTF-8 name
while IFS='|' read -r raw want; do
    got=$(bash -c '. "$1"; ci_normalise_locale "$2"' _ "$common_lib" "$raw")
    [[ "$got" == "$want" ]]; assert "normalise '$raw' -> '$want' (got '$got')" "$?"
done <<'LOCALES'
en_GB.UTF-8|en_GB.UTF-8
en_GB.utf8|en_GB.UTF-8
en_US.ISO-8859-1|en_US.UTF-8
en-GB|en_GB.UTF-8
sr-Latn-RS|sr_RS.UTF-8@latin
sr_RS@latin|sr_RS.UTF-8@latin
zh-Hans-CN|zh_CN.UTF-8
zh-Hans_CN|zh_CN.UTF-8
en_GB@rg=gbzzzz|en_GB.UTF-8
de_DE@euro|de_DE.UTF-8
es-419|es.UTF-8
fr|fr.UTF-8
C|C.UTF-8
POSIX|C.UTF-8
C.UTF-8|C.UTF-8
LOCALES
for raw in "" 123 x-IV "en GB"; do
    bash -c '. "$1"; ci_normalise_locale "$2"' _ "$common_lib" "$raw" >/dev/null
    [[ "$?" != "0" ]]; assert "normalise rejects '$raw'" "$?"
done

# Host detection, with stub uname (-s and -r), macOS defaults and Windows reg.exe
locale_bin() {
    local dir="$tmp/locale-$1"
    mkdir -p "$dir"
    printf '#!/bin/sh\ncase "$1" in -r) echo "%s" ;; *) echo "%s" ;; esac\n' "$3" "$2" > "$dir/uname"
    printf '#!/bin/sh\n[ "$*" = "read -g AppleLocale" ] && echo "en_AU@rg=auzzzz"\n' > "$dir/defaults"
    # reg.exe prints CRLF lines; it must receive /v unmangled by MSYS path conversion
    cat > "$dir/reg.exe" <<'REG'
#!/bin/sh
[ "$3" = "/v" ] && [ "$4" = "LocaleName" ] || exit 1
printf '\r\nHKEY_CURRENT_USER\\Control Panel\\International\r\n    LocaleName    REG_SZ    de-CH\r\n\r\n'
REG
    chmod +x "$dir/uname" "$dir/defaults" "$dir/reg.exe"
    printf '%s' "$dir"
}
linux_bin=$(locale_bin linux Linux 6.1.0-generic)
wsl_bin=$(locale_bin wsl Linux 6.18.40.1-microsoft-standard-WSL2)
mingw_bin=$(locale_bin mingw MINGW64_NT-10.0 3.4.10)
darwin_bin=$(locale_bin darwin Darwin 23.0.0)
# resolve_locale PATH_PREFIX RAW [VAR=VALUE...]: ci_resolve_locale RAW in a fresh bash
resolve_locale() {
    local bin="$1" raw="$2"
    shift 2
    no_locale_env "$@" PATH="$bin:$PATH" bash -c '. "$1"; ci_resolve_locale "$2"' _ "$common_lib" "$raw"
}

out=$(resolve_locale "$linux_bin" like-host LANG=fr_FR.UTF-8)
[[ "$out" == "fr_FR.UTF-8" ]]; assert "like-host reads LANG (got '$out')" "$?"
out=$(resolve_locale "$linux_bin" "" LC_ALL=it_IT.UTF-8 LANG=fr_FR.UTF-8)
[[ "$out" == "it_IT.UTF-8" ]]; assert "LC_ALL wins over LANG, and empty means like-host (got '$out')" "$?"
out=$(resolve_locale "$linux_bin" like-host LANG=C.UTF-8)
[[ "$out" == "C.UTF-8" ]]; assert "Linux with only C.UTF-8 falls back to C.UTF-8 (got '$out')" "$?"
out=$(resolve_locale "$darwin_bin" like-host LANG=C.UTF-8)
[[ "$out" == "en_AU.UTF-8" ]]; assert "macOS falls back to AppleLocale (got '$out')" "$?"
out=$(resolve_locale "$mingw_bin" like-host)
[[ "$out" == "de_CH.UTF-8" ]]; assert "Git Bash reads the Windows locale from the registry (got '$out')" "$?"
out=$(resolve_locale "$wsl_bin" like-host LANG=C.UTF-8)
[[ "$out" == "de_CH.UTF-8" ]]; assert "WSL with only C.UTF-8 reads the Windows locale (got '$out')" "$?"
out=$(resolve_locale "$wsl_bin" like-host LANG=pt_BR.UTF-8)
[[ "$out" == "pt_BR.UTF-8" ]]; assert "WSL with a real LANG keeps it (got '$out')" "$?"
out=$(resolve_locale "$linux_bin" nb-NO LANG=fr_FR.UTF-8)
[[ "$out" == "nb_NO.UTF-8" ]]; assert "an explicit locale overrides the host's (got '$out')" "$?"
resolve_locale "$linux_bin" '!!' >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "an unreadable locale is an error" "$?"

# code-it-build passes the locale as a build arg and labels the image with it
out=$(LANG=en_GB.UTF-8 PATH="$linux_bin:$stub_docker:$PATH" "$build_it" --toolchain dotnet,node --dry-run --dockerfile-dir "$script_dir" 2>&1)
assert_contains "build defaults LOCALE to the host's" "$out" "--build-arg LOCALE=en_GB.UTF-8"
assert_contains "build labels the image's locale" "$out" "--label code-it.locale=en_GB.UTF-8"
out=$(PATH="$stub_docker:$PATH" "$build_it" --toolchain dotnet,node --dry-run --dockerfile-dir "$script_dir" --locale de-DE 2>&1)
assert_contains "build --locale translates a Windows name" "$out" "--build-arg LOCALE=de_DE.UTF-8"
out=$(PATH="$stub_docker:$PATH" "$build_it" --toolchain dotnet,node --dry-run --dockerfile-dir "$script_dir" -l C 2>&1)
assert_contains "build -l is the short form" "$out" "--build-arg LOCALE=C.UTF-8"
PATH="$stub_docker:$PATH" "$build_it" --toolchain dotnet,node --dry-run --dockerfile-dir "$script_dir" --locale '!!' >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "code-it-build unreadable --locale fails" "$?"
grep -q '^ARG LOCALE=C.UTF-8$' "$script_dir/Dockerfile" && grep -q '^ENV LANG=\$LOCALE$' "$script_dir/Dockerfile"
assert "Dockerfile sets LANG from the LOCALE build arg" "$?"

# code-it passes the locale to the run
out=$(LANG=en_GB.UTF-8 PATH="$linux_bin:$stub_docker:$PATH" "$code_it" "${common_args[@]}" --toolchain dotnet,node 2>&1)
assert_contains "code-it runs with the host's locale" "$out" '-e LANG="en_GB.UTF-8"'
out=$(PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}" --toolchain dotnet,node --locale sv-SE 2>&1)
assert_contains "code-it --locale sets the run's LANG" "$out" '-e LANG="sv_SE.UTF-8"'
PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}" --toolchain dotnet,node --locale '!!' >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "code-it unreadable --locale fails" "$?"

# ---------------------------------------------------------------------------
echo "21. Extra run arguments: --env, --env-file, --run-arg and SAVE-DIR/run-args"
ra_save="$tmp/run-args-save"; mkdir -p "$ra_save"
ra_args=(--work-dir "$script_dir" --save-dir "$ra_save" --toolchain dotnet)
ra_envfile="$tmp/proxy.env"; echo "HTTP_PROXY=http://proxy:8080" > "$ra_envfile"

# (a) each option becomes run arguments, in command-line order, after code-it's own
out=$(PATH="$stub_docker:$PATH" "$code_it" "${ra_args[@]}" --dry-run \
    --env FOO=1 -e BAR --env-file "$ra_envfile" --run-arg --network=host --docker-arg --dns --docker-arg 10.0.0.2 2>&1)
assert "dry-run with extra run arguments exit code" "$?"
assert_contains "--env NAME=VALUE is printed" "$out" "-e FOO=1"
assert_contains "-e NAME is printed without a value" "$out" "-e BAR \\"
assert_contains "--env-file is printed" "$out" "--env-file $ra_envfile"
assert_contains "--run-arg is printed" "$out" "--network=host"
assert_contains "--docker-arg values join their option's line" "$out" "--dns 10.0.0.2 \\"
out=$(BAR=host-bar PATH="$stub_docker:$PATH" "$code_it" "${ra_args[@]}" \
    --env FOO=1 -e BAR --env-file "$ra_envfile" --run-arg --network=host --run-arg "--label=a b" 2>&1)
assert_contains "extra run arguments keep their command-line order" "$out" \
    "-e FOO=1 -e BAR --env-file $ra_envfile --network=host --label=a b"
assert_contains "extra run arguments follow the mounted agent state" "$out" \
    "$ra_save/opencode-v2/.config/opencode:/home/agent1/.config/opencode"
assert_contains "extra run arguments precede the mounted agent data" "$out" \
    "$ra_save/opencode-v2/.local/share/opencode:/home/agent1/.local/share/opencode"
case "$out" in
    *host-bar*) assert "docker reads a bare -e NAME itself, so its value is not passed" 1 ;;
    *)          assert "docker reads a bare -e NAME itself, so its value is not passed" 0 ;;
esac

# (b) bad --env and missing --env-file are errors
PATH="$stub_docker:$PATH" "$code_it" "${ra_args[@]}" --dry-run --env "NOT A NAME=1" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "--env with an invalid name fails" "$?"
PATH="$stub_docker:$PATH" "$code_it" "${ra_args[@]}" --dry-run --env-file "$tmp/no-such.env" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "--env-file that does not exist fails" "$?"

# (c) SAVE-DIR/run-args: one argument per line, trimmed, CRLF, comments and blanks skipped,
# before the command line's
printf '# Behind the office proxy\r\n  -e\r\nHTTPS_PROXY  \r\n\r\n--dns=10.0.0.2\r\n--label=x y\n' > "$ra_save/run-args"
out=$(PATH="$stub_docker:$PATH" "$code_it" "${ra_args[@]}" --env FOO=1 2>&1)
assert_contains "run-args file is reported" "$out" "Using run arguments from $ra_save/run-args"
assert_contains "run-args file comes first, then the command line's" "$out" \
    "-e HTTPS_PROXY --dns=10.0.0.2 --label=x y -e FOO=1"
case "$out" in
    *Behind*) assert "run-args comments are skipped" 1 ;;
    *)        assert "run-args comments are skipped" 0 ;;
esac
out=$(PATH="$stub_docker:$PATH" "$code_it" "${ra_args[@]}" --dry-run 2>&1)
assert_contains "run-args file is printed, quoted" "$out" "--label=x\\ y"
rm "$ra_save/run-args"
out=$(PATH="$stub_docker:$PATH" "$code_it" "${ra_args[@]}" 2>&1)
case "$out" in
    *"Using run arguments"*) assert "no run-args file, no extra arguments" 1 ;;
    *)                       assert "no run-args file, no extra arguments" 0 ;;
esac

# (d) the Apple container CLI is given the host's value for a bare -e NAME, and an
# unset NAME is dropped, as docker does; the printout still shows no value
out=$(BAR=host-bar PATH="$stub_container:$stub_docker:$PATH" "$code_it" -r container "${ra_args[@]}" \
    -e BAR -e UNSET_NAME_FOR_TEST -e FOO=1 --run-arg --env --run-arg BAZ=2 2>&1)
assert_contains "container: bare -e NAME gets the host's value" "$out" "[-e][BAR=host-bar][-e][FOO=1][--env][BAZ=2]"
assert_contains "container: image follows runtime arguments" "$out" "[code-it-alpine-dotnet"
assert_contains "container: printout shows the bare name" "$out" "-e BAR \\"

# (e) the agent's -- arguments still go to the agent, not the runtime
out=$(PATH="$stub_docker:$PATH" "$code_it" "${ra_args[@]}" --run-arg --network=host -- --continue 2>&1)
case "$out" in
    *"--network=host"*"code-it-alpine-"*":latest --continue"*) assert "-- still goes to the agent, after the image" 0 ;;
    *)                                                         assert "-- still goes to the agent, after the image" 1 ;;
esac

# (f) --help documents the options
out=$(PATH="$stub_docker:$PATH" "$code_it" --help)
assert_contains "--help documents --env" "$out" "--env, -e NAME[=VALUE]"
assert_contains "--help documents --env-file" "$out" "--env-file FILE"
assert_contains "--help documents --run-arg" "$out" "--run-arg ARG"
assert_contains "--help documents the run-args file" "$out" "SAVE-DIR/run-args"

# ---------------------------------------------------------------------------
echo
echo "22. Exclusive agent state: one container per opencode session database"
excl="$tmp/save-excl"; mkdir -p "$excl"
excl_args=(--work-dir "$script_dir" --save-dir "$excl")
# opencode-v1 keeps its state at the save-dir root; its lock dir is named for it
excl_locks="$excl/.code-it-instances/opencode-v1"
slot1_mount="-v \"$excl/.local/share/opencode:/home/agent1/.local/share/opencode\""
# A pid that is certainly not running: a child that has already exited
sh -c 'exit 0' & dead_pid=$!; wait "$dead_pid"

# (a) no lock: slot 1, no warning, and a dry run takes no lock
out=$(PATH="$stub_docker:$PATH" "$code_it" --agent opencode-v1 --dry-run "${excl_args[@]}" 2>&1)
assert_contains "no lock: slot 1 is mounted" "$out" "$slot1_mount"
[[ "$out" != *"Another opencode-v1 container"* ]]; assert "no lock: no warning" "$?"
[[ ! -e "$excl_locks/1.lock" ]]; assert "dry run takes no lock" "$?"

# (b) slot 1 held by a live process (this test): warn and mount slot 2
mkdir -p "$excl_locks" "$excl/.local/share/opencode"
echo '{"anthropic":{"type":"api"}}' > "$excl/.local/share/opencode/auth.json"
echo "$$" > "$excl_locks/1.lock"
out=$(PATH="$stub_docker:$PATH" "$code_it" --agent opencode-v1 --dry-run "${excl_args[@]}" 2>&1)
assert_contains "held lock: warns of the other container" "$out" "Warning: Another opencode-v1 container is using $excl/.local/share/opencode"
assert_contains "held lock: slot 2 is mounted" "$out" "-v \"$excl_locks/2/.local/share/opencode:/home/agent1/.local/share/opencode\""
assert_contains "held lock: config is still shared" "$out" "-v \"$excl/.config/opencode:/home/agent1/.config/opencode\""
[[ ! -e "$excl_locks/2" ]]; assert "dry run copies nothing" "$?"

# (c) a real (stub) run holds slot 2's lock while the container runs, carries auth.json
# over, and frees the lock afterwards
stub_locks="$tmp/stub-locks"; mkdir -p "$stub_locks"
cat > "$stub_locks/docker" <<'EOF'
#!/bin/sh
case "$1" in
    images) echo "code-it-alpine-dotnet-node:latest" ;;
    image)  echo "${STUB_IMAGE_TOOLCHAINS-dotnet,node}" ;;
    run)    echo "STUB-DOCKER-RUN $*"; echo "LOCKS-DURING-RUN: $(cd "$STUB_LOCK_DIR" && ls *.lock | tr '\n' ' ')" ;;
    *)      echo "stub docker: $*" ;;
esac
EOF
chmod +x "$stub_locks/docker"
out=$(STUB_LOCK_DIR="$excl_locks" PATH="$stub_locks:$PATH" "$code_it" --agent opencode-v1 "${excl_args[@]}" 2>&1)
assert_contains "real run mounts slot 2" "$out" "-v $excl_locks/2/.local/share/opencode:/home/agent1/.local/share/opencode"
assert_contains "real run holds slot 2's lock while running" "$out" "LOCKS-DURING-RUN: 1.lock 2.lock"
[[ "$out" != *"no saved login"* ]]; assert "auth.json to carry: no login note" "$?"
[[ ! -e "$excl_locks/2.lock" ]]; assert "real run frees its lock afterwards" "$?"
[[ -e "$excl_locks/1.lock" ]]; assert "real run leaves the other run's lock alone" "$?"
cmp -s "$excl/.local/share/opencode/auth.json" "$excl_locks/2/.local/share/opencode/auth.json"
assert "auth.json is carried into the copy" "$?"

# (d) a newer auth.json in slot 1 refreshes the copy's; an older one does not
echo '{"anthropic":{"type":"oauth"}}' > "$excl/.local/share/opencode/auth.json"
touch -t 203001010000 "$excl/.local/share/opencode/auth.json"
STUB_LOCK_DIR="$excl_locks" PATH="$stub_locks:$PATH" "$code_it" --agent opencode-v1 "${excl_args[@]}" >/dev/null 2>&1
cmp -s "$excl/.local/share/opencode/auth.json" "$excl_locks/2/.local/share/opencode/auth.json"
assert "a newer auth.json refreshes the copy" "$?"
echo '{"in":"copy"}' > "$excl_locks/2/.local/share/opencode/auth.json"
touch -t 203101010000 "$excl_locks/2/.local/share/opencode/auth.json"
STUB_LOCK_DIR="$excl_locks" PATH="$stub_locks:$PATH" "$code_it" --agent opencode-v1 "${excl_args[@]}" >/dev/null 2>&1
grep -q '"in":"copy"' "$excl_locks/2/.local/share/opencode/auth.json"
assert "an older auth.json leaves the copy's alone" "$?"

# (e) slots 1 and 2 held: slot 3
echo "$$" > "$excl_locks/2.lock"
out=$(PATH="$stub_docker:$PATH" "$code_it" --agent opencode-v1 --dry-run "${excl_args[@]}" 2>&1)
assert_contains "slots 1 and 2 held: slot 3 is mounted" "$out" "$excl_locks/3/.local/share/opencode:/home/agent1/.local/share/opencode"
rm -f "$excl_locks/2.lock"

# (f) a stale lock (its process has exited): slot 1, no warning; a real run replaces it
echo "$dead_pid" > "$excl_locks/1.lock"
out=$(PATH="$stub_docker:$PATH" "$code_it" --agent opencode-v1 --dry-run "${excl_args[@]}" 2>&1)
assert_contains "stale lock: slot 1 is mounted" "$out" "$slot1_mount"
[[ "$out" != *"Another opencode-v1 container"* ]]; assert "stale lock: no warning" "$?"
out=$(STUB_LOCK_DIR="$excl_locks" PATH="$stub_locks:$PATH" "$code_it" --agent opencode-v1 "${excl_args[@]}" 2>&1)
assert_contains "stale lock: a real run takes slot 1" "$out" "LOCKS-DURING-RUN: 1.lock"
[[ ! -e "$excl_locks/1.lock" ]]; assert "stale lock: removed after the run" "$?"

# (g) an agent without AGENT_EXCLUSIVE_DIRS takes no lock
rm -rf "$excl/.code-it-instances"
PATH="$stub_docker:$PATH" "$code_it" -c "${excl_args[@]}" >/dev/null 2>&1
[[ ! -e "$excl/.code-it-instances" ]]; assert "claude takes no lock" "$?"

# (h) opencode (v2, the default agent): both its data and its shared-service state are
# exclusive, locked under its own save subdir, apart from opencode-v1's
v2_locks="$excl/opencode-v2/.code-it-instances/opencode"
mkdir -p "$v2_locks"; echo "$$" > "$v2_locks/1.lock"
out=$(PATH="$stub_docker:$PATH" "$code_it" --agent opencode --dry-run "${excl_args[@]}" 2>&1)
assert_contains "v2 held lock: warns of the other container" "$out" "Warning: Another opencode container is using $excl/opencode-v2/.local/share/opencode"
assert_contains "v2 held lock: data from slot 2" "$out" "-v \"$v2_locks/2/.local/share/opencode:/home/agent1/.local/share/opencode\""
assert_contains "v2 held lock: shared-service state from slot 2" "$out" "-v \"$v2_locks/2/.local/state/opencode:/home/agent1/.local/state/opencode\""
assert_contains "v2 held lock: config is still shared" "$out" "-v \"$excl/opencode-v2/.config/opencode:/home/agent1/.config/opencode\""
assert_contains "v2 new copy: says it has no saved login" "$out" "This copy has no saved login"
mkdir -p "$excl/opencode-v2/.local/share/opencode"
echo '{"v1":"style"}' > "$excl/opencode-v2/.local/share/opencode/auth.json"
out=$(STUB_LOCK_DIR="$v2_locks" PATH="$stub_locks:$PATH" "$code_it" --agent opencode "${excl_args[@]}" 2>&1)
assert_contains "v2 real run holds slot 2's lock" "$out" "LOCKS-DURING-RUN: 1.lock 2.lock"
[[ -d "$v2_locks/2/.local/state/opencode" ]]; assert "v2 copy has its own shared-service state" "$?"
[[ ! -e "$v2_locks/2/.local/share/opencode/auth.json" ]]; assert "v2 carries no auth.json (its login is in its database)" "$?"
out=$(STUB_LOCK_DIR="$v2_locks" PATH="$stub_locks:$PATH" "$code_it" --agent opencode "${excl_args[@]}" 2>&1)
[[ "$out" != *"no saved login"* ]]; assert "v2 reused copy: no login note (it keeps its own)" "$?"
rm -f "$v2_locks/1.lock"
out=$(PATH="$stub_docker:$PATH" "$code_it" --agent opencode --dry-run "${excl_args[@]}" 2>&1)
assert_contains "v2 free: slot 1 state is mounted" "$out" "-v \"$excl/opencode-v2/.local/state/opencode:/home/agent1/.local/state/opencode\""
mkdir -p "$excl_locks"; echo "$$" > "$excl_locks/1.lock"
out=$(PATH="$stub_docker:$PATH" "$code_it" --agent opencode --dry-run "${excl_args[@]}" 2>&1)
[[ "$out" != *"Another opencode container"* ]]; assert "an opencode-v1 lock does not affect opencode (v2)" "$?"
rm -rf "$excl/.code-it-instances"

# (i) help documents it
out=$(PATH="$stub_docker:$PATH" "$code_it" --help)
assert_contains "--help documents exclusive state" "$out" "AGENT_EXCLUSIVE_DIRS"

# ---------------------------------------------------------------------------
echo "23. Work dir mounts at /work/<parent>/<name> (Spec 18)"
[[ "$(ci_work_mount_path "/")" == "/work" ]]
assert "mount path of / is /work" "$?"
[[ "$(ci_work_mount_path "/tmp")" == "/work/tmp" ]]
assert "a work dir with no parent to name mounts at /work/<name>" "$?"
[[ "$(ci_work_mount_path "/tmp/x")" == "/work/tmp/x" ]]
assert "mount path uses the parent directory's name" "$?"
[[ "$(ci_work_mount_path "/a/b/c/d")" == "/work/c/d" ]]
assert "mount path uses the nearest names only" "$?"
[[ "$(ci_work_mount_path "/a/b:c/d")" == "/work/b-c/d" ]]
assert "a ':' in a directory name cannot break -v syntax" "$?"
[[ "$(ci_work_mount_path "/a/b/")" == "/work/a/b" ]]
assert "a trailing slash does not change the mount path" "$?"
mkdir -p "$tmp/work-parent/work-dir"
out=$(PATH="$stub_docker:$PATH" "$code_it" --dry-run --work-dir "$tmp/work-parent/work-dir" --save-dir "$save")
assert "dry-run with a nested work dir exit code" "$?"
assert_contains "nested work dir mounts at /work/<parent>/<name>" "$out" "work-parent/work-dir:/work/work-parent/work-dir"
assert_contains "nested work dir env tells go.sh where to cd" "$out" 'CODE_IT_WORK_DIR="/work/work-parent/work-dir"'

# ---------------------------------------------------------------------------
echo
echo "Results: $pass passed, $fail failed"
[[ "$fail" == "0" ]] || exit 1

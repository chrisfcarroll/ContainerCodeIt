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
    image)  case "$2" in inspect) echo "${STUB_IMAGE_TOOL_CHAINS-dotnet,node}" ;; *) echo "stub docker: $*" ;; esac ;;
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
                inspect) echo "${STUB_IMAGE_TOOL_CHAINS-dotnet,node}" ;;
                *)       echo "stub container: $*" ;;
            esac ;;
    build)  echo "STUB-CONTAINER-BUILD $*" ;;
    run)    echo "STUB-CONTAINER-RUN $*"; printf '[%s]' "$@"; echo ;;
    *)      echo "stub container: $*" ;;
esac
EOF
chmod +x "$stub_container/container"
# Port probe used when resolving --port 0 for the Apple container runtime:
# report every port free, so the first candidate (3000) is chosen deterministically.
cat > "$stub_container/nc" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$stub_container/nc"

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
common_args=(--dry-run --work-dir "$script_dir" --save-dir "$save")

# ---------------------------------------------------------------------------
echo "1. Syntax checks (bash -n)"
for f in code-it.sh code-it-build.sh code-it-first-run.sh code-it-add-agent.sh \
         code-it-add-tool-chain.sh lib/code-it-common.sh claude-it.sh opencode-it.sh \
         tests/test-code-it.sh completions/code-it.bash completions/code-it-build.bash \
         completions/code-it-add-agent.bash completions/code-it-add-tool-chain.bash \
         completions/code-it-first-run.bash; do
    bash -n "$script_dir/$f"
    assert "bash -n $f" "$?"
done
if command -v zsh &>/dev/null; then
    for f in completions/_code-it completions/_code-it-build completions/_code-it-add-agent \
             completions/_code-it-add-tool-chain completions/_code-it-first-run; do
        zsh -n "$script_dir/$f"
        assert "zsh -n $f" "$?"
    done
else
    echo "  skip: zsh -n completions (no zsh)"
fi

# ---------------------------------------------------------------------------
echo "2. --help exits 0 and prints usage"
out=$(PATH="$stub_docker:$PATH" "$code_it" --help)
assert "--help exit code" "$?"
assert_contains "--help shows usage" "$out" "Usage:"
assert_contains "--help documents -c" "$out" "--claude, -c"
assert_contains "--help documents -o" "$out" "--opencode, -o"
assert_contains "--help documents --rebuild-image" "$out" "--rebuild-image"
assert_contains "--help documents --prompt" "$out" "--prompt, -p TEXT"
assert_contains "--help documents --headless" "$out" "--headless"
assert_contains "--help documents the -- separator" "$out" "-- AGENT-ARGS..."

# ---------------------------------------------------------------------------
echo "3. Default dry-run with docker: opencode agent, only its state mounted"
out=$(PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}")
assert "dry-run exit code" "$?"
assert_contains "reports OpenCode config creation" "$out" "Created OpenCode configuration"
assert_contains "uses docker runtime" "$out" "Using container runtime: docker"
assert_contains "defaults to opencode" "$out" 'CODE_AGENT="opencode"'
assert_contains "docker run command" "$out" "docker run -it"
assert_contains "image name" "$out" "code-it-alpine-dotnet-node:latest"
assert_contains "work dir mount" "$out" "$script_dir:/work"
assert_contains "opencode config mount" "$out" "/.config/opencode:/home/agent1/.config/opencode"
assert_contains "opencode data mount" "$out" "/.local/share/opencode:/home/agent1/.local/share/opencode"
case "$out" in
    *"/home/agent1/.claude"*) assert "opencode run mounts no claude state" 1 ;;
    *)                        assert "opencode run mounts no claude state" 0 ;;
esac
assert_contains "docker default auto-assign port" "$out" "-p 0:3000"

# ---------------------------------------------------------------------------
echo "4. Save dir structure is created for first run"
[[ -d "$save/.config/opencode" ]];        assert "save/.config/opencode created" "$?"
[[ -d "$save/.local/share/opencode" ]];   assert "save/.local/share/opencode created" "$?"
[[ "$(tr -d '[:space:]' < "$save/.config/opencode/config.json")" == '{"$schema":"https://opencode.ai/config.json","permission":"allow"}' ]]
assert "OpenCode config permits all actions" "$?"
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
out=$(PATH="$stub_docker:$PATH" "$code_it" --list-agents)
assert "--list-agents exit code" "$?"
assert_contains "--list-agents lists claude" "$out" "claude"
assert_contains "--list-agents lists opencode" "$out" "opencode"
assert_contains "--list-agents shows the short flag" "$out" "-o"
PATH="$stub_docker:$PATH" "$code_it" --agent nosuchagent "${common_args[@]}" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "unknown --agent fails" "$?"

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
assert_contains "container default resolves port 0 to a free port" "$out" "-p 3000:3000"
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
[[ "$?" != "0" ]]; assert "unknown image without --build-image fails" "$?"
out=$(STUB_IMAGES_FAIL=1 PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}" 2>&1)
[[ "$?" != "0" ]]; assert "failure to list images fails" "$?"
assert_contains "failure to list images asks if the runtime is running" "$out" "Could not list docker images"

# ---------------------------------------------------------------------------
echo "10. Build image"
out=$(PATH="$stub_docker:$PATH" "$code_it" --build-image "${common_args[@]}")
assert "--build-image exit code" "$?"
assert_contains "docker build invoked" "$out" "STUB-DOCKER-BUILD"
assert_contains "build tags the image" "$out" "-t code-it-alpine-dotnet-node:latest"
PATH="$stub_docker:$PATH" "$code_it" --build-image --dockerfile-dir "$tmp" "${common_args[@]}" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "--build-image with no Dockerfile fails" "$?"
out=$(STUB_BUILD_FAIL=1 PATH="$stub_docker:$PATH" "$code_it" --build-image --work-dir "$script_dir" --save-dir "$save" 2>&1)
[[ "$?" != "0" ]]; assert "failed build exits non-zero" "$?"
[[ "$out" != *STUB-DOCKER-RUN* ]]; assert "failed build does not run the container" "$?"

# ---------------------------------------------------------------------------
echo "10b. Rebuild image (updates the agent install fragments)"
dfdir="$tmp/dfdir"; mkdir -p "$dfdir"
cp "$script_dir/Dockerfile" "$dfdir/Dockerfile"
cp -R "$script_dir/agents" "$dfdir/agents"
sed -i -E "s/# last changed [0-9]{4}-[0-9]{2}-[0-9]{2}/# last changed 2000-01-01/" "$dfdir/agents/"*/install.dockerfile
today=$(date +%Y-%m-%d)
out=$(PATH="$stub_docker:$PATH" "$code_it" --rebuild-image --dockerfile-dir "$dfdir" "${common_args[@]}")
assert "--rebuild-image exit code" "$?"
assert_contains "rebuild invokes docker build" "$out" "STUB-DOCKER-BUILD"
assert_contains "rebuild implies build (no --build-image needed)" "$out" "-t code-it-alpine-dotnet-node:latest"
grep -q "# last changed $today" "$dfdir/agents/opencode/install.dockerfile"
assert "opencode install fragment dates bumped to today" "$?"
grep -q "# last changed 2000-01-01" "$dfdir/agents/opencode/install.dockerfile" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "old dates gone from the fragment" "$?"
# plain --build-image leaves the dates alone
sed -i -E "s/# last changed [0-9]{4}-[0-9]{2}-[0-9]{2}/# last changed 2000-01-01/" "$dfdir/agents/"*/install.dockerfile
out=$(PATH="$stub_docker:$PATH" "$code_it" --build-image --dockerfile-dir "$dfdir" "${common_args[@]}")
assert "--build-image exit code (dfdir)" "$?"
grep -q "# last changed 2000-01-01" "$dfdir/agents/opencode/install.dockerfile"
assert "--build-image leaves dates unchanged" "$?"

# ---------------------------------------------------------------------------
echo "10c. code-it-build: dry-run, labels, --tech, --rebuild"
build_it="$script_dir/code-it-build.sh"

# --dry-run prints the build command (the same args code-it passes) without executing
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" 2>&1)
assert "code-it-build --dry-run exit code" "$?"
assert_contains "build dry-run prints the build command" "$out" "docker build"
assert_contains "build dry-run passes DOTNET=true" "$out" "--build-arg DOTNET=true"
assert_contains "build dry-run passes NODE=true" "$out" "--build-arg NODE=true"
assert_contains "build dry-run passes NUGET=true (implied by dotnet)" "$out" "--build-arg NUGET=true"
assert_contains "build dry-run passes NPM=true (implied by node)" "$out" "--build-arg NPM=true"
assert_contains "build dry-run labels the tool chains" "$out" "--label code-it.tool-chains=dotnet,node"
assert_contains "build dry-run labels the package caches" "$out" "--label code-it.package-caches=nuget,npm"
assert_contains "build dry-run derives the default image name" "$out" "-t code-it-alpine-dotnet-node:latest"
case "$out" in
    *STUB-DOCKER-BUILD*) assert "code-it-build --dry-run does not execute the build" 1 ;;
    *)                   assert "code-it-build --dry-run does not execute the build" 0 ;;
esac

# --tech is the kept alias of --tool-chains
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --tech bun 2>&1)
assert_contains "build --tech alias selects BUN" "$out" "--build-arg BUN=true"
assert_contains "build --tech alias derives the image name" "$out" "-t code-it-alpine-bun:latest"

# --package-caches replaces the implied set
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --tool-chains bun --package-caches nuget 2>&1)
assert_contains "build --package-caches nuget without dotnet" "$out" "--build-arg NUGET=true"
assert_contains "build --package-caches nuget excludes NPM" "$out" "--build-arg NPM=false"

# Unknown names are hard errors
PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --tool-chains cobol >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "code-it-build unknown tool chain fails" "$?"
PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --package-caches pip >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "code-it-build unknown package cache fails" "$?"

# --rebuild bumps the dates and then really builds
bdfdir="$tmp/build-dfdir"; mkdir -p "$bdfdir"
cp "$script_dir/Dockerfile" "$bdfdir/Dockerfile"
cp -R "$script_dir/agents" "$bdfdir/agents"
sed -i -E "s/# last changed [0-9]{4}-[0-9]{2}-[0-9]{2}/# last changed 2000-01-01/" "$bdfdir/agents/"*/install.dockerfile
out=$(PATH="$stub_docker:$PATH" "$build_it" --rebuild --dockerfile-dir "$bdfdir" --runtime docker 2>&1)
assert "code-it-build --rebuild exit code" "$?"
assert_contains "code-it-build --rebuild invokes docker build" "$out" "STUB-DOCKER-BUILD"
grep -q "# last changed $today" "$bdfdir/agents/opencode/install.dockerfile"
assert "code-it-build --rebuild bumps the opencode fragment" "$?"
grep -q "# last changed $today" "$bdfdir/agents/claude/install.dockerfile"
assert "code-it-build --rebuild bumps the claude fragment" "$?"
# A missing Dockerfile is an error
PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$tmp" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "code-it-build without a Dockerfile fails" "$?"

echo "10f. code-it-build agents"
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" 2>&1)
assert_contains "default build installs opencode and claude" "$out" "agents opencode,claude"
assert_contains "default build labels the agents" "$out" "--label code-it.agents=opencode,claude"
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --agent opencode 2>&1)
assert_contains "--agent opencode selects only opencode" "$out" "agents opencode"
case "$out" in
    *"agents opencode,claude"*) assert "--agent opencode excludes claude" 1 ;;
    *)                         assert "--agent opencode excludes claude" 0 ;;
esac
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --agent claude,opencode 2>&1)
assert_contains "--agent accepts a list" "$out" "agents claude,opencode"
out=$(PATH="$stub_docker:$PATH" "$build_it" --list-agents)
assert "--list-agents exit code" "$?"
assert_contains "code-it-build --list-agents lists claude" "$out" "claude"
assert_contains "code-it-build --list-agents lists opencode" "$out" "opencode"
PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --agent nosuch >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "code-it-build unknown agent fails" "$?"

echo "10d. code-it reads the image label"
out=$(STUB_IMAGE_TOOL_CHAINS=node,bun PATH="$stub_docker:$PATH" "$code_it" --image code-it-alpine-dotnet-node "${common_args[@]}" 2>&1)
assert_contains "warns when the image label disagrees with --tool-chains" "$out" "looks built for tech 'node,bun'"
out=$(PATH="$stub_docker:$PATH" "$code_it" --build-image "${common_args[@]}")
assert_contains "the --build-image shim prints a deprecation note" "$out" "deprecated"

echo "10e. Python tool chain (python / uv / --stack)"
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --stack python 2>&1)
assert_contains "--stack python sets PYTHON=true" "$out" "--build-arg PYTHON=true"
assert_contains "--stack python derives the image name" "$out" "-t code-it-alpine-python:latest"
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" --tool-chains uv 2>&1)
assert_contains "uv aliases python (PYTHON=true)" "$out" "--build-arg PYTHON=true"
assert_contains "uv canonical image name" "$out" "-t code-it-alpine-python:latest"
out=$(PATH="$stub_docker:$PATH" "$build_it" --dry-run --dockerfile-dir "$script_dir" 2>&1)
assert_contains "default build sets PYTHON=false" "$out" "--build-arg PYTHON=false"
out=$(PATH="$stub_docker:$PATH" "$code_it" --stack python -b "${common_args[@]}" 2>&1)
assert_contains "code-it --stack python delegates a PYTHON=true build" "$out" "--build-arg PYTHON=true"
# uv is installed for every image (base layer), so the default image still has it;
# python3 is gated on the tool chain
grep -q "apk add --no-cache uv" "$script_dir/Dockerfile"
assert "Dockerfile installs uv for every image" "$?"
grep -q 'if \[ "\$PYTHON" = true \]' "$script_dir/Dockerfile"
assert "Dockerfile gates python3 on PYTHON" "$?"

# ---------------------------------------------------------------------------
echo "10g. Choosing an existing image that contains the requested tool chains"
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
        "$code_it" --tool-chains dotnet "${super_args[@]}")
assert_contains "uses the exact image when it exists" "$out" "code-it-alpine-dotnet:latest"
case "$out" in
    *"does not exist; using"*) assert "no substitution when the exact image exists" 1 ;;
    *)                         assert "no substitution when the exact image exists" 0 ;;
esac

# The exact image missing: the most-recently listed image containing the chain wins
out=$(STUB_IMAGES="code-it-alpine-dotnet-bun:latest code-it-alpine-dotnet-node:latest" PATH="$superbin:$PATH" \
        "$code_it" --tool-chains dotnet "${super_args[@]}")
assert_contains "substitutes a superset image" "$out" "does not exist; using 'code-it-alpine-dotnet-bun'"
assert_contains "runs the superset image" "$out" "code-it-alpine-dotnet-bun:latest"
assert_contains "notes the extra tool chains" "$out" "also contains bun"

# Order decides: whichever qualifying image is listed first (most recently built)
out=$(STUB_IMAGES="code-it-alpine-dotnet-node:latest code-it-alpine-dotnet-bun:latest" PATH="$superbin:$PATH" \
        "$code_it" --tool-chains dotnet "${super_args[@]}")
assert_contains "picks the most recent qualifying image" "$out" "using 'code-it-alpine-dotnet-node'"

# Every requested chain must be present: dotnet-node does not contain bun
PATH="$superbin:$PATH" STUB_IMAGES="code-it-alpine-dotnet-node:latest" \
    "$code_it" --tool-chains dotnet,bun "${super_args[@]}" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "requires every requested chain to be present" "$?"

# No image contains the requested chain: still an error
PATH="$superbin:$PATH" STUB_IMAGES="code-it-alpine-dotnet-node:latest code-it-alpine-dotnet-bun:latest" \
    "$code_it" --tool-chains python "${super_args[@]}" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "errors when no image contains the requested chain" "$?"

# An explicit --image is never substituted, and errors if missing
PATH="$superbin:$PATH" STUB_IMAGES="code-it-alpine-dotnet-bun:latest" \
    "$code_it" --tool-chains dotnet --image code-it-alpine-nope "${super_args[@]}" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "explicit --image is used as-is and errors if missing" "$?"

# ---------------------------------------------------------------------------
echo "11. Custom options"
out=$(PATH="$stub_docker:$PATH" "$code_it" --port 8000 "${common_args[@]}")
assert_contains "custom --port maps the host port to container 3000" "$out" "-p 8000:3000"
out=$(PATH="$stub_docker:$PATH" "$code_it" --port 8000 -o "${common_args[@]}")
assert_contains "flag after --port value is not eaten" "$out" 'CODE_AGENT="opencode"'
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
out=$(PATH="$stub_docker:$PATH" "$code_it" -t node,bun -b "${common_args[@]}")
assert_contains "-t is --tool-chains" "$out" "code-it-alpine-node-bun:latest"
out=$(PATH="$stub_docker:$PATH" "$code_it" -b "${common_args[@]}")
assert_contains "-b is --build-image" "$out" "STUB-DOCKER-BUILD"
out=$(PATH="$stub_container:$stub_docker:$PATH" "$code_it" -r container -i code-it-alpine-dotnet-node -w "$script_dir" -s "$save" -d)
assert_contains "-r is --runtime" "$out" "Using container runtime: container"
assert_contains "-i is --image" "$out" "code-it-alpine-dotnet-node:latest"
case "$out" in
    *STUB-DOCKER-RUN*) assert "-d is --dry-run (no run)" 1 ;;
    *)                 assert "-d is --dry-run (no run)" 0 ;;
esac
alias_dfdir="$tmp/alias-dfdir"; mkdir -p "$alias_dfdir"
cp "$script_dir/Dockerfile" "$alias_dfdir/Dockerfile"
cp -R "$script_dir/agents" "$alias_dfdir/agents"
out=$(PATH="$stub_docker:$PATH" "$code_it" -B --dockerfile-dir "$alias_dfdir" -w "$script_dir" -s "$save" -d)
assert_contains "-B is --rebuild-image" "$out" "STUB-DOCKER-BUILD"

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
echo "12b. Tech stack: --tool-chains / --package-caches build args and read-only caches"
npm_cache="$tmp/npm-cache"; mkdir -p "$npm_cache"
bun_cache="$tmp/bun-cache"; mkdir -p "$bun_cache"

# Defaults: tech dotnet,node and the package repos they imply (nuget, npm)
out=$(PATH="$stub_docker:$PATH" "$code_it" --build-image "${common_args[@]}")
assert_contains "default build passes DOTNET=true" "$out" "--build-arg DOTNET=true"
assert_contains "default build passes NODE=true" "$out" "--build-arg NODE=true"
assert_contains "default build passes BUN=false" "$out" "--build-arg BUN=false"
assert_contains "dotnet implies NUGET=true" "$out" "--build-arg NUGET=true"
assert_contains "node implies NPM=true" "$out" "--build-arg NPM=true"
assert_contains "reports the resolved tech" "$out" "tech dotnet,node; package repos nuget,npm"

# --tool-chains replaces the default set
out=$(PATH="$stub_docker:$PATH" "$code_it" --build-image --tool-chains node,bun "${common_args[@]}")
assert_contains "--tool-chains node,bun drops DOTNET" "$out" "--build-arg DOTNET=false"
assert_contains "--tool-chains node,bun keeps NODE" "$out" "--build-arg NODE=true"
assert_contains "--tool-chains node,bun keeps BUN" "$out" "--build-arg BUN=true"
assert_contains "--tool-chains node,bun drops NUGET (dotnet gone)" "$out" "--build-arg NUGET=false"
assert_contains "--tool-chains node,bun keeps NPM (node present)" "$out" "--build-arg NPM=true"

# --package-caches replaces the implied set, independently of --tool-chains
out=$(PATH="$stub_docker:$PATH" "$code_it" --build-image --tool-chains node,bun --package-caches npm "${common_args[@]}")
assert_contains "--package-caches npm keeps NPM" "$out" "--build-arg NPM=true"
assert_contains "--package-caches npm excludes BUN cache" "$out" "--build-arg NUGET=false"
out=$(PATH="$stub_docker:$PATH" "$code_it" --build-image --tool-chains node,bun --package-caches bun "${common_args[@]}")
assert_contains "--package-caches bun selects the BUN package cache" "$out" "--build-arg NPM=false"
assert_contains "--package-caches bun excludes NPM" "$out" "--build-arg NUGET=false"

# --package-caches nuget with no dotnet still selects the NuGet cache (nuget without dotnet)
out=$(PATH="$stub_docker:$PATH" "$code_it" --build-image --tool-chains bun --package-caches nuget "${common_args[@]}")
assert_contains "nuget package cache without dotnet" "$out" "--build-arg NUGET=true"

# The default image name follows --tool-chains, so the built and run images agree
out=$(PATH="$stub_docker:$PATH" "$code_it" --build-image --tool-chains node,bun "${common_args[@]}")
assert_contains "image name derives from --tool-chains" "$out" "-t code-it-alpine-node-bun:latest"

# The old --tech spelling is kept as a hidden alias
out=$(PATH="$stub_docker:$PATH" "$code_it" --build-image --tech bun "${common_args[@]}")
assert_contains "--tech alias selects BUN" "$out" "--build-arg BUN=true"

# Tech aliases resolve to the canonical name: js-node/ts-node -> node, js-bun/ts-bun -> bun
out=$(PATH="$stub_docker:$PATH" "$code_it" --build-image --tool-chains js-node "${common_args[@]}")
assert_contains "js-node aliases node (NODE=true)" "$out" "--build-arg NODE=true"
assert_contains "js-node canonical image name" "$out" "-t code-it-alpine-node:latest"
out=$(PATH="$stub_docker:$PATH" "$code_it" --build-image --tool-chains ts-node "${common_args[@]}")
assert_contains "ts-node aliases node (NODE=true)" "$out" "--build-arg NODE=true"
assert_contains "ts-node canonical image name" "$out" "-t code-it-alpine-node:latest"
assert_contains "ts-node implies the npm package cache" "$out" "--build-arg NPM=true"
out=$(PATH="$stub_docker:$PATH" "$code_it" --build-image --tool-chains js-bun "${common_args[@]}")
assert_contains "js-bun aliases bun (BUN=true)" "$out" "--build-arg BUN=true"
assert_contains "js-bun canonical image name" "$out" "-t code-it-alpine-bun:latest"
out=$(PATH="$stub_docker:$PATH" "$code_it" --build-image --tool-chains ts-bun,bun "${common_args[@]}")
assert_contains "ts-bun aliases bun and dedupes with bun" "$out" "-t code-it-alpine-bun:latest"

# The old --packages spelling is gone, not an alias
PATH="$stub_docker:$PATH" "$code_it" --build-image --packages npm "${common_args[@]}" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "removed --packages spelling fails" "$?"

# An image label that disagrees with --tool-chains is called out
out=$(STUB_IMAGE_TOOL_CHAINS=dotnet PATH="$stub_docker:$PATH" "$code_it" --tool-chains node,bun --image code-it-alpine-dotnet-node "${common_args[@]}" 2>&1)
assert_contains "warns when the image label disagrees with --tool-chains" "$out" "looks built for tech 'dotnet'"
# Without a label (older images), fall back to the name-based guess
out=$(STUB_IMAGE_TOOL_CHAINS="" PATH="$stub_docker:$PATH" "$code_it" --tool-chains node,bun --image code-it-alpine-dotnet-node "${common_args[@]}" 2>&1)
assert_contains "falls back to the image-name guess without a label" "$out" "looks built for tech 'dotnet,node'"

# Unknown names are hard errors
PATH="$stub_docker:$PATH" "$code_it" --build-image --tool-chains cobol "${common_args[@]}" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "--tool-chains with an unknown name fails" "$?"
PATH="$stub_docker:$PATH" "$code_it" --build-image --package-caches pip "${common_args[@]}" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "--package-caches with an unknown name fails" "$?"

# Host caches for enabled package repos are mounted read-only
out=$(HOME="$fakehome" NPM_CONFIG_CACHE="$npm_cache" PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}")
assert_contains "npm cache mounted read-only" "$out" "-v \"$npm_cache:/home/agent1/.npm-host:ro\""
out=$(HOME="$fakehome" BUN_INSTALL_CACHE_DIR="$bun_cache" PATH="$stub_docker:$PATH" "$code_it" --package-caches bun "${common_args[@]}")
assert_contains "bun cache mounted read-only" "$out" "-v \"$bun_cache:/home/agent1/.bun-host:ro\""

# Omitting a package repo from --package-caches suppresses its mount entirely
out=$(HOME="$fakehome" NPM_CONFIG_CACHE="$npm_cache" PATH="$stub_docker:$PATH" "$code_it" --tool-chains node --package-caches= "${common_args[@]}")
case "$out" in
    *.npm-host*) assert "empty --package-caches: no npm mount" 1 ;;
    *)           assert "empty --package-caches: no npm mount" 0 ;;
esac
out=$(HOME="$fakehome" NUGET_PACKAGES="$nuget_cache" PATH="$stub_docker:$PATH" "$code_it" --tool-chains dotnet --package-caches npm "${common_args[@]}")
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
assert_contains "opencode: prompt becomes --prompt" "$out" 'code-it-alpine-dotnet-node:latest --prompt explain\ this\ repo'
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
assert_contains "opencode --headless uses run" "$out" 'code-it-alpine-dotnet-node:latest run fix\ the\ build'

# -- passes the rest to the agent verbatim
out=$(PATH="$stub_docker:$PATH" "$code_it" -c "${common_args[@]}" -- --continue --model opus)
assert_contains "-- passes agent flags through" "$out" "code-it-alpine-dotnet-node:latest --continue --model opus"
out=$(PATH="$stub_docker:$PATH" "$code_it" -c --headless --prompt "tidy" "${common_args[@]}" -- --max-turns 5)
assert_contains "agent flags precede the prompt for claude" "$out" "code-it-alpine-dotnet-node:latest -p --max-turns 5 tidy"
out=$(PATH="$stub_docker:$PATH" "$code_it" -o --headless --prompt "tidy" "${common_args[@]}" -- --model opus)
assert_contains "agent flags follow run for opencode" "$out" "code-it-alpine-dotnet-node:latest run --model opus tidy"
out=$(PATH="$stub_docker:$PATH" "$code_it" -o --headless "${common_args[@]}" -- --session abc)
assert_contains "opencode headless with no prompt still uses run" "$out" "code-it-alpine-dotnet-node:latest run --session abc"
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
    echo "CLAUDEALIAS:$(comp ./claude-it.sh -- --mod | tr '\n' ' ')"
    echo "CLAUDEFLAG:$(comp ./code-it.sh -c -- --perm | tr '\n' ' ')"
    echo "CLAUDEMODE:$(comp ./code-it.sh -c -- --permission-mode '' | tr '\n' ' ')"
    echo "OPENCODEDEF:$(comp ./code-it.sh -- --se | tr '\n' ' ')"
    echo "OPENCODEALIAS:$(comp ./opencode-it.sh -- --th | tr '\n' ' ')"
)
assert_contains "completes launcher options" "$completions_out" "OPTS:--headless"
assert_contains "completes --runtime values" "$completions_out" "RUNTIME:docker container"
assert_contains "offers nothing for a free-text --prompt" "$completions_out" "FREETEXT:
"
assert_contains "claude-it.sh completes claude flags after --" "$completions_out" "CLAUDEALIAS:--model"
assert_contains "-c completes claude flags after --" "$completions_out" "CLAUDEFLAG:--permission-mode"
assert_contains "completes claude --permission-mode values" "$completions_out" "CLAUDEMODE:default acceptEdits"
assert_contains "defaults to opencode flags after --" "$completions_out" "OPENCODEDEF:--session"
assert_contains "opencode-it.sh completes opencode flags after --" "$completions_out" "OPENCODEALIAS:--thinking"

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

    for agent in claude opencode; do
        cat > "$gobin/$agent" <<EOF
#!/bin/sh
printf 'AGENT-$agent'
printf '[%s]' "\$@"
echo
EOF
        chmod +x "$gobin/$agent"
    done
    # go.sh resolves the agent binary from the build-time name=binary map
    printf 'opencode=%s/opencode\nclaude=%s/claude\n' "$gobin" "$gobin" > "$gobin/agents"
    # tmux takes the command as one string: run it, so what the agent receives is visible
    cat > "$gobin/tmux" <<'EOF'
#!/bin/sh
case "$*" in *" -d"*) exit 0 ;; esac
for a in "$@"; do last="$a"; done
eval "$last"
EOF
    chmod +x "$gobin/tmux"
    printf '#!/bin/sh\nexit 0\n' > "$gobin/git"; chmod +x "$gobin/git"

    out=$(PATH="$gobin:$PATH" CODE_AGENT=claude zsh "$tmp/go.sh" 2>&1)
    assert_contains "go.sh runs the chosen agent in tmux" "$out" "AGENT-claude"
    out=$(PATH="$gobin:$PATH" CODE_AGENT=opencode zsh "$tmp/go.sh" --prompt "explain this repo" 2>&1)
    assert_contains "go.sh forwards arguments through tmux, unsplit" "$out" "AGENT-opencode[--prompt][explain this repo]"
    out=$(PATH="$gobin:$PATH" CODE_AGENT=claude CODE_AGENT_HEADLESS=1 zsh "$tmp/go.sh" -p "fix it; rm -rf /" 2>&1)
    assert_contains "headless go.sh runs the agent directly" "$out" "AGENT-claude[-p][fix it; rm -rf /]"
    [[ "$out" != *AGENT-claude*AGENT-claude* ]]; assert "headless go.sh does not also start tmux" "$?"
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
echo "17. code-it-add-tool-chain"
add_tc="$script_dir/code-it-add-tool-chain.sh"

# (a) --dry-run prints the prompt (with the security gate) and the command
repo_d="$tmp/addtc-a"; mkrepo "$repo_d"
out=$(PATH="$stub_docker:$PATH" "$add_tc" java --repo "$repo_d" --code-it "$stub_ci" --dry-run 2>&1)
assert "add-tool-chain --dry-run exit code" "$?"
assert_contains "add-tool-chain prompt names the tool chain" "$out" "Tool chain to add: java"
assert_contains "add-tool-chain prompt includes the gate" "$out" "Gate first"
assert_contains "add-tool-chain prompt requires a secure install" "$out" "installs securely"
assert_contains "add-tool-chain prompt requires musl builds" "$out" "musl builds for x86_64 and aarch64"
assert_contains "add-tool-chain dry-run prints the command" "$out" "--headless"
[[ -z "$(git -C "$repo_d" branch --list 'add-tool-chain/*')" ]]; assert "add-tool-chain --dry-run creates no branch" "$?"

# (b) --url is included
out=$(PATH="$stub_docker:$PATH" "$add_tc" java --url "https://openjdk.org/install/" --repo "$repo_d" --code-it "$stub_ci" --dry-run 2>&1)
assert_contains "add-tool-chain prompt includes the docs URL" "$out" "https://openjdk.org/install/"

# (c) dirty repo refusal
printf 'y\n' >> "$repo_d/x"
PATH="$stub_docker:$PATH" "$add_tc" java --repo "$repo_d" --code-it "$stub_ci" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "add-tool-chain refuses a dirty repo" "$?"
git -C "$repo_d" checkout -q -- .

# (d) branch creation and summary
out=$(PATH="$stub_docker:$PATH" "$add_tc" java --repo "$repo_d" --code-it "$stub_ci" 2>&1)
assert "add-tool-chain run exit code" "$?"
[[ "$(git -C "$repo_d" rev-parse --abbrev-ref HEAD)" == "add-tool-chain/java" ]]
assert "add-tool-chain checks out the new branch" "$?"
assert_contains "add-tool-chain prints the branch" "$out" "Branch: add-tool-chain/java"

# (e) gate refusal exit code is propagated
repo_e="$tmp/addtc-b"; mkrepo "$repo_e"
STUB_CODE_IT_EXIT=4 PATH="$stub_docker:$PATH" "$add_tc" java --repo "$repo_e" --code-it "$stub_ci" >/dev/null 2>&1
[[ "$?" == "4" ]]; assert "add-tool-chain propagates a gate refusal" "$?"

# ---------------------------------------------------------------------------
echo "18. code-it-first-run"
first_run="$script_dir/code-it-first-run.sh"
stub_first_build="$tmp/stub-first-build.sh"
cat > "$stub_first_build" <<EOF
#!/bin/sh
echo "STUB-FIRST-BUILD \$*"
touch "$tmp/first-build-ran"
exit 0
EOF
chmod +x "$stub_first_build"

# (a) detection with a stubbed PATH/HOME: docker and node present, no bun
firstbin="$tmp/firstbin"; mkdir -p "$firstbin"
for cmd in bash sh sed grep tr uname dirname mkdir cat git touch echo printf pwd basename find cp ls test; do
    src=$(command -v "$cmd" 2>/dev/null) && ln -s "$src" "$firstbin/$cmd"
done
cp "$stub_docker/docker" "$firstbin/docker"; chmod +x "$firstbin/docker"
printf '#!/bin/sh\necho v20.0.0\n' > "$firstbin/node"; chmod +x "$firstbin/node"
firsthome="$tmp/firsthome"; mkdir -p "$firsthome"

out=$(printf '\n\n\n' | HOME="$firsthome" PATH="$firstbin" bash "$first_run" --dry-run \
        --code-it-build "$stub_first_build" 2>&1)
assert "first-run detection exit code" "$?"
assert_contains "first-run uses the detected runtime" "$out" "Using container runtime: docker"
assert_contains "first-run numbers the tool chains" "$out" "1) dotnet"
assert_contains "first-run marks node detected" "$out" "2) node *"
assert_contains "first-run marks python undetected" "$out" "4) python"
assert_contains "first-run defaults to the detected tool chains" "$out" "--tool-chains node"
case "$out" in
    *"2) node *"*) assert "first-run detection is not fooled by bun" 0 ;;
    *)             assert "first-run detection is not fooled by bun" 1 ;;
esac

# (b) answer parsing: pick tool chain 4 (python) and agent 2 (claude)
out=$(printf '4\n2\n\n' | HOME="$firsthome" PATH="$firstbin" bash "$first_run" --dry-run \
        --code-it-build "$stub_first_build" 2>&1)
assert_contains "first-run parses tool chain numbers" "$out" "--tool-chains python"
assert_contains "first-run parses agent numbers" "$out" "--agent claude"

# (c) --dry-run builds nothing
[[ ! -e "$tmp/first-build-ran" ]]; assert "first-run --dry-run ran no build" "$?"
rm -f "$tmp/first-build-ran"

# (d) copy carries state over but never overwrites
fh="$tmp/firstcopy-home"; fs="$tmp/firstcopy-save"
mkdir -p "$fh/.config/opencode" "$fs/.config/opencode"
echo ORIGINAL > "$fh/.config/opencode/config.json"
echo NEW > "$fh/.config/opencode/new.json"
echo KEEP > "$fs/.config/opencode/config.json"
out=$(HOME="$fh" PATH="$stub_docker:$PATH" bash "$first_run" --yes --tool-chains node --agents opencode \
        --save-dir "$fs" --code-it-build "$stub_first_build" 2>&1)
assert "first-run copy exit code" "$?"
assert_contains "first-run invoked the build" "$out" "STUB-FIRST-BUILD"
[[ "$(cat "$fs/.config/opencode/config.json")" == "KEEP" ]]; assert "first-run never overwrites existing state" "$?"
[[ "$(cat "$fs/.config/opencode/new.json")" == "NEW" ]]; assert "first-run copies missing state" "$?"
assert_contains "first-run warns that credentials are copied" "$out" "credentials"
assert_contains "first-run prints the start command" "$out" "code-it.sh --agent opencode"

# (e) --dry-run makes no changes and copies nothing
rm -f "$tmp/first-build-ran"
fd="$tmp/firstdry"; mkdir -p "$fd"
out=$(HOME="$fh" PATH="$stub_docker:$PATH" bash "$first_run" --yes --dry-run --tool-chains node --agents opencode \
        --save-dir "$fd/save" --code-it-build "$stub_first_build" 2>&1)
[[ ! -e "$fd/save" ]]; assert "first-run --dry-run creates no save dir" "$?"
assert_contains "first-run --dry-run says it will not build" "$out" "dry run: not building"
assert_contains "first-run --dry-run says what it would copy" "$out" "would copy"
[[ ! -e "$tmp/first-build-ran" ]]; assert "first-run --dry-run ran no build" "$?"

# ---------------------------------------------------------------------------
echo
echo "Results: $pass passed, $fail failed"
[[ "$fail" == "0" ]] || exit 1

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
    images) echo "code-it-alpine-dotnet:latest" ;;
    build)  echo "STUB-DOCKER-BUILD $*" ;;
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
    image)  echo "code-it-alpine-dotnet  latest" ;;
    build)  echo "STUB-CONTAINER-BUILD $*" ;;
    run)    echo "STUB-CONTAINER-RUN $*" ;;
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
common_args=(--dry-run --work-dir "$script_dir" --save-dir "$save")

# ---------------------------------------------------------------------------
echo "1. Syntax checks (bash -n)"
for f in code-it.sh claude-it.sh opencode-it.sh tests/test-code-it.sh; do
    bash -n "$script_dir/$f"
    assert "bash -n $f" "$?"
done

# ---------------------------------------------------------------------------
echo "2. --help exits 0 and prints usage"
out=$(PATH="$stub_docker:$PATH" "$code_it" --help)
assert "--help exit code" "$?"
assert_contains "--help shows usage" "$out" "Usage:"
assert_contains "--help documents -c" "$out" "--claude, -c"
assert_contains "--help documents -o" "$out" "--opencode, -o"

# ---------------------------------------------------------------------------
echo "3. Default dry-run with docker: opencode agent, all state mounts"
out=$(PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}")
assert "dry-run exit code" "$?"
assert_contains "uses docker runtime" "$out" "Using container runtime: docker"
assert_contains "defaults to opencode" "$out" 'CODE_AGENT="opencode"'
assert_contains "docker run command" "$out" "docker run -it"
assert_contains "image name" "$out" "code-it-alpine-dotnet:latest"
assert_contains "work dir mount" "$out" "$script_dir:/repos"
assert_contains "claude dir mount" "$out" "/.claude:/home/agent1/.claude"
assert_contains "claude.json mount" "$out" "/.claude.json:/home/agent1/.claude.json"
assert_contains "opencode mount" "$out" "/.local/share/opencode:/home/agent1/.local/share/opencode"
assert_contains "docker default auto-assign ports" "$out" "-p 0:3000 -p 0:3001"

# ---------------------------------------------------------------------------
echo "4. Save dir structure is created for first run"
[[ -d "$save/.claude" ]];                 assert "save/.claude created" "$?"
[[ -d "$save/.local/share/opencode" ]];   assert "save/.local/share/opencode created" "$?"
[[ -f "$save/.claude.json" ]];            assert "save/.claude.json created as a file" "$?"

# ---------------------------------------------------------------------------
echo "5. Agent selection switches"
out=$(PATH="$stub_docker:$PATH" "$code_it" --opencode "${common_args[@]}")
assert_contains "--opencode selects opencode" "$out" 'CODE_AGENT="opencode"'
out=$(PATH="$stub_docker:$PATH" "$code_it" -o "${common_args[@]}")
assert_contains "-o selects opencode" "$out" 'CODE_AGENT="opencode"'
out=$(PATH="$stub_docker:$PATH" "$code_it" --claude "${common_args[@]}")
assert_contains "--claude selects claude" "$out" 'CODE_AGENT="claude"'
out=$(PATH="$stub_docker:$PATH" "$code_it" -c "${common_args[@]}")
assert_contains "-c selects claude" "$out" 'CODE_AGENT="claude"'

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
assert_contains "container default fixed ports" "$out" "-p 3000:3000 -p 3001:3001"
# On non-macOS with both available, prefer docker
out=$(PATH="$stub_container:$stub_docker:$PATH" "$code_it" "${common_args[@]}")
assert_contains "non-macOS prefers docker" "$out" "Using container runtime: docker"
# Forced runtime
out=$(PATH="$stub_container:$stub_docker:$PATH" "$code_it" --runtime container "${common_args[@]}")
assert_contains "--runtime container forces apple container" "$out" "Using container runtime: container"
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

# ---------------------------------------------------------------------------
echo "10. Build image"
out=$(PATH="$stub_docker:$PATH" "$code_it" --build-image "${common_args[@]}")
assert "--build-image exit code" "$?"
assert_contains "docker build invoked" "$out" "STUB-DOCKER-BUILD"
assert_contains "build tags the image" "$out" "-t code-it-alpine-dotnet:latest"
PATH="$stub_docker:$PATH" "$code_it" --build-image --dockerfile-dir "$tmp" "${common_args[@]}" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "--build-image with no Dockerfile fails" "$?"

# ---------------------------------------------------------------------------
echo "11. Custom options"
out=$(PATH="$stub_docker:$PATH" "$code_it" --ports "8000:3000" "8001:3001" "${common_args[@]}")
assert_contains "custom ports" "$out" "-p 8000:3000 -p 8001:3001"
out=$(PATH="$stub_docker:$PATH" "$code_it" --ports "8000:3000" -o "${common_args[@]}")
assert_contains "flag after --ports values is not eaten as a port" "$out" 'CODE_AGENT="opencode"'
assert_contains "single --ports value padded with default" "$out" "-p 8000:3000 -p 0:3001"
out=$(PATH="$stub_docker:$PATH" "$code_it" --agent-name "MyAgent" "${common_args[@]}")
assert_contains "agent name lowercased in mounts" "$out" "/home/myagent/.claude"
assert_contains "agent name in git author" "$out" 'GIT_AUTHOR_NAME="MyAgent for'

# ---------------------------------------------------------------------------
echo
echo "Results: $pass passed, $fail failed"
[[ "$fail" == "0" ]] || exit 1

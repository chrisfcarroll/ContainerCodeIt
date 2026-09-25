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
    images) [ -n "${STUB_IMAGES_FAIL:-}" ] && exit 1; echo "code-it-alpine-dotnet:latest" ;;
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
    image)  echo "code-it-alpine-dotnet  latest" ;;
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
common_args=(--dry-run --work-dir "$script_dir" --save-dir "$save")

# ---------------------------------------------------------------------------
echo "1. Syntax checks (bash -n)"
for f in code-it.sh claude-it.sh opencode-it.sh tests/test-code-it.sh completions/code-it.bash; do
    bash -n "$script_dir/$f"
    assert "bash -n $f" "$?"
done
if command -v zsh &>/dev/null; then
    zsh -n "$script_dir/completions/_code-it"
    assert "zsh -n completions/_code-it" "$?"
else
    echo "  skip: zsh -n completions/_code-it (no zsh)"
fi

# ---------------------------------------------------------------------------
echo "2. --help exits 0 and prints usage"
out=$(PATH="$stub_docker:$PATH" "$code_it" --help)
assert "--help exit code" "$?"
assert_contains "--help shows usage" "$out" "Usage:"
assert_contains "--help documents -c" "$out" "--claude, -c"
assert_contains "--help documents -o" "$out" "--opencode, -o"
assert_contains "--help documents --rebuild-image" "$out" "--rebuild-image"
assert_contains "--help documents --prompt" "$out" "--prompt TEXT"
assert_contains "--help documents --headless" "$out" "--headless"
assert_contains "--help documents the -- separator" "$out" "-- AGENT-ARGS..."

# ---------------------------------------------------------------------------
echo "3. Default dry-run with docker: opencode agent, all state mounts"
out=$(PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}")
assert "dry-run exit code" "$?"
assert_contains "uses docker runtime" "$out" "Using container runtime: docker"
assert_contains "defaults to opencode" "$out" 'CODE_AGENT="opencode"'
assert_contains "docker run command" "$out" "docker run -it"
assert_contains "image name" "$out" "code-it-alpine-dotnet:latest"
assert_contains "work dir mount" "$out" "$script_dir:/work"
assert_contains "claude dir mount" "$out" "/.claude:/home/agent1/.claude"
assert_contains "claude.json mount" "$out" "/.claude.json:/home/agent1/.claude.json"
assert_contains "opencode config mount" "$out" "/.config/opencode:/home/agent1/.config/opencode"
assert_contains "opencode mount" "$out" "/.local/share/opencode:/home/agent1/.local/share/opencode"
assert_contains "docker default auto-assign ports" "$out" "-p 0:3000 -p 0:3001"

# ---------------------------------------------------------------------------
echo "4. Save dir structure is created for first run"
[[ -d "$save/.claude" ]];                 assert "save/.claude created" "$?"
[[ -d "$save/.config/opencode" ]];        assert "save/.config/opencode created" "$?"
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
assert_contains "build tags the image" "$out" "-t code-it-alpine-dotnet:latest"
PATH="$stub_docker:$PATH" "$code_it" --build-image --dockerfile-dir "$tmp" "${common_args[@]}" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "--build-image with no Dockerfile fails" "$?"
out=$(STUB_BUILD_FAIL=1 PATH="$stub_docker:$PATH" "$code_it" --build-image --work-dir "$script_dir" --save-dir "$save" 2>&1)
[[ "$?" != "0" ]]; assert "failed build exits non-zero" "$?"
[[ "$out" != *STUB-DOCKER-RUN* ]]; assert "failed build does not run the container" "$?"

# ---------------------------------------------------------------------------
echo "10b. Rebuild image (updates the agents)"
dfdir="$tmp/dfdir"; mkdir -p "$dfdir"
sed -E "s/# last changed [0-9]{4}-[0-9]{2}-[0-9]{2}/# last changed 2000-01-01/" "$script_dir/Dockerfile" > "$dfdir/Dockerfile"
today=$(date +%Y-%m-%d)
out=$(PATH="$stub_docker:$PATH" "$code_it" --rebuild-image --dockerfile-dir "$dfdir" "${common_args[@]}")
assert "--rebuild-image exit code" "$?"
assert_contains "rebuild invokes docker build" "$out" "STUB-DOCKER-BUILD"
assert_contains "rebuild implies build (no --build-image needed)" "$out" "-t code-it-alpine-dotnet:latest"
grep -q "# last changed $today" "$dfdir/Dockerfile"
assert "Dockerfile dates bumped to today" "$?"
grep -q "# last changed 2000-01-01" "$dfdir/Dockerfile" >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "old dates gone from Dockerfile" "$?"
# plain --build-image leaves the dates alone
sed -E "s/# last changed [0-9]{4}-[0-9]{2}-[0-9]{2}/# last changed 2000-01-01/" "$script_dir/Dockerfile" > "$dfdir/Dockerfile"
out=$(PATH="$stub_docker:$PATH" "$code_it" --build-image --dockerfile-dir "$dfdir" "${common_args[@]}")
assert "--build-image exit code (dfdir)" "$?"
grep -q "# last changed 2000-01-01" "$dfdir/Dockerfile"
assert "--build-image leaves dates unchanged" "$?"

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
assert_contains "agent name in git committer" "$out" 'GIT_COMMITTER_NAME="MyAgent for'
assert_contains "git committer email passed" "$out" 'GIT_COMMITTER_EMAIL='
out=$(GIT_AUTHOR_NAME="Agent1 for Some One" PATH="$stub_docker:$PATH" "$code_it" --agent-name "MyAgent" "${common_args[@]}")
assert_contains "run inside an agent container does not repeat the agent prefix" "$out" 'GIT_AUTHOR_NAME="MyAgent for Some One"'

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
echo "13. Prompt and agent arguments"
# A bare argument, or --prompt, is the agent's opening prompt, spelled each agent's way
out=$(PATH="$stub_docker:$PATH" "$code_it" -c "explain this repo" "${common_args[@]}")
assert_contains "claude: bare prompt appended to the image" "$out" 'code-it-alpine-dotnet:latest explain\ this\ repo'
out=$(PATH="$stub_docker:$PATH" "$code_it" -c --prompt "explain this repo" "${common_args[@]}")
assert_contains "claude: --prompt is the same as a bare prompt" "$out" 'code-it-alpine-dotnet:latest explain\ this\ repo'
out=$(PATH="$stub_docker:$PATH" "$code_it" -o "explain this repo" "${common_args[@]}")
assert_contains "opencode: prompt becomes --prompt" "$out" 'code-it-alpine-dotnet:latest --prompt explain\ this\ repo'
# No prompt and no agent args: nothing is appended, and the run stays interactive
out=$(PATH="$stub_docker:$PATH" "$code_it" "${common_args[@]}")
[[ "$out" == *"code-it-alpine-dotnet:latest" ]]; assert "no prompt appends nothing" "$?"
assert_contains "interactive runs allocate a TTY" "$out" "docker run -it"
[[ "$out" != *CODE_AGENT_HEADLESS* ]]; assert "interactive runs are not headless" "$?"

# --headless: one-shot, no TTY, and the agent's non-interactive form
out=$(PATH="$stub_docker:$PATH" "$code_it" -c --headless "fix the build" "${common_args[@]}")
assert_contains "claude --headless uses -p" "$out" 'code-it-alpine-dotnet:latest -p fix\ the\ build'
assert_contains "--headless passes CODE_AGENT_HEADLESS" "$out" "-e CODE_AGENT_HEADLESS=1"
assert_contains "--headless allocates no TTY" "$out" "docker run -i --rm"
out=$(PATH="$stub_docker:$PATH" "$code_it" -o --headless "fix the build" "${common_args[@]}")
assert_contains "opencode --headless uses run" "$out" 'code-it-alpine-dotnet:latest run fix\ the\ build'

# -- passes the rest to the agent verbatim
out=$(PATH="$stub_docker:$PATH" "$code_it" -c "${common_args[@]}" -- --continue --model opus)
assert_contains "-- passes agent flags through" "$out" "code-it-alpine-dotnet:latest --continue --model opus"
out=$(PATH="$stub_docker:$PATH" "$code_it" -c --headless --prompt "tidy" "${common_args[@]}" -- --max-turns 5)
assert_contains "agent flags precede the prompt for claude" "$out" "code-it-alpine-dotnet:latest -p --max-turns 5 tidy"
out=$(PATH="$stub_docker:$PATH" "$code_it" -o --headless --prompt "tidy" "${common_args[@]}" -- --model opus)
assert_contains "agent flags follow run for opencode" "$out" "code-it-alpine-dotnet:latest run --model opus tidy"
# --headless without a prompt leaves the agent command to the caller
out=$(PATH="$stub_docker:$PATH" "$code_it" -c --headless "${common_args[@]}" -- -p "count the files")
assert_contains "--headless with no prompt adds no -p of its own" "$out" 'code-it-alpine-dotnet:latest -p count\ the\ files'

# The prompt reaches the container as a single argument
out=$(PATH="$stub_darwin:$stub_container:$PATH" "$code_it" -c "explain this repo" --work-dir "$script_dir" --save-dir "$save")
assert_contains "prompt is passed as one argument" "$out" "[code-it-alpine-dotnet:latest][explain this repo]"
out=$(PATH="$stub_darwin:$stub_container:$PATH" "$code_it" -c --headless "fix it" --work-dir "$script_dir" --save-dir "$save")
assert_contains "headless run passes -i and the agent args" "$out" "[-i][--rm]"
assert_contains "headless run passes the prompt after -p" "$out" "[code-it-alpine-dotnet:latest][-p][fix it]"

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
        | sed -e "s#/home/agent1/.opencode/bin/opencode#$gobin/opencode#" \
              -e "s#/home/agent1/.local/bin/claude#$gobin/claude#" \
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
echo
echo "Results: $pass passed, $fail failed"
[[ "$fail" == "0" ]] || exit 1

#!/usr/bin/env bash
#
# Tests for code-it-defaults.sh, and for how code-it.sh uses what it saves.
#
# No container runtime is required: the launcher tests place stub `docker` and
# `uname` executables on the PATH and run code-it with --dry-run, asserting on the
# printed run command. The defaults tests run with a PATH that has no jq and no
# curl, so the no-jq line editing and the refresh-missing-tools paths are covered
# hermetically even where they are installed. Run with:
#   ./tests/test-code-it-defaults.sh

set -uo pipefail

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script_dir=$(dirname "$tests_dir")
defaults="$script_dir/code-it-defaults.sh"
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

# A PATH with the tools the scripts need but no jq and no curl, so the no-jq JSON
# editing and the --refresh-models without-them paths test hermetically even on
# machines that have them.
cleanbin="$tmp/cleanbin"
mkdir -p "$cleanbin"
for cmd in bash sh sed grep tr uname dirname mkdir cat head sort mv cp chmod git touch wc tail awk date find; do
    src=$(command -v "$cmd" 2>/dev/null) && ln -s "$src" "$cleanbin/$cmd"
done

# Stub docker, as tests/test-code-it.sh does, for the launcher tests
stub_docker="$tmp/stub-docker"
mkdir -p "$stub_docker"
cat > "$stub_docker/docker" <<'EOF'
#!/bin/sh
case "$1" in
    images)
        [ -n "${STUB_IMAGES_FAIL-}" ] && exit 1
        echo "code-it-alpine-dotnet-node:latest"
        if [ -n "${STUB_IMAGES_EXTRA-}" ]; then echo "$STUB_IMAGES_EXTRA"; fi
        ;;
    image)  case "$*" in *code-it.agent-binaries*) echo "${STUB_IMAGE_AGENT_BINARIES-}" ;; *code-it.agents*) echo "${STUB_IMAGE_AGENTS-}" ;; *) echo "${STUB_IMAGE_TOOL_CHAINS-dotnet,node}" ;; esac ;;
    run)    echo "STUB-DOCKER-RUN $*" ;;
    *)      echo "stub docker: $*" ;;
esac
EOF
chmod +x "$stub_docker/docker"

launched() { PATH="$stub_docker:$PATH" "$code_it" --dry-run --work-dir "$script_dir" "$@"; }

# ---------------------------------------------------------------------------
echo "1. Syntax checks (bash -n)"
for f in code-it-defaults.sh tests/test-code-it-defaults.sh completions/code-it-defaults.bash; do
    bash -n "$script_dir/$f"
    assert "bash -n $f" "$?"
done
if command -v zsh &>/dev/null; then
    zsh -n "$script_dir/completions/_code-it-defaults"
    assert "zsh -n completions/_code-it-defaults" "$?"
fi

# ---------------------------------------------------------------------------
echo "2. --help exits 0 and prints usage"
out=$(PATH="$cleanbin:$PATH" "$defaults" --help)
assert "--help exit code" "$?"
assert_contains "--help shows usage" "$out" "Usage:"
assert_contains "--help documents --agent" "$out" "--agent, -a NAME"
assert_contains "--help documents --model AGENT=MODEL" "$out" "--model AGENT=MODEL"
assert_contains "--help documents --toolchain" "$out" "--toolchain, -t LIST"
assert_contains "--help documents --show" "$out" "--show"
assert_contains "--help documents --refresh-models" "$out" "--refresh-models"
assert_contains "--help documents --dry-run" "$out" "--dry-run, -d"

# ---------------------------------------------------------------------------
echo "3. --show with no defaults"
save_a="$tmp/show-a"; mkdir -p "$save_a"
out=$(PATH="$cleanbin:$PATH" "$defaults" -s "$save_a" --show); assert "--show exit code" "$?"
assert_contains "--show says none saved yet" "$out" "No defaults saved yet"

# ---------------------------------------------------------------------------
echo "4. --agent sets the default agent; unknown agents fail"
save="$tmp/save"; mkdir -p "$save"
out=$(PATH="$cleanbin:$PATH" "$defaults" -s "$save" --agent claude 2>&1); assert "--agent exit code" "$?"
assert_contains "--agent reports it" "$out" "Default agent: claude"
grep -q '^default-agent=claude$' "$save/defaults"; assert "defaults file records the agent" "$?"
PATH="$cleanbin:$PATH" "$defaults" -s "$save" --agent nope >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "unknown agent fails" "$?"
[[ ! "$save/defaults" == *default-agent=nope* ]]; assert "unknown agent saves nothing" "$?"

# ---------------------------------------------------------------------------
echo "5. --toolchain sets the canonical default; unknown toolchains fail"
out=$(PATH="$cleanbin:$PATH" "$defaults" -s "$save" -t node,bun 2>&1); assert "--toolchain exit code" "$?"
grep -q '^default-toolchain=node,bun$' "$save/defaults"; assert "defaults file records the toolchain" "$?"
PATH="$cleanbin:$PATH" "$defaults" -s "$save" -t pv-node >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "unknown toolchain fails" "$?"
PATH="$cleanbin:$PATH" "$defaults" -s "$save" -t ts-node >/dev/null 2>&1
grep -q '^default-toolchain=node$' "$save/defaults"; assert "alias resolves to the canonical name" "$?"
PATH="$cleanbin:$PATH" "$defaults" -s "$save" -t '' >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "empty toolchain fails" "$?"

# ---------------------------------------------------------------------------
echo "6. --model writes each agent's own config under the save dir"
save="$tmp/save"; mkdir -p "$save"
out=$(PATH="$cleanbin:$PATH" "$defaults" -s "$save" --model 'opencode=anthropic/claude-sonnet-4-5' \
    --model 'claude=opus' --model 'opencode-v2=zhipuai/glm-4.6' 2>&1)
assert "--model exit code" "$?"
grep -q '^model.opencode=anthropic/claude-sonnet-4-5$' "$save/defaults"; assert "defaults records opencode's model" "$?"
grep -q '^model.claude=opus$' "$save/defaults"; assert "defaults records claude's model" "$?"
grep -q '^model.opencode-v2=zhipuai/glm-4.6$' "$save/defaults"; assert "defaults records opencode-v2's model" "$?"
grep -q '"model": "anthropic/claude-sonnet-4-5"' "$save/.config/opencode/config.json"
assert "opencode config gets the model key" "$?"
grep -q '"model": "opus"' "$save/.claude/settings.json"; assert "claude settings get the model key" "$?"
grep -q '"model": "zhipuai/glm-4.6"' "$save/opencode-v2/.config/opencode/opencode.json"
assert "opencode-v2 config, under its save subdir, gets the model key" "$?"
pwsh -NoProfile -Command "try { Get-Content '$save/.config/opencode/config.json' -Raw | ConvertFrom-Json | Out-Null; exit 0 } catch { exit 1 }"
assert "edited opencode config is valid JSON" "$?"

# Records survive a round-trip into an existing, other-keyed config
mkdir -p "$save/.config/opencode" "$save/.claude"
cp "$script_dir/agents/opencode/default-config/.config/opencode/config.json" "$save/.config/opencode/config.json"
cp "$script_dir/agents/claude/default-config/.claude/settings.json" "$save/.claude/settings.json"
PATH="$cleanbin:$PATH" "$defaults" -s "$save" --model 'opencode=openai/gpt-5' --model 'claude=claude-opus-4-5' >/dev/null 2>&1
assert "model round-trip exit code" "$?"
grep -q '"schema": "https://opencode.ai/config.json"' "$save/.config/opencode/config.json" \
    || grep -q '"\$schema": "https://opencode.ai/config.json"' "$save/.config/opencode/config.json"
assert "other opencode config keys survive" "$?"
grep -q '"model": "openai/gpt-5"' "$save/.config/opencode/config.json"; assert "opencode model set in existing config" "$?"
grep -q '"defaultMode": "auto"' "$save/.claude/settings.json"; assert "other claude settings keys survive" "$?"
grep -q '"model": "claude-opus-4-5"' "$save/.claude/settings.json"; assert "claude model set in existing settings" "$?"
pwsh -NoProfile -Command "try { Get-Content '$save/.claude/settings.json' -Raw | ConvertFrom-Json | Out-Null; exit 0 } catch { exit 1 }"
assert "edited claude settings are valid JSON" "$?"

# --show lists them
out=$(PATH="$cleanbin:$PATH" "$defaults" -s "$save" --show)
assert_contains "--show lists the agent" "$out" "default agent:"
assert_contains "--show lists the toolchain" "$out" "default toolchain:"
assert_contains "--show lists a model" "$out" "model for claude:"

# The bundled catalog exists and is parseable
catalog=$(PATH="$cleanbin:$PATH" "$defaults" -s "$save" --show; true)
grep -qv '^#' "$script_dir/lib/models.txt"; assert "lib/models.txt has models" "$?"
awk '/^[^#]/ && NF && $0 !~ /^[a-z0-9][a-z0-9.-]*\/[a-z0-9][a-z0-9.-]*$/ { bad=1 } END { exit bad }' "$script_dir/lib/models.txt"
assert "lib/models.txt entries are provider/model" "$?"

# ---------------------------------------------------------------------------
echo "7. --model AGENT= clears the model; bad specs fail"
PATH="$cleanbin:$PATH" "$defaults" -s "$save" --model 'claude=' >/dev/null 2>&1
assert "clearing a model exits 0" "$?"
grep -q '"model"' "$save/.claude/settings.json"
[[ "$?" != "0" ]]; assert "cleared model removed from claude settings" "$?"
grep -q '^model.claude=' "$save/defaults"
[[ "$?" != "0" ]]; assert "cleared model removed from the defaults file" "$?"
PATH="$cleanbin:$PATH" "$defaults" -s "$save" --model 'opencode' >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "--model without AGENT= fails" "$?"
PATH="$cleanbin:$PATH" "$defaults" -s "$save" --model 'nope=x' >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "--model of an unknown agent fails" "$?"

# ---------------------------------------------------------------------------
echo "8. --dry-run writes nothing"
save_d="$tmp/save-dry"; mkdir -p "$save_d"
out=$(PATH="$cleanbin:$PATH" "$defaults" -s "$save_d" --dry-run --agent claude -t node,bun --model 'opencode=x/y' 2>&1)
assert "dry-run exit code" "$?"
assert_contains "dry-run says what it would set" "$out" "would set"
[[ -z "$(find "$save_d" -type f)" ]]; assert "dry-run wrote no files" "$?"

# ---------------------------------------------------------------------------
echo "9. Interactive: picks by number, blanks keep, none clears"
save_i="$tmp/save-int"; mkdir -p "$save_i"
# Toolchains are listed as code-it-build lists them: bun, dotnet, node, powershell, python
out=$(printf '1\n\n\n\n3,5\n' | PATH="$cleanbin:$PATH" "$defaults" -s "$save_i" 2>&1)
assert "interactive exit code" "$?"
grep -q '^default-agent=claude$' "$save_i/defaults"; assert "first agent preselected answer is claude" "$?"
grep -q '^default-toolchain=node,python$' "$save_i/defaults"; assert "toolchain answered by numbers" "$?"
[[ ! -e "$save_i/.claude/settings.json" ]]; assert "blank model answer keeps (creates nothing)" "$?"
out=$(printf '2\n\nmy-favourite-model\n\nnode\n' | PATH="$cleanbin:$PATH" "$defaults" -s "$save_i" 2>&1)
assert "second interactive run exit code" "$?"
grep -q '^default-agent=opencode-v2$' "$save_i/defaults"; assert "agent answered as a name" "$?"
grep -q '^model.opencode-v2=my-favourite-model$' "$save_i/defaults"; assert "a free-text model is accepted" "$?"
grep -q '^model.claude=' "$save_i/defaults"
[[ "$?" != "0" ]]; assert "kept model is not overwritten" "$?"
out=$(printf '5\nsonnet\nnone\n\nnone\n' | PATH="$cleanbin:$PATH" "$defaults" -s "$save_i" 2>&1)
assert "third interactive run exit code" "$?"
grep -q '^default-agent=opencode-v2$' "$save_i/defaults"; assert "out-of-range number keeps the saved agent" "$?"
grep -q '^model.claude=sonnet$' "$save_i/defaults"; assert "claude model set by number from its list" "$?"
grep -q '^model.opencode-v2=' "$save_i/defaults"
[[ "$?" != "0" ]]; assert "'none' clears a model" "$?"
grep -q '^model.opencode-v2=my-favourite-model$' "$save_i/.claude/settings.json" 2>/dev/null
[[ -z "$(cat "$save_i/opencode-v2/.config/opencode/opencode.json" 2>/dev/null | grep '"model"')" ]]
assert "'none' clears the model from the agent's config" "$?"
grep -q '^default-toolchain=' "$save_i/defaults"
[[ "$?" != "0" ]]; assert "'none' clears the toolchain" "$?"
out=$(printf 'none\n' | PATH="$cleanbin:$PATH" "$defaults" -s "$save_i" --yes 2>&1)
PATH="$cleanbin:$PATH" "$defaults" -s "$save_i" --show >/dev/null 2>&1
PATH="$cleanbin:$PATH" "$defaults" -s "$save_i" --refresh-models >/dev/null 2>&1
[[ "$?" != "0" ]]; assert "--refresh-models without curl and jq fails" "$?"
[[ ! -e "$save_i/model-catalog.txt" ]]; assert "failed refresh writes no cache" "$?"

# ---------------------------------------------------------------------------
echo "10. --refresh-models with stub curl and jq writes the catalog cache, which the picker then uses"
save_r="$tmp/save-refresh"; mkdir -p "$save_r"
stubbin="$tmp/stubbin"; mkdir -p "$stubbin"
cat > "$stubbin/curl" <<'EOF'
#!/bin/sh
echo '{"prov1":{"models":{"m-one":{},"m-two":{}}},"prov2":{"models":{"m-three":{}}},"prov3":{}}'
EOF
cat > "$stubbin/jq" <<'EOF'
#!/bin/sh
cat > /dev/null
printf 'prov1/m-two\nprov1/m-one\nprov2/m-three\n'
EOF
chmod +x "$stubbin/curl" "$stubbin/jq"
out=$(PATH="$stubbin:$cleanbin:$PATH" "$defaults" -s "$save_r" --refresh-models 2>&1)
assert "--refresh-models exit code" "$?"
assert_contains "--refresh-models reports it" "$out" "Refreshed"
grep -q '^prov1/m-one$' "$save_r/model-catalog.txt"; assert "cache has the fetched models, sorted" "$?"
grep -qv '^#' "$save_r/model-catalog.txt"; assert "cache has more than the header" "$?"
out=$(printf '1\n99\n\n\nnode\n' | PATH="$stubbin:$cleanbin:$PATH" "$defaults" -s "$save_r" 2>&1)
assert_contains "the interactive picker offers the fetched catalog" "$out" "prov1/m-one"
grep -q '^model.claude=' "$save_r/defaults"
[[ "$?" != "0" ]]; assert "picker out-of-range number is refused" "$?"

# ---------------------------------------------------------------------------
echo "11. code-it uses the saved defaults; its own options win"
d="$tmp/launcher"; mkdir -p "$d"
printf 'default-agent=claude\ndefault-toolchain=node\nmodel.opencode=y/z\n' > "$d/defaults"

out=$(launched --save-dir "$d" 2>&1)
assert_contains "launches the saved agent" "$out" 'CODE_AGENT="claude"'
assert_contains "says the toolchain came from defaults" "$out" "Using saved default toolchain: node"
assert_contains "uses an image named for the default toolchain" "$out" "'code-it-alpine-node' does not exist; using 'code-it-alpine-dotnet-node'"
assert_contains "no package cache for node but npm" "$out" 'npm-host'

out=$(launched --save-dir "$d" -o 2>&1)
assert_contains "--opencode beats the saved agent" "$out" 'CODE_AGENT="opencode"'

out=$(launched --save-dir "$d" -c 2>&1)
assert_contains "--claude launches claude" "$out" 'CODE_AGENT="claude"'

out=$(launched --save-dir "$d" --toolchain dotnet 2>&1)
[[ "$out" != *"saved default toolchain"* ]]; assert "--toolchain beats the saved default" "$?"
assert_contains "--toolchain derives the image" "$out" "code-it-alpine-dotnet"

out=$(STUB_IMAGES_EXTRA="code-it-alpine-custom:latest" launched --save-dir "$d" --image code-it-alpine-custom 2>&1)
[[ "$out" != *"saved default toolchain"* ]]; assert "--image beats the saved default" "$?"
assert_contains "the named image is used as-is" "$out" "code-it-alpine-custom:latest"

# A remembered image does not override the default toolchain (Spec 09's heuristic)
printf '20260101 code-it-alpine-dotnet-node\n' > "$d/image-history"
out=$(launched --save-dir "$d" 2>&1)
assert_contains "the saved default beats the remembered-image heuristic" "$out" "Using saved default toolchain: node"

# Unknown saved agents error like unknown --agent
printf 'default-agent=ghost\n' > "$d/defaults"
out=$(launched --save-dir "$d" 2>&1)
assert_contains "unknown saved agent warns" "$out" "Unknown agent 'ghost'"

# Without a relevant default, everything is as before
rm -f "$d/defaults"
out=$(launched --save-dir "$d" 2>&1)
assert_contains "no defaults: opencode" "$out" 'CODE_AGENT="opencode"'
[[ "$out" != *"saved default toolchain"* ]]; assert "no defaults: no toolchain note" "$?"

# code-it --help documents where defaults fit
out=$(PATH="$stub_docker:$PATH" "$code_it" --help)
assert_contains "code-it --help mentions code-it-defaults" "$out" "code-it-defaults"

# ---------------------------------------------------------------------------
echo
echo "12. A save dir that does not exist yet; --show names the model files; the agent switch says so"

# Saving must create the save dir: on a machine code-it has not run on yet, it is absent
fresh="$tmp/save-created-by-defaults"
out=$(PATH="$cleanbin:$PATH" "$defaults" --save-dir "$fresh" --agent opencode --toolchain node 2>&1)
rc=$?
assert "parameterised run into a missing save dir exits 0" "$rc"
[[ -f "$fresh/defaults" ]]; assert "defaults file written" "$?"
assert_contains "it says the agent was set" "$out" "Default agent: opencode"

# --show names where each agent's model was set
show_d="$tmp/show-d"
mkdir -p "$show_d/.config/opencode"
printf '%s\n' "default-agent=opencode" "model.opencode=anthropic/claude-sonnet-4-5" > "$show_d/defaults"
printf '{\n  "model": "anthropic/claude-sonnet-4-5"\n}\n' > "$show_d/.config/opencode/config.json"
out=$(PATH="$cleanbin:$PATH" "$defaults" --save-dir "$show_d" --show)
printf '%s\n' "$out" | grep -q 'model for opencode:.*anthropic/claude-sonnet-4-5'
assert "--show shows the model" "$?"
assert_contains "--show names the model file" "$out" "(set in $show_d/.config/opencode/config.json)"

# Switching the default agent interactively explains that the agent's own state,
# and login, come with it
note_d="$tmp/note-d"
out=$(printf 'opencode-v2\nnone\nnone\nnone\nnone\n' | PATH="$cleanbin:$PATH" "$defaults" --save-dir "$note_d" 2>&1)
rc=$?
assert "interactive switch exits 0" "$rc"
assert_contains "the switch explains each agent's own state and login" "$out" "log in again"
[[ -f "$note_d/defaults" ]] && grep -q '^default-agent=opencode-v2$' "$note_d/defaults"
assert "the switched agent is saved" "$?"

# Plain code-it says when the saved agent is what it launches
agent_d="$tmp/agent-d"
mkdir -p "$agent_d"
printf 'default-agent=claude\n' > "$agent_d/defaults"
out=$(launched --save-dir "$agent_d" 2>&1)
assert_contains "code-it says which saved agent it launches" "$out" "Using saved default agent: claude"
rm -f "$agent_d/defaults"
out=$(launched --save-dir "$agent_d" 2>&1)
[[ "$out" != *"saved default agent"* ]]; assert "no default agent: no agent note" "$?"

# ---------------------------------------------------------------------------
echo
echo "Results: $pass passed, $fail failed"
[[ "$fail" == "0" ]] || exit 1

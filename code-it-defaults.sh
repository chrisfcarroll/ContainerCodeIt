#!/usr/bin/env bash
#
# Sets the defaults code-it uses when you give it no options: which agent to run,
# which model each agent uses, and which toolchain image to prefer.
#
# With no parameters it asks. With any of --agent/--model/--toolchain it sets exactly
# those and asks nothing. Everything is saved in SAVE-DIR/defaults (default
# ~/.config/code-it/defaults), which code-it reads; models are also written into each
# agent's own configuration under the save dir (from AGENT_MODEL_FILE in
# agents/NAME/config), so the agent picks them up on every run.
#
# Usage:
#   ./code-it-defaults.sh [OPTIONS]
#
# Options:
#   --agent, -a NAME        Set the default agent, as code-it --agent would take it.
#                           `none` clears it.
#   --model AGENT=MODEL     Set AGENT's default model in its own config, e.g.
#                             --model 'opencode=anthropic/claude-sonnet-4-5'
#                             --model 'claude=opus'
#                           An empty MODEL, as in --model 'opencode=', clears it.
#                           Repeatable. Any model string is accepted: the catalog of
#                           known models is best effort and always incomplete.
#   --toolchain, -t LIST    Set the default toolchain list, as code-it --toolchain
#                           would take it. Overrides code-it's remembered-image
#                           heuristic; an explicit --toolchain still wins.
#   --show                  Print the current defaults and exit.
#   --refresh-models        Refresh SAVE-DIR/model-catalog.txt, the model list offered
#                           by the interactive picker, from https://models.dev/api.json
#                           (needs curl and jq). The bundled list in lib/models.txt is
#                           used until then.
#   --save-dir, -s DIR      Where the defaults and agent state live.
#                           Default: ~/.config/code-it
#   --dry-run, -d           Show what would be written; change nothing.
#   --help, -h              Show this help message.
#
# Interactive questions read answers from stdin, so they can be scripted; a blank
# answer keeps the current value.

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/code-it-common.sh
. "$script_dir/lib/code-it-common.sh"

CI_MODELS_URL="https://models.dev/api.json"
CI_DEFAULTS_HEADER="# code-it defaults, written by code-it-defaults, read by code-it."
# Claude Code's model aliases, offered by the picker alongside full model names
CI_CLAUDE_ALIASES="opus sonnet haiku opusplan"

save_dir="$HOME/.config/code-it"
agent_arg=""
toolchain_arg=""
toolchain_set=false
model_args=()
show=false
refresh=false
dry_run=false

show_help() { sed -n '2,/^$/{ s/^# \{0,1\}//; p; }' "$0"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent|-a)       agent_arg="$2"; shift 2 ;;
        --model)          model_args+=("$2"); shift 2 ;;
        --toolchain|-t)   toolchain_arg="$2"; toolchain_set=true; shift 2 ;;
        --show)           show=true; shift ;;
        --refresh-models) refresh=true; shift ;;
        --save-dir|-s)    save_dir="$2"; shift 2 ;;
        --dry-run|-d)     dry_run=true; shift ;;
        --help|-h)        show_help; exit 0 ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Run $0 --help for usage." >&2
            exit 1
            ;;
        *)
            echo "Unexpected argument: $1" >&2
            echo "Run $0 --help for usage." >&2
            exit 1
            ;;
    esac
done

agents_dir="$script_dir/agents"
defaults_file="$save_dir/defaults"
catalog_bundled="$script_dir/lib/models.txt"
catalog_cache="$save_dir/model-catalog.txt"

# current KEY: the saved value of KEY in the defaults file, or nothing
current() {
    local v=""
    v=$(ci_config_value "$defaults_file" "$1" 2>/dev/null) || true
    printf '%s' "$v"
}

# defaults_set KEY [VALUE]: set KEY=VALUE in the defaults file, preserving the rest
# of the file; empty VALUE removes the line. --dry-run prints what would change.
defaults_set() {
    local key="$1" value="${2:-}" line found=false tmp
    if [[ "$dry_run" == true ]]; then
        if [[ -n "$value" ]]; then
            echo "    would set in $defaults_file: $key=$value"
        else
            echo "    would remove from $defaults_file: $key"
        fi
        return 0
    fi
    # The save dir may not exist yet on a machine that has not run code-it
    mkdir -p "$save_dir" || return 1
    if [[ -f "$defaults_file" ]]; then
        tmp="$defaults_file.tmp"
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "$key="* ]]; then
                found=true
                if [[ -n "$value" ]]; then printf '%s=%s\n' "$key" "$value"; fi
            else
                printf '%s\n' "$line"
            fi
        done < "$defaults_file" > "$tmp"
        mv "$tmp" "$defaults_file"
    fi
    if [[ "$found" == false && -n "$value" ]]; then
        [[ -f "$defaults_file" ]] || printf '%s\n' "$CI_DEFAULTS_HEADER" > "$defaults_file"
        printf '%s=%s\n' "$key" "$value" >> "$defaults_file"
    fi
}

# json_editable FILE: true if FILE is absent or empty, or a pretty-printed object (an
# opening "{" alone on its first line) — the only kind the no-jq line editing below
# can handle
json_editable() {
    [[ -f "$1" ]] || return 0
    [[ ! -s "$1" ]] && return 0
    [[ "$(head -n 1 "$1" | tr -d '[:space:]')" == "{" ]]
}

# json_set FILE KEY VALUE: set the top-level KEY of the JSON object in FILE to the
# string VALUE, creating FILE if absent and otherwise preserving the rest. Uses jq
# when it is installed; otherwise edits lines, which only works for the pretty
# one-key-per-line objects code-it writes. Returns 1, with a warning, if the file
# cannot be edited safely.
json_set() {
    local file="$1" key="$2" value="$3" tmp line found=false comma=""
    if [[ -f "$file" ]] && command -v jq >/dev/null 2>&1; then
        tmp=$(mktemp "${TMPDIR:-/tmp}/code-it-defaults.XXXXXX") || tmp=""
        if [[ -n "$tmp" ]] && jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$file" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$file"
            return 0
        fi
        [[ -n "$tmp" ]] && rm -f "$tmp"
        # Fall through to line editing
    fi
    if [[ -f "$file" ]] && ! json_editable "$file"; then
        echo "Warning: Cannot edit $file safely (no jq found, and the JSON is not one key per line)." >&2
        echo "    Add \"$key\": \"$value\" to it by hand." >&2
        return 1
    fi
    tmp="$file.tmp"
    local -a lines=() out=()
    if [[ -f "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            lines+=("${line%$'\r'}")
        done < "$file"
        # The opening brace must be alone on its first line (json_editable checked)
        # and the closing brace on its own last line, for the insert below to be safe
        line=$(printf '%s\n' "${lines[${#lines[@]} - 1]}" | tr -d '[:space:]')
        if [[ "$line" != "}" ]]; then
            echo "Warning: Cannot edit $file safely (no jq found, and the JSON is not one key per line)." >&2
            echo "    Add \"$key\": \"$value\" to it by hand." >&2
            return 1
        fi
    fi
    if [[ ${#lines[@]} -eq 0 ]]; then
        printf '{\n  "%s": "%s"\n}\n' "$key" "$value" > "$tmp"
    else
        local inserted=false
        for i in "${!lines[@]}"; do
            line="${lines[i]}"
            if [[ "$line" =~ ^([[:space:]]*)\"$key\"[[:space:]]*: ]]; then
                comma=""
                [[ "$line" == *, ]] && comma=","
                out+=("$(printf '%s"%s": "%s"%s' "${BASH_REMATCH[1]}" "$key" "$value" "$comma")")
                found=true
            else
                out+=("$line")
                if [[ "$i" -eq 0 && "$found" == false && "$inserted" == false ]]; then
                    # The opening brace: a new key goes right after it, with a trailing
                    # comma, which is valid whatever the other keys' values look like
                    out+=("$(printf '  "%s": "%s",' "$key" "$value")")
                    inserted=true
                fi
            fi
        done
        if [[ "$found" == false && "$inserted" == false ]]; then
            # An object with no keys: the new key is the only one, so no comma
            local -a body=("${out[@]:0:${#out[@]}-1}")
            out=(${body[@]+"${body[@]}"} "$(printf '  "%s": "%s"' "$key" "$value")" "${out[${#out[@]} - 1]}")
        fi
        for line in "${out[@]}"; do printf '%s\n' "$line"; done > "$tmp"
    fi
    mv "$tmp" "$file"
}

# json_remove FILE KEY: remove the top-level KEY from the JSON object in FILE. Best
# effort like json_set; a missing KEY, or missing FILE, is fine.
json_remove() {
    local file="$1" key="$2" tmp line found=false i prev
    if [[ -f "$file" ]] && command -v jq >/dev/null 2>&1; then
        tmp=$(mktemp "${TMPDIR:-/tmp}/code-it-defaults.XXXXXX") || tmp=""
        if [[ -n "$tmp" ]] && jq --arg k "$key" 'del(.[$k])' "$file" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$file"
            return 0
        fi
        [[ -n "$tmp" ]] && rm -f "$tmp"
    fi
    [[ -f "$file" ]] || return 0
    if ! json_editable "$file"; then
        echo "Warning: Cannot edit $file safely (no jq found, and the JSON is not one key per line)." >&2
        echo "    Remove \"$key\" from it by hand." >&2
        return 1
    fi
    local -a lines=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        lines+=("${line%$'\r'}")
    done < "$file"
    for i in "${!lines[@]}"; do
        if [[ "${lines[i]}" =~ ^([[:space:]]*)\"$key\"[[:space:]]*: ]]; then
            found=true
            # Removing a key leaves the entry before it with a dangling comma when
            # the removed one was the last. In valid JSON exactly one line of the
            # previous entry ends with a comma; find and strip it. A removed key with
            # a trailing comma had keys after it: nothing dangles.
            if [[ "${lines[i]}" != *, ]]; then
                for ((prev = i - 1; prev >= 0; prev--)); do
                    if [[ "${lines[prev]}" == *, ]]; then
                        lines[prev]="${lines[prev]%,}"
                        break
                    fi
                done
            fi
            unset 'lines[i]'
        fi
    done
    if [[ "$found" == false ]]; then
        return 0
    fi
    tmp="$file.tmp"
    for line in "${lines[@]}"; do printf '%s\n' "$line"; done > "$tmp"
    mv "$tmp" "$file"
}

# json_get FILE KEY: the string value of the top-level KEY, or nothing
json_get() {
    local file="$1" key="$2" line
    [[ -f "$file" ]] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null && return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        if [[ "$line" =~ ^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done < "$file"
}

# agent_save_path AGENT REL: where AGENT's REL lives under the save dir, including
# any AGENT_SAVE_SUBDIR
agent_save_path() {
    local subdir=""
    subdir=$(ci_agent_config "$agents_dir" "$1" AGENT_SAVE_SUBDIR) || subdir=""
    printf '%s%s/%s' "$save_dir" "${subdir:+/$subdir}" "$2"
}

# set_model AGENT MODEL: write MODEL into the agent's own config, the AGENT_MODEL_FILE
# of its definition, and record it as model.AGENT in the defaults file. Empty MODEL
# clears both. Returns 1 if the agent has no known model mechanism.
set_model() {
    local agent="$1" model="$2" spec path key target
    if ! ci_agent_exists "$agents_dir" "$agent"; then
        echo "Warning: Unknown agent '$agent'. Known agents: $(ci_list_agents "$agents_dir" | tr '\n' ' ')" >&2
        return 1
    fi
    spec=$(ci_agent_config "$agents_dir" "$agent" AGENT_MODEL_FILE) || spec=""
    if [[ -z "$spec" || "$spec" != *:* ]]; then
        echo "Warning: agents/$agent/config has no AGENT_MODEL_FILE, so there is no known way to set its default model." >&2
        return 1
    fi
    path=${spec%%:*}
    key=${spec##*:}
    target=$(agent_save_path "$agent" "$path")
    if [[ -z "$model" ]]; then
        if [[ "$dry_run" == true ]]; then
            echo "    would clear $agent's model in $target"
        else
            if [[ -f "$target" ]] && ! json_remove "$target" "$key"; then
                return 1
            fi
            echo "    Cleared $agent's model in $target"
        fi
        defaults_set "model.$agent" ""
        return 0
    fi
    if [[ "$model" =~ [[:cntrl:]] ]]; then
        echo "Warning: '$model' is not a model name I can save." >&2
        return 1
    fi
    if [[ "$dry_run" == true ]]; then
        echo "    would set $agent's model in $target: \"$key\": \"$model\""
    else
        mkdir -p "$(dirname "$target")"
        json_set "$target" "$key" "$model" || return 1
        echo "    Set $agent's model in $target: $model"
    fi
    defaults_set "model.$agent" "$model"
}

# catalog_file: the model catalog to offer: the refreshed cache when present, else
# the bundled list
catalog_file() {
    if [[ -f "$catalog_cache" ]]; then
        printf '%s' "$catalog_cache"
    else
        printf '%s' "$catalog_bundled"
    fi
}

refresh_models() {
    if [[ "$dry_run" == true ]]; then
        echo "    would fetch $CI_MODELS_URL into $catalog_cache"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        echo "Warning: --refresh-models needs curl and jq." >&2
        return 1
    fi
    mkdir -p "$save_dir"
    local tmp="$catalog_cache.tmp"
    if ! curl -fsSL --max-time 30 "$CI_MODELS_URL" 2>/dev/null \
            | jq -r 'to_entries[] | .key as $p | (.value.models // {}) | keys[] | $p + "/" + .' > "$tmp" \
            || [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        echo "Warning: Could not fetch the model catalog from $CI_MODELS_URL." >&2
        return 1
    fi
    {
        printf '# model catalog refreshed from %s on %s\n' "$CI_MODELS_URL" "$(date +%Y-%m-%d)"
        sort -u "$tmp"
    } > "$catalog_cache"
    rm -f "$tmp"
    echo "    Refreshed $catalog_cache ($(grep -cv '^#' "$catalog_cache" || true) models)"
}

# do_show: the saved defaults, or a pointer to the interactive run
do_show() {
    local a m t m_file spec live
    if [[ ! -f "$defaults_file" ]]; then
        echo "No defaults saved yet in $defaults_file."
        echo "Run code-it-defaults with no arguments to set them."
        return 0
    fi
    echo "Saved defaults in $defaults_file:"
    a=$(current default-agent)
    if [[ -n "$a" ]]; then printf '  %-22s %s\n' "default agent:" "$a"; fi
    t=$(current default-toolchain)
    if [[ -n "$t" ]]; then printf '  %-22s %s\n' "default toolchain:" "$t"; fi
    while IFS= read -r a; do
        m=$(current "model.$a")
        m_file=""
        spec=$(ci_agent_config "$agents_dir" "$a" AGENT_MODEL_FILE) || spec=""
        if [[ -n "$spec" && "$spec" == *:* ]]; then
            m_file=$(agent_save_path "$a" "${spec%%:*}")
            live=$(json_get "$m_file" "${spec##*:}")
            # The agent's own config is the source of truth for its model
            [[ -n "$live" ]] && m=$live
        fi
        if [[ -n "$m" ]]; then
            printf '  %-22s %s\n' "model for $a:" "$m"
            [[ -n "$m_file" ]] && printf '    (set in %s)\n' "$m_file"
        fi
    done < <(ci_list_agents "$agents_dir")
    return 0
}

# pick_one ANSWER items...: the item ANSWER names, by number or name, else nothing
pick_one() {
    local answer="$1"; shift
    local items=("$@") it
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#items[@]} )); then
        printf '%s' "${items[$((answer - 1))]}"
        return 0
    fi
    for it in "${items[@]}"; do
        [[ "$it" == "$answer" ]] && { printf '%s' "$it"; return 0; }
    done
    return 1
}

# parse_multi ANSWER items...: the items ANSWER names, by number or name, comma- or
# space-separated, as ci_comma_list_add builds them
parse_multi() {
    local answer="$1"; shift
    local items=("$@") out="" tok it
    local IFS=', '
    for tok in $answer; do
        [[ -n "$tok" ]] || continue
        if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#items[@]} )); then
            out=$(ci_comma_list_add "$out" "${items[$((tok - 1))]}")
        else
            for it in "${items[@]}"; do
                [[ "$it" == "$tok" ]] && out=$(ci_comma_list_add "$out" "$it")
            done
        fi
    done
    printf '%s' "$out"
}

# choose_from LABEL DEFAULT DETECTED CURRENT items...: print a numbered list and read
# a choice from stdin; echoes the chosen item. CLEAR ("none") clears, blank keeps
# DEFAULT, which may be empty.
choose_from() {
    local label="$1" default="$2" detected="$3" current="$4"; shift 4
    local items=("$@") i=1 item flag answer
    printf '%s (detected marked *):\n' "$label" >&2
    for item in ${items[@]+"${items[@]}"}; do
        flag=""
        [[ "$item" == "$current" ]] && flag=" (current)"
        case " $detected " in *" $item "*) flag=" *$flag" ;; esac
        printf '  %d) %s%s\n' "$i" "$item" "$flag" >&2
        i=$((i + 1))
    done
    printf 'Choose %s [%s, or none]: ' "$label" "$(ci_join , "${default:-none}")" >&2
    read -r answer || answer=""
    [[ -z "$answer" ]] && answer="$default"
    printf '%s' "$answer"
}

interactive() {
    local agents_available=() detected_agents="" detected_toolchain="" a answer
    while IFS= read -r a; do agents_available+=("$a"); done < <(ci_list_agents "$agents_dir")
    for a in ${agents_available[@]+"${agents_available[@]}"}; do
        ci_agent_detected "$agents_dir" "$a" && detected_agents=$(ci_comma_list_add "$detected_agents" "$a")
    done

    echo "Setting code-it defaults, saved in $defaults_file. A blank answer keeps the"
    echo "current value; code-it uses them whenever its own options do not say."

    # 1. Default agent
    echo
    local saved_agent preselect
    saved_agent=$(current default-agent)
    preselect="$saved_agent"
    [[ -z "$preselect" ]] && preselect="${detected_agents%% *}"
    [[ -z "$preselect" ]] && preselect="${CI_DEFAULT_AGENTS%% *}"
    answer=$(choose_from "default agent" "$preselect" "$detected_agents" "$saved_agent" ${agents_available[@]+"${agents_available[@]}"})
    if [[ "$answer" == "none" || -z "$answer" ]]; then
        defaults_set default-agent ""
    else
        a=$(pick_one "$answer" "${agents_available[@]}") || a=""
        if [[ -n "$a" ]]; then
            defaults_set default-agent "$a"
            echo "    Default agent: $a"
            if [[ "$a" != "$saved_agent" ]]; then
                echo "    Note: each agent keeps its own state, and its own login, under the"
                echo "    save dir, so switching the default agent switches that state too."
                echo "    opencode-v2 keeps its login in the database under its own directory,"
                echo "    so its first run there can ask you to log in again."
            fi
        else
            echo "    Unknown agent '$answer'; keeping what is saved." >&2
        fi
    fi

    # 2. Default model, for each agent that has a known mechanism
    local spec path key live target catalog entry claude_style="" choice
    local -a models=()
    for a in "${agents_available[@]}"; do
        spec=$(ci_agent_config "$agents_dir" "$a" AGENT_MODEL_FILE) || spec=""
        if [[ -z "$spec" || "$spec" != *:* ]]; then
            echo
            echo "No known way to set $a's default model (no AGENT_MODEL_FILE in its definition); skipping."
            continue
        fi
        path=${spec%%:*}
        target=$(agent_save_path "$a" "$path")
        live=$(json_get "$target" "${spec##*:}")
        echo
        echo "Default model for $a [current: ${live:-none}]. The catalog below is best effort"
        echo "and always incomplete: any model string is accepted."
        models=()
        claude_style=""
        case "$path" in .claude/*) claude_style=true ;; esac
        if [[ "$claude_style" == true ]]; then
            for entry in $CI_CLAUDE_ALIASES; do models+=("$entry"); done
        fi
        catalog=$(catalog_file)
        if [[ -f "$catalog" ]]; then
            while IFS= read -r entry; do
                entry=${entry%%#*}
                entry=${entry%"${entry##*[![:space:]]}"}
                [[ -z "$entry" ]] && continue
                # Claude Code takes bare model names, not provider/model ids: offer
                # Anthropic's without the prefix, and nothing else
                if [[ "$claude_style" == true ]]; then
                    case "$entry" in anthropic/*) entry=${entry#anthropic/} ;; *) continue ;; esac
                fi
                models+=("$entry")
            done < "$catalog"
        fi
        local i=1
        for entry in ${models[@]+"${models[@]}"}; do
            flag=""
            [[ "$entry" == "$live" ]] && flag=" (current)"
            printf '  %d) %s%s\n' "$i" "$entry" "$flag"
            i=$((i + 1))
        done
        printf "Choose model for %s [%s, 'none' clears]: " "$a" "${live:-none}"
        read -r answer || answer=""
        if [[ -z "$answer" ]]; then
            continue
        elif [[ "$answer" == "none" ]]; then
            set_model "$a" ""
        elif [[ "$answer" =~ ^[0-9]+$ ]]; then
            if (( answer >= 1 && answer <= ${#models[@]} )); then
                set_model "$a" "${models[$((answer - 1))]}"
            else
                echo "    No such entry: $answer; keeping $a's model as it is." >&2
            fi
        else
            set_model "$a" "$answer"
        fi
    done

    # 3. Default toolchain, as code-it-build's selection: multi-choice, detected
    # preselected (powershell too on Windows)
    echo
    local toolchain_available=($CI_KNOWN_TOOLCHAIN) saved_toolchain t
    for t in "${toolchain_available[@]}"; do
        ci_toolchain_detected "$t" && detected_toolchain=$(ci_comma_list_add "$detected_toolchain" "$t")
    done
    saved_toolchain=$(current default-toolchain)
    if [[ -n "$saved_toolchain" ]]; then
        preselect="$saved_toolchain"
    else
        preselect="$detected_toolchain"
        ci_host_is_windows && preselect=$(ci_comma_list_add "$preselect" powershell)
    fi
    answer=$(choose_from "default toolchain" "$preselect" "$detected_toolchain" "$saved_toolchain" "${toolchain_available[@]}")
    if [[ "$answer" == "none" || -z "$answer" ]]; then
        defaults_set default-toolchain ""
    else
        local multi
        multi=$(parse_multi "$answer" "${toolchain_available[@]}")
        multi=$(ci_resolve_toolchain "$(ci_join , "$multi")") || multi=""
        if [[ -n "$multi" ]]; then
            defaults_set default-toolchain "$(ci_join , "$multi")"
            echo "    Default toolchain: $(ci_join , "$multi")"
        fi
    fi

    echo
    do_show
}

# ---------------------------------------------------------------------------
# Main

if [[ "$refresh" == true ]]; then
    refresh_models || exit 1
fi

if [[ "$show" == true ]]; then
    do_show
    exit 0
fi

if [[ -z "$agent_arg" && "$toolchain_set" == false && ${#model_args[@]} -eq 0 ]]; then
    interactive
    exit 0
fi

# Parameterised: set exactly what was given, ask nothing
rc=0
if [[ -n "$agent_arg" ]]; then
    if [[ "$agent_arg" == "none" ]]; then
        defaults_set default-agent ""
    elif ci_agent_exists "$agents_dir" "$agent_arg"; then
        defaults_set default-agent "$agent_arg"
        echo "    Default agent: $agent_arg"
    else
        echo "Warning: Unknown agent '$agent_arg'. Known agents: $(ci_list_agents "$agents_dir" | tr '\n' ' ')" >&2
        rc=1
    fi
fi
for m in ${model_args[@]+"${model_args[@]}"}; do
    if [[ "$m" != *=* ]]; then
        echo "Warning: --model needs AGENT=MODEL, not '$m'." >&2
        rc=1
        continue
    fi
    set_model "${m%%=*}" "${m#*=}" || rc=1
done
if [[ "$toolchain_set" == true ]]; then
    resolved=$(ci_resolve_toolchain "$toolchain_arg") || resolved=""
    if [[ -z "$resolved" ]]; then
        echo "Warning: --toolchain needs at least one known toolchain." >&2
        rc=1
    else
        defaults_set default-toolchain "$(ci_join , "$resolved")"
        echo "    Default toolchain: $(ci_join , "$resolved")"
    fi
fi
exit "$rc"

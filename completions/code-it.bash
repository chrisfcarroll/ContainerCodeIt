# Bash completion for code-it.sh, claude-it.sh and opencode-it.sh.
#
# Install by sourcing it, e.g. from ~/.bashrc:
#     source /path/to/ContainerCodeIt/completions/code-it.bash
#
# Completes the launcher's own options, and, after `--`, the flags of whichever
# coding agent the command line selects: claude-it.sh (or -c) completes Claude Code
# flags, opencode-it.sh (or -o, the default) completes OpenCode flags.
#     https://code.claude.com/docs/en/cli-reference
#     https://opencode.ai/docs/cli/

_code_it_opts='--opencode -o --claude -c --prompt --headless --work-dir --save-dir
    --image --build-image --rebuild-image --dockerfile-dir --runtime --ports
    --agent-name --dry-run --help -h --'

# The flags people reach for most, not the full list; add your own favourites here.
_code_it_claude_opts='--print -p --continue -c --resume -r --fork-session --model
    --fallback-model --effort --agent --permission-mode --dangerously-skip-permissions
    --allowed-tools --disallowed-tools --add-dir --append-system-prompt --settings
    --mcp-config --output-format --max-turns --max-budget-usd --verbose --debug --ide'
_code_it_claude_models='opus sonnet haiku claude-opus-5 claude-sonnet-5 claude-haiku-4-5'
_code_it_claude_permission_modes='default acceptEdits plan auto dontAsk bypassPermissions manual'

_code_it_opencode_opts='run --continue -c --session -s --fork --prompt --model -m
    --agent --auto --port --hostname --share --file -f --format --title --thinking
    --variant --dir'

_code_it() {
    local cur prev agent seen_dashdash=0 i

    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}

    # Which agent's flags to offer: the alias script chooses it, a later -c/-o wins
    case "${COMP_WORDS[0]}" in
        *claude-it*) agent=claude ;;
        *)           agent=opencode ;;
    esac
    for (( i = 1; i < COMP_CWORD; i++ )); do
        case "${COMP_WORDS[i]}" in
            --claude|-c)   agent=claude ;;
            --opencode|-o) agent=opencode ;;
            --)            seen_dashdash=1 ;;
        esac
    done

    if (( seen_dashdash )); then
        if [[ "$agent" == claude ]]; then
            case "$prev" in
                --model|--fallback-model)
                    COMPREPLY=( $(compgen -W "$_code_it_claude_models" -- "$cur") ); return ;;
                --permission-mode)
                    COMPREPLY=( $(compgen -W "$_code_it_claude_permission_modes" -- "$cur") ); return ;;
                --effort)
                    COMPREPLY=( $(compgen -W "low medium high xhigh max" -- "$cur") ); return ;;
                --output-format)
                    COMPREPLY=( $(compgen -W "text json stream-json" -- "$cur") ); return ;;
                --add-dir|--settings|--mcp-config)
                    COMPREPLY=( $(compgen -f -- "$cur") ); return ;;
            esac
            COMPREPLY=( $(compgen -W "$_code_it_claude_opts" -- "$cur") )
        else
            case "$prev" in
                --format)     COMPREPLY=( $(compgen -W "default json" -- "$cur") ); return ;;
                --file|-f)    COMPREPLY=( $(compgen -f -- "$cur") ); return ;;
                --dir)        COMPREPLY=( $(compgen -d -- "$cur") ); return ;;
            esac
            COMPREPLY=( $(compgen -W "$_code_it_opencode_opts" -- "$cur") )
        fi
        return
    fi

    case "$prev" in
        --work-dir|--save-dir|--dockerfile-dir)
            COMPREPLY=( $(compgen -d -- "$cur") ); return ;;
        --runtime)
            COMPREPLY=( $(compgen -W "docker container" -- "$cur") ); return ;;
        --image)
            COMPREPLY=( $(compgen -W "code-it-alpine-dotnet $(docker images --format '{{.Repository}}' 2>/dev/null)" -- "$cur") ); return ;;
        --agent-name)
            COMPREPLY=( $(compgen -W "Agent1" -- "$cur") ); return ;;
        --prompt|--ports)
            # free text: leave it to the user
            return ;;
    esac

    COMPREPLY=( $(compgen -W "$_code_it_opts" -- "$cur") )
}

complete -F _code_it code-it.sh claude-it.sh opencode-it.sh

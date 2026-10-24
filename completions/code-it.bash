# Bash completion for code-it.sh, claude-it.sh and opencode-it.sh.
#
# Install by sourcing it, e.g. from ~/.bashrc:
#     source /path/to/ContainerCodeIt/completions/code-it.bash
#
# Completes the launcher's own options, and, after `--`, the flags of whichever
# coding agent the command line selects: claude-it.sh (or -c) completes Claude Code
# flags, opencode-it.sh (or -o, the default) completes OpenCode flags.
#     https://code.claude.com/docs/en/cli-reference
#     https://opencode.ai/v2/docs/cli/

_code_it_opts='--agent -a --list-agents --opencode -o --claude -c --no-agent --zsh --prompt -p --headless
    --work-dir -w --save-dir -s --image -i
    --runtime -r --locale -l --agent-name --toolchain -t --stack
    --package-caches --env -e --env-file --run-arg --docker-arg --dry-run -d --help -h --'

# The flags people reach for most, not the full list; add your own favourites here.
_code_it_claude_opts='--print -p --continue -c --resume -r --fork-session --model
    --fallback-model --effort --agent --permission-mode --dangerously-skip-permissions
    --allowed-tools --disallowed-tools --add-dir --append-system-prompt --settings
    --mcp-config --output-format --max-turns --max-budget-usd --verbose --debug --ide'
_code_it_claude_models='opus sonnet haiku claude-opus-5 claude-sonnet-5 claude-haiku-4-5'
_code_it_claude_permission_modes='default acceptEdits plan auto dontAsk bypassPermissions manual'

# OpenCode: the flags people reach for most
_code_it_opencode_opts='run mini --standalone --server --model --agent --prompt
    --continue -c --session --format --file --help'

# OpenAI Codex: the flags people reach for most
_code_it_codex_opts='exec resume login logout review mcp -m --model -s --sandbox
    -a --ask-for-approval -p --profile -c --config -C --cd --worktree --search
    --add-dir -i --image --oss'
_code_it_codex_models='gpt-6.1-sol gpt-6-sol gpt-6-luna gpt-6-astra o4-mini'
_code_it_codex_sandboxes='read-only workspace-write danger-full-access'
_code_it_codex_approvals='on-request never'

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
            --agent|-a)    agent=${COMP_WORDS[i+1]} ;;
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
        elif [[ "$agent" == opencode ]]; then
            case "$prev" in
                --format) COMPREPLY=( $(compgen -W "text json" -- "$cur") ); return ;;
                --file) COMPREPLY=( $(compgen -f -- "$cur") ); return ;;
            esac
            COMPREPLY=( $(compgen -W "$_code_it_opencode_opts" -- "$cur") )
        elif [[ "$agent" == codex ]]; then
            case "$prev" in
                -m|--model)   COMPREPLY=( $(compgen -W "$_code_it_codex_models" -- "$cur") ); return ;;
                -s|--sandbox) COMPREPLY=( $(compgen -W "$_code_it_codex_sandboxes" -- "$cur") ); return ;;
                -a|--ask-for-approval) COMPREPLY=( $(compgen -W "$_code_it_codex_approvals" -- "$cur") ); return ;;
                -c|--config)  return ;; # free text key=value: leave it to the user
            esac
            COMPREPLY=( $(compgen -W "$_code_it_codex_opts" -- "$cur") )
        fi
        return
    fi

    case "$prev" in
        --work-dir|-w|--save-dir|-s)
            COMPREPLY=( $(compgen -d -- "$cur") ); return ;;
        --runtime|-r)
            COMPREPLY=( $(compgen -W "docker container" -- "$cur") ); return ;;
        --env|-e)
            COMPREPLY=( $(compgen -e -- "$cur") ); return ;;
        --env-file)
            COMPREPLY=( $(compgen -f -- "$cur") ); return ;;
        --image|-i)
            COMPREPLY=( $(compgen -W "$(docker images --format '{{.Repository}}' 2>/dev/null)" -- "$cur") ); return ;;
        --agent-name)
            COMPREPLY=( $(compgen -W "Agent1" -- "$cur") ); return ;;
        --locale|-l)
            COMPREPLY=( $(compgen -W "like-host C.UTF-8" -- "$cur") ); return ;;
        --agent|-a)
            COMPREPLY=( $(compgen -W "$(ls "${BASH_SOURCE[0]%/*}/../agents" 2>/dev/null)" -- "$cur") ); return ;;
        --toolchain|-t|--stack)
            COMPREPLY=( $(compgen -W "dotnet node js-node ts-node bun js-bun ts-bun python uv powershell pwsh rust go gcc g++ clang llvm" -- "$cur") ); return ;;
        --package-caches)
            COMPREPLY=( $(compgen -W "nuget npm bun" -- "$cur") ); return ;;
        --prompt|-p|--run-arg|--docker-arg)
            # free text: leave it to the user
            return ;;
    esac

    COMPREPLY=( $(compgen -W "$_code_it_opts" -- "$cur") )
}

complete -F _code_it code-it.sh claude-it.sh opencode-it.sh

# Bash completion for code-it-defaults.sh.
#
# Install by sourcing it, e.g. from ~/.bashrc:
#     source /path/to/ContainerCodeIt/completions/code-it-defaults.bash

_code_it_defaults_opts='--agent -a --model --toolchain -t --show --refresh-models
    --save-dir -s --dry-run -d --help -h'

_code_it_defaults() {
    local cur prev
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}

    case "$prev" in
        --save-dir|-s)
            COMPREPLY=( $(compgen -d -- "$cur") ); return ;;
        --agent|-a)
            COMPREPLY=( $(compgen -W "$(ls "${BASH_SOURCE[0]%/*}/../agents" 2>/dev/null) none" -- "$cur") ); return ;;
        --model)
            COMPREPLY=( $(compgen -W "$(ls "${BASH_SOURCE[0]%/*}/../agents" 2>/dev/null | sed 's/$/=/')" -- "$cur") ); return ;;
        --toolchain|-t)
            COMPREPLY=( $(compgen -W "dotnet node js-node ts-node bun js-bun ts-bun python uv powershell pwsh" -- "$cur") ); return ;;
    esac

    COMPREPLY=( $(compgen -W "$_code_it_defaults_opts" -- "$cur") )
}

complete -F _code_it_defaults code-it-defaults.sh

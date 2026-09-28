# Bash completion for code-it-add-tool-chain.sh.
#
# Install by sourcing it, e.g. from ~/.bashrc:
#     source /path/to/ContainerCodeIt/completions/code-it-add-tool-chain.bash

_code_it_add_tool_chain_opts='--url --repo --code-it --branch --dry-run -d --help -h'

_code_it_add_tool_chain() {
    local cur prev
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}

    case "$prev" in
        --repo|--code-it)
            COMPREPLY=( $(compgen -d -- "$cur") ); return ;;
        --url|--branch)
            return ;;   # free text
    esac

    COMPREPLY=( $(compgen -W "$_code_it_add_tool_chain_opts" -- "$cur") )
}

complete -F _code_it_add_tool_chain code-it-add-tool-chain.sh

# Bash completion for code-it-first-run.sh.
#
# Install by sourcing it, e.g. from ~/.bashrc:
#     source /path/to/ContainerCodeIt/completions/code-it-first-run.bash

_code_it_first_run_opts='--save-dir -s --work-dir -w --toolchain -t --agents -a
    --image -i --dockerfile-dir --runtime -r --code-it-build --yes -y --dry-run -d --help -h'

_code_it_first_run() {
    local cur prev
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}

    case "$prev" in
        --save-dir|-s|--work-dir|-w|--dockerfile-dir|--code-it-build)
            COMPREPLY=( $(compgen -d -- "$cur") ); return ;;
        --runtime|-r)
            COMPREPLY=( $(compgen -W "docker container" -- "$cur") ); return ;;
        --toolchain|-t)
            COMPREPLY=( $(compgen -W "dotnet node js-node ts-node bun js-bun ts-bun python uv" -- "$cur") ); return ;;
        --agents|-a)
            COMPREPLY=( $(compgen -W "$(ls "${BASH_SOURCE[0]%/*}/../agents" 2>/dev/null)" -- "$cur") ); return ;;
    esac

    COMPREPLY=( $(compgen -W "$_code_it_first_run_opts" -- "$cur") )
}

complete -F _code_it_first_run code-it-first-run.sh

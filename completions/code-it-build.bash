# Bash completion for code-it-build.sh.
#
# Install by sourcing it, e.g. from ~/.bashrc:
#     source /path/to/ContainerCodeIt/completions/code-it-build.bash

_code_it_build_opts='--tool-chains -t --stack --package-caches --rebuild --image -i
    --dockerfile-dir --runtime -r --dry-run -d --help -h'

_code_it_build() {
    local cur prev
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}

    case "$prev" in
        --dockerfile-dir)
            COMPREPLY=( $(compgen -d -- "$cur") ); return ;;
        --runtime|-r)
            COMPREPLY=( $(compgen -W "docker container" -- "$cur") ); return ;;
        --image|-i)
            COMPREPLY=( $(compgen -W "code-it-alpine-dotnet-node $(docker images --format '{{.Repository}}' 2>/dev/null)" -- "$cur") ); return ;;
        --tool-chains|-t|--stack)
            COMPREPLY=( $(compgen -W "dotnet node js-node ts-node bun js-bun ts-bun python uv" -- "$cur") ); return ;;
        --package-caches)
            COMPREPLY=( $(compgen -W "nuget npm bun" -- "$cur") ); return ;;
    esac

    COMPREPLY=( $(compgen -W "$_code_it_build_opts" -- "$cur") )
}

complete -F _code_it_build code-it-build.sh

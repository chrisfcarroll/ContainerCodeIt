# Bash completion for code-it-doctor.sh.
#
# Install by sourcing it, e.g. from ~/.bashrc:
#     source /path/to/ContainerCodeIt/completions/code-it-doctor.bash

_code_it_doctor_opts='--runtime -r --image -i --save-dir -s --no-live-test --yes -y --fix --repo --code-it --branch --dry-run -d --help -h'

_code_it_doctor() {
    local cur prev
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}

    case "$prev" in
        --runtime|-r)
            COMPREPLY=( $(compgen -W "docker container" -- "$cur") ); return ;;
        --save-dir|-s|--repo|--code-it)
            COMPREPLY=( $(compgen -d -- "$cur") ); return ;;
        --image|-i|--branch)
            return ;;   # free text
    esac

    COMPREPLY=( $(compgen -W "$_code_it_doctor_opts" -- "$cur") )
}

complete -F _code_it_doctor code-it-doctor.sh

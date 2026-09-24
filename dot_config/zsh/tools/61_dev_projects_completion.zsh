# Static completion: never scan repositories while loading a shell.
# Keep aligned with dot_config/bash/61_dev_projects_completion.bash.
_dev_projects() {
    local context state state_descr line
    typeset -A opt_args
    _arguments -C '--help[show help]' '1:command:->command' '*::argument:->args'
    case "$state" in
        command)
            local -a commands=(
                'list:List fresh dev repository candidates as JSON'
                'open:Validate and open a repository'
                'sidecar-import:Preview optional add-only Sidecar registration'
            )
            _describe 'dev-projects command' commands
            ;;
        args)
            case "$line[1]" in
                list) _arguments '--json[emit JSON]' '--help[show help]' ;;
                open)
                    _arguments '1:repository directory:_files -/' \
                        '--tool=[application]:tool:(sidecar nvim)' '--help[show help]'
                    ;;
                sidecar-import)
                    _arguments '--config=[Sidecar config file]:file:_files' \
                        '*--repo=[selected repository]:directory:_files -/' \
                        '--apply[apply missing entries; requires --yes]' \
                        '--yes[confirm apply]' '--json[emit JSON]' '--help[show help]'
                    ;;
            esac
            ;;
    esac
}
compdef _dev_projects dev-projects

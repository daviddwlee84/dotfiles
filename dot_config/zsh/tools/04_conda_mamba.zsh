# 04_conda_mamba.zsh - Conda/Mamba/Miniforge initialization (lazy-loaded)
# Supports: miniforge3, miniconda3, anaconda3
# (Legacy Supports)

# Find conda installation
_conda_root=""
for _conda_path in "$HOME/miniforge3" "$HOME/miniconda3" "$HOME/anaconda3" "/opt/homebrew/Caskroom/miniforge/base"; do
    if [[ -d "$_conda_path" ]]; then
        _conda_root="$_conda_path"
        break
    fi
done

# Exit if no conda installation found
if [[ -z "$_conda_root" ]]; then
    unset _conda_path _conda_root
    return 0
fi

# Store root for lazy init, then define wrapper functions
_CONDA_ROOT="$_conda_root"

_conda_init() {
    unfunction conda mamba 2>/dev/null
    local _root="$_CONDA_ROOT"
    unset _CONDA_ROOT

    # >>> conda initialize >>>
    __conda_setup="$("$_root/bin/conda" 'shell.zsh' 'hook' 2>/dev/null)"
    if [ $? -eq 0 ]; then
        eval "$__conda_setup"
    else
        if [ -f "$_root/etc/profile.d/conda.sh" ]; then
            . "$_root/etc/profile.d/conda.sh"
        else
            export PATH="$_root/bin:$PATH"
        fi
    fi
    unset __conda_setup

    # Mamba initialization (if available)
    if [ -f "$_root/etc/profile.d/mamba.sh" ]; then
        . "$_root/etc/profile.d/mamba.sh"
    fi
    # <<< conda initialize <<<

    # Don't modify prompt (oh-my-zsh handles it, or we prefer clean prompt)
    export CONDA_CHANGEPS1=false
}

conda() { _conda_init; conda "$@"; }
mamba() { _conda_init; mamba "$@"; }

# Cleanup
unset _conda_path _conda_root

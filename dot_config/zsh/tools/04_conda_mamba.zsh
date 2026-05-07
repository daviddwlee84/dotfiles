# 04_conda_mamba.zsh - Conda/Mamba/Miniforge/Micromamba initialization (lazy-loaded)
# Supports: miniforge3, miniconda3, anaconda3 (full distros), and
# micromamba (single-binary, common on noRoot / EL7 / corporate compute
# nodes where a full conda install is overkill).

# === Path 1: full distro (miniforge / miniconda / anaconda) ===
# These ship with $ROOT/bin/conda, $ROOT/etc/profile.d/conda.sh, etc.
# Lazy-init via conda's `shell.zsh hook` to avoid ~200ms PATH/prompt setup
# on every shell start.
_conda_root=""
for _conda_path in "$HOME/miniforge3" "$HOME/miniconda3" "$HOME/anaconda3" "/opt/homebrew/Caskroom/miniforge/base"; do
    if [[ -d "$_conda_path" ]]; then
        _conda_root="$_conda_path"
        break
    fi
done

# === Path 2: micromamba (single-binary, ~/.local/bin/micromamba) ===
# Different layout from full distros: just a binary + env tree under
# $MAMBA_ROOT_PREFIX (default ~/.local/share/mamba or ~/micromamba).
# Lazy-init via `micromamba shell hook --shell zsh` (mirrors mamba's API).
_micromamba_bin=""
for _mm_path in "$HOME/.local/bin/micromamba" "$HOME/bin/micromamba" "/opt/homebrew/bin/micromamba"; do
    if [[ -x "$_mm_path" ]]; then
        _micromamba_bin="$_mm_path"
        break
    fi
done

# Resolve MAMBA_ROOT_PREFIX (env var if set, else conventional defaults)
_mamba_root="${MAMBA_ROOT_PREFIX:-}"
if [[ -z "$_mamba_root" ]]; then
    for _mr_path in "$HOME/.local/share/mamba" "$HOME/micromamba"; do
        if [[ -d "$_mr_path" ]]; then
            _mamba_root="$_mr_path"
            break
        fi
    done
fi

# Exit early if neither installation found
if [[ -z "$_conda_root" && -z "$_micromamba_bin" ]]; then
    unset _conda_path _conda_root _mm_path _micromamba_bin _mr_path _mamba_root
    return 0
fi

# Stash for lazy init
_CONDA_ROOT="$_conda_root"
_MICROMAMBA_BIN="$_micromamba_bin"
_MAMBA_ROOT_PREFIX="$_mamba_root"

_conda_init() {
    unfunction conda mamba micromamba 2>/dev/null
    local _root="$_CONDA_ROOT"
    local _mm_bin="$_MICROMAMBA_BIN"
    local _mm_root="$_MAMBA_ROOT_PREFIX"
    unset _CONDA_ROOT _MICROMAMBA_BIN _MAMBA_ROOT_PREFIX

    # --- Full distro path ---
    if [[ -n "$_root" ]]; then
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
    fi

    # --- Micromamba path (independent of full distro; can coexist) ---
    if [[ -n "$_mm_bin" ]]; then
        [[ -n "$_mm_root" ]] && export MAMBA_ROOT_PREFIX="$_mm_root"
        # `micromamba shell hook --shell zsh` emits the activate/deactivate
        # functions and PROMPT hooks. Idempotent if conda was already
        # init'd — micromamba's hook checks for an existing $CONDA_PREFIX.
        __micromamba_setup="$("$_mm_bin" shell hook --shell zsh 2>/dev/null)"
        if [ $? -eq 0 ]; then
            eval "$__micromamba_setup"
        fi
        unset __micromamba_setup
    fi

    # Don't modify prompt (oh-my-zsh / starship handle it, or we prefer
    # a clean prompt without the conda env name prefix).
    export CONDA_CHANGEPS1=false
}

conda() { _conda_init; conda "$@"; }
mamba() { _conda_init; mamba "$@"; }
micromamba() { _conda_init; micromamba "$@"; }

# Cleanup
unset _conda_path _conda_root _mm_path _micromamba_bin _mr_path _mamba_root

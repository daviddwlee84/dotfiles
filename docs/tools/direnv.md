# direnv

`direnv` loads per-project environment variables as you enter and leave directories. In this repo it is initialized from Zsh, while prompt display is handled by Starship.

- **Helper file**: `~/.config/direnv/direnvrc` (chezmoi source: `dot_config/direnv/direnvrc`)
- **Zsh init**: `~/.config/zsh/tools/30_direnv.zsh`
- **Prompt**: `~/.config/starship.toml` via Starship's `[python]` module

## Python `.venv` helper

This repo provides `layout_python_venv [venv_dir=.venv]`.

- Activates an existing virtual environment directory
- Does not auto-create `.venv`
- Delegates activation to `layout python3`
- Watches the venv marker files so creating `.venv` later triggers a reload on the next prompt

## Recommended `.envrc`

```sh
layout_python_venv
dotenv_if_exists
```

Then allow it once per project:

```bash
direnv allow
```

You can target a non-default virtual environment directory if needed:

```sh
layout_python_venv venv
dotenv_if_exists
```

## Behavior Notes

- Equivalent for daily use: `VIRTUAL_ENV`, `PATH`, and `PYTHONHOME` handling come from direnv's built-in `layout python3`
- Not fully equivalent to `source .venv/bin/activate`: no `deactivate()` shell function and no direct `PS1` rewriting
- Prompt display still works because Starship reads `VIRTUAL_ENV` and shows the active environment name
- Leaving the directory automatically restores the previous environment

## References

- [Python · direnv Wiki](https://github.com/direnv/direnv/wiki/Python)
- [Activate python venv by default? · Issue #1264](https://github.com/direnv/direnv/issues/1264)
- [PS1 · direnv Wiki](https://github.com/direnv/direnv/wiki/PS1)

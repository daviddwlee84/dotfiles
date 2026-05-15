# Xonsh — experimental tertiary shell

[Xonsh](https://xon.sh/) is a Python-superset shell: the language is Python 3
with seamless shell-command integration (`len($(curl -L https://xon.sh))`,
`$PATH.append('/tmp')`, lambda aliases, …). In this repo it's installed as an
**experimental secondary shell** — never as your login shell.

## Scope (read this before you wonder why something is missing)

- ❌ **Not** wired into `primaryShell` (still `zsh|bash`). No `chsh`.
- ❌ **Not** integrated with `fleet` / `mlf` / `pqsum` / `wt` / `wm` /
  `.shellrc.adhoc` / `.shellrc.secrets` / atuin / ble.sh / oh-my-zsh / the 14
  auto-generated tab completions. Xonsh has its own syntax; porting all of it
  buys little for a "play with it" tool.
- ✅ Installed everywhere `chezmoi apply` runs (via `python_uv_tools` role).
- ✅ Minimal `~/.xonshrc` that handles PATH, starship prompt, vim-mode, and
  loads a starter set of xontribs.
- ✅ Personal extension sandbox at `~/.config/xonsh/rc.xsh`.

The mental model: **drop in for ad-hoc Python-in-shell work, drop out**.

## Install

Installed automatically when you run `chezmoi apply` (or `just upgrade-uv`).
The entry lives in
[`dot_ansible/roles/python_uv_tools/defaults/main.yml`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_ansible/roles/python_uv_tools/defaults/main.yml)
and uses `uv tool install xonsh --with <xontribs>`, so everything lands in one
isolated venv under `~/.local/share/uv/tools/xonsh/`.

Manually trigger just this role:

```bash
cd ~/.local/share/chezmoi
ansible-playbook -i dot_ansible/inventories/local.yml \
  dot_ansible/playbooks/$(uname | tr '[:upper:]' '[:lower:]').yml \
  --tags python_uv_tools
```

Verify:

```bash
which xonsh           # → ~/.local/bin/xonsh
xonsh --version       # ≥ 0.23.x
```

## Launch

```bash
xonsh                              # interactive REPL
xonsh -c 'print(1+1); echo hello'  # one-shot
xonsh -c 'print($(ls).splitlines()[:3])'   # mix Python + shell
```

Not a login shell, so it inherits the env from whatever zsh/bash session you
launched it from. PATH is re-augmented by `~/.xonshrc` to be safe.

## Preinstalled xontribs

All four come from the `with:` list on the xonsh entry in `python_uv_tools` and
are loaded by `~/.xonshrc`:

| Xontrib       | What it gives you |
|---            |---                |
| `jedi`        | Tab-completion for Python objects (via [Jedi](https://github.com/davidhalter/jedi)) |
| `zoxide`      | `z <pattern>` / `zi` to jump to frecency-ranked directories (needs `zoxide` on PATH — already installed by `devtools` role) |
| `pipeliner`   | Pipe shell output through Python expressions: `ls -la \| @ json.dumps({'l': line, 'n': len(line)})` |
| `fzf-widgets` | `Ctrl+R` / `Ctrl+T` fzf widgets (needs `fzf` on PATH — already installed) |

Trim or add more in `~/.xonshrc` — install extras via
`uv tool install xonsh --with xontrib-<name> --reinstall`.

## Where to put your extensions

Three layers, mirror of how `dot_config/{shell,zsh,bash}/` works for the
primary shells:

1. **`~/.xonshrc`** (managed via `dot_xonshrc.tmpl`) — stable minimum, don't
   bloat. Edit the template in the repo.
2. **`~/.config/xonsh/rc.xsh`** (managed via `dot_config/xonsh/rc.xsh.tmpl`)
   — versioned starter for your aliases / Python helpers. Edit the template
   in the repo; ships with two example patterns.
3. **`~/.xonshrc.local`** (untracked, not auto-stubbed) — machine-local
   overrides / secrets. Same rule as `~/.shellrc.secrets`: chezmoi never
   creates an empty stub.

## Vim mode

If you ran `chezmoi init` with `enableVimMode = true` (default), `~/.xonshrc`
sets `$VI_MODE = True`. You get xonsh's built-in modal editing
(prompt-toolkit-based). This is consistent with how `enableVimMode` drives
`zsh-vi-mode` / `set -o vi` / ble.sh vi-mode in your primary shells; it does
**not** affect Neovim or editor configs.

## What's deliberately NOT wired up

| Want it? | Where to add |
|---       |---           |
| `fleet` / `mlf` / `pqsum` etc. aliases | Wrap them as `aliases['fleet'] = ['fleet']` in `~/.config/xonsh/rc.xsh`. Most are already plain executables, so xonsh sees them on PATH automatically — only the zsh/bash *functions* need wrapping. |
| atuin history sharing | No xontrib exists. Write a `precmd`/`prompt` event hook that shells out to `atuin history add` if you want it. |
| Repo-wide tab completion for `chezmoi` / `mise` / `uv` / `just` / `gh` … | Xonsh's completion model differs from zsh/bash compdefs. Not auto-generated. Hand-write in `~/.config/xonsh/rc.xsh` if you need one. |
| Login shell | Don't. `primaryShell` schema only accepts `zsh\|bash`; switching xonsh in would break the entire shellrc loadout. |

## Uninstall

```bash
uv tool uninstall xonsh
```

To stop reinstalling it on the next `chezmoi apply`, also remove the xonsh
entry from `dot_ansible/roles/python_uv_tools/defaults/main.yml`. The
`~/.xonshrc` and `~/.config/xonsh/` files are harmless to leave behind.

## References

- Upstream: <https://github.com/xonsh/xonsh>
- Docs: <https://xon.sh/>
- Xontrib index: <https://xon.sh/xontribs.html>

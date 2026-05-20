# btop

[btop](https://github.com/aristocratos/btop) is a resource monitor (CPU / memory / network / processes / disks) — the C++ continuation of bashtop & bpytop. It reads its config and themes from `~/.config/btop/` at launch.

## Managed config

This repo seeds `~/.config/btop/btop.conf` (via `dot_config/btop/create_btop.conf.tmpl`) and vendors a Catppuccin Mocha theme at `~/.config/btop/themes/catppuccin_mocha.theme`.

The baseline overrides just a few keys on top of btop's stock config (so you stay close to upstream and keep your own `presets` / `shown_boxes`):

| Key | Value | Why |
|---|---|---|
| `color_theme` | `"catppuccin_mocha"` | Matches the repo's Catppuccin Mocha standard (tmux, …). Requires the vendored theme file — see [Theme](#theme). |
| `proc_tree` | `True` | Show processes as a tree — easier to see what spawned `python` / `uv` / `claude` / tmux / pueue workers. |
| `vim_keys` | `{{ if .enableVimMode }}…{{ end }}` | `h,j,k,l,g,G` list navigation, gated on the repo's `enableVimMode` prompt (see [Vim integration](../this_repo/vim-mode.md)). |

Preserved from the seed: `update_ms = 2000`, `proc_sorting = "cpu lazy"`, `presets`, `shown_boxes = "cpu mem net proc"`, `theme_background = True`.

### Seeded once (`create_`) — why, and how to refresh

btop **rewrites `btop.conf` on every exit** (it serializes the entire current config). If the file were fully managed, every quit would drift it from the source and `chezmoi apply` would fight btop. So it uses chezmoi's `create_` prefix: **seeded once on a fresh machine, then never touched again**. btop owns the file afterward → zero apply drift. (Same pattern as `dot_config/nvim/create_lazy-lock.json` and `dot_config/marimo/create_marimo.toml.tmpl`; see [chezmoi prefixes](chezmoi-prefixes.md).)

Consequences:

- On a machine that **already** has `~/.config/btop/btop.conf`, chezmoi will **not** overwrite it. To adopt this baseline on such a box, delete it once and re-apply:

  ```bash
  rm ~/.config/btop/btop.conf
  chezmoi apply
  ```

- To **update the repo baseline** from a tweaked live config, neither `chezmoi add` (strips `create_`) nor `chezmoi re-add` (skips `create_`) works. Copy the live file into the source path, then re-apply the templated overrides if btop reset them:

  ```bash
  cp ~/.config/btop/btop.conf "$(chezmoi source-path ~/.config/btop/btop.conf)"
  ```

## Theme

`color_theme = "catppuccin_mocha"` requires `~/.config/btop/themes/catppuccin_mocha.theme` to exist — **if the file is missing, btop silently falls back to the `Default` theme with no error**. That's why the theme is vendored in the repo (mirroring `dot_config/bat/themes/`), not fetched at runtime. Unlike bat, btop reads `.theme` files directly at launch — there is **no cache to rebuild**, so there is intentionally no `run_onchange` hook for it.

To switch flavors, drop another catppuccin theme (`catppuccin_latte` / `_frappe` / `_macchiato`) into `dot_config/btop/themes/` and point `color_theme` at it.

## Gotchas

- **There is no `proc_cmdline` key.** btop has no config toggle to "always show full command lines in the list" — `proc_cmdline` does not exist in 1.3.x or 1.4.x (don't trust AI suggestions that invent it). The full command line shows in the **process detail view** (select a process + `Enter`), or by setting `proc_sorting = "arguments"`. The tree view (`proc_tree = True`) already shows command hierarchy.
- **Booleans are Python-style `True` / `False`** (capitalized); string values keep their quotes (`proc_sorting = "cpu lazy"`). Match btop's exact serialization when hand-editing.

## Install — and the snap trap

On Linux the repo installs btop via **apt** (`dot_ansible/roles/devtools/tasks/main.yml`) with a GitHub musl-static fallback for no-root / CentOS hosts; macOS uses Homebrew. The repo never installs the snap build.

> **If btop crashes on launch with `Permission denied` + `IOT instruction (core dumped)`**, you are almost certainly running a **snap** build of btop. It is AppArmor-confined and cannot read your `~/.config/btop/themes` (the snap `home` interface blocks hidden dirs), so `std::filesystem::directory_iterator` throws and aborts. The directory permissions are a **red herring** — `chown`/`chmod` won't help. Remove or shadow the snap so the apt / brew / `~/.local/bin` btop wins on `PATH`:
>
> ```bash
> sudo snap remove btop        # then /usr/bin/btop (apt) takes over
> # — or, for the newest version via a package manager:
> brew install btop            # linuxbrew btop wins on PATH; unconfined
> ```
>
> Full write-up: [`pitfalls/btop-themes-permission-denied-core-dumped.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/btop-themes-permission-denied-core-dumped.md).

## See also

- [Vim integration](../this_repo/vim-mode.md) — the `enableVimMode` flag that drives `vim_keys`.
- [chezmoi prefixes](chezmoi-prefixes.md) — `create_` seed-once semantics and the refresh recipe.

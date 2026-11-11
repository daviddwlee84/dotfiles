# Herdr App managed fragments

Shared, byte-identical between `daviddwlee84/dotfiles` and
`daviddwlee84/dotfiles-windows` (`diff -r` of this directory must be empty).

- `keys.json`: bindings deep-merged into `~/.config/herdr-app/keys.json`.
  These are the three `tmux-prefix` keys from the upstream mod recipe.
- `settings.json`: preferences deep-merged into `~/.config/herdr-app/settings.json`.

The `modify_` overlays apply them. Managed keys win, and every other key the app or
you wrote is preserved. An empty or missing live file stays empty, so the app
still writes its full defaults on first start; the next apply merges.

`dot_config/herdr-app/mods/tmux-prefix/{main.js,mod.json}` is vendored unchanged
from `herdrdev/herdr-layout-examples@ed4eda7a02e255191203df0ff04b9dc7ae56e1ad`
(`tmux-prefix/`). Re-vendor it by copying both files from a newer commit and
updating this pin in both repos.

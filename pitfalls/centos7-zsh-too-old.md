# CentOS 7's zsh 5.0.2 is too old for this repo's config

## Symptom

After a "successful" `chezmoi apply` on a CentOS 7 host, opening zsh
prints a wall of plugin-load errors:

```
yczhang in 🌐 idc-server104 in ~ via  v2.7.5
❯ zsh
/etc/profile.d/bash_env.sh:19: command not found: conda
/home/yczhang/.oh-my-zsh/custom/plugins/zsh-vi-mode/zsh-vi-mode.zsh:487: parse error near `]]'
(eval):73: unknown condition: -v
/home/yczhang/.config/zsh/tools/05_aisuggest.zsh:429: add-zle-hook-widget: function definition file not found
/home/yczhang/.config/zsh/tools/28_tldr.zsh:4: unknown file attribute
_maybe_add_keys:6: unknown file attribute
```

(The `command not found: conda` line is a separate `/etc/profile.d/`
issue, not a zsh-version problem.)

## Root cause

CentOS 7's `yum install zsh` lands at **5.0.2-34.el7** (zsh 5.0.2 was
released 2014). The deployed `~/.zshrc`, oh-my-zsh, zsh-vi-mode, and
this repo's `dot_config/zsh/tools/*.zsh` plugins all assume **zsh
≥ 5.3+** for several syntactic and runtime features:

| Feature | Min zsh | Used by |
|---------|---------|---------|
| `[[ -v var ]]` (parameter set test) | 5.3 | zsh-vi-mode, our `_maybe_add_keys` |
| `add-zle-hook-widget` (via zle module) | 5.3 | `05_aisuggest.zsh` |
| Glob qualifier `(.)` for plain files | 5.0 (works) | most |
| Newer glob qualifiers (`(N)`, `(om[1])`) | 5.3+ | `28_tldr.zsh`, helpers |
| `zsh/parameter` extensions | 5.3+ | various |

Five-and-something releases since 2014 — it's not realistic to keep our
dotfiles compatible. Better to upgrade zsh.

## Why we can't just `yum upgrade zsh`

CentOS 7 base + EPEL only ship 5.0.2. There's no SCL devtoolset for zsh.
IUS used to provide newer zsh on EL7 but dropped it years ago. The
practical paths are:

1. **Source build** to `~/.local` — gcc 4.8.5 + ncurses-devel + make is
   enough to compile zsh 5.9 in ~3 minutes. No sudo needed for the
   install itself (just for the build deps).
2. **Conda/Mamba** — `mamba install -c conda-forge zsh` works but pulls
   a full conda env we may not want.
3. **Linuxbrew** — works on glibc 2.17 in theory, but CentOS 7's curl
   7.29 < Homebrew's 7.41 minimum, so the installer aborts (see
   [`bootstrap-no-tty-sudo-prompt-skipped.md`](bootstrap-no-tty-sudo-prompt-skipped.md) →
   "CentOS 7 brew note").

We pick (1) — `dot_ansible/roles/zsh/tasks/main.yml` now detects
`zsh < 5.3` and builds 5.9 user-level into `~/.local/bin/zsh` when the
host is RedHat-family.

## Fix in this repo

Three new tasks in `roles/zsh/tasks/main.yml`, all gated on
`ansible_facts["os_family"] == "RedHat"` + `zsh_too_old | default(false)`:

1. **Detect system zsh version** — `zsh --version | awk '{print $2}'`,
   then `set_fact zsh_too_old` when major < 5 or (major == 5 and
   minor < 3).
2. **Install ncurses-devel via yum CLI** (same pattern as base/zsh
   install — see [`centos7-ansible-yum-dnf-backend.md`](centos7-ansible-yum-dnf-backend.md)
   for why we avoid `ansible.builtin.yum:`). Tagged `[sudo]` so noRoot
   skips it.
3. **Build zsh 5.9 from source** — `curl -fLO zsh.org/pub/zsh-5.9.tar.xz`
   + `./configure --prefix=$HOME/.local --enable-multibyte` + `make` +
   `make install`. Idempotent via `creates: ~/.local/bin/zsh`.
4. **Add `~/.local/bin/zsh` to `/etc/shells`** — so `chsh -s` accepts
   it as the user's login shell.

The downstream "Locate zsh binary" task then prefers `~/.local/bin/zsh`
over the system `/usr/bin/zsh` for the chsh step, and downstream
`primary_shell == zsh` users get the modern zsh.

## Alternative: bring your own zsh

If your CentOS 7 box already has a newer zsh on PATH (e.g. via Software
Collections, conda, or a manual install), the detection task simply
sees `zsh ≥ 5.3` and skips the build. Nothing to disable.

## Manual repro

```bash
zsh --version                        # zsh 5.0.2
zsh -c '[[ -v foo ]]'                 # condition error → confirms < 5.3

# Manual fix (what the ansible task does):
sudo yum install -y ncurses-devel
cd /tmp
curl -fLO https://www.zsh.org/pub/zsh-5.9.tar.xz
tar xf zsh-5.9.tar.xz && cd zsh-5.9
./configure --prefix="$HOME/.local" --enable-multibyte --with-tcsetpgrp
make -j"$(nproc)" && make install
~/.local/bin/zsh --version            # zsh 5.9

echo "$HOME/.local/bin/zsh" | sudo tee -a /etc/shells
chsh -s "$HOME/.local/bin/zsh" "$USER"
```

## Subtlety: `./configure` needs `--with-tcsetpgrp` when run non-interactively

zsh's `configure` auto-probes tcsetpgrp(3) by **spawning a child that
asks for its controlling TTY**. When the build runs from ansible's
`shell:` (no controlling TTY in the child process), the probe aborts:

```
configure: error: no controlling tty
Try running configure with --with-tcsetpgrp or --without-tcsetpgrp
```

We pass `--with-tcsetpgrp` explicitly because zsh needs job control to
function as a real interactive shell. Without it, the build either
fails (as above) or ships a zsh that can't background processes.

If you ever copy the `./configure` invocation out of the role to debug
manually in an SSH session, keep `--with-tcsetpgrp` even though
interactive `configure` would auto-detect it correctly — having both
paths produce the same artifact avoids "works on my terminal, fails in
ansible" drift.

## Related

- [`pitfalls/centos7-noroot.md`](centos7-noroot.md) — the noRoot path
  for this same host class. There zsh is left at 5.0.2 because no sudo
  is available to install ncurses-devel; the ~/.zshrc still works
  partially but vi-mode + aisuggest are broken.
- [`pitfalls/centos7-ansible-yum-dnf-backend.md`](centos7-ansible-yum-dnf-backend.md) —
  why the `ncurses-devel` install uses `ansible.builtin.shell: yum
  install` instead of `ansible.builtin.yum:`.
- [`backlog/zsh-noroot-fallback.md`](../backlog/zsh-noroot-fallback.md) —
  alternative zsh install paths (Miniforge, mise, source) for noRoot
  hosts.
- `dot_ansible/roles/zsh/tasks/main.yml` — the role that implements
  this fix.

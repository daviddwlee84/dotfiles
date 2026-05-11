# uv bootstrap, version gate, and per-machine upgrade dispatch

> How `uv` (Astral's Python package manager) is installed on every host this repo touches, why the `python_uv_tools` ansible role enforces a minimum version, and how the auto-upgrade picks the right channel — `brew upgrade uv` vs `uv self update` — without the user having to think about it.

## Why this page exists

Different machines in the same fleet end up with `uv` installed via different channels:

```text
Other Mac (manual brew)
❯ uv --version
uv 0.10.2 (Homebrew 2026-02-10)
❯ which uv
/opt/homebrew/bin/uv

Ubuntu (curl install via run_once_before_00_bootstrap)
❯ uv --version
uv 0.7.18
❯ which uv
/home/daviddwlee84/.local/bin/uv

This Mac (curl install, never refreshed)
❯ uv --version
uv 0.7.4 (6fbcd09b5 2025-05-15)
❯ which uv
/Users/zhouhanru/.local/bin/uv
```

`uv self update` works on the curl-installed boxes and silently no-ops on Homebrew uv (it refuses with `self-update is disabled for this build`). `brew upgrade uv` works only when uv is in fact a brew formula. Get this wrong and the host stays months behind, then a future `chezmoi apply` fails because some role uses a flag from a newer uv.

This page documents the contract that fixes the mismatch.

## Bootstrap path

There is exactly **one** installer in this repo:

```sh
curl -LsSf https://astral.sh/uv/install.sh | sh
```

It runs in two places, both gated on `command -v uv`:

| File | When it runs |
|---|---|
| `bootstrap.sh` lines 52–61 | First entry point on a fresh box (one-shot `curl … \| bash`) |
| `run_once_before_00_bootstrap.sh.tmpl` lines 206–213 | First `chezmoi apply` on the box |

Result: every host the repo touches has uv at `~/.local/bin/uv` **unless the user already had `brew install uv`** before the bootstrap ran, in which case the `command -v uv` guard sees the brew binary and skips the curl install.

The repo never proactively `brew install`s uv. There's no `brew "uv"` line in any Brewfile (`grep -rn '"uv"' dot_config/homebrew/`). No mise plugin, no asdf, no apt package. Curl-or-brew is the entire matrix.

## Why a minimum version is enforced

`dot_ansible/roles/python_uv_tools/defaults/main.yml` uses the `with_executables_from:` key on the `jupyterlab` entry to expose `jupyter` and `jupyter-notebook` shims from the `jupyter-core` and `notebook` packages:

```yaml
- name: jupyterlab
  binary: jupyter-lab
  with:
    - marimo[sandbox]
    - marimo-jupyter-extension
    - ipykernel
    - ipywidgets
  with_executables_from:
    - notebook       # exposes jupyter-notebook (classic UI, Notebook 7)
    - jupyter-core   # exposes the `jupyter` meta-CLI dispatcher
```

That maps to `uv tool install jupyterlab --with ... --with-executables-from notebook --with-executables-from jupyter-core`. The `--with-executables-from` flag is **uv 0.8.5+** (PR [astral-sh/uv#14014](https://github.com/astral-sh/uv/pull/14014), released ~2025-08). On older uv, the install bombs with:

```
error: unexpected argument '--with-executables-from' found
  tip: a similar argument exists: '--with'
```

— and then ansible retries 3× per tool because of the `retries: 3` block. Fail-fast at the start of the role is much cheaper than waiting for the loop to fail twelve times.

## Auto-upgrade dispatch

When the role finds uv below `min_uv_version` (currently `0.8.5`, set via `set_fact` at the top of `tasks/main.yml`), it runs the upgrade automatically by detecting the install style:

```sh
# pseudo (the real one is in tasks/main.yml as an `ansible.builtin.shell`)
case "$(command -v uv)" in
  */homebrew/*|*/Cellar/*|*/linuxbrew/*) echo brew ;;
  /usr/local/bin/uv)
    # Intel-mac brew shares /usr/local/bin with the curl installer; ask brew
    brew list --formula uv >/dev/null 2>&1 && echo brew || echo curl
    ;;
  $HOME/.local/bin/uv|$HOME/.cargo/bin/uv) echo curl ;;
  *) brew list --formula uv >/dev/null 2>&1 && echo brew || echo curl ;;
esac
```

then:

| Detected style | Upgrade command (ansible) | Upgrade command (`scripts/upgrade_tools.sh`) |
|---|---|---|
| `brew` | `community.general.homebrew name=uv state=latest` | `brew upgrade uv` |
| `curl` | `uv self update` | `uv self update` |

After the upgrade fires (or doesn't, when uv was already current), the role re-probes the version one more time and `fail`s with a clear message if uv is *still* below the minimum. That last fail catches three edge cases:

1. The detect-style heuristic guessed wrong and the chosen command silently no-opped.
2. The brew formula simply hasn't bumped to a recent enough version yet.
3. The host is offline / behind a proxy and the upgrade attempt failed.

## Per-machine truth table

For the three example machines at the top:

| Machine | Initial uv | Style detected | Upgrade fired | Result |
|---|---|---|---|---|
| Other Mac | `0.10.2 (Homebrew 2026-02-10)` | `brew` | none — already ≥ 0.8.5 | continues to install loop |
| Ubuntu | `0.7.18` | `curl` | `uv self update` → e.g. `0.11.13` | continues to install loop |
| This Mac | `0.7.4 (... 2025-05-15)` | `curl` | `uv self update` → e.g. `0.11.13` | continues to install loop |

All three converge. No manual intervention needed beyond `chezmoi apply`.

A hypothetical fourth machine — Ubuntu desktop with `brew install uv` from Linuxbrew, currently at uv 0.7.x — would be detected as `brew`, get `community.general.homebrew name=uv state=latest`, and converge the same way.

A hypothetical fifth — CentOS 7 air-gapped — would fail at the post-upgrade re-probe, because `uv self update` can't reach `astral.sh` and there's no brew. The fail message points the user at the manual fix table.

## Manual fallback by install style

```text
macOS Homebrew     →  brew upgrade uv
Linuxbrew          →  brew upgrade uv
curl/standalone    →  uv self update     (or: just upgrade-tools uv)
unknown / other    →  reinstall via https://docs.astral.sh/uv/getting-started/installation/
```

`just upgrade-tools uv` (calling `cat_uv()` in `scripts/upgrade_tools.sh`) does the same dispatch; it's what to run when you want to refresh uv outside of the chezmoi-apply path.

## Why we don't unify on `brew install uv` for macOS

Tempting — it would shrink the upgrade matrix to "always `brew upgrade uv`" — but rejected because:

1. **Bootstrap dependency chain.** A fresh Mac would need Homebrew installed before the curl installer runs, and Homebrew install + first `brew update` is much slower than `curl … | sh`. The current curl path lets `uv tool install ansible-core` get going within seconds.
2. **Linux fleet still needs the curl path.** CentOS 7 / Linuxbrew-less Ubuntu / Docker images all rely on the standalone installer. We'd end up with two paths regardless.
3. **Brew formula lag.** Astral ships standalone uv first; the homebrew-core formula bumps a few days to a week later. The `--with-executables-from` flag this repo depends on actually shipped on standalone uv 0.8.5 several days before the brew formula caught up.

So we keep both styles supported, dispatch at upgrade time, and document the matrix here.

## When to bump `min_uv_version`

The `set_fact: min_uv_version: "0.8.5"` lives at the top of `dot_ansible/roles/python_uv_tools/tasks/main.yml`. Bump it whenever:

- A new entry in `defaults/main.yml` uses a `uv tool install` flag added in a newer release. Check the [uv changelog](https://github.com/astral-sh/uv/blob/main/CHANGELOG.md) for the version it shipped in.
- An existing tool's transitive dep starts requiring a uv resolver feature (rare, usually surfaces as a confusing resolution error).

When you bump it, also:

1. Update the comment in `tasks/main.yml` explaining *which flag* the bump is for.
2. Update the comment in `defaults/main.yml`'s top header where `with_executables_from:` is documented.
3. Update the table on this page.
4. Re-test on the oldest-uv machine in the fleet (or temporarily downgrade with `uv self install --version <old>` to simulate).

## Cross-references

- [`AGENTS.md` § Install vs upgrade is split on purpose](../../AGENTS.md#install-vs-upgrade-is-split-on-purpose) — the wider invariant this dispatch fits inside.
- [`docs/this_repo/upgrades.md`](upgrades.md) — the `cat_uv()` row in the category matrix; mirrors this page's dispatch.
- [`docs/this_repo/bootstrap.md`](bootstrap.md) — covers `bootstrap.sh` + `run_once_before_00_bootstrap.sh.tmpl` more broadly.
- [`pitfalls/uv-self-update-homebrew-noop.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/uv-self-update-homebrew-noop.md) — the trap that motivated the dispatch.
- [`pitfalls/ansible-when-regex-replace-backslash-strip.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/ansible-when-regex-replace-backslash-strip.md) — companion trap from the same debugging session: the version-comparison `when:` clause had its own bug (backslashes silently stripped) before this page existed.
- [`scripts/upgrade_tools.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/scripts/upgrade_tools.sh) — the `cat_uv()` implementation.
- [`dot_ansible/roles/python_uv_tools/tasks/main.yml`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_ansible/roles/python_uv_tools/tasks/main.yml) — the role that enforces the version gate.

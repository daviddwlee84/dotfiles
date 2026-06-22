# `chezmoi apply` dies at llm_tools: `brew link` step did not complete (ollama)

<!-- Symptom = the brew link failure; root cause = the ollama-app cask symlink
     shadows the CLI-only formula. Grep terms: "brew link", "Could not symlink
     bin/ollama", "ollama", "shadowed by /usr/local/bin/ollama". -->

**Symptoms** (grep this section):

- `chezmoi apply` / `chezmoi apply --init` aborts in the `llm_tools` ansible role:
  ```
  [87] TASK · [llm_tools : Install Ollama via Homebrew formula (macOS CLI install)]
  [ERROR]: Task failed: Module failed: ✔︎ Bottle ollama (0.30.10)
  Error: The `brew link` step did not complete successfully
  Origin: /Users/david/.ansible/roles/llm_tools/tasks/main.yml:90:3
  ...
  ✘ fatal: [localhost]: FAILED! (23.9s) =>
      changed: false
      msg: |-
          ✔︎ Bottle ollama (0.30.10)
          Error: The `brew link` step did not complete successfully
  ...
  chezmoi: .chezmoiscripts/global/20_ansible_roles.sh: exit status 2
  ```
- Running the link by hand spells out the conflict:
  ```
  $ brew link ollama
  Error: Could not symlink bin/ollama
  Target /usr/local/bin/ollama
  already exists. You may want to remove it:
    rm '/usr/local/bin/ollama'

  To force the link and overwrite all conflicting files:
    brew link --overwrite ollama
  ```
- `brew info ollama` shows the bottle is installed but **not linked**, with a
  shadow caveat:
  ```
  ==> Caveats
  The following ollama executables are shadowed by other commands earlier in your PATH:
    ollama (shadowed by /usr/local/bin/ollama)
  ```
- The colliding target is a symlink into the **GUI app**, not a stray file:
  ```
  $ readlink /usr/local/bin/ollama
  /Applications/Ollama.app/Contents/Resources/ollama
  $ brew list --cask | grep -i ollama
  ollama-app
  ```
- Because the play aborts mid-run, every role tagged **after** `llm_tools`
  (`networking_tools`, `tunnel_tools`, `iac_tools`, `media_tools`,
  `dotnet_tools`) silently never runs — `PLAY RECAP` shows `failed=1` and the
  remaining roles are simply absent.

**First seen**: 2026-06 on `Hanrus-MacBook-Pro` (Intel, macOS 26.3.1) during
`chezmoi apply --init` with `installBrewApps=false`. The host had picked up the
`ollama-app` cask months earlier (a prior apply with `installBrewApps=true`),
then a later apply with `installBrewApps=false` tried to add the CLI-only
formula on top.
**Affects**: macOS hosts where the **`ollama-app` cask** (GUI runtime) is
installed AND the `llm_tools` role's formula path runs (i.e.
`installBrewApps=false`). Both Intel (`/usr/local/bin/ollama`) and Apple
Silicon (`/opt/homebrew/bin/ollama`). Any tool with both a cask that drops a
CLI shim and a same-named formula can hit the identical trap.
**Status**: fixed in `dot_ansible/roles/llm_tools/tasks/main.yml` — a
`which ollama` pre-check now gates the formula install so it never fights an
existing CLI.

## Root cause

Two Homebrew packages want the **same** link target `…/bin/ollama`:

| Package | Kind | Provides | When this repo installs it |
|---|---|---|---|
| `ollama-app` | cask (GUI) | `Ollama.app` + a `…/bin/ollama` symlink into the app bundle | `Brewfile.darwin` when `installAiDesktopApps && installLlmTools` |
| `ollama` | formula (CLI) | `…/Cellar/ollama/<v>/bin/ollama`, linked into `…/bin/ollama` | `llm_tools` role when `installBrewApps=false` |

`brew install ollama` pours the bottle fine, then auto-runs `brew link`, which
**refuses to clobber** the cask's existing symlink and exits non-zero. The
ansible `community.general.homebrew` module surfaces that as a task failure and
the whole play aborts.

The role's original guard was the wrong signal:

```yaml
when:
  - ansible_facts["os_family"] == "Darwin"
  - not (llm_tools_install_brew_apps | bool)   # ← proxy, not the real conflict
```

`llm_tools_install_brew_apps` (← the `installBrewApps` prompt) is only a *proxy*
for "did we install GUI apps this run". It does **not** detect a cask that a
*previous* run (or a manual `brew install --cask ollama-app`) already dropped on
disk. The real question is simply: **is there already an `ollama` on PATH?** If
yes, the formula is redundant and linking it can only collide.

> Note the gating is doubly mismatched: the cask is gated on
> `installAiDesktopApps && installLlmTools`, while the formula-skip was gated on
> `installBrewApps`. So the proxy can't even be made consistent — only the
> on-disk "is there an ollama CLI" check is reliable.

## Workaround

**The durable fix (already in the role):** pre-check for an existing CLI and
skip the formula when one is present.

```yaml
- name: Check whether an ollama CLI is already present (macOS)
  when: ansible_facts["os_family"] == "Darwin"
  ansible.builtin.command: which ollama
  register: llm_tools_ollama_macos_check
  changed_when: false
  failed_when: false

- name: Install Ollama via Homebrew formula (macOS CLI install)
  when:
    - ansible_facts["os_family"] == "Darwin"
    - not (llm_tools_install_brew_apps | bool)
    - llm_tools_ollama_macos_check.rc != 0   # ← only if no ollama CLI yet
  community.general.homebrew:
    name: ollama
    state: present
```

**To clean up a host that's already in the half-installed state**, pick the
end-state you want — the app and the formula both provide a working `ollama`
CLI, so you only need one:

```sh
# A) Keep the GUI app (it already provides the CLI) — drop the redundant formula
brew uninstall ollama
which ollama   # -> /usr/local/bin/ollama -> /Applications/Ollama.app/...

# B) Go CLI-only — remove the app, then link the formula (now unobstructed)
brew uninstall --cask ollama-app
brew link ollama
```

Do **not** reach for `brew link --overwrite ollama` as the fix: it makes the
formula win *this* time, but you still have two installs fighting over the same
path, and an app self-update will recreate its symlink and re-break linking.

**To finish the aborted apply** (the post-`llm_tools` roles never ran), just
re-run `chezmoi apply`. If chezmoi thinks the ansible run-script is unchanged
and skips it, force the one script to re-run:

```sh
chezmoi state delete --bucket=entryState \
  --key="$HOME/.chezmoiscripts/global/20_ansible_roles.sh"
chezmoi apply
```

## Prevention

- Guard package installs on the **observable end-state** (`which <tool>`), not a
  prompt/role-var proxy, whenever a sibling package can already provide the same
  binary. The proxy var answers "did the user opt into X this run", which is a
  different question from "is X already on disk".
- When a tool ships **both** a cask-with-CLI-shim and a same-named formula,
  assume some hosts will end up with both. Installing the second one must be a
  no-op, not a hard error.
- Remember that an ansible task failure **aborts the whole play** — a single
  brew-link collision silently drops every later role. After any mid-run
  failure, assume the tail of the role list didn't run and re-apply.

## Related

- Sibling brew/cask trap: [`brew-bundle-redownloads-manually-installed-cask.md`](brew-bundle-redownloads-manually-installed-cask.md)
  — same family (cask vs already-present `.app`), different mechanism (bundle
  re-download vs formula link collision).
- Sibling Homebrew-on-apply trap: [`homebrew-6-refuses-untrusted-tap-formula.md`](homebrew-6-refuses-untrusted-tap-formula.md)
  — another "`chezmoi apply` dies in an ansible homebrew task" failure mode.
- Source of the fix: `dot_ansible/roles/llm_tools/tasks/main.yml` (the
  `Check whether an ollama CLI is already present (macOS)` pre-check).
- GUI side of the gating: `dot_config/homebrew/Brewfile.darwin.tmpl`
  (`cask "ollama-app"` under `installAiDesktopApps && installLlmTools`).
- Latent follow-up (not yet fixed): the cask-gate (`installAiDesktopApps &&
  installLlmTools`) and the formula-gate (`installBrewApps`) can disagree, so
  `installBrewApps=true` + `installAiDesktopApps=false` installs *no* ollama at
  all. The `which ollama` guard doesn't cover that case (the `not
  install_brew_apps` condition short-circuits first).

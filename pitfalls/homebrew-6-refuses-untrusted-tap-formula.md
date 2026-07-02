# `chezmoi apply` aborts: Homebrew refuses to load a formula/cask from an untrusted tap

**Symptoms** (grep this section):
- `Error: Refusing to load formula raine/workmux/workmux from untrusted tap raine/workmux.`
- `Run \`brew trust --formula raine/workmux/workmux\` or \`brew trust raine/workmux\` to trust it.`
- `Error: Refusing to load formula teamookla/speedtest/speedtest from untrusted tap teamookla/speedtest.`
- `Error: Refusing to load cask wxtsky/tap/codeisland from untrusted tap wxtsky/tap.`
- ansible `devtools : Install developer CLI tools (macOS)` task → `FAILED!` → `changed: false`
- ansible `networking_tools : Install speedtest` task → `FAILED!` → `changed: false`
- `brew bundle` fails while fetching `codeisland`, then the retry fails the same way
- `.chezmoiscripts/global/20_ansible_roles.sh: exit status 2`; `PLAY RECAP … failed=1`
- Worked fine on the same machine days earlier; nobody changed the tap

**First seen**: 2026-06 (Mac mini, macOS 26.2, Homebrew 6.0.2)
**Affects**: Homebrew ≥ 6.0 on any OS, any third-party tap this repo uses (`raine/workmux`, `dlvhdr/formulae`, `teamookla/speedtest`, Brewfile taps such as `wxtsky/tap`)
**Status**: fixed in repo (`devtools` + `networking_tools` trust tasks; Brewfile run-script trusts `tap "..."` entries before `brew bundle`)

## Symptom

`chezmoi apply` / `chezmoi update` dies in the `devtools` role:

```
[24] TASK · [devtools : Install developer CLI tools (macOS)]
[ERROR]: Task failed: Module failed: Error: Refusing to load formula raine/workmux/workmux from untrusted tap raine/workmux.
Run `brew trust --formula raine/workmux/workmux` or `brew trust raine/workmux` to trust it.
...
chezmoi: .chezmoiscripts/global/20_ansible_roles.sh: exit status 2
```

The task taps `raine/workmux` and `dlvhdr/formulae` (via `community.general.homebrew_tap`)
and then `brew install`s `workmux` + `diffnav` from them. The tap succeeds; the
**install** refuses. Even after manually trusting `raine/workmux`, the next run
fails again on `dlvhdr/formulae` — **both** taps are untrusted.

Same shape in other install paths:

- `networking_tools` manually taps `teamookla/speedtest`, then `brew install speedtest` refuses.
- Brewfile taps such as `wxtsky/tap` are tapped by `brew bundle`, then cask fetch/install
  refuses with `Refusing to load cask ... from untrusted tap`.

## Root cause

**Homebrew 6.0 added a tap-trust security gate.** `brew install` / `brew bundle`
now refuse to load formulae or casks from third-party taps until the tap is
explicitly trusted. `community.general.homebrew_tap` taps the repo but has **no
trust parameter** (the feature is newer than the module), so the tap stays
untrusted and the install fails.

Confirm state with `brew tap-info <tap>` — an untrusted tap shows a literal
`Untrusted` line:

```
$ brew tap-info raine/workmux
raine/workmux: Installed
Untrusted          # <-- this line is the gate
1 formula
```

Older Homebrew (< 6.0) has no trust concept at all — `tap-info` never prints
`Untrusted`, so this trap simply cannot occur there.

## Workaround

Trust the whole tap (one-liner, idempotent):

```bash
brew trust raine/workmux
brew trust dlvhdr/formulae
brew trust teamookla/speedtest
brew trust wxtsky/tap
# or per-formula: brew trust --formula raine/workmux/workmux
```

Then re-run `chezmoi apply` (or the ansible `devtools` tag).

## Prevention

Role-driven installs now trust their third-party taps automatically, between the
tap task and the install task. They check `brew tap-info` for the `Untrusted`
line and only run `brew trust` when needed (so it no-ops on older Homebrew and
on already-trusted machines):

```yaml
- name: Check trust state of third-party taps (macOS, Homebrew >= 6.0 formula-trust gate)
  when: ansible_facts["os_family"] == "Darwin"
  ansible.builtin.command: "brew tap-info {{ item }}"
  loop:
    - dlvhdr/formulae
    - raine/workmux
  register: devtools_tap_info
  changed_when: false
  failed_when: false

- name: Trust untrusted third-party taps (macOS)
  when:
    - ansible_facts["os_family"] == "Darwin"
    - "'Untrusted' in item.stdout"
  ansible.builtin.command: "brew trust {{ item.item }}"
  loop: "{{ devtools_tap_info.results }}"
  loop_control:
    label: "{{ item.item }}"
  changed_when: true
```

The Brewfile run-script uses the same pattern for `tap "..."` entries before
calling `brew bundle`, so casks from third-party taps do not fail after the tap
is added.

**Any new third-party tap added to a role must get this trust check near the tap
task too** — a tapped-but-untrusted formula/cask silently blocks the entire
ansible or Brewfile run.

## Related

- `dot_ansible/roles/devtools/tasks/main.yml` — the tap + trust + install tasks
- `dot_ansible/roles/networking_tools/tasks/main.yml` — `teamookla/speedtest`
  tap + trust + install tasks
- `.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl` — Brewfile
  tap trust pre-flight
- [`docs/this_repo/tool-managers.md`](../docs/this_repo/tool-managers.md) — tap/trust note
- Sibling: [`brew-bundle-redownloads-manually-installed-cask`](brew-bundle-redownloads-manually-installed-cask.md)

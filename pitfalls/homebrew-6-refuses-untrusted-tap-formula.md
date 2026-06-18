# `chezmoi apply` aborts: Homebrew refuses to load a formula from an untrusted tap

**Symptoms** (grep this section):
- `Error: Refusing to load formula raine/workmux/workmux from untrusted tap raine/workmux.`
- `Run \`brew trust --formula raine/workmux/workmux\` or \`brew trust raine/workmux\` to trust it.`
- ansible `devtools : Install developer CLI tools (macOS)` task → `FAILED!` → `changed: false`
- `.chezmoiscripts/global/20_ansible_roles.sh: exit status 2`; `PLAY RECAP … failed=1`
- Worked fine on the same machine days earlier; nobody changed the tap

**First seen**: 2026-06 (Mac mini, macOS 26.2, Homebrew 6.0.2)
**Affects**: Homebrew ≥ 6.0 on any OS, any third-party tap this repo uses (`raine/workmux`, `dlvhdr/formulae`)
**Status**: fixed in repo (`dot_ansible/roles/devtools/tasks/main.yml` trust task)

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

## Root cause

**Homebrew 6.0 added a formula-trust security gate.** `brew install` now refuses
to load formulae from third-party (non-core, non-cask) taps until the tap is
explicitly trusted. `community.general.homebrew_tap` taps the repo but has **no
trust parameter** (the feature is newer than the module), so the formula stays
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
# or per-formula: brew trust --formula raine/workmux/workmux
```

Then re-run `chezmoi apply` (or the ansible `devtools` tag).

## Prevention

The `devtools` role now trusts its third-party taps automatically, between the
`homebrew_tap` tasks and the install task. It checks `brew tap-info` for the
`Untrusted` line and only runs `brew trust` when needed (so it no-ops on older
Homebrew and on already-trusted machines):

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

**Any new third-party tap added to `devtools` (or another role) must be added to
this `loop` too** — a tapped-but-untrusted formula silently blocks the entire
ansible run.

## Related

- `dot_ansible/roles/devtools/tasks/main.yml` — the tap + trust + install tasks
- [`docs/this_repo/tool-managers.md`](../docs/this_repo/tool-managers.md) — tap/trust note
- Sibling: [`brew-bundle-redownloads-manually-installed-cask`](brew-bundle-redownloads-manually-installed-cask.md)

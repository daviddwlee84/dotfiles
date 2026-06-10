# `Failed to update apt cache after 5 retries: ''` kills the whole play at the base role

**Symptoms** (grep this section): `Failed to update cache after 5 retries due to , retrying` / `Sleeping for 13 seconds, before attempting to refresh the cache again` / `fatal: [localhost]: FAILED!` `msg: 'Failed to update apt cache after 5 retries: '` (empty reason) / `Failed to update apt cache: unknown reason` — at `roles/base/tasks/main.yml` "Install base packages (Debian/Ubuntu)"; `chezmoi init` exits 1; ansible script `20_ansible_roles.sh: exit status 2`
**First seen**: 2026-06 (Ubuntu 22.04 `ta-stg`, `useChineseMirror=true`)
**Affects**: any Debian/Ubuntu host with one broken/unreachable third-party apt source; especially GFW hosts
**Status**: fixed (base role best-effort cache update + diagnostics; dead lazygit PPA removed + purged; deb822 repos verified + rolled back)

## Symptom

On a Ubuntu 22.04 host behind the GFW, `chezmoi init --apply` died ~4 minutes
into the ansible phase, at the very first apt task:

```
[WARNING]: Failed to update cache after 5 retries due to , retrying
[WARNING]: Sleeping for 13 seconds, before attempting to refresh the cache again
[ERROR]: Task failed: Module failed: Failed to update apt cache after 5 retries:
Origin: /home/daweilee/.ansible/roles/base/tasks/main.yml:19:3

19 - name: Install base packages (Debian/Ubuntu)

✘ fatal: [localhost]: FAILED! (3m55s) =>
    changed: false
    msg: 'Failed to update apt cache after 5 retries: '
```

Note the **empty error reason** ("due to ,") — the apt module swallows the
underlying python-apt fetch exception, so the output never says *which*
source is broken.

## Root cause

Two stacked problems:

1. **One broken source fails `apt-get update` for the whole machine**, and the
   base role inlined `update_cache: true` in its install task, so the play died
   before installing anything. Empirically (verified in an ubuntu:22.04
   container):
   - a **404 / missing-Release-file** source (e.g. a dead PPA) only produces a
     *warning* — python-apt still returns success;
   - a **timeout / connection-refused** source (GFW-blackholed host, dead
     proxy) makes python-apt raise `FetchFailedException` with an **empty
     message** → exactly the symptom above. So the trigger on GFW hosts is an
     unreachable repo host, not a 404.
2. **We planted the broken sources ourselves**: `lazyvim_deps` still added
   `ppa:lazygit-team/release`, which upstream deprecated in **2021**
   ([jesseduffield/lazygit#1399](https://github.com/jesseduffield/lazygit/issues/1399))
   — no Release file for focal+ — and `deb.gierens.de` (eza) plus
   `ppa.launchpadcontent.net` are flaky-to-unreachable behind the GFW. A
   partially-interrupted earlier run can leave such a source file behind in
   `/etc/apt/sources.list.d/`, and then **every** later run fails at base.

## Workaround

On the affected host, find and remove the broken source, then re-apply:

```bash
sudo apt-get update            # the CLI *does* name the failing source
ls /etc/apt/sources.list.d/
sudo rm /etc/apt/sources.list.d/<broken>.{list,sources}
chezmoi apply
```

## Prevention (what the repo now does)

- `roles/base`: cache update is a separate **best-effort** task
  (`ignore_errors`); on failure a follow-up task runs `apt-get update` via CLI
  and prints the `Err:` / `E:` lines naming the broken source, then package
  install proceeds against the (possibly stale) lists — base packages all live
  in the main archives, so this almost always works.
- `roles/lazyvim_deps`: the dead lazygit PPA path is **gone** (GitHub release
  install only) and the role purges leftover `*lazygit*` source files from
  previously provisioned hosts.
- `roles/devtools` (eza) / `roles/gui_apps_linux` (AppImageLauncher PPA,
  VSCode): migrated `apt_repository` → `deb822_repository` (the old module is
  deprecated, removal slated for ansible-core 2.25). Since `deb822_repository`
  does NOT run `apt update` itself, each role refreshes explicitly and then
  **verifies with `apt-cache policy <pkg>`** that the package actually
  resolves from that repo URI — if not, the `.sources` file is rolled back so
  it cannot break later runs. (Plain `apt` module status is useless here: a
  partially-failed update is "success with warnings".)
- `deb822_repository` needs `python3-debian` on the target → added to the base
  package list.

## Related

- [`centos7-idc-slow-broken-installs.md`](centos7-idc-slow-broken-installs.md) — GFW/IDC network pain, RedHat flavor
- [`tuna-nodejs-mirror-aggressive-gc.md`](tuna-nodejs-mirror-aggressive-gc.md) — China-mirror flakiness elsewhere in the stack
- `docs/this_repo/tool-managers.md` § lazyvim_deps / devtools rows (install mechanisms)
- Upstream: [lazygit PPA deprecation](https://github.com/jesseduffield/lazygit/issues/1399); [`apt_repository` deprecation in favor of `deb822_repository`](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/apt_repository_module.html)

# `Failed to update apt cache after 5 retries: ''` kills the whole play at the base role

**Symptoms** (grep this section): `Failed to update cache after 5 retries due to , retrying` / `Sleeping for 13 seconds, before attempting to refresh the cache again` / `fatal: [localhost]: FAILED!` `msg: 'Failed to update apt cache after 5 retries: '` (empty reason) / `Failed to update apt cache: unknown reason` — at `roles/base/tasks/main.yml` "Install base packages (Debian/Ubuntu)", **or any other role that inlines `update_cache: true` in an install task** (seen at `roles/docker` "Install rootless Docker prerequisites", `roles/media_tools` "Install media/AV tools from apt"); `chezmoi init` exits 1; ansible script `20_ansible_roles.sh: exit status 2`
**First seen**: 2026-06 (Ubuntu 22.04 `ta-stg`, `useChineseMirror=true`); recurred 2026-06 on Ubuntu 24.04 `David-Ubuntu` behind a Clash/socks proxy (`HTTP_PROXY=http://127.0.0.1:7890`) — the proxy dropped for >30s mid-play, so `docker`/`media_tools` cache updates failed and aborted the play before `gui_apps_linux` (Steam) ran.
**Affects**: any Debian/Ubuntu host with one broken/unreachable/slow third-party apt source — broken PPA, GFW-blackholed host, OR a flaky local proxy that drops connections intermittently
**Status**: fixed (base role best-effort cache update + diagnostics; dead lazygit PPA removed + purged; deb822 repos verified + rolled back; `docker`/`media_tools` no longer inline `update_cache`; Steam refresh scoped to its own source)

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
   - a **truncated / 0-byte signing key** is the nastiest variant: if a
     `curl … | gpg --dearmor -o /etc/apt/keyrings/<x>.gpg` is cut off mid-stream
     (flaky proxy), gpg has already created the output file, so a **0-byte key**
     is left behind. The matching `.list`/`.sources` still has `signed-by=`, so
     **every** later `apt-get update` dies with `NO_PUBKEY …` until the key is
     fixed. Seen 2026-06: a failed OpenTofu install left `opentofu.gpg` at 0
     bytes → `NO_PUBKEY 70DF59811A8B9109` wedged every subsequent apply.
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
- `roles/docker`, `roles/media_tools`, `roles/niri`, `roles/input_method`,
  `roles/auditd`, `roles/ruby_gem_tools`, `roles/homelab_tools`: install tasks
  no longer inline `update_cache: true`. They install **main-archive/universe**
  packages already covered by base's best-effort refresh at play start, so they
  now use `update_cache: false` — a transient proxy/source drop (or a broken
  sibling source like the 0-byte key above) can no longer abort the play here.
- `roles/iac_tools` (OpenTofu): hardened against the 0-byte-key trap — the key
  is dearmored to `opentofu.gpg.tmp`, **verified non-empty (`test -s`)**, then
  atomically `mv`'d into place; the live keyring is never truncated on a failed
  download, and its `apt-get update` is **scoped to `opentofu.list` only**
  (`-o Dir::Etc::sourcelist=… -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0`).
  A pre-existing 0-byte key self-heals on the next successful apply. To unwedge
  immediately: `sudo rm -f /etc/apt/keyrings/opentofu.gpg /etc/apt/sources.list.d/opentofu.list && chezmoi apply`.
- `roles/gui_apps_linux` (Steam): the Valve repo is new (base's refresh hasn't
  seen it) so it MUST update after adding the source — but instead of a full
  `apt-get update` (which re-fetches every flaky third-party source), it runs a
  **source-scoped** `apt-get update -o Dir::Etc::sourcelist=sources.list.d/steam.sources -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0`.
  This is immune to sibling sources and has no `ansible.builtin.apt` equivalent
  (the module can't target a single source). Verify on a host with:
  `sudo apt-get update -o Dir::Etc::sourcelist=sources.list.d/steam.sources -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 && apt-cache policy steam-launcher`

## Related

- [`centos7-idc-slow-broken-installs.md`](centos7-idc-slow-broken-installs.md) — GFW/IDC network pain, RedHat flavor
- [`tuna-nodejs-mirror-aggressive-gc.md`](tuna-nodejs-mirror-aggressive-gc.md) — China-mirror flakiness elsewhere in the stack
- `docs/this_repo/tool-managers.md` § lazyvim_deps / devtools rows (install mechanisms)
- Upstream: [lazygit PPA deprecation](https://github.com/jesseduffield/lazygit/issues/1399); [`apt_repository` deprecation in favor of `deb822_repository`](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/apt_repository_module.html)

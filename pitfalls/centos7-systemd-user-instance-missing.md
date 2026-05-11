# `ansible … pueued systemd --user` fails with "Failed to get D-Bus connection" on CentOS 7 — `Unit user@$UID.service could not be found`

**Symptoms** (grep this section):

- ansible task `rust_cargo_tools : Enable and start pueued service` fails with:
  ```
  [WARNING]: daemon-reload failed, but target is a chroot or systemd is offline. Continuing. Error was: 1 / Failed to get D-Bus connection: No such file or directory
  [ERROR]: Task failed: Module failed: Failed to get D-Bus connection: No such file or directory
  cmd: /usr/bin/systemctl --user
  msg: 'Failed to get D-Bus connection: No such file or directory'
  rc: 1
  ...ignoring
  ```
- PLAY RECAP shows `failed=0` but `ignored=1`; pueued daemon is silently never enabled / never starts.
- `sudo loginctl enable-linger $USER` does NOT fix it; manually re-running `systemctl --user daemon-reload` after the linger toggle still prints:
  ```
  Failed to get D-Bus connection: No such file or directory
  ```
- `loginctl show-user $USER` confirms `Linger=yes`, `State=active`, `RuntimePath=/run/user/<UID>` — but `/run/user/<UID>/bus` and `/run/user/<UID>/systemd` are absent.
- `sudo systemctl start user@$(id -u).service` returns:
  ```
  Failed to start user@8091.service: Unit not found.
  ```
- `find /usr/lib/systemd /etc/systemd -name 'user@.service'` returns nothing.

**First seen**: 2026-05 on `idc-server104` (CentOS 7.9, systemd-219-78.el7_9.7).
**Affects**: any CentOS 7 / RHEL 7 / Oracle Linux 7 host using stock distro systemd. Anything that calls `systemctl --user` (currently only `dot_ansible/roles/rust_cargo_tools` for `pueued`; would also bite a future role attempting rootless docker on CentOS 7 stock).
**Status**: WONTFIX upstream (RHEL 7 EOL'd 2024-06; no backport coming). Workaround documented; ansible role correctly `ignore_errors: true`-wraps it.

## Symptom (verbatim)

```
[89] TASK · [rust_cargo_tools : Enable and start pueued service]
[WARNING]: daemon-reload failed, but target is a chroot or systemd is offline. Continuing. Error was: 1 / Failed to get D-Bus connection: No such file or directory
[ERROR]: Task failed: Module failed: Failed to get D-Bus connection: No such file or directory
Origin: ~/.ansible/roles/rust_cargo_tools/tasks/main.yml:176:3

✘ fatal: [localhost]: FAILED! (0.8s) =>
    changed: false
    cmd: /usr/bin/systemctl --user
    msg: 'Failed to get D-Bus connection: No such file or directory'
    rc: 1
    stderr: |-
        Failed to get D-Bus connection: No such file or directory
...ignoring
```

User then tries the obvious "linger" fix:

```
$ sudo loginctl enable-linger yczhang
$ systemctl --user daemon-reload
Failed to get D-Bus connection: No such file or directory
```

Linger _is_ enabled (`loginctl show-user yczhang` shows `Linger=yes`), but the
error persists.

## Root cause

CentOS 7 / RHEL 7 ship **systemd 219** (May 2015 vintage, plus security
backports). The `user@.service` template — the unit that PID 1 launches per
user to provide their `systemctl --user` instance — was added in **systemd
~226** (Sep 2015) and **was never backported to RHEL 7**.

```
$ systemctl --version | head -1
systemd 219

$ find /usr/lib/systemd /etc/systemd -name 'user@.service'
(empty)

$ sudo systemctl start user@$(id -u).service
Failed to start user@8091.service: Unit not found.

$ ls -la /run/user/$(id -u)
drwx------  yczhang yczhang  blesh/      ← logind made the dir on login
drwx------  yczhang yczhang  keyring/
drwx------  yczhang yczhang  ssh-agent/
                              # ↑ but no `bus` socket, no `systemd` subdir
                              # because no user systemd instance ever started
```

What you DO get on CentOS 7:

- `systemd-logind` runs as a system service. ✓
- It creates `/run/user/$UID/` on first login per user. ✓
- It populates `XDG_RUNTIME_DIR`. ✓
- Linger (`loginctl enable-linger`) keeps `/run/user/$UID/` alive across
  logouts. ✓

What you DON'T get:

- The `user@.service` template unit. ✗
- A user-scoped `systemd --user` instance running as PID-of-the-user. ✗
- `/run/user/$UID/systemd/` (the user manager's runtime dir). ✗
- `/run/user/$UID/bus` (the user-scope D-Bus socket). ✗
- Therefore `systemctl --user <anything>` always fails with the D-Bus error,
  no matter how many times you re-login or toggle linger.

This is _by design_ for RHEL 7 — Red Hat's documented stance is that
"systemd user instances are a Fedora-only feature" for the 7 series. RHEL 8
fixed this (`user@.service` ships and is auto-started by logind).

## Why ansible's "WARNING: target is a chroot or systemd is offline" is
**misleading**

Look at the ansible warning text:

> daemon-reload failed, but target is a chroot or systemd is offline.

This is the message ansible's `systemd` module prints when
`systemctl --user daemon-reload` returns non-zero. The text was written for
the common container case (`docker run` without `--init`, no PID 1 systemd).
On CentOS 7 stock, systemd is **online and active** — `systemctl status` and
the entire system instance work fine. It's the _user_ instance that's
missing. The warning misleads you into thinking "oh, it's a container thing,
I'll re-check on the bare-metal" — but the bare-metal has the same defect.

## Why `ignore_errors: true` in the role is correct

`dot_ansible/roles/rust_cargo_tools/tasks/main.yml`:

```yaml
- name: Enable and start pueued service
  when: ansible_facts["os_family"] in ["Debian", "RedHat"]
  ansible.builtin.systemd:
    name: pueued
    scope: user
    enabled: true
    state: started
    daemon_reload: true
  ignore_errors: true  # May fail in containers without systemd; also CentOS 7
                       # has no user@.service template (see pitfalls/centos7-systemd-user-instance-missing.md)
```

There is no clean per-host detection ansible can do that's better than "try
and ignore". Pre-flight checks (`systemctl --user --version` / probing
`/run/user/$UID/bus`) would force the role to encode "if CentOS 7 then skip"
which is fragile and would also miss future hosts where the user instance is
broken for unrelated reasons. The current "try, ignore failure, leave the
unit file on disk for manual use" is the pragmatic answer.

## Workaround (if you actually want pueued running on a CentOS 7 host)

Ranked by intrusiveness:

### Option 1 — Run pueued without systemd (simplest, recommended)

The pueued daemon doesn't _need_ systemd. Start it under tmux, screen, or
`nohup`:

```bash
# In a tmux pane / window dedicated to background daemons:
~/.cargo/bin/pueued --verbose

# Or detached:
nohup ~/.cargo/bin/pueued --verbose >/tmp/pueued.log 2>&1 &
disown
```

Cost: dies on logout (unless inside a tmux session that has a tmux server
detached). Have to remember to start it. Unaffected by reboots — needs a
manual restart.

### Option 2 — Install pueued as a system service (one machine boundary)

Edit the unit ansible wrote to add `User=$USER`, copy to system path, enable:

```bash
sudo cp ~/.config/systemd/user/pueued.service /etc/systemd/system/pueued.service
sudo sed -i 's|^ExecStart=%h/|ExecStart=/home/yczhang/|' /etc/systemd/system/pueued.service
sudo sed -i '/^\[Service\]/a User=yczhang\nGroup=yczhang' /etc/systemd/system/pueued.service
sudo systemctl daemon-reload
sudo systemctl enable --now pueued.service
```

Cost: requires sudo for any restart; daemon runs at boot regardless of who
logs in; cross-user contamination (other CentOS 7 users can't have their
own pueued without colliding on socket path). Not recommended for shared
hosts.

### Option 3 — Upgrade systemd (NOT recommended on production CentOS 7)

In theory, replacing systemd with a build from CRB / EPEL test repos would
give you a newer version with `user@.service`. In practice this risks
breaking everything on the box (DBus, logind, journald, networking
service handling). Don't do this on a host you can't reimage.

### Option 4 — Migrate to RHEL 8 / Rocky 9 / Alma 9

The clean answer. Rocky 9's systemd 250+ has `user@.service` working out of
the box; `loginctl enable-linger` actually does what its name suggests.

## Prevention

When adding a new ansible role that uses `systemctl --user`, mirror the
existing pattern in `dot_ansible/roles/rust_cargo_tools/tasks/main.yml`:

- Wrap the `state: started` task in `ignore_errors: true`.
- Document in a comment that it WILL fail on CentOS 7 stock and in
  containers without systemd, and that the unit file on disk is the
  artifact even when the daemon never starts.
- Cross-link this pitfall.

Don't try to "fix" the failure by adding a CentOS 7 detection — there's no
clean fix at the role level. The only fix is migrating the host or
accepting Option 1/2 manually per host.

## Related

- [`pitfalls/centos7-numpy-pandas-source-build.md`](centos7-numpy-pandas-source-build.md) — sister CentOS 7
  "stock distro is too old, modern toolchain expects newer baseline" story
  (gcc 4.8.5 vs gcc 9.3+ for numpy 2.x source build).
- [`pitfalls/centos7-noroot.md`](centos7-noroot.md) — glibc 2.17 vs musl
  binaries on the same host class.
- [`pitfalls/centos7-zsh-too-old.md`](centos7-zsh-too-old.md) — zsh 5.0.2
  vs OMZ's 5.3 minimum, same EL7 baseline limitation.
- [`pitfalls/centos7-ansible-yum-dnf-backend.md`](centos7-ansible-yum-dnf-backend.md) — ansible-side
  workaround for the same EL7 host family.
- [`docs/tools/container-config-map.md`](../docs/tools/container-config-map.md) — the rootless docker
  story which depends on the same `systemctl --user` mechanism that's
  broken on CentOS 7 stock; the ansible `docker` role's
  `loginctl enable-linger` step would hit a similar wall on CentOS 7
  (currently moot because the rootless docker pivot targets Ubuntu /
  Rocky 9, not EL7).
- Upstream context: [systemd PR adding `user@.service` template](https://github.com/systemd/systemd/commit/49ab17a) (~2015,
  v226). Red Hat's [bz#1099218](https://bugzilla.redhat.com/show_bug.cgi?id=1099218)
  on RHEL 7 user systemd was closed WONTFIX.

# Shared storage permissions (group + ACL) and `raid-perm-check`

How a multi-user data mount is shared here, the two failure modes that break
it silently, and the `raid-perm-check` helper that audits both.

Applies to any group-shared mount. The worked example is `/mnt/raid` on
`ta-stg` (xfs, shared between several analyst accounts).

## The access model

Plain Unix ownership can express one owning group. That is not enough once you
want **read-write** and **read-only** tiers over the same tree, so each
top-level directory combines three mechanisms:

| Mechanism | Purpose |
|---|---|
| `root:<rw-group>` ownership | the writers |
| mode `2770` (**setgid**) | new files inherit the group instead of the creator's primary group |
| POSIX ACL `group:<ro-group>:r-x` + `default:` | the readers, and inheritance for future files |

The `default:` entries matter as much as the live ones: without them a file
created tomorrow carries no ACL and the read-only tier silently loses access to
new data only — the directory still looks correct.

A worked layout:

```
/mnt/raid/gst      root:ax_data_rw      2770  + ACL ax_data_r:r-x  (+ defaults)
/mnt/raid/jingle   root:ax_data_rw      2770  + ACL ax_data_r:r-x  (+ defaults)
/mnt/raid/crypto   root:crypto_data_rw  2770  + ACL crypto_data_r:r-x (+ defaults)
```

Naming convention: the read-only tier is the read-write group name with `_rw`
replaced by `_r`. Read-only groups usually appear **only** in ACLs and never as
a directory's owning group, so `ls -l` and `stat -c %G` cannot see them — you
have to read `getfacl`.

## Failure mode 1 — orphaned uid/gid

When an account is deleted (or data is restored from another host), files keep
the numeric owner. It resolves to nothing, belongs to no current group, and
therefore excludes **everyone** — including the group that is supposed to own
the data.

```console
$ ls -l /mnt/raid/gst/orders/
-rw-rw---- 1 1000 1000  73k sz_2026-05-22.feather     # 1000 has no passwd entry
```

Detect (depth-limited — an unbounded walk over a multi-TB array is slow enough
that nobody runs it twice):

```bash
find /mnt/raid -maxdepth 3 \( -nouser -o -nogroup \)
```

Fix — reassign the group **and** set setgid so it cannot recur:

```bash
sudo chgrp -R <group> <path>
sudo chmod -R g+rwX <path>
sudo find <path> -type d -exec chmod g+s {} +
```

`chgrp`/`chmod` preserve existing ACL entries; `chmod g+rwX` moves the ACL
**mask**, not the group entry, so pre-existing `group:` grants survive. Verify
with `getfacl` rather than assuming.

## Failure mode 2 — stale `systemd --user` groups

`systemd --user` resolves supplementary groups **once, at manager start**, and
every user unit inherits that frozen set. A later `usermod -aG` never reaches
the running manager.

This produces the most confusing symptom in this whole area: a scheduled job
dies with `EACCES` on a path your interactive shell reads perfectly, because
each SSH login opens a fresh PAM session with current groups.

```bash
# The two disagree — that is the bug
grep ^Groups /proc/$(pgrep -u "$USER" -f 'systemd --user')/status
grep ^Groups /proc/$$/status

# Test what the manager can actually see (not what your shell can)
systemd-run --user --wait --pipe /bin/ls /mnt/raid/gst/orders/
```

Fix:

```bash
sudo systemctl restart user@$(id -u).service
```

!!! warning "Do not use `loginctl terminate-user` from inside that user's session"
    It terminates every session of the user, including the shell you are typing
    in. `systemctl restart user@<uid>.service` leaves login sessions alone —
    they are separate `session-N.scope` units under `user-<uid>.slice`, not
    children of `user@<uid>.service`.

The restart stops **everything** under the manager: rootless docker and its
containers, `pueued` (running tasks are killed), and all user timers. If a
container provides your outbound network path (e.g. a proxy), anything pushing
to the internet fails during the window. Check first:

```bash
pueue status                                     # nothing running?
systemctl --user is-enabled docker.service       # enabled -> returns by itself
loginctl show-user "$USER" -p Linger             # Linger=yes -> manager persists
```

## `raid-perm-check`

Read-only auditor for all of the above — it never modifies anything, it prints
the fixing command for you to run.

```bash
raid-perm-check                 # summary: dirs, ACLs, your own access
raid-perm-check orphans         # uid/gid with no passwd/group entry
raid-perm-check groups          # membership, including ACL-only read-only tiers
raid-perm-check units           # systemd --user manager group staleness
raid-perm-check user yczhang    # what one account can actually reach
raid-perm-check all             # everything
```

Takes an optional `ROOT` (default `$RAID_PERM_CHECK_ROOT`, else `/mnt/raid`);
orphan-scan depth is `$RAID_PERM_CHECK_DEPTH` (default 3). Exits `1` when it
finds something, so it drops straight into a cron/monitoring check.

Nothing is hard-coded to one host: the group list is discovered from the mount's
own directory ownership **and** ACL entries, which is what makes the read-only
tiers visible.

```console
$ raid-perm-check units
systemd --user manager group staleness
    manager pid 68051, started Tue Jul 28 16:28:19 2026
    manager : 24 30 46 2000 10000 10002
    current : 24 30 46 2000 10000 10002
  ✔ in sync — user units see the same groups you do
```

Source: `dot_dotfiles/bin/executable_raid-perm-check`. Completions:
[zsh-completions § F](../zsh/zsh-completions.md).

## Related

- [Scheduled jobs](scheduled-jobs.md) — the timers that hit failure mode 2
- [Disk / filesystem monitoring](disk.md)
- [Sessions and login](sessions.md) — where the PAM-vs-manager distinction comes from

# Disk / filesystem monitoring

Sysadmin morning question: **is anything full, and what's eating it?**

This page documents the disk-related helpers and the `tv disk` channel.
For the dense reference table, see [helpers.md](helpers.md#disk--filesystem).

## Why care

Three failure modes that wake you up at 3am:

1. **Disk full** (`No space left on device`) — auditd panics the kernel
   if `disk_full_action = halt`. Most other daemons just stop accepting
   writes silently.
2. **Inode exhaustion** — disk shows free space, but `touch foo` fails
   because the inode table is full. Common with apps that create
   millions of tiny files (mail spools, badly-tuned caches).
3. **Mount lost / mounted with wrong options** — the same path
   exists but isn't where you think it is, or is now `nosuid,nodev`
   when it shouldn't be (security regression after a manual remount).

The helpers cover all three.

## Quick CLI

```bash
disk-usage             # per-mount df with green/yellow/red thresholds
disk-inodes            # inode usage per mount
disk-largest /var      # largest depth-1 children of /var
disk-largest /var/log --top 10  # classic /var/log triage
mount-info             # active mounts + /etc/fstab
disk-watch /           # live update of root mount usage
```

`disk-largest` auto-elevates via `sudo -v` when the path is root-owned
(e.g. `disk-largest /var/lib/docker`). Same gotcha as the audit
helpers: these are shell **functions**, so `sudo disk-largest …`
doesn't work; warm the sudo cache once with `sudo -v` and the helper
takes care of the rest.

## Interactive: `tv disk`

```bash
tv disk
```

`Ctrl+S` cycles 5 sources: per-mount df → inodes → largest dirs in
`/var /home /tmp /opt /srv` → active mounts → largest files >100M.
Preview is path-aware (uses `du --max-depth=1` for dirs, `ls -lh +
file` for files). `Enter` opens dir in yazi or file in less. `Alt+E`
edits `/etc/fstab`. `Alt+T` tails `dmesg -wT --color=always` to catch
ENOSPC and I/O errors live.

## Daily / weekly recipes

### Morning sweep

```bash
disk-usage         # any red rows? jump to that mount
disk-inodes        # any mount > 80% inodes?
```

If both are green you're done in 5 seconds. If `disk-usage` shows red:

```bash
disk-largest <red-mount> --top 20
# then drill into the offender
disk-largest <red-mount>/<biggest-subdir> --top 20
```

`tv disk` is faster for the drill phase because the path-aware preview
eliminates the second `disk-largest` call.

### `/var/log` is full

```bash
disk-largest /var/log --top 20
```

Usual suspects:

- `journal/` — `sudo journalctl --vacuum-size=200M` to cap.
- `*.log.1.gz` accumulating — logrotate misconfigured, or a service
  not signalled to reopen its log file.
- `audit/` — auditd; tune `max_log_file` / `num_logs` per
  [auditd.md](auditd.md).

### Disk free but `touch foo` fails

Inode exhaustion:

```bash
disk-inodes
```

Look for `IUse%` >= 95%. To find the culprit (millions of tiny files):

```bash
sudo find / -xdev -type d -exec sh -c 'echo "$(ls -A "$1" 2>/dev/null | wc -l) $1"' _ {} \; 2>/dev/null \
  | sort -rn | head -20
```

(Slow on large filesystems; run during off-peak.)

### Mount audit

```bash
mount-info
```

Look for:

- A `/home` mounted without `nosuid,nodev` — privilege-escalation
  surface.
- A `/tmp` mounted without `noexec,nosuid,nodev` — common attacker
  drop site.
- A drive in `/etc/fstab` that *should* mount but doesn't appear in
  the active list — mount failure at boot.

## Caveats

- **macOS doesn't have `df -hT`** — the helper templates emit `df -h`
  on Darwin.
- **`du --max-depth=1` is a GNU extension** — macOS BSD `du` accepts
  `-d 1`. The helper uses `--max-depth=1` (works because Homebrew
  installs GNU coreutils as the default `du` on most macOS hosts in
  this repo); pure macOS without coreutils will see the option flag
  rejected. Workaround: install `coreutils` via `brew install
  coreutils` (already done if you're using this repo's Brewfile).
- **`disk-largest` doesn't follow mount boundaries** unless you tell
  it to. By default `du` includes mounted subdirs in the parent's
  total. For per-filesystem accounting use `du -x`.
- **`dmesg` requires root on most modern kernels** (`kernel.dmesg_restrict=1`).
  `Alt+T` in `tv disk` calls it via sudo.

## See also

- [auditd framework](auditd.md) — `disk_full_action` policy
- [Helpers in this repo](helpers.md#disk--filesystem)
- [Cookbook recipe 12](cookbook.md#12-network-exposure--persistence-the-weekly-sweep)
  — combines disk + firewall + scheduled-jobs into one weekly pass

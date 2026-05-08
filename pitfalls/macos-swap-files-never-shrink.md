# macOS swap files never shrink: "System Data" / "Other Volumes" balloons until reboot

**Symptoms** (grep this section):
- About > General > Storage shows 30+ GB of "System Data" or "Other
  Volumes" growing daily, even though the user has not added files
- Activity Monitor's Memory tab shows **Memory Pressure** in green or
  yellow (not red) — i.e. the OS believes it's coping fine
- Activity Monitor's Memory tab shows **Swap Used** at 10-20+ GB
- After reboot, "System Data" drops 15-20+ GB instantly with no other
  user action
- The pattern repeats every few days / weeks with the same delta
- `ls -lh /System/Volumes/VM/swapfile*` (Apple Silicon / modern Intel)
  or `ls -lh /private/var/vm/swapfile*` (older Intel) shows multiple
  1 GB files
- `du -ch /System/Volumes/VM/swapfile* 2>/dev/null | tail -1` matches
  the "Swap Used" reported by Activity Monitor
- `sysctl vm.swapusage` shows current `used` is moderate but
  cumulative — `total` keeps growing across days
- Trying `sudo rm /System/Volumes/VM/swapfile*` "succeeds" but
  reclaims zero disk space (verified with `df -h /` before/after)

**First seen**: 2026-05 on Apple Silicon Mac mini (16 GB RAM, macOS 15.x);
also reproduced on Intel MBP 16" 2019 (32 GB RAM, macOS 14.x). Likely
affects every macOS host that runs uninterrupted for more than a few days.
**Affects**: all macOS versions since at least Mavericks (10.9). Worse on
small-RAM systems (8-16 GB) running heavy memory consumers (Electron apps,
browsers with many tabs, VMs, Docker, AI agents).
**Status**: working as designed by Apple. There is **no userspace fix**.
Repo workaround: `dot_config/shell/55_macos_mem.sh.tmpl` ships
`mac-mem-status` / `mac-mem-reclaim` to reclaim *adjacent* storage
(disk caches, Spotlight indexers, TM snapshots, sleepimage) without
touching swapfiles. See [`docs/tools/macos-swap.md`](../docs/tools/macos-swap.md)
for the full mental model.

## Symptom

User reports the Storage pie chart (About > General > Storage) showing
the System Data / Other Volumes segment growing 1-3 GB per day. They've
verified they haven't added files — `du -sh ~` is stable, Documents /
Downloads / Library are unchanged in size. Yet 30+ GB has appeared in
"System Data" over a week.

Reboot reclaims 15-20+ GB instantly. The pattern then repeats.

The user (correctly) suspects swap, because Activity Monitor's Memory
tab shows `Swap Used: 17.59 GB`. But Memory Pressure is yellow, not red,
so they believe the OS is coping — which makes the disk usage feel
unjustified.

## Diagnosis

The 17 GB lives in `/System/Volumes/VM/` (Apple Silicon and modern
Intel) or `/private/var/vm/` (older Intel — the modern Apple Silicon
hosts have an empty stub at this path):

```sh
$ ls -lh /System/Volumes/VM/swapfile* 2>/dev/null
-rw-------  1 root  wheel   1.0G  Apr 28  swapfile0
-rw-------  1 root  wheel   1.0G  Apr 28  swapfile1
-rw-------  1 root  wheel   1.0G  Apr 29  swapfile10
-rw-------  1 root  wheel   1.0G  May  7  swapfile11
... (17 files in total)
```

`vm.swapusage` confirms:

```sh
$ sysctl vm.swapusage
vm.swapusage: total = 17408.00M  used = 15958.75M  free = 1449.25M  (encrypted)
```

After two days of normal use the file count and `total` field *only
ever grow*. `used` fluctuates with current pressure. `free` is just the
arithmetic difference.

## Root cause

macOS dynamically grows swapfiles as memory pressure dictates:

1. First swapfile is **64 MB**.
2. Each subsequent file doubles up to **1 GB**, then stays at 1 GB.
3. New files are added on demand; the only cap is **free disk** on the
   system volume.
4. **Existing swapfiles are never deleted while macOS is running.**
   Even when memory pressure drops to zero and `vm.swapusage`'s `used`
   falls to a few hundred MB, the allocated swapfiles stay on disk.
   They get re-used the next time pressure rises.
5. Reboot deletes all swapfiles; one fresh empty 64 MB swapfile is
   created on first need.

There is **no public API to ask the kernel to delete a swapfile**.
Not `sysctl`, not `vm_pressure_monitor`, not Endpoint Security. Apple's
`dynamic_pager(8)` daemon decides when to *create* swapfiles but never
decides to *delete* them mid-run.

This is intentional Apple design (see
[`docs/tools/macos-swap.md` → Why reboot really is the answer](../docs/tools/macos-swap.md#why-reboot-really-is-the-answer)
for the rationale).

## Workaround

Two angles, in order of preference:

### Reclaim *adjacent* storage that's bloating alongside swap

Use `mac-mem-reclaim` (this repo) — runs `sudo purge`, optionally
restarts Spotlight indexers, optionally thins Time Machine local
snapshots, optionally deletes sleepimage. None of these touch
swapfiles, but they often reclaim 5-15 GB combined and may be enough
to delay reboot.

```sh
mac-mem-reclaim --include spotlight,snapshots
# desktop on AC only:
mac-mem-reclaim --include sleepimage
```

### Schedule a reboot

If the workload genuinely accumulates 10+ GB of swap per week, the
only reliable fix is rebooting. The repo's recommended cadences:

| Workload | Reboot cadence |
|---|---|
| Daily-driver laptop on battery | Weekly |
| Always-on workstation / Mac mini server | Every 2-4 weeks |
| Heavy VM / Docker / AI-agent dev box | Every 1-2 weeks |

Add a calendar reminder. macOS does not auto-reboot for swap reclaim.

## What NOT to try

The following all appear in old forum posts and **do not work** on
modern macOS:

| Don't | Why |
|---|---|
| `sudo nvram boot-args="vm_compressor=2"` to disable the compressor | Hard-hangs Apple Silicon on next boot — the entire VM subsystem assumes the compressor exists. Recovery requires NVRAM reset. |
| `sudo dynamic_pager -L 0` toggling | Either no-op or hard-hangs the kernel on modern macOS. The swap subsystem no longer routes cleanup decisions through `dynamic_pager`. |
| `sudo rm /System/Volumes/VM/swapfile*` while macOS is running | Kernel has them open via `mmap`; `unlink` removes the directory entry but the kernel keeps writing to the now-orphan inode. Reclaims **zero** disk space, may corrupt processes whose pages were swapped to those files. |
| Third-party "memory cleaner" apps from the App Store | Most just call `sudo purge` (which `mac-mem-reclaim` does for free). Some aggressively kill processes, causing data loss. None can shrink swapfiles on a running system — Apple has no API for it. |
| Setting an aggressive `pmset hibernatemode` to "force flush swap" on sleep | Hibernation writes RAM to `sleepimage`, not to swapfiles. Doesn't help. |

## Why this is in `mac-mem-reclaim` as a deliberate omission

The helper has `--include sleepimage` and `--include windowserver`
opt-ins for risky-but-real reclaims. It deliberately has **no**
`--include swapfiles` option, because every approach to deleting
swapfiles on a running system either silently fails (orphan inode
case) or risks process corruption.

If a future macOS version exposes a supported swapfile-shrink API,
add `--include swapfiles` calling that API. Until then, the answer is
"reboot, sorry".

## Related

- [`docs/tools/macos-swap.md`](../docs/tools/macos-swap.md) — full deep-dive (mental model, diagnosis, reclaim, monitoring)
- [`dot_config/shell/55_macos_mem.sh.tmpl`](../dot_config/shell/55_macos_mem.sh.tmpl) — `mac-mem-status` / `mac-mem-reclaim` / `mac-mem-watch`
- [`dot_config/television/cable/mac-procs.toml.tmpl`](../dot_config/television/cable/mac-procs.toml.tmpl) — `tv mac-procs` channel

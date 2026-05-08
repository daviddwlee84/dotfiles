# macOS swap, memory pressure & "System Data" bloat

When About > General > Storage shows 30+ GB of "System Data" / "Other Volumes"
that you never created, and rebooting reclaims most of it instantly, you're
not imagining things — you're watching macOS's dynamic VM subsystem do
exactly what it's designed to do, just *aggressively*.

This page explains what's actually happening, how to diagnose it without
guessing, and how to reclaim space without rebooting (within the limits of
what macOS allows — see the [pitfall page][pitfall] for what it doesn't).

[pitfall]: https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/macos-swap-files-never-shrink.md

## TL;DR

Three commands. Run them in order:

```sh
mac-mem-status                         # diagnose: what's eating RAM and disk?
mac-mem-reclaim --dry-run              # preview the always-safe cleanup
mac-mem-reclaim                        # do the safe cleanup
mac-mem-reclaim --include snapshots    # opt-in: also drop TM local snapshots
```

Short aliases for daily use: **`mms`** = `mac-mem-status`, **`mmr`** =
`mac-mem-reclaim`, **`mmw`** = `mac-mem-watch`. Use long forms in scripts
(non-interactive shells skip alias resolution); short forms in your terminal.

If swap is still 10+ GB and disk is still tight after that — **reboot**.
There is no userspace API to shrink existing swapfiles on a running system;
this is not a workaround failure, it's an OS design decision (see
[Why reboot really is the answer](#why-reboot-really-is-the-answer)).

For a live tail in a tmux side-pane while debugging an offender:

```sh
mac-mem-watch                          # 5s tick; Ctrl+C to stop
mac-mem-watch 2                        # 2s tick (more responsive, more noise)
```

For a fuzzy picker over the heaviest processes (with kill / inspect actions),
on macOS hosts only:

```sh
tv mac-procs
```

All four live in this repo:
[`dot_config/shell/55_macos_mem.sh.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/shell/55_macos_mem.sh.tmpl)
+ [`dot_config/television/cable/mac-procs.toml.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/television/cable/mac-procs.toml.tmpl).

---

## Mental model: how macOS VM actually works

### The five "buckets" you'll see in Activity Monitor / `vm_stat`

| Bucket | What it is | Reclaimable? |
|---|---|---|
| **Wired** | Pinned in physical RAM by the kernel — drivers, kernel data structures, `kernel_task`'s working set. Cannot be paged out. | Only by killing the process that asked for it (mostly the kernel itself, so: no). |
| **App / Active** | Pages currently in use by user processes. | Page out via the compressor or to swap when needed. |
| **Inactive** | Recently used but not currently. First in line to be compressed / swapped. | Yes — automatically when pressure rises. |
| **Compressed** | App memory that was compressed in-place (not written to disk) by the WKdm compressor. ~50% ratio typical. | Decompresses on next access. Counts as "in use" but cheaply. |
| **Cached Files** | Disk pages cached in RAM. Activity Monitor shows this as "Cached Files" / `vm_stat` as `file-backed`. | Yes — `sudo purge` flushes this. Recreated lazily on next read. |

Your Activity Monitor screenshot showed **6.78 GB Compressed** — that's
~13 GB of pre-compression app memory living in 6.78 GB of physical RAM.
This is the system working as intended. The compressor was added in
Mavericks (10.9, 2013) and **replaces** old-style swap-everything as the
first line of defense.

### When does macOS actually swap to disk?

Only after the compressor can't keep up — i.e., when so much memory is
"hot" that even compressed pages have to be evicted. At that point macOS
writes to one of `/System/Volumes/VM/swapfile{0..N}` (Apple Silicon /
Big Sur+) or `/private/var/vm/swapfile{0..N}` (older / pre-APFS).

Swapfile growth pattern:

1. First swapfile is created at **64 MB**.
2. Each subsequent file doubles: 128 MB → 256 MB → 512 MB → **capped at 1 GB**.
3. New files are added on demand; the only cap is **free disk**.
4. **Swapfiles are never deleted while macOS is running.** Even if you
   close every memory hog and pressure drops to zero, the files stay on
   disk taking up space. They get re-used the next time pressure rises.
5. Reboot deletes all swapfiles; one fresh empty 64 MB swapfile is
   created on first need.

This is the root of the "System Data ballooned overnight" complaint. Your
17.59 GB swap from the screenshot = 17 × 1 GB swapfile + 1 partial.

### `sleepimage`: the other 16 GB you didn't know about

`/private/var/vm/sleepimage` exists to enable **safe sleep** (also called
"hibernation" on Apple Silicon's `hibernatemode 25`, "deep sleep" on
older Intel). When the system enters extended sleep — or when the
battery threatens to die mid-sleep — the kernel writes a **full snapshot
of physical RAM to disk** so it can be restored from a hard power-off.

Size: **equal to physical RAM**. On your 16 GB Mac mini that's 16 GB
sitting in `/private/var/vm/sleepimage`, even if you never let it
hibernate.

| Mac type | Default `hibernatemode` | sleepimage on disk? | Safe to delete? |
|---|---|---|---|
| Apple Silicon laptop (M1/M2/M3 MBP/MBA) | `25` (hibernate) | yes (~RAM size) | **No** — battery-dead = lost session |
| Apple Silicon desktop (Mac mini/Studio/Pro) | `0` (no hibernate) | no | n/a |
| Intel laptop (2019-2020 MBP) | `3` (safe-sleep) | yes (~RAM size) | **No** — same risk |
| Intel desktop (iMac/Mac Pro) | `0` | no | n/a |

If your Activity Monitor shows `Swap Used: 17 GB` AND your disk shows
"System Data" at +16 GB more than swap, sleepimage is the suspect.
Verify with `ls -lh /private/var/vm/sleepimage`. **For laptops, leave it
alone.** For desktops on AC power, see the
[Reclaim recipes](#reclaim-recipes) sleepimage section.

### "Other Volumes" / Time Machine local snapshots

When Time Machine is configured (even paused), macOS takes a local APFS
snapshot of `/` every hour and keeps it for 24 hours, so you can roll
back recent changes without an external drive. These snapshots count as
"Other Volumes" in the Storage pie because they live on a separate APFS
snapshot list, not in your home directory.

Each snapshot's *apparent* size is huge (looks like a full disk) but
its *unique* size is tiny (only changed blocks). Reclaim them with
`tmutil thinlocalsnapshots` — see [Reclaim recipes](#reclaim-recipes).

### Memory Pressure being green ≠ swap is small

This is the most common misconception. The Memory Pressure graph
measures **how hard the compressor is working right now**. After a
heavy spike (multiple browser tabs, a big build, a VM), pressure
returns to green within seconds — but the swap files written during the
spike **stay on disk forever** until reboot.

This is why your 14.29 GB Used + 6.78 GB Compressed + green/yellow
pressure can coexist with 17.59 GB of swap: the OS got through the
spike, but the disk allocation is permanent until reboot.

## Diagnosis cookbook

The repo's `mac-mem-status` wraps most of these into one screen — but
when you want to dig deeper, here are the underlying commands.

### Memory side

| Command | What it answers |
|---|---|
| `vm_stat` | One-shot snapshot of every page class (free / active / inactive / wired / compressor / file-backed / anonymous). All counts are in pages — multiply by `sysctl -n hw.pagesize` (16384 on Apple Silicon, 4096 on Intel) for bytes. |
| `vm_stat 5` | Cumulative counters every 5 s. The `pageins` / `pageouts` / `swapins` / `swapouts` columns are *cumulative since boot* — compute deltas across two rows for "per second" rates. The repo's `mac-mem-watch` does this for you. |
| `sysctl vm.swapusage` | Current swap total / used / free. Format: `total = 17408.00M  used = 15958.75M  free = 1449.25M  (encrypted)`. The `(encrypted)` is informational — Apple Silicon always encrypts swap. |
| `memory_pressure` | Kernel's own pressure notifier. Runs forever by default; `memory_pressure -Q` is the one-shot variant on recent macOS. |
| `top -l 1 -o mem -n 20` | Top 20 by memory. The `mem` column is **compressed-aware** (matches Activity Monitor's "Memory" column). Available without sudo on all macOS versions. |
| `ps -axm -o pid,rss,vsz,user,comm` | Older RSS-only view. RSS does NOT include compressed or swapped pages, so it can mislead — prefer `top -o mem`. |
| `sudo footprint -all -s --swapped --sort=swapped` | Apple Silicon only. Per-process **swapped + compressed** breakdown, sorted by swapped pages. Best tool for "who actually pushed pages to disk". `-s` skips idle processes. Needs sudo. |
| `sudo footprint -p <pid> --swapped` | Per-PID detailed memory map. Useful for inspecting one specific offender. |

### Swap & disk side

| Command | What it answers |
|---|---|
| `ls -lh /System/Volumes/VM/swapfile* 2>/dev/null` | Swapfile sizes on Apple Silicon / modern Intel. |
| `ls -lh /private/var/vm/swapfile* 2>/dev/null` | Swapfile sizes on older Intel. (Empty stub on Apple Silicon.) |
| `du -ch /System/Volumes/VM/swapfile* 2>/dev/null \| tail -1` | Total swap on disk. |
| `ls -lh /private/var/vm/sleepimage` | sleepimage size — equal to RAM if hibernation is enabled. |
| `pmset -g \| grep hibernatemode` | Current hibernate mode (0 = no sleepimage, 3 = Intel safe-sleep, 25 = Apple Silicon hibernate). |
| `df -Hh /` | Free disk on the system volume. |
| `system_profiler SPStorageDataType` | The pretty CLI version of About > Storage's pie chart. |
| `tmutil listlocalsnapshots /` | Time Machine local snapshots on /. |
| `diskutil apfs listSnapshots /` | Same, with sizes. |

### Live activity

| Command | What it answers |
|---|---|
| `mac-mem-watch [N]` | One-line-per-tick summary: free / compressed / swap_used / pageouts/s / swapouts/s. Best in a tmux side pane. |
| `vm_stat 1` | Raw vm_stat at 1 s ticks. Watch the `swapouts` column — anything sustained > 0 means active disk swap. |
| `sudo fs_usage -w -f filesys \| grep '/var/vm\\|/System/Volumes/VM'` | Real-time syscall trace filtered to swap I/O. Noisy but definitive. |
| `latency -rt 5` *(needs root)* | Kernel latency events including memory pressure stalls. |

## Reclaim recipes

Ordered cheapest → most disruptive. The repo's `mac-mem-reclaim` wraps
steps 1–5; the rest are documented for completeness.

### 1. Close obvious offenders (free, instant)

Run `mac-mem-status` (or `tv mac-procs`). The top of the list is almost
always:

- A browser with 50+ tabs (Chrome / Arc / Firefox)
- An Electron app (Slack / Discord / VSCode-with-many-extensions / Obsidian)
- Xcode + `SourceKitService` (commonly leaks 5-10 GB after long edit sessions)
- `WindowServer` after multi-display + multi-day uptime
- `mds_stores` / `mdworker_shared` mid-reindex (if you just installed a big app or copied a lot of files)

Quitting and re-opening a single Electron app often frees 1-2 GB. Quitting
a browser with many tabs can free 5+ GB instantly.

### 2. `sudo purge` (free, instant, always safe)

```sh
sudo purge
```

Forces the kernel to flush disk caches (the "Cached Files" bucket).
Reclaims 1-3 GB on a typical workstation. Safe to run repeatedly. Does
**not** touch swap files or kill any process — you can run it from a
script with no concern.

`mac-mem-reclaim` runs this as Step 1 by default.

### 3. Restart Spotlight indexers (free, ~1 min CPU spike)

```sh
sudo killall mds_stores
sudo killall mdworker_shared
```

If `mdworker_shared` is in your top-10 RSS, it's probably stuck on a
broken file or a giant directory. launchd respawns both immediately;
they restart their indexing jobs from scratch (CPU spike for ~1 min,
then idle). Often reclaims 500 MB - 2 GB if the worker had bloated.

`mac-mem-reclaim --include spotlight`.

### 4. Thin Time Machine local snapshots (free, ~10 s)

```sh
tmutil thinlocalsnapshots / 5000000000 4
```

Drops local TM snapshots on `/` until at least **5 GB** (the second arg)
is reclaimed, with **urgency 4** (max — most aggressive thinning). Safe:
your *external* TM backups are not affected, only the on-disk local
copies. Reclaims anywhere from 0 (no snapshots) to 30+ GB (heavy use,
no recent reboot).

`mac-mem-reclaim --include snapshots`.

### 5. Disable hibernation + delete sleepimage (~RAM size, **laptop caveat**)

```sh
sudo pmset -a hibernatemode 0       # disable hibernation
sudo rm -f /private/var/vm/sleepimage
```

Reclaims `~physical-RAM` GB. **Desktop Macs (mini/Studio/Pro on AC)**:
no downside — they don't use sleepimage. **Laptops**: you lose
**safe-sleep**, meaning if your battery dies while suspended, you lose
your session and any unsaved work.

`mac-mem-reclaim --include sleepimage` (gated behind a confirmation
prompt; gated behind `--force` if `--yes` is also passed).

To re-enable on a laptop: `sudo pmset -a hibernatemode 3` (Intel) or
`sudo pmset -a hibernatemode 25` (Apple Silicon).

### 6. Restart `WindowServer` (~500 MB - 3 GB, **logs you out**)

```sh
sudo killall -HUP WindowServer
```

`WindowServer` is the macOS compositor. It leaks slowly under multi-display
+ many-window workloads. Restart logs out the current GUI session — **save
all unsaved work first**.

`mac-mem-reclaim --include windowserver` (double-confirmation prompt;
gated behind `--force` if `--yes` is also passed).

### 7. Reboot (the big hammer)

Reclaims:

- All `/System/Volumes/VM/swapfile*` (everything from the swap section)
- `/private/var/vm/sleepimage` (recreated on next sleep)
- All Time Machine local snapshots whose retention window has passed
- All in-memory caches that survived `purge`
- Any user-process or kernel-extension memory leak

If you've done steps 1-6 and `Storage > System Data` is still bloated,
this is the answer. See the next section for why this is not a
workaround failure.

### Things to AVOID

| Don't | Why |
|---|---|
| `sudo nvram boot-args="vm_compressor=2"` | Sometimes recommended in old forum posts to "disable the compressor". On Apple Silicon this **breaks the entire VM subsystem** — the OS assumes the compressor exists. Will hard-hang on boot. |
| `sudo dynamic_pager -L 0` toggling | Old (10.6-era) trick to force swapfile cleanup. Either does nothing or hard-hangs the kernel on modern macOS — the swap subsystem no longer routes through `dynamic_pager` for cleanup decisions. |
| Deleting swapfiles directly with `sudo rm /System/Volumes/VM/swapfile*` while macOS is running | The kernel has them open via `mmap`; deleting unlinks the directory entry but the kernel keeps writing to the now-orphan inode until reboot. You free zero disk space and may corrupt running processes that get paged out. |
| Disabling swap | macOS has no supported "no swap" mode on Apple Silicon. Don't try. |
| Third-party "memory cleaner" apps from the App Store | Most just call `sudo purge` (which you can do for free) and pad the result with cosmetic graphs. Some aggressively kill processes, causing data loss. |

## FAQ: "How do I just clean swap?"

Short answer: **you can't, except by rebooting.** This is the most common
mistaken expectation when first encountering macOS swap accumulation, so
let's lay out the complete option matrix:

| Method | Risk | Reclaims swapfiles? | Verdict |
|---|---|---|---|
| **Reboot** | None (other than interrupting work) | ✓ 100% — kernel deletes them all | **Only clean option.** |
| Close memory hogs (browsers / Electron / VMs) and wait | None | ✗ — frees RAM + compressor, but on-disk swapfiles stay allocated | Reduces *future* swap growth, doesn't shrink current usage |
| `sudo killall -HUP WindowServer` | Medium — logs you out, unsaved GUI work lost | ✗ (frees ~1-3 GB of RAM only) | If you're going to log out anyway, just reboot |
| `mac-mem-reclaim` (this repo) | Low — wraps `sudo purge` + opt-in extras | ✗ — touches caches, snapshots, sleepimage; never swapfiles | Reclaims *adjacent* storage; can buy time but doesn't shrink swap |
| `sudo dynamic_pager -L 0` toggling | **High — kernel hang on modern macOS** | ✗ | **Don't.** Old 10.6-era trick that no longer works. |
| `sudo rm /System/Volumes/VM/swapfile*` while running | **High — process corruption** | ✗ — kernel still has them open via `mmap`; `unlink` doesn't free disk | **Don't.** Reclaims zero space, can corrupt swapped processes. |
| Disable swap entirely (no supported flag) | **Catastrophic on Apple Silicon** | n/a | Apple Silicon's VM subsystem assumes swap exists. Don't. |
| App Store "memory cleaner" apps | Variable — most are wrappers around `sudo purge` | ✗ | Snake oil. None can shrink swapfiles — Apple has no API. |

**Why this is the case**: macOS treats swap as ephemeral state cleared at
boot. There's no public kernel API to ask `dynamic_pager(8)` to delete a
specific swapfile, no `swapoff` equivalent, no sysctl to trigger
contraction. Compare with Linux (`swapoff -a` migrates pages back to RAM
then unlinks swap) or Windows (registry + reboot to resize pagefile) —
both have user-controllable swap reclaim; macOS deliberately doesn't.

**Practical takeaway**: prevention > cure. If your workload regularly
accumulates 10+ GB of swap per week:

1. **Schedule a weekly reboot** (e.g. Monday morning before starting work).
2. **Keep an eye on `mms`** — if it hits `CRITICAL — REBOOT RECOMMENDED`,
   that's the OS telling you the buffer to act has shrunk to "next big
   memory spike crashes something".
3. **Identify chronic offenders** with `tv mac-procs` over a few sessions.
   If Arc / Discord / a specific Electron app is always near the top,
   consider native alternatives or running fewer of them concurrently.

The repo's `mac-mem-reclaim` will refuse to run when `disk_free < 3%` —
not because reclaim is *dangerous* there, but because it would be *useless*
(`purge` typically frees < 100 MB at that level, while the actual problem
is GB of swap that only `reboot` can address). Override with `--force`
if you really want to try, but reboot is faster.

## FAQ: "Then how do always-on Linux servers cope?"

Short answer: **completely differently — they don't have macOS's problem
in the first place.** Four reasons Linux servers can run for a year+
without swap-driven degradation:

### 1. Linux swap *can* shrink at runtime

```sh
sudo swapoff -a && sudo swapon -a
```

This idiom is legitimate on Linux. `swapoff` migrates every swapped page
back into RAM (preconditions: enough free RAM to hold them) then unmaps
the swap device, then `swapon` re-attaches it empty. No data loss, no
process corruption, no reboot. macOS has *no equivalent* — there is no
public API to drain a swapfile back into RAM.

### 2. Linux swap is fixed-size

Typical install: a swap *partition* or *file* sized at install time
(usually 0.5-2× RAM, capped around 8-16 GB). It does **not** dynamically
grow into free disk like macOS swapfiles do. Once full, the OOM killer
fires; the swap allocation itself never balloons.

macOS's "every spare GB on the system volume can become swap" model is
specifically what causes the "System Data ate my disk" symptom that this
page exists to address.

### 3. Linux exposes `vm.swappiness`

```sh
sysctl vm.swappiness=10   # default 60; lower = prefer evicting cache over anon pages
```

Server tuning typically lands at 10-30, which keeps anonymous (app)
memory in RAM longer and lets file cache get reclaimed first. macOS
does not expose this knob — its compressor + dynamic_pager pipeline is
not user-tunable.

### 4. Linux's actual long-uptime problems are *individually addressable*

| Problem | Fix |
|---|---|
| Memory leak in a specific service | `systemctl restart <service>` (one service, not whole machine) |
| `journald` disk usage | `journalctl --vacuum-size=500M` or `--vacuum-time=30d` |
| `/tmp` / `/var/tmp` accumulation | `systemd-tmpfiles --clean` (auto-runs daily on most distros) |
| Docker images / volumes / build cache | `docker system prune -a --volumes` |
| Slab cache bloat (rare) | `echo 2 \| sudo tee /proc/sys/vm/drop_caches` |
| Kernel security update | The *only* thing genuinely requiring reboot — and even that is avoidable with `kpatch` / `livepatch` on RHEL/SLES/Ubuntu Pro |

Year-plus Linux server uptimes are common because **each resource has a
targeted reclaim tool**. macOS retired all of these for UX simplicity;
the cost is "weekly reboot" being the canonical answer.

### Practical implication for this repo's fleet

[`scripts/fleet_apply.py`](https://github.com/daviddwlee84/dotfiles/blob/main/scripts/fleet_apply.py)
runs against both macOS and Linux hosts. Different reboot cadences apply:

| Host type | Monitoring | Action when bloated |
|---|---|---|
| macOS (Mac mini / laptop) | `mms` shows `CRITICAL` | **Reboot** (no alternative) |
| Linux server (IDC / NAS / VPS) | `free -h`, `vmstat 1`, `journalctl --disk-usage`, `df -h` | **Targeted reclaim** (`swapoff -a && swapon -a` for swap; `systemctl restart` for leaky service; `journalctl --vacuum-*` for logs; `docker system prune` for containers). Reboot only for kernel updates. |
| Linux desktop (rare in this fleet) | Same as server | Same as server |

A future companion `linux-mem-status` / `linux-mem-reclaim` helper
would mirror the `mac-mem-*` ergonomics on the Linux side, exposing
the targeted reclaim tools through the same diagnose / dry-run / opt-in
shape. Tracked in [TODO.md](https://github.com/daviddwlee84/dotfiles/blob/main/TODO.md)
under P3.

It's tempting to read "reboot fixes it" as a Windows-9x-era admission of
defeat. It isn't. It's a deliberate macOS design trade-off:

1. **Apple chose simplicity over reclamation complexity.** Linux can
   shrink swap with `swapoff` (which migrates pages back to RAM, fails
   if RAM is too small). Windows can shrink the pagefile with a
   reg-key + reboot. macOS picked: "we'll never bother — reboot is
   cheap, our laptops sleep more than they restart anyway".
2. **The compressor reduces the *need* for swap so dramatically** (often
   3-5× less swap traffic than pre-compressor macOS) that the
   occasional "swap files accumulate, reboot to reclaim" is rarely
   user-visible — except when storage is tight, like your screenshot.
3. **There is no public API to ask the kernel to delete swapfile-N.**
   Not `sysctl`, not `vm_pressure_monitor`, not Endpoint Security.
   Apple's `dynamic_pager` daemon decides when to *create* swapfiles
   but never decides to *delete* them mid-run.

**Practical implication**: if your daily / weekly workflow regularly
exhausts disk because of swap accumulation, the answer is **schedule
a reboot**, not engineer around the OS. Activity Monitor's Memory tab
is the indicator; your `mac-mem-status` Verdict line is the trigger.

Common reboot cadences in this repo's recommended workflow:

- **Daily-driver laptop on battery**: weekly reboot is enough — sleep
  cycles tend to keep swap modest (the OS uses memory more
  conservatively when it knows it might hibernate soon).
- **Always-on workstation / Mac mini server**: reboot every 2-4 weeks,
  or whenever `mac-mem-status` shows red.
- **Heavy-VM / heavy-Docker dev box**: every 1-2 weeks. VMs +
  containers churn the swapfile aggressively; even with the compressor
  doing 50% ratio you'll accumulate 10-20 GB of swapfiles per week.

## Prevention & monitoring

### Menubar / GUI tools (comparison)

| Tool | License | Menubar swap meter? | Free | Notes |
|---|---|---|---|---|
| [**Stats.app**](https://github.com/exelban/stats) | MIT | yes | ✓ | exelban/stats. Native Swift, actively maintained, Apple-Silicon-native. **Recommended.** Install: `brew install --cask stats`. Not in this repo's `Brewfile.darwin.tmpl` by default — see [TODO.md](https://github.com/daviddwlee84/dotfiles/blob/main/TODO.md) for the cask candidate evaluation entry. |
| [iStat Menus](https://bjango.com/mac/istatmenus/) | proprietary | yes | $ | Best polish; paid one-time. |
| [MenuMeters](https://github.com/yujitach/MenuMeters) | LGPL | yes | ✓ | yujitach fork; older but solid. |
| Activity Monitor (built-in) | — | no menubar | ✓ | Memory tab shows pressure graph + Swap Used. |
| **Stats.app vs others, why we recommend it**: MIT-licensed (no proprietary lock-in), zero-config Apple-Silicon support, swap + pressure both visible in 1-line menubar widget, ~30 MB RAM footprint. Stats.app's only weak spot is no kernel/wired breakdown — you'd still use `mac-mem-status` for that. | | | | |

### CLI / TUI monitors

| Tool | Already in this repo? | Shows swap? | Notes |
|---|---|---|---|
| [`btm`](https://github.com/ClementTsang/bottom) | yes — `devtools` ansible role | yes | Best general-purpose TUI. Press `?` for keymap. |
| `htop` | yes — `devtools` | no swap column on macOS by default | Press `F2` to enable swap column if available. |
| `btop` | yes — `devtools` | yes | Heavier UI than `btm`; same data. |
| Activity Monitor | built-in | yes (Memory tab) | The truth source; everything else is reformatting it. |

### Non-recommendations

- **Don't disable swap.** Even on a 64 GB Mac Pro, the compressor is
  more efficient with a swap backing — see Apple's `xnu` source
  comments on `compressor_pool_size`.
- **Don't disable `sleepimage` on a laptop you ever carry.**
  Battery-dead while suspended = lost session, no warning.
- **Don't run `purge` from a launchd timer every minute.** It's safe
  but it churns the disk cache; you'll lose the performance benefit
  of the cache existing.
- **Don't kill `WindowServer` from a script you don't watch.**
  Unsaved GUI work dies.

## Pitfalls & gotchas

See [`pitfalls/macos-swap-files-never-shrink.md`][pitfall] for the full
case study (symptoms, diagnosis, root cause, what NOT to try). The
short version: swapfiles only get deleted on reboot. There is no
supported workaround. The `mac-mem-reclaim` helper deliberately does
not include any "delete swapfiles while running" step because all
known approaches either silently fail or risk corruption.

Other gotchas worth knowing:

- **`top -o mem` shows the compressed-aware footprint** in the `mem`
  column on Apple Silicon, but the column header still says "MEM"
  with no indication of what's included. Apple's docs are silent on
  this; verified empirically against `footprint -summary <pid>`.
- **`ps -o rss` is misleading on Apple Silicon.** RSS is "resident set
  size" in the classic Unix sense — pages currently in physical RAM.
  It does NOT include compressed or swapped pages. A process with
  100 MB RSS may have 2 GB of compressed + swapped data behind it.
  Use `top -o mem` or `footprint -summary` for the truth.
- **`vm.swapusage` `total` grows but never shrinks at runtime.** The
  `total` field is the high-water-mark of allocated swap, not "currently
  configured". `used` is the live number; `free = total - used` only
  tells you headroom in already-allocated swapfiles.
- **`memory_pressure` without `-Q` runs forever.** The man page on
  recent macOS adds `-Q` for one-shot; older versions don't. The
  `mac-mem-status` helper falls back to `head -3` of the streaming
  output if `-Q` is unsupported.
- **`tmutil thinlocalsnapshots` is a no-op without TM configured.**
  It exits 0 silently. Not an error — just nothing to thin.
- **Apple Silicon swap is always encrypted.** This adds a small CPU
  cost on swap I/O but is non-disableable. Don't worry about the
  `(encrypted)` tag in `vm.swapusage` output.

## References

### In this repo

- [`dot_config/shell/55_macos_mem.sh.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/shell/55_macos_mem.sh.tmpl) — the three helpers (`mac-mem-status` / `mac-mem-reclaim` / `mac-mem-watch`)
- [`dot_config/television/cable/mac-procs.toml.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/television/cable/mac-procs.toml.tmpl) — `tv mac-procs` channel
- [`pitfalls/macos-swap-files-never-shrink.md`][pitfall] — the case study
- [`docs/shells/aliases.md`](../shells/aliases.md) — one-line summary table includes the three helpers
- [`docs/tools/tv.md`](tv.md) — channel reference includes `mac-procs`

### Apple / official

- `man vm_stat` — page-class definitions
- `man memory_pressure` — pressure subsystem semantics
- `man footprint` — Apple Silicon per-process memory accounting (the only first-party tool that exposes swapped + compressed bytes per process)
- `man pmset` — `hibernatemode` values + tradeoffs
- `man tmutil` — local-snapshot subcommands
- `man purge` — disk-cache flush
- [Apple Developer: Memory Usage Performance Guidelines](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/ManagingMemory/Articles/AboutMemory.html) — older but still accurate on the wired/active/inactive model

### Community write-ups (background reading)

- [Eclectic Light: Memory and swap](https://eclecticlight.co/?s=memory+swap) — howard oakley's series, best non-Apple writeup
- [xnu source: `osfmk/vm/vm_compressor.c`](https://github.com/apple-oss-distributions/xnu) — the WKdm compressor implementation
- The `top` source in xnu's `system_cmds` package documents which sysctl each column reads

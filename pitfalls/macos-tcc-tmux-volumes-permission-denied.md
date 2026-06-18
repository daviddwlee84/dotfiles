# macOS `/Volumes` access fails in tmux with `Permission denied: . - code: 13`

**Symptoms** (grep this section): `Permission denied: . - code: 13`,
`Skipped 1 directories due to permission denied: .`, `ls /Volumes/Data`
fails in Alacritty but works in Cursor, `tmux attach` inside Cursor still
cannot list an external APFS volume, old tmux sessions cannot access
`/Volumes/Data`, Cursor can access the directory but the attached tmux pane
cannot.
**First seen**: 2026-06-19 on macOS with `/Volumes/Data` as an external APFS volume
**Affects**: macOS TCC-protected locations, especially external/removable
volumes, when tmux server was started by an app without the right privacy grant
**Status**: workaround — grant Full Disk Access to the app that starts the
tmux server, kill the old server, restart tmux from that authorized app

## Symptom

In an Alacritty shell:

```text
Program/Tadronaut/libkdc-simple-demo
❯ ls
Permission denied: . - code: 13

Skipped 1 directories due to permission denied:
  .
```

The same path is readable from Cursor or from another authorized host process:

```bash
ls -la /Volumes/Data/Program/Tadronaut
# works; owner/perms are normal, e.g. drwxr-xr-x
```

After switching to Cursor and running `tmux attach`, the problem can persist
inside already-existing tmux sessions. The attached client is authorized, but
the tmux server is not.

## Root Cause

This is not Unix file permission. The observed directories were owned by the
user and mode `755`. The error is macOS TCC (Transparency, Consent, and
Control) denying access above the Unix permission layer.

External volumes are TCC-sensitive. `diskutil info /Volumes/Data` showed:

```text
Mount Point:              /Volumes/Data
File System Personality:  APFS
Device Location:          External
```

TCC grants are tied to the responsible app/process lineage, not to the shell
binary by itself:

- Cursor terminal inherits Cursor.app's privacy grant.
- Alacritty inherits Alacritty.app's privacy grant.
- tmux panes inherit the tmux server's process identity, not the client that
  later attaches.

tmux makes this especially confusing because `tmux attach` is only an I/O
client. The shell and commands inside panes are forked by the long-running
tmux server. If the server was originally started from an unauthorized app or
automation context, attaching from authorized Cursor does not upgrade it.

Observed server shape:

```text
PID    PPID  STARTED                  COMMAND
20208  1     Wed Jun 3 16:53:30 2026  tmux new-session -d ...
```

`PPID 1` means the server is now orphaned under launchd, but its TCC identity
was fixed when it was first created.

## Fix

1. Grant Full Disk Access to the terminal/app that will start tmux:
   System Settings → Privacy & Security → Full Disk Access → add
   `/Applications/Alacritty.app` or the chosen app.
2. Fully quit that app (`Cmd+Q`) so macOS reloads the TCC grant.
3. Kill the old tmux server. If you want an intentional empty restart, use
   the repo wrapper:

   ```bash
   tmux-kill-clean
   ```

   If you want tmux-resurrect to restore the previous layout, use raw
   `tmux kill-server` and accept the restore behavior.
4. Start the first new tmux server from the authorized app.

After that, attaching from Cursor or Alacritty is fine because the server's
children inherit the authorized server identity.

## Diagnostics

```bash
ls -lde /Volumes/Data /Volumes/Data/Program /Volumes/Data/Program/Tadronaut
diskutil info /Volumes/Data | grep -Ei 'Mount Point|File System|Read-Only|Removable|External'
tmux display-message -p '#{pid}'
ps -o pid,ppid,lstart,command -p "$(tmux display-message -p '#{pid}')"
```

Interpretation:

- Normal Unix modes plus TCC-style denial means privacy grant, not chmod.
- `Device Location: External` makes TCC involvement likely.
- A tmux server started days earlier, especially detached and parented to
  launchd, may carry an old unauthorized identity.

## Things That Look Like Fixes But Aren't

- `chmod -R` or `chown -R` on the project directory. The permissions were
  already correct; this does not change TCC.
- Attaching from Cursor after Cursor has access. The tmux client does not
  control the server's TCC identity.
- Granting Full Disk Access but leaving the old tmux server running. Existing
  processes do not gain the new grant retroactively.
- Killing only a session inside the old tmux server. Other sessions keep the
  same unauthorized server alive.

## Related

- [`tmux-continuum-restores-on-intentional-quit.md`](tmux-continuum-restores-on-intentional-quit.md)
- [`tmux-resurrect-agents.md`](tmux-resurrect-agents.md)

# Wake-on-LAN codification

Design notes for the WoL feature (shipped 2026-07). Index entry: [`../TODO.md`](../TODO.md).

## What shipped

- **Passive (receiver)** — `wake_on_lan` ansible role (Linux-only, chezmoi prompt
  `installWakeOnLan`): installs ethtool, deploys a `wol@.service` systemd template,
  auto-detects wired magic-packet-capable NICs, and enables `wol@<iface>` so the
  arming survives reboots.
- **Active (sender)** — `wake` CLI (`dot_dotfiles/bin/executable_wake`, pure stdlib)
  + `wakeonlan` package (`networking_tools`). Host→MAC map in the private
  `~/.config/wake/hosts.toml` (repo ships only a commented `create_private_` template).
- **Docs** — `docs/sysadmin/wake-on-lan.md` (+ `.zh-TW`).
  **Knowledge** — `pitfalls/wol-wakes-from-suspend-but-not-full-shutdown.md`.

## Decisions

- **MAC storage decoupled from fleet.** fleet's `machines.toml` has sync invariants
  (CLAUDE.md) and is SSH-connection-oriented, not MAC-oriented. A dedicated
  `~/.config/wake/hosts.toml` avoids coupling and keeps real MACs out of the public
  repo (`create_private_` seed with commented examples only).
- **`wake` is pure stdlib (argparse + socket + tomllib), not tyro.** No startup cost,
  works on a fresh box before any pip/uv, mirrors `crash-blackbox`'s plain-`python3`
  style → Strategy B hand-written completions.
- **BIOS stays manual.** ErP / Power-On-By-PCIe can't be set from Ansible; it's a
  documented checklist instead (and the subject of the pitfall above).

## Open follow-ups (not done)

- **`wake --wait`**: send, then poll ping/ssh until the host answers (or times out),
  so `wake box && ssh box` just works. Small; deferred to keep the first cut simple.
- **fleet integration**: `fleet wake <host>`, or let `wake` read fleet host names and
  cross-reference a MAC field. Needs a MAC column in fleet's schema (touches the sync
  invariants) — evaluate the churn before doing it.
- **`wake --learn <ssh-host>`**: SSH in, read `ip link` for the default-route wired
  iface, append the entry automatically. Nice ergonomics; needs care picking the iface.
- **WoWLAN (Wi-Fi wake)**: a different mechanism (needs AP + driver support); out of
  scope for now.

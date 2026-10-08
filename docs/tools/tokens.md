# tokens (tokens.ci)

[tokens](https://github.com/missuo/tokens) (MIT, a fork of
[tokscale](https://github.com/junhoyeo/tokscale)) reads the local session logs of
coding agents — Claude Code, Codex, Cursor, Gemini, OpenCode, Antigravity, Trae, Warp, … —
and reports token usage and cost. If you opt in, it also submits that usage to the
[tokens.ci](https://tokens.ci) leaderboard.

## How this repo installs it

The `# === tokens (tokens.ci) ===` block of
[`dot_ansible/roles/coding_agents/tasks/main.yml`](../../dot_ansible/roles/coding_agents/tasks/main.yml)
installs **the binary only**. It runs when `installCodingAgents` is enabled.

| Platform | Mechanism | Result |
|---|---|---|
| macOS | `brew install owo-network/brew/tokens` (the tap is trusted first because of the Homebrew 6 trust gate) | `tokens` in the brew prefix |
| Linux x86_64 / aarch64 | Latest GitHub release `tokens-<tag>-<arch>-unknown-linux-gnu.tar.gz` | `~/.local/bin/tokens` |

The `-gnu` build needs only `GLIBC_2.28` (the same floor as Linuxbrew), so it runs on every
supported distro. Upstream publishes no `.sha256` files for the tarballs, so the download
has no checksum to verify.

Upgrades: `just upgrade-brew` (macOS) or `just upgrade-agents` (Linux). On Linux this runs
the official installer with `TOKENS_NO_SERVICE=1 TOKENS_INSTALL_DIR=~/.local/bin`.

### Why the Linux one-liner fails

```console
$ curl -fsSL https://tokens.ci/install.sh | sh
sh: 17: set: Illegal option -o pipefail
```

`install.sh` is a bash script, but the docs pipe it to `sh`, which is dash on
Debian/Ubuntu. Pipe it to `bash` instead:

```bash
curl -fsSL https://tokens.ci/install.sh | TOKENS_NO_SERVICE=1 bash
```

Without `TOKENS_NO_SERVICE=1`, the installer also writes
`~/.config/systemd/user/tokens.service`. It does not enable the service.

## Manual opt-in: login and background submission

The role does **not** log in or start the background submitter. `tokens serve` uploads your
usage to a public leaderboard, so it should never start by itself on every fleet host.

```bash
tokens login          # one-time browser auth (or: tokens login --token …)
tokens status         # auth, device and background-service state
tokens submit         # submit once
```

To submit on a schedule (every 30 minutes by default; override with `TOKENS_SUBMIT_INTERVAL`):

- **macOS**: `brew services start tokens` (log: `$(brew --prefix)/var/log/tokens.log`)
- **Linux**: create `~/.config/systemd/user/tokens.service` with
  `ExecStart=%h/.local/bin/tokens serve` (or run the installer without
  `TOKENS_NO_SERVICE`), then `systemctl --user enable --now tokens`. To keep it running
  without an active login, also run `sudo loginctl enable-linger "$USER"`.

To delete everything you have uploaded: `tokens delete-submitted-data`.

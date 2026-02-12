# td + sidecar

`td` is a task-management CLI for AI-assisted workflows. `sidecar` is a TUI dashboard for working with those workflows.

## MANDATORY: Use td for Task Management

At conversation start (or after `/clear`), run:

```bash
td usage --new-session
```

For subsequent reads in the same session:

```bash
td usage -q
```

## Installation in This Dotfiles Repo

Both tools are installed automatically by the `coding_agents` ansible role.

- macOS: Homebrew preferred (`marcus/tap`)
- Linux: Homebrew (Linuxbrew) preferred; fallback to GitHub release binaries in `~/.local/bin`

## Manual Installation

### macOS (preferred)

```bash
brew install marcus/tap/td
brew install marcus/tap/sidecar
```

### GitHub Releases

- `td`: <https://github.com/marcus/td/releases>
- `sidecar`: <https://github.com/marcus/sidecar/releases>

## Verify Installation

```bash
td version
sidecar --version
```

## References

- [td docs](https://marcus.github.io/td/)
- [sidecar docs](https://sidecar.haplab.com/)

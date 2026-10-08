# tokens.ci one-liner dies with `set: Illegal option -o pipefail` on Linux

**Symptoms** (grep this section):
- `sh: 17: set: Illegal option -o pipefail`
- Running the documented `curl -fsSL https://tokens.ci/install.sh | sh` on Ubuntu/Debian/WSL

**First seen**: 2026-09 (Ubuntu, tokens v27.1.1)
**Affects**: any Linux host where `/bin/sh` is dash
**Status**: worked around in repo (the `coding_agents` role downloads the release tarball;
`scripts/upgrade_tools.sh` pipes the installer to `bash`)

## Root cause

`install.sh` starts with `#!/usr/bin/env bash` and `set -euo pipefail`. A shebang is
ignored when a script is piped into an interpreter, so `| sh` runs it under dash, which has
no `pipefail` option. Upstream's comments even acknowledge the `| sh` instructions, but only
work around the `$'…'` colour codes, not `pipefail`.

## Fix

```bash
curl -fsSL https://tokens.ci/install.sh | TOKENS_NO_SERVICE=1 bash
```

`TOKENS_NO_SERVICE=1` stops it from writing `~/.config/systemd/user/tokens.service`.
See [docs/tools/tokens.md](../docs/tools/tokens.md).

# `mise install node@*` 404 on TUNA — TUNA's nodejs-release mirror keeps only ~5 versions

## Symptom

After `useChineseMirror=true`, this repo exports
`MISE_NODE_MIRROR_URL=https://mirrors.tuna.tsinghua.edu.cn/nodejs-release/`
(see `dot_config/shell/00_exports.sh.tmpl`). Every `mise install node`
attempt 404s no matter what version is requested:

```
$ mise use -g node@22
mise ERROR Failed to install core:node@22:
  HTTP status client error (404 Not Found) for url
  (https://mirrors.tuna.tsinghua.edu.cn/nodejs-release/v22.22.2/node-v22.22.2.tar.gz)

$ mise use -g node           # latest
mise ERROR Failed to install core:node@latest:
  HTTP 404 for v26.1.0/node-v26.1.0.tar.gz

$ mise use -g node@24        # `lts`-style alias
mise ERROR Failed to install core:node@24:
  HTTP 404 for v24.15.0/node-v24.15.0.tar.gz
```

Visiting <https://mirrors.tuna.tsinghua.edu.cn/nodejs-release/?C=M&O=D>
in a browser reveals the issue: TUNA's directory listing only shows
~5 specific versions (e.g. v24.1.0, v22.16.0, v24.0.2, v23.11.1) —
NOT the canonical "all releases" archive.

## Root cause

**TUNA's `nodejs-release` mirror does not mirror upstream
`https://nodejs.org/dist/`. It mirrors a subset.** The directory listing
suggests they keep only a few hand-picked versions per major (probably
chosen for some internal reason — current LTS-ish versions, snapshots
of mirror runs, etc.), and aggressively garbage-collect old versions to
save disk space.

This is **not** a typical mirror lag (which would mean "missing the
last few days of releases"). This is a **completeness gap** — the
mirror is functionally not a substitute for `nodejs.org/dist/`.

mise's `node` plugin queries upstream nodejs.org/dist for the version
list (gets the full 1000+ versions) but downloads tarballs from
`MISE_NODE_MIRROR_URL`. So mise resolves `node@22` → `v22.22.2` from
the canonical list, then 404s when trying to fetch from TUNA which
doesn't have that specific patch version.

A second, separate failure: even when picking a version TUNA DOES
have (e.g. `node@24.1.0`), mise fails with:

```
gpg: new configuration file `/home/yczhang/.gnupg/gpg.conf' created
gpg: WARNING: options in `/home/yczhang/.gnupg/gpg.conf' are not yet active during this run
gpg: key 0DDBF2B7: no valid user IDs
gpg: key B168D356: no valid user IDs
mise ERROR gpg failed
mise ERROR Failed to install core:node@24.1.0: gpg exited with non-zero status: exit code 2
```

mise's node plugin verifies the tarball with GPG against Node.js
release-signing keys. On a fresh `~/.gnupg/` (no prior usage), `gpg`
imports the keys but rejects them because they were imported from
TUNA's `SHASUMS256.txt.sig` flow without ultimate trust set up. mise
treats `gpg` exit 2 as fatal.

## Fix

Pick whichever fits — they're independent:

### A. Switch to a more complete mirror

Aliyun's nodejs mirror is more complete than TUNA's. Override per-shell:

```bash
export MISE_NODE_MIRROR_URL=https://mirrors.aliyun.com/nodejs-release/
mise install node@22   # picks from upstream resolver, downloads from Aliyun
```

To make persistent, add to `~/.zshrc.adhoc` / `~/.bashrc.adhoc`:

```bash
# Override repo's TUNA default — TUNA's nodejs-release mirror only keeps ~5
# versions; Aliyun mirrors all of nodejs.org/dist
export MISE_NODE_MIRROR_URL=https://mirrors.aliyun.com/nodejs-release/
```

### B. Skip GPG verification

For the gpg-key-trust failure on the rare versions TUNA does have:

```bash
export MISE_NODE_VERIFY=0   # mise sources/install.go honours this
mise install node@24.1.0
```

The `MISE_NODE_VERIFY=0` flag is documented in
<https://mise.jdx.dev/configuration.html#mise_node_verify>.

### C. Bypass mirror entirely

If your network can reach nodejs.org directly (most corporate proxies do
even when GitHub is iffy):

```bash
unset MISE_NODE_MIRROR_URL
mise install node@22
```

## Why this repo isn't auto-fixed yet

Adding a mirror-fallback list to `dot_config/shell/00_exports.sh.tmpl`
would require runtime probing (HEAD a known version against each
candidate mirror until one returns 200) — that's startup-time-expensive
for every shell launch. The pragmatic answer is "let the user override
in `~/.bashrc.adhoc` when they hit this" — i.e. this pitfall is a
documentation fix, not a code fix.

A future repo improvement could add a `MISE_NODE_MIRROR_URL_FALLBACKS`
chain or auto-probe at first-use time, but it'd need to live in a
mise-aware shim, not raw env exports.

## Related

- [`dot_config/shell/00_exports.sh.tmpl`](../dot_config/shell/00_exports.sh.tmpl) — where `MISE_NODE_MIRROR_URL` is set when `useChineseMirror=true`
- [`docs/tools/mirrors.md`](../docs/tools/mirrors.md) — repo-wide mirror strategy
- [`pitfalls/centos7-noroot.md`](centos7-noroot.md) — sister GFW + CentOS 7 mirror friction
- mise upstream issue tracker: <https://github.com/jdx/mise/issues> — search "TUNA" or "nodejs mirror"

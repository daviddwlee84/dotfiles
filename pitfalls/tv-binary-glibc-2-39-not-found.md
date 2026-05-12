# tv binary requires GLIBC_2.39 not found on Ubuntu 22.04

**Symptoms** (grep this section): `tv: /lib/x86_64-linux-gnu/libc.so.6: version GLIBC_2.39 not found (required by tv)`; `television` (`tv`) launched from any shell aborts immediately; `tv --version` also fails with the same message.
**First seen**: 2026-05
**Affects**: `television` ≥ 0.13 on Ubuntu 22.04 (jammy, glibc 2.35) when the GitHub release's **glibc-flavoured** tarball was installed (e.g. `tv-*-x86_64-unknown-linux-gnu.tar.gz` or a `.deb` not built for jammy).
**Status**: fixed by reinstalling from the **musl** tarball (`tv-*-x86_64-unknown-linux-musl.tar.gz`), which is statically linked and has zero glibc dependency.

## Symptom

```text
$ tv
tv: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found (required by tv)
$ tv --version
tv: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found (required by /home/<user>/.local/bin/tv)
```

The host's actual glibc is older:

```text
$ ldd --version | head -1
ldd (Ubuntu GLIBC 2.35-0ubuntu3.8) 2.35
```

The installed `tv` is glibc-dynamic:

```text
$ file ~/.local/bin/tv
ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked,
interpreter /lib64/ld-linux-x86-64.so.2, for GNU/Linux 3.2.0, ..., stripped
```

Other Rust CLI tools on the same box (`nvim`, `delta`, `yazi`) work fine —
they were either statically linked (yazi: `static-pie linked`) or were
released against an older glibc baseline.

## Root cause

The release artifact named `*-x86_64-unknown-linux-gnu.*` is built on a
recent CI image (currently Ubuntu 24.04 → glibc 2.39). When the dynamic
linker on a 22.04 host loads the binary, it walks the `Verneed` table,
finds a required version `GLIBC_2.39` in `libc.so.6`'s version map, and
the host's `libc.so.6` only exposes versions up to `GLIBC_2.34`. Load is
aborted before `main`.

This is **not** a tv bug — it's the standard glibc forward-incompatibility
behaviour. The same release page ships a musl-static tarball precisely so
older hosts can still run the tool.

## Fix

Replace with the musl artifact:

```bash
# Find the musl tarball URL (also a checksum file next to it)
ver=$(curl -s https://api.github.com/repos/alexpasmantier/television/releases/latest \
      | grep '"tag_name"' | head -1 | cut -d'"' -f4)
base="https://github.com/alexpasmantier/television/releases/download/${ver}"
fname="tv-${ver}-x86_64-unknown-linux-musl.tar.gz"

cd /tmp
curl -sL -o "$fname"        "${base}/${fname}"
curl -sL -o "${fname}.sha256" "${base}/${fname}.sha256"
sha256sum -c "${fname}.sha256" || { echo "checksum mismatch"; exit 1; }

mkdir -p tv-extract && tar xzf "$fname" -C tv-extract
cp ~/.local/bin/tv ~/.local/bin/tv.bak-glibc 2>/dev/null || true
cp tv-extract/tv-${ver}-x86_64-unknown-linux-musl/tv ~/.local/bin/tv
chmod +x ~/.local/bin/tv

# Verify
file ~/.local/bin/tv      # expect: static-pie linked
ldd  ~/.local/bin/tv      # expect: not a dynamic executable / statically linked
tv --version              # expect: version line, no GLIBC error
```

Once `tv` runs cleanly, remove the backup and tmp files:

```bash
rm ~/.local/bin/tv.bak-glibc /tmp/tv*.tar.gz /tmp/tv*.sha256
rm -rf /tmp/tv-extract
```

## Why not "just upgrade Ubuntu"?

Considered and rejected for this host (a GPU training box):

- `do-release-upgrade` to 24.04 jumps kernel 5.15 → 6.8 and forces a full
  NVIDIA driver + CUDA + cuDNN rebuild, plus `cuda-ubuntu2204` repo
  re-pointing to `2404`. Hours of downtime, non-trivial rollback risk.
- The actual user need was four CLI tools (`nvim`, `delta`, `yazi`, `tv`),
  three of which already worked. Upgrading the host glibc to fix one
  Rust binary is the wrong cost/value trade.

The general decision tree, plus alternative install strategies (Linuxbrew,
distrobox, GitHub musl binaries), are documented in
[`docs/glibc-and-musl.md`](../docs/glibc-and-musl.md).

## Generalising — same fix pattern for other Rust CLIs

Whenever a Rust CLI from a GitHub release prints `GLIBC_2.X not found`:

1. Re-check the same release page for a `*-musl` / `*-static` artifact.
   Rust ecosystem ships these ~95% of the time.
2. If not present, file an issue / PR upstream — adding a musl target to
   a Rust release pipeline is usually a one-line GitHub Actions matrix
   addition.
3. Fall back to `brew install <tool>` if Linuxbrew is available, or
   `distrobox` for a sealed Ubuntu 24.04 environment.

Verifying the swap was actually static:

```bash
file <new-binary>           # static-pie linked
ldd  <new-binary>           # not a dynamic executable
# Optional: confirm no glibc symbols required at all
objdump -T <new-binary> 2>/dev/null | grep GLIBC_ || echo "OK: no glibc deps"
```

## See also

- [`docs/glibc-and-musl.md`](../docs/glibc-and-musl.md) — full glibc vs
  musl reference, decision tree, and OS-upgrade risk matrix.
- [`docs/linux-package-sources.md`](../docs/linux-package-sources.md) —
  apt vs Linuxbrew vs snap vs GitHub binary trade-offs.

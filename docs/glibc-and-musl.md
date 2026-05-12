# GLIBC vs musl: when "version not found" hits, what to actually do

A practical reference for the specific failure mode:

```text
$ tv
tv: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found (required by tv)
```

…and why **upgrading the host OS is almost never the right answer** for a
single user-space CLI tool.

## The two libc implementations

Every dynamically-linked Linux binary is linked against **a libc** (the C
standard library — `malloc`, `printf`, `open`, threading primitives, DNS
resolution, locale, …). Two implementations dominate:

| | glibc | musl |
|---|---|---|
| Full name | GNU C Library | musl libc |
| Size | Large (tens of MB) | Small (~1 MB) |
| Default on | Ubuntu / Debian / RHEL / Fedora / Arch | Alpine Linux, many Docker base images |
| Linkage convention | Dynamic | Often **statically linked** into the binary |
| Versioned symbols | **Strict** — a binary built against `GLIBC_2.39` cannot run on a host with `GLIBC_2.35` | None — a static-linked musl binary has zero libc dependency at runtime |
| Behaviour quirks | Reference behaviour for most Linux software | Different DNS resolver, locale handling, threading edge cases |

The key asymmetry that causes the `GLIBC_2.X not found` error: **glibc symbol
versions are forward-incompatible**. A binary built on Ubuntu 24.04 (glibc
2.39) records `GLIBC_2.38` / `GLIBC_2.39` symbol references; on a 22.04 host
(glibc 2.35) the dynamic linker checks the version map and refuses to load.

## What "musl binary" actually means in a GitHub release

When a release page lists e.g. `tool-x86_64-unknown-linux-musl.tar.gz`, that
binary was:

1. Compiled with the `x86_64-unknown-linux-musl` target (uses musl headers /
   musl crt instead of glibc).
2. **Statically linked** — musl itself is bundled into the binary.

Result: the binary ignores the host's `libc.so.6` entirely. It runs on any
Linux x86_64 — Ubuntu 14.04, RHEL 7, Alpine, container scratch images,
whatever — because its only kernel-ABI requirement is the syscall interface.

Verification:

```bash
file ./tool
# glibc dynamic: dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2
# musl static:  static-pie linked  (or "statically linked")

ldd ./tool
# glibc:        linux-vdso.so.1 ... libc.so.6 => ...
# musl static:  not a dynamic executable   (or "statically linked")
```

If `file` says `static-pie linked` and `ldd` says `not a dynamic executable`
→ host glibc version is irrelevant.

### Why Rust ships musl builds and C/C++ rarely does

Rust's cross-compile story makes musl trivial: `cargo build --target
x86_64-unknown-linux-musl` produces a portable binary with no extra work.
Most popular Rust CLI tools (`ripgrep`, `fd`, `bat`, `eza`, `delta`, `yazi`,
`zoxide`, `starship`, `television`, `bottom`, `tokei`, `hyperfine`, …) ship
both glibc and musl tarballs in their GitHub releases.

C/C++ projects rarely do, because real musl porting touches behavioural
differences (locale, DNS, `getaddrinfo`, threading, dlopen edge cases) that
glibc papers over. Go is the other big "static by default" ecosystem — Go
binaries are CGO-free static by default and don't even need a musl variant.

## Decision tree when you hit `GLIBC_2.X not found`

```
                        ┌──────────────────────────────────┐
                        │  binary X needs newer GLIBC      │
                        └──────────────────┬───────────────┘
                                           │
                          ┌────────────────┴────────────────┐
                          │ Is this a Rust / Go CLI tool?   │
                          └────────────────┬────────────────┘
                                           │
                       ┌───────── yes ─────┴───── no ─────┐
                       ▼                                  ▼
            ┌────────────────────────┐          ┌─────────────────────┐
            │ Look for *-musl* or    │          │ Is Linuxbrew        │
            │ *-static* in releases. │          │ available (sudo OK  │
            │ ~95% of Rust CLIs ship │          │ or already set up)? │
            │ them; Go is static by  │          └──────────┬──────────┘
            │ default.               │                     │
            └────────────────────────┘            ┌── yes ─┴── no ──┐
                                                  ▼                 ▼
                                       ┌────────────────┐  ┌──────────────────┐
                                       │ brew install X │  │ distrobox / pod- │
                                       │ — brew ships   │  │ man with newer   │
                                       │ its own glibc  │  │ Ubuntu/Fedora    │
                                       │ in /home/      │  │ image; binary    │
                                       │ linuxbrew.     │  │ exposed to host. │
                                       └────────────────┘  └──────────────────┘
```

**Last resort (almost never warranted for a single tool)**: upgrade the host
OS via `do-release-upgrade`. See "When upgrading the OS *is* the right call"
below.

## Three install strategies, ranked

### 1. Drop in a musl / static binary (preferred for single Rust/Go tool)

Zero footprint, zero risk, instant. The repo's existing GitHub-binary
install pattern in [`linux-package-sources.md`](linux-package-sources.md)
already uses this for many tools.

```bash
# Pattern: download → extract → install to ~/.local/bin → verify
url=$(curl -s https://api.github.com/repos/<owner>/<repo>/releases/latest \
      | grep browser_download_url \
      | grep -E 'x86_64.*linux.*musl.*\.tar\.gz' \
      | head -1 | cut -d'"' -f4)
curl -sL "$url" -o /tmp/x.tar.gz
tar xzf /tmp/x.tar.gz -C /tmp/
cp /tmp/<extracted>/<binary> ~/.local/bin/
file ~/.local/bin/<binary>      # expect: static-pie linked
ldd  ~/.local/bin/<binary>      # expect: not a dynamic executable
```

Always verify the SHA256 if the release publishes one.

### 2. Linuxbrew (preferred when sudo + multi-tool churn)

Linuxbrew installs to `/home/linuxbrew/.linuxbrew/`, ships its own newer
glibc inside `Cellar/glibc/`, and uses `RPATH` so brew-built binaries skip
the system `libc.so.6` entirely. Same `Brewfile` as macOS, same formula
names, fresh upstream versions.

```bash
brew install neovim delta yazi television
```

Trade-offs covered in [`linux-package-sources.md`](linux-package-sources.md).
Caveat: needs sudo at install time (`chown` on `/home/linuxbrew`); the
unprivileged `~/homebrew` mode loses bottles → forces source builds → pulls
in `-dev` packages → needs sudo anyway. On a no-sudo host, fall back to
strategy 1 or 3.

### 3. distrobox / podman / docker (when the tool needs a real glibc env)

For complex tools, GUI apps, or stacks (e.g. a build toolchain that *itself*
expects glibc 2.39 in its sysroot), run the entire thing inside an Ubuntu
24.04 / Fedora 40 container while leaving the host untouched.

```bash
# distrobox is the user-friendly wrapper — auto-mounts $HOME, $XDG_RUNTIME_DIR,
# X11/Wayland sockets, GPU devices; exposes the container's binaries via
# distrobox-export ~/.local/bin shims.
sudo apt install distrobox podman   # one-time, needs sudo
distrobox create -i ubuntu:24.04 -n u24
distrobox enter u24
# inside the container: apt install <whatever-needs-glibc-2.39>
# distrobox-export --bin /usr/bin/<tool>   # exposes to host PATH
```

GPU / CUDA passthrough works out of the box on NVIDIA hosts (distrobox
inherits the host's `/dev/nvidia*` and userland libs).

## When upgrading the OS *is* the right call

**Only when all of these are true**:

- The tool is system-level (not a single CLI), e.g. a kernel module, a
  systemd unit that integrates deeply with PAM / D-Bus / NetworkManager.
- The cost of running it in a container is unacceptable (e.g. it needs
  PID 1, or to manage host services).
- You already planned to do an LTS upgrade for other reasons.

For a personal workstation on Ubuntu 22.04 needing glibc 2.39:

| Concern | Risk on this kind of box |
|---|---|
| **NVIDIA driver + CUDA stack** | High — kernel jumps from 5.15 → 6.8, driver must be recompiled, `cuda-ubuntu2204` repo must be re-pointed to `2404`, cuDNN compatibility re-verified. Plan a maintenance window. |
| **Third-party apt repos** (e.g. BeeGFS, Docker, NVIDIA, ngrok, GitHub CLI) | Medium — disable before upgrade, re-add `noble` versions after. Some vendors lag on the new release. |
| **Out-of-tree kernel modules** (BeeGFS client, ZFS, DKMS-based drivers) | High — must recompile against the new kernel; if the vendor hasn't shipped support yet you may be unbootable on the new kernel. |
| **Snap / Flatpak** | Low — usually transparent across LTS upgrades. |
| **Old kernel cruft in `/boot`** | Medium — purge with `apt autoremove --purge` *before* the upgrade so `/boot` doesn't fill. |
| **Linuxbrew** | Low — `/home/linuxbrew` survives, but `brew doctor` after upgrade is wise. |

Pre-upgrade hygiene checklist:

```bash
# Snapshot package state
dpkg --get-selections > ~/pkglist-$(date +%F).txt
sudo apt-mark showmanual > ~/manual-$(date +%F).txt
sudo tar czf /backup/etc-$(date +%F).tar.gz /etc

# Clean up before upgrading
sudo apt update && sudo apt full-upgrade
sudo apt autoremove --purge

# Disable third-party repos that don't have a noble/jammy+1 version yet
sudo mv /etc/apt/sources.list.d/cuda-ubuntu2204.list ~/disabled-repos/

# Run the upgrade
sudo do-release-upgrade        # add -d for not-yet-released versions
```

## Diagnosing in 30 seconds

```bash
# 1. What's the host's libc version?
ldd --version | head -1

# 2. Is the failing binary using glibc dynamically?
file $(which <tool>)
ldd  $(which <tool>) 2>&1 | head -5

# 3. Which symbol is the binary asking for?
objdump -T $(which <tool>) | grep GLIBC_ | sort -u | tail -5
# or:
strings -a $(which <tool>) | grep -E '^GLIBC_[0-9]'

# 4. What versions does the host actually expose?
strings -a /lib/x86_64-linux-gnu/libc.so.6 | grep -E '^GLIBC_[0-9]' | sort -u
```

If step 4's max version < step 3's max version → swap the binary
(strategies 1–3 above). Don't touch the host libc.

**Never** try to install a newer `libc6` package from a non-matching
distro release, and **never** compile glibc from source over the system
one. Both routes will brick the box (every binary on the system, including
`bash`, `apt`, `sudo`, `ssh`, links against `libc.so.6` at runtime). If
you need a newer glibc badly enough to consider this, use distrobox.

## Cross-references

- [Linux package sources: apt vs Linuxbrew vs snap vs GitHub binaries](linux-package-sources.md)
  — broader picture of which package source to pick for what tool.
- Pitfall: [tv binary requires GLIBC_2.39 not found on jammy](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/tv-binary-glibc-2-39-not-found.md)
  — the concrete debugging walkthrough that prompted this doc.

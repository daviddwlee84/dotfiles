# Linux toolchain baseline — glibc, libstdc++, kernel, gcc, and what runs on what

This page is the reference you reach for when a binary refuses to run with
errors like `GLIBC_2.27 not found`, `GLIBCXX_3.4.21 not found`,
`CXXABI_1.3.9 not found`, or `kernel too old`. It maps the **system-side
versions** (glibc, libstdc++, kernel, libc++) to the **distro releases**
that ship them, and explains which combinations actually run modern
prebuilt software (Node 18+, numpy 2.x, Bun, Rust binaries, dotnet).

This is **distro-agnostic Linux knowledge** — it applies to any Linux
host you SSH into, not just to chezmoi-managed ones. It exists in this
repo because we keep hitting the same wall on legacy IDC servers
(CentOS 7) and several pitfalls cross-link here.

## The four numbers that decide what runs

When a Linux binary loads, four versions matter, in roughly this order
of importance:

| Layer | What it controls | How to check |
|-------|------------------|--------------|
| **glibc** | Most syscall wrappers, dynamic linker, threading, locale | `ldd --version` |
| **libstdc++** | C++ runtime — class layouts, `noexcept`, `std::filesystem`, etc. | `strings $(gcc --print-file-name=libstdc++.so.6) \| grep GLIBCXX` |
| **kernel** | Syscall surface, namespaces, io_uring, BPF | `uname -r` |
| **gcc** | What you can *build* (matches libstdc++ but exists separately) | `gcc --version` |

Each of these has a **floor** that determines what you can *run*. The
ceiling is whatever the distro lets you install (apt/yum upgrade is
constrained). On a single machine you generally cannot raise the floor
without replacing the OS.

## Distro release ↔ baseline matrix (x86_64)

| Distro release | EOL | glibc | libstdc++ (gcc) | kernel | Default Python |
|----------------|-----|-------|-----------------|--------|----------------|
| **CentOS 6** / RHEL 6 | 2020-11 | 2.12 | gcc 4.4 | 2.6.32 | 2.6 |
| **CentOS 7** / RHEL 7 | **2024-06** | **2.17** | **gcc 4.8.5 → libstdc++ 4.8.2** | 3.10.0 | 2.7 / 3.6.8 (EPEL) |
| Ubuntu 18.04 | 2023-05 | 2.27 | gcc 7.5 → libstdc++ 7 | 4.15 / 5.4 (HWE) | 3.6 |
| Debian 10 | 2024-06 | 2.28 | gcc 8.3 → libstdc++ 8 | 4.19 | 3.7 |
| **RHEL 8 / Rocky 8 / Alma 8** | 2029-05 | 2.28 | gcc 8.5 (default) / 11+ (DTS) | 4.18 | 3.6 (default) / 3.9+ (modules) |
| Ubuntu 20.04 | 2025-04 | 2.31 | gcc 9.4 → libstdc++ 9 | 5.4 / 5.15 (HWE) | 3.8 |
| Debian 11 | 2026-08 | 2.31 | gcc 10.2 | 5.10 | 3.9 |
| Ubuntu 22.04 | 2027-04 | 2.35 | gcc 11.4 → libstdc++ 11 | 5.15 / 6.5 (HWE) | 3.10 |
| **RHEL 9 / Rocky 9 / Alma 9** | 2032-05 | 2.34 | gcc 11.4 (default) / newer (DTS) | 5.14 | 3.9 |
| Debian 12 | 2028-06 | 2.36 | gcc 12.2 | 6.1 | 3.11 |
| Ubuntu 24.04 | 2029-04 | 2.39 | gcc 13.2 → libstdc++ 13 | 6.8 | 3.12 |

**The two big watersheds:**

- **glibc 2.17** → **glibc 2.28**: Released 2012 → 2018. Crossed when
  CentOS/RHEL bumped 7 → 8 and most distros bumped sometime around
  2018-2020. **Most modern prebuilt binaries draw their floor here.**
- **glibc 2.28** → **glibc 2.34/2.35**: Released 2018 → 2021. Crossed
  with RHEL 9 / Ubuntu 22.04. Some 2025+ binaries (esp. statically
  linked Rust nightlies, certain Node releases) draw their floor here.

## What modern software actually requires

These thresholds come from upstream release artifacts — they shift over
time, so always double-check at the release notes for the version you
need.

### Node.js (binary tarballs from nodejs.org/dist/)

| Node version | Min glibc | EL7 (glibc 2.17) | EL8 (glibc 2.28) | EL9 (glibc 2.34) |
|--------------|-----------|-------------------|-------------------|-------------------|
| 16.x (EOL 2023-09) | 2.17 | ✅ | ✅ | ✅ |
| 17.x (EOL 2022-06) | 2.17 | ✅ | ✅ | ✅ |
| **18.x** (LTS until 2025-04) | **2.28** | ❌ | ✅ | ✅ |
| 20.x (LTS until 2026-04) | 2.28 | ❌ | ✅ | ✅ |
| 22.x (LTS until 2027-04) | 2.28 | ❌ | ✅ | ✅ |
| 24.x (current) | 2.28 | ❌ | ✅ | ✅ |

**EL7 escape hatch**: NodeSource still publishes Node 16 RPMs for EL7
(the last EL7-compatible LTS). The package is built specifically against
glibc 2.17 + libstdc++ 4.8 with a bundled-runtime workaround.

```bash
# EL7 only — Node 16 (deprecated upstream but the only option that runs)
curl -fsSL https://rpm.nodesource.com/setup_16.x | sudo bash -
sudo yum install -y nodejs   # node 16.20.x, npm 8.x
```

The EOL warning is real — no security patches — but Node 16 still works
for installing static-binary CLIs (Copilot CLI, Codex CLI, Gemini CLI)
that just need npm to drop their own bundled runtime. For long-running
production Node servers, move off EL7.

### Python wheels (manylinux baseline)

| Manylinux tag | Min glibc | When wheels typically targeted |
|---------------|-----------|-------------------------------|
| `manylinux2014` / `_2_17` | 2.17 | Numpy 1.x, scipy 1.x, pandas 1.x, pyarrow ≤ 13 |
| `manylinux_2_28` | 2.28 | **Numpy 2.x, pandas 3.x, pyarrow 14+, modern data-science wheels** |
| `manylinux_2_34` | 2.34 | A few latest scientific wheels (PyTorch nightly etc.) |

**EL7 implication**: when uv / pip resolves a package on Python 3.13, it
prefers the newest wheel. If only `_2_28` wheels exist, uv falls back to
**source build**, which needs gcc ≥ 9 (numpy meson asserts it explicitly).
EL7's gcc 4.8.5 fails. See
[`pitfalls/centos7-numpy-pandas-source-build.md`](../../pitfalls/centos7-numpy-pandas-source-build.md).

### libstdc++ / GCC C++ ABI

The libstdc++ shipped with a distro is whatever its system gcc was built
with. The `GLIBCXX_*` symbol versions (3.4.20, 3.4.21, 3.4.22, …) are
extra-strict because **adding a symbol bumps the version even if the ABI
is technically backward-compatible**:

| GLIBCXX symbol | Min gcc shipping it | Common consumers |
|----------------|---------------------|------------------|
| `GLIBCXX_3.4.20` | gcc 4.9 | greenlet (Python sqlalchemy), some Node native modules |
| `GLIBCXX_3.4.21` | gcc 5.1 | Node 18+, dotnet 6+, libwebkit |
| `GLIBCXX_3.4.22` | gcc 6.1 | dotnet 7+ |
| `GLIBCXX_3.4.26` | gcc 9 | newer std::filesystem features |
| `CXXABI_1.3.9` | gcc 5 | most modern C++ binaries |

**EL7 has libstdc++ from gcc 4.8.5** — so `GLIBCXX_3.4.20` and
`CXXABI_1.3.9` are absent. This trips:

- Bun (musl variant works around glibc but linker still references new
  CXXABI in some builds)
- .NET / dotnet (needs GLIBCXX_3.4.20+)
- Native Python C++ extensions: greenlet (sqlalchemy), some grpcio
  builds, certain torch builds
- Modern C++ Rust crates with C++ in their FFI

### Rust (rustup)

The rustup-installed toolchain runs on glibc 2.17+ (still). Source
builds of Rust crates need a **C compiler that supports the crate's
language requirements**:

- **Most crates**: gcc 4.8.5 OK (C99 sufficient).
- **Crates with C++ deps** (e.g. `clang-sys`, `bindgen`): often need
  gcc 5+ for C++11.
- **Crates pulling in `cmake-rs`**: depends on cmake's C++ check, can
  fail on old gcc.

The Rust *binary* is fine on EL7. The pain is when a downstream Rust
crate has a C++ dep with modern requirements. Workarounds:

- Use a SCL devtoolset (`devtoolset-9` or `-11`) to run modern gcc on EL7.
- Build the troublesome crate in a Rocky 9 container and copy the binary
  in (musl-static-link if possible).

## Why you can't (easily) upgrade glibc on a running system

glibc is the foundation of every dynamically-linked binary on the box.
Upgrading it requires:

1. Replacing `/lib64/libc.so.6` (and dozens of related shared libraries)
2. Restarting **every** running process — kernel does not relink running
   processes mid-execution
3. Trusting that the new glibc is ABI-backward-compatible with all your
   already-installed binaries (usually true within minor versions, but
   even 2.17 → 2.28 has dozens of edge cases)
4. Surviving the dynamic linker boot if the upgrade is interrupted (a
   half-installed glibc can brick the box — no shell, no rescue, only
   a recovery-image boot)

**Practical reality**: a glibc upgrade on a production box is an OS
reinstall. CentOS 7 → Rocky 9 is not an in-place upgrade — you boot from
fresh media and migrate `/home`. ELevate (the AlmaLinux migration tool)
exists for 7 → 8 but not 7 → 9, and even 7 → 8 has caveats.

**Will it require a reboot?** Yes. A full kernel + glibc replacement
needs a reboot. On an old IDC machine with multiple users and shared
disks:

- Schedule with IT — they'll typically want a maintenance window.
- Snapshot LVM `/` first. ELevate can fail mid-upgrade.
- Other users' open SSH sessions will be killed when the box reboots.
- Firmware quirks: 5+ year old BIOS/iLO/iDRAC may not boot cleanly
  after a kernel jump. Have a console / IPMI plan.

For a single-user dev workstation, the migration is straightforward.
For a 224-CPU shared compute node with 3TB RAM, the cost-benefit is:
**probably not worth the disruption** — the workarounds below cost less.

## Workarounds, in order of preference

When you can't upgrade the OS, these get you a modern-ish stack on a
crusty kernel:

### 1. micromamba / conda-forge (no sudo, no glibc upgrade)

micromamba ships its own glibc-2.17-compatible binary and pulls
conda-forge packages that bring their own glibc/libstdc++ in
the env's `lib/`. This is the cleanest "modern Python + numpy + pandas
+ pyarrow + pytorch on EL7" path AND the cleanest way to get **modern
Node** (which dropped EL7 support at v18, see Node table above).

#### Modern Python + scientific stack

```bash
# Single-binary install, ~/.local/bin/micromamba (~30MB, no sudo)
curl -fsSL https://micro.mamba.pm/api/micromamba/linux-64/latest \
  | tar -xj -C ~/.local/bin --strip-components=1 bin/micromamba

# Modern Python + dataframe stack — bundles its own libstdc++ from
# conda-forge so EL7's gcc 4.8.5 doesn't matter.
micromamba create -n modern -c conda-forge -y \
  python=3.13 numpy pandas pyarrow polars duckdb
micromamba activate modern
python -c "import numpy, pandas; print(numpy.__version__, pandas.__version__)"
# 2.4.4 2.3.3 (or whatever's current on conda-forge)
```

#### Modern Node + npm-based CLIs (Copilot/Codex/Gemini)

This is the EL7 escape hatch for npm packages requiring Node 18+.
NodeSource Node 16 RPMs work for installation but the actual CLIs
fail with `Unsupported engine: requires Node >= 20`.

```bash
# Create an env with Node 22 (current LTS at time of writing). conda-forge
# ships nodejs builds linked against its bundled glibc, so this works on
# EL7's glibc 2.17.
micromamba create -n node22 -c conda-forge -y nodejs=22

# Activate to get node + npm on PATH:
micromamba activate node22
node --version    # v22.x.x
npm --version

# Install the npm-based coding agent CLIs:
npm install -g @anthropic-ai/claude-code   # Claude Code via npm
npm install -g @google/gemini-cli           # Gemini CLI
npm install -g @openai/codex                # OpenAI Codex CLI
npm install -g @github/copilot              # GitHub Copilot CLI
```

To make this seamless across SSH sessions, add to `~/.bashrc.adhoc`:

```bash
# Auto-activate the Node 22 env for any interactive shell on this host
if [ -x ~/.local/bin/micromamba ]; then
    eval "$(~/.local/bin/micromamba shell hook --shell bash)"
    micromamba activate node22 2>/dev/null || true
fi
```

#### Limitations

- conda-forge envs have their own internal coherence — mixing pip
  packages with conda-forge libstdc++ generally works but has
  occasional ABI drama. Stick to one channel per env.
- The env is "rooted" at the conda-forge libstdc++; stepping outside
  with `LD_LIBRARY_PATH` overrides can break things subtly.
- Each env consumes 200MB-1GB+ disk depending on tools. Not free.
- conda-forge nodejs is built fresh — minor lag (1-2 days) behind
  upstream Node releases vs. nodejs.org's same-day publish.

### 2. Apptainer / Singularity / Podman (rootless container)

Rocky 9 (or Ubuntu 24.04) inside a container, sharing `/home`. The
container brings its own glibc 2.34 / libstdc++ 13. The host kernel
(3.10) is a non-issue for everything except very modern syscalls
(io_uring, fanotify on directories) which most workloads don't need.

```bash
# Apptainer is rootless and IDC-friendly — ask IT to install if missing.
apptainer pull docker://rockylinux:9
apptainer shell --bind /home --bind /data1 --bind /data2 rockylinux_9.sif
# Inside the container: glibc 2.34, gcc 11, all modern tooling.
```

Limitation: requires Apptainer or Podman (rootless Docker) to be
installed by IT. Plain Docker is usually root-required.

### 3. SCL devtoolset (modern gcc on EL7, RPM)

Software Collections gives you `gcc 9` / `gcc 11` / `gcc 12` while
keeping the system gcc 4.8.5 untouched. Lives in `/opt/rh/`.

```bash
sudo yum install -y centos-release-scl
sudo yum install -y devtoolset-11
scl enable devtoolset-11 bash
gcc --version    # 11.x
```

Lets you compile crates / wheels that need modern gcc but doesn't help
with glibc-2.17-locked binaries.

### 4. Static / musl binaries

Many CLIs ship `*-x86_64-unknown-linux-musl` releases that statically
link musl libc and don't care about glibc. ripgrep, fd, zoxide,
eza, bat, fzf all do.

We already prefer musl in [`pitfalls/centos7-noroot.md`](../../pitfalls/centos7-noroot.md) — see the
"glibc-2.17 fallout" section.

### 5. Source build with an older toolchain

Last resort. Build the offending package from source, pinning to a
version that still supports your glibc.

- **Node**: NodeSource Node 16 (above) — EOL but works.
- **numpy**: pin to 1.26.4 — last manylinux_2_17 release.
- **pyarrow**: pin to 13.x — same boundary.
- **mlflow**: avoid; needs sqlalchemy → greenlet which compiles modern
  C++. See [`pitfalls/centos7-numpy-pandas-source-build.md`](../../pitfalls/centos7-numpy-pandas-source-build.md).

## Decision tree

When you hit a `GLIBC_*` / `GLIBCXX_*` / `CXXABI_*` not-found error:

1. **Is the binary a CLI you can swap?** Look for a musl variant
   (ripgrep, fd, etc.) or use the system-package equivalent.
2. **Is it Python?** Use micromamba + conda-forge. Skip pip.
3. **Is it Node?** Use NodeSource Node 16 (EL7) or upgrade OS.
4. **Is it C++?** Try a SCL devtoolset to rebuild from source. If the
   project pins a specific C++ stdlib feature you can't get on EL7,
   wrap it in Apptainer.
5. **Is it production-critical and you'll keep using EL7 for ≥1 year?**
   Get IT to schedule the OS migration. A 6-year-old glibc has been
   accumulating CVEs since 2018 — security alone justifies the
   maintenance window.

## How this repo treats EL7

The chezmoi config + ansible roles in this repo detect EL7 in several
places and route around the worst cases:

| Surface | Behaviour on EL7 |
|---------|------------------|
| `dot_config/mise/config.toml.tmpl` | Skips `node`/`bun`/`rust`/`dotnet` mise pins (this doc's twin). User runs Node via NodeSource and Rust via direct rustup. |
| `dot_ansible/roles/python_uv_tools/tasks/main.yml` | Probes `gcc -dumpversion`, skips tools tagged `needs_modern_gcc: true` (visidata, sqlit-tui[ssh], mlflow). |
| `run_once_before_00_bootstrap.sh.tmpl` | Detects `glibc < 2.28`, prefers mise musl binary directly. |
| `dot_ansible/roles/zsh/tasks/main.yml` | Detects `zsh < 5.3`, builds zsh 5.9 user-level from source. |
| `dot_ansible/roles/{base,zsh,bash,ruby_gem_tools}/` | Use `yum` CLI instead of `ansible.builtin.yum` (which routes through `dnf` backend missing on EL7). |
| `pitfalls/centos7-*.md` | Symptom-grep-able pitfall corpus for everything else. |

Cross-linked pitfalls:

- [`pitfalls/centos7-noroot.md`](../../pitfalls/centos7-noroot.md) — noRoot path, glibc 2.17 musl fallback story.
- [`pitfalls/centos7-numpy-pandas-source-build.md`](../../pitfalls/centos7-numpy-pandas-source-build.md) — the numpy 2.x meson wall.
- [`pitfalls/centos7-zsh-too-old.md`](../../pitfalls/centos7-zsh-too-old.md) — system zsh 5.0.2 vs. config requirements.
- [`pitfalls/centos7-ansible-yum-dnf-backend.md`](../../pitfalls/centos7-ansible-yum-dnf-backend.md) — ansible-core 2.18+ yum module wrapper.
- [`pitfalls/bootstrap-no-tty-sudo-prompt-skipped.md`](../../pitfalls/bootstrap-no-tty-sudo-prompt-skipped.md) — sudo session + Linuxbrew installer.
- [`pitfalls/tuna-nodejs-mirror-aggressive-gc.md`](../../pitfalls/tuna-nodejs-mirror-aggressive-gc.md) — TUNA mirror keeps only a few node versions.

## References

- glibc release tags: <https://sourceware.org/glibc/wiki/Release>
- gcc release tags: <https://gcc.gnu.org/releases.html>
- libstdc++ ABI symbol version table:
  <https://gcc.gnu.org/onlinedocs/libstdc++/manual/abi.html>
- manylinux PEPs: 600 (2014/`_2_17`), 656 (`_2_28`), 690 (`_2_34`)
- NodeSource distribution policy:
  <https://github.com/nodesource/distributions>
- Rocky Linux migration guide (alternative to in-place):
  <https://docs.rockylinux.org/release_notes/9_3/>
- ELevate (AlmaLinux project) for 7→8:
  <https://wiki.almalinux.org/elevate/>

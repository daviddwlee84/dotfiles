# Debian Ecosystem: Debian / Ubuntu / Raspberry Pi OS

Overview of the Debian family tree, release cadences, and how to choose between
them. For RHEL/CentOS equivalent, see [rhel-ecosystem.md](rhel-ecosystem.md).
For toolchain-level details (glibc, gcc, kernel) see
[linux-toolchain-baseline.md](linux-toolchain-baseline.md).

---

## The family tree

```
Debian (stable / testing / unstable)
  │
  ├── Raspberry Pi OS  (Debian base + Pi hardware + raspi-config)
  │
  └── Ubuntu  (Canonical; 6-month cadence, 2-year LTS)
        ├── Official flavours: Kubuntu, Xubuntu, Lubuntu, Ubuntu Server,
        │   Ubuntu Core, Ubuntu Studio …
        └── Downstream: Linux Mint, Pop!_OS, elementary OS, Zorin OS …
```

Ubuntu is *based on* Debian but is **not** an official Debian release.
Raspberry Pi OS is *based on* Debian but hardware-specialised for Pi.
Neither is a downstream "version" of the other — they are parallel forks.

---

## Debian

The root of the family. Key characteristics:

- **Community-governed** — no single corporate owner.
- **Very conservative release cadence** — "release when ready", roughly every
  2-3 years, not calendar-driven.
- **Three active branches at any time**:

  | Branch | Alias | Description |
  |--------|-------|-------------|
  | `stable` | current codename | Production-ready; security-patched for ~5 years |
  | `testing` | next codename | Future stable candidate pool |
  | `unstable` | `sid` | Rolling; never released as stable |

- **Source of `apt` / `dpkg`** — every Debian-family distro inherits this.
- **Toy Story codenames** (see [Version codenames](#version-codenames)).

### When to choose Debian

| Use case | Fits? |
|----------|-------|
| Long-lived server, NAS, home lab | Yes — very stable, low churn |
| Minimal footprint, no corporate defaults | Yes |
| Latest GPU stack / CUDA / NVIDIA drivers | No — use Ubuntu or backports |
| Most online tutorials / PPA | No — Ubuntu has far more |
| Raspberry Pi hardware | No — use Raspberry Pi OS |

---

## Ubuntu

Canonical's product built on Debian. The distro most people mean when they say
"I use Linux" for development.

### Release cadence

| Type | Cadence | Support |
|------|---------|---------|
| Interim release | Every 6 months (April + October) | 9 months |
| LTS | Every 2 years (April, even years) | 5 years standard; 10 years with Ubuntu Pro |

Ubuntu Pro extends LTS maintenance to 10 years for free on up to 5 personal
machines.

### Recent releases

| Version | Codename | Type | EOL |
|---------|----------|------|-----|
| 22.04 | Jammy Jellyfish | LTS | 2027-04 (standard) |
| 24.04 | Noble Numbat | LTS | 2029-04 (standard) |
| 25.10 | Questing Quokka | Interim | 2026-07 |
| 26.04 | Resolute Raccoon | LTS | 2031-04 (standard) |

For production servers, always use an LTS; interim releases are for development
machines where you want newer packages.

### Why Ubuntu dominates cloud / dev / AI workloads

- **NVIDIA / CUDA**: official drivers, CUDA repos, container images all target
  Ubuntu LTS first.
- **Docker / Kubernetes**: official install docs default to Ubuntu.
- **PPA ecosystem**: add-apt-repository gives access to recent tooling without
  compiling from source.
- **Cloud AMIs / images**: AWS, GCP, Azure all ship Ubuntu LTS images as a
  first-class option.
- **Volume of tutorials**: majority of DevOps, AI/ML, and system-admin guides
  use Ubuntu examples.

### Ubuntu trade-offs

- **Snap**: Canonical pushes Snap for some system packages (Firefox, etc.);
  divisive in the community. `apt install firefox` may give a Snap instead of
  a deb on newer releases.
- **More "opinionated" defaults** than Debian — Canonical makes product
  decisions that affect every user.
- **6-month interim releases** can disrupt workflows if you follow them; stick
  to LTS for stability.

---

## Raspberry Pi OS

Formerly named **Raspbian**. The official OS for Raspberry Pi hardware.

```
Raspberry Pi OS = Debian base
               + Pi boot firmware / config.txt
               + Pi kernel + device tree + GPIO / camera / display support
               + raspi-config utility
               + Pi official desktop (LXDE-based)
```

Pi OS releases track Debian stable codenames (bullseye → bookworm → trixie).
It is **not** Ubuntu for Pi — it is Debian for Pi.

### Choosing an OS for Raspberry Pi

| Goal | Best choice |
|------|-------------|
| Easiest setup, best hardware support (GPIO, camera, display) | **Raspberry Pi OS** |
| Headless server, want same OS as your cloud VMs | Ubuntu Server for Raspberry Pi |
| Pure Debian, no Pi extras | Debian arm64 (hardware support may lag) |
| 64-bit only | Raspberry Pi OS (64-bit) or Ubuntu Server |

Raspberry Pi OS comes in three flavours:

| Flavour | Description |
|---------|-------------|
| Desktop | Full GUI, recommended for beginners |
| Desktop Lite | Minimal GUI |
| Lite | No GUI — best for headless servers / embedded |

---

## Choosing between Debian, Ubuntu, and Raspberry Pi OS

| Goal | Recommendation |
|------|----------------|
| General Linux server | Debian stable or Ubuntu LTS |
| Dev machine / AI / Docker / CUDA | **Ubuntu LTS** |
| Cloud VM | Ubuntu LTS (most image support); Debian is also solid |
| Most conservative, minimal stable server | **Debian stable** |
| Raspberry Pi (GPIO / camera / sensors) | **Raspberry Pi OS** |
| Raspberry Pi as headless server | Raspberry Pi OS Lite or Ubuntu Server |
| Fewer Canonical product decisions | Debian |
| Maximum tutorial coverage & compatibility | Ubuntu |

One-line summary:

> **Debian**: stable, clean, community, conservative.  
> **Ubuntu**: easy, well-supported, opinionated, dev-friendly.  
> **Raspberry Pi OS**: Debian-based, Pi-hardware-first.

---

## Debian vs RHEL family: key differences

| | Debian / Ubuntu | RHEL / Rocky / Alma |
|-|-----------------|---------------------|
| Package format | `.deb` / `apt` / `dpkg` | `.rpm` / `dnf` / `rpm` |
| Community / enterprise balance | Community-first (Debian), productised (Ubuntu) | Enterprise-first (RHEL), community rebuild (Rocky/Alma) |
| Cloud / DevOps dominance | Ubuntu LTS very strong | RHEL / Alma in regulated / HPC / enterprise |
| Desktop / new user adoption | Ubuntu leads | Fedora / Alma smaller share |
| ABI stability guarantee | Ubuntu LTS stable within a release | RHEL famous for binary ABI guarantees across minor releases |
| Toolchain age on stable | Ubuntu LTS ships newer gcc/glibc than RHEL equivalent | RHEL 9 ≈ Ubuntu 22.04 LTS for most toolchain versions |

Use case cross-reference from this repo's perspective:

| Scenario | Choose |
|----------|--------|
| Personal dev machine / AI / CUDA / Docker | Ubuntu LTS |
| HPC cluster / enterprise internal server | Rocky / Alma / RHEL |
| Raspberry Pi / GPIO / embedded | Raspberry Pi OS |
| Cleanest stable server, no corporate defaults | Debian stable |
| CentOS 7 migration target | Rocky Linux 9 / AlmaLinux 9 (see [rhel-ecosystem.md](rhel-ecosystem.md)) |

---

## Version codenames

### Debian (Toy Story characters)

| Version | Codename | Status |
|---------|----------|--------|
| 11 | bullseye | oldstable |
| 12 | bookworm | oldstable (as of Debian 13 release) |
| 13 | trixie | **stable** (released 2025-08-09) |
| — | sid | unstable (permanent alias) |

### Ubuntu (adjective + animal, alphabetical)

| Version | Codename | Type |
|---------|----------|------|
| 22.04 LTS | Jammy Jellyfish | LTS |
| 24.04 LTS | Noble Numbat | LTS |
| 25.10 | Questing Quokka | Interim |
| 26.04 LTS | Resolute Raccoon | LTS |

### Raspberry Pi OS

Tracks Debian stable codenames. Current releases: bookworm (stable), trixie
(newer). Check the [official downloads page](https://www.raspberrypi.com/software/operating-systems/)
for the current recommended image.

---

## See also

- [rhel-ecosystem.md](rhel-ecosystem.md) — RHEL / CentOS family, migration
  from CentOS 7.
- [linux-toolchain-baseline.md](linux-toolchain-baseline.md) — glibc / gcc /
  kernel version matrix, including Ubuntu and Debian rows.

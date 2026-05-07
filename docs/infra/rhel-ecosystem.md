# RHEL Ecosystem & CentOS Migration Guide

Reference for understanding the RHEL/CentOS family tree and choosing a migration
path for machines currently running CentOS 7 (the distribution this repo was
originally developed against). For toolchain-level details (glibc, gcc, kernel
versions per distro) see [linux-toolchain-baseline.md](linux-toolchain-baseline.md).

---

## The family tree

```
Fedora  (bleeding-edge upstream)
  │
  ▼
CentOS Stream  ←── RHEL minor-release preview / upstream development branch
  │
  ▼
RHEL  (Red Hat's paid enterprise product)
  │
  ├── AlmaLinux  (community RHEL-compatible, CloudLinux-backed)
  ├── Rocky Linux (community RHEL rebuild, CentOS co-founder lineage)
  └── Oracle Linux (Oracle-backed; choice of RHEL-compat or UEK kernel)
```

**Key shift (2020):** Red Hat redirected the CentOS Project. The old model was
`RHEL → CentOS Linux` (RHEL rebuild released after RHEL). The new model makes
CentOS Stream a *pre-RHEL* development branch — closer to Fedora in spirit.

---

## EOL timeline

| Distro | EOL |
|--------|-----|
| CentOS Linux 6 | 2020-11-30 |
| CentOS Linux 7 | **2024-06-30** (reached) |
| CentOS Linux 8 | 2021-12-31 (cut short) |
| CentOS Stream 8 | 2024-05-31 |
| CentOS Stream 9 | ~2027 (follows RHEL 9 lifecycle) |
| CentOS Stream 10 | ~2030 (follows RHEL 10 lifecycle) |
| RHEL / Alma / Rocky 8 | 2029-05 |
| RHEL / Alma / Rocky 9 | 2032-05 |

CentOS Linux 8 was cut 4 years early (announced 2020, EOL 2021). There is no
"CentOS Linux 9" — the equivalent stable community rebuilds are AlmaLinux 9 and
Rocky Linux 9.

---

## What each distro is now

### RHEL
Paid enterprise product from Red Hat. Required if your org has a subscription or
a compliance mandate. Most "RHEL-compatible" guarantees are stated relative to
RHEL's ABI.

### CentOS Stream
No longer a stable-release RHEL clone. It is the *upstream development branch*
that feeds into the next RHEL minor release:

```
Fedora → CentOS Stream → RHEL → Alma/Rocky
```

Useful for developers who want to preview RHEL changes or contribute upstream.
**Not recommended as a drop-in CentOS 7 replacement for production servers.**

### AlmaLinux
Community-driven RHEL-compatible distro backed by CloudLinux. Primary goal is
filling the gap left by CentOS Linux. Since RHEL 9.2, AlmaLinux's strategy
shifted from "byte-for-byte clone" to "ABI/application compatibility" (see
[AlmaLinux FAQ](https://almalinux.org/blog/2023-06-05-centos-alternative/)).
Practically, this matters very rarely. Large, active community; backed by a
commercial entity.

### Rocky Linux
Community RHEL rebuild founded by Gregory Kurtzer (CentOS co-founder). Closest
in spirit to the original CentOS Linux "RHEL rebuild released after RHEL"
philosophy. Strong community; well-regarded in HPC and research environments.

### Oracle Linux
Oracle-backed RHEL-compatible distro. Offers a choice between a
RHEL-compatible kernel and Oracle's own UEK (Unbreakable Enterprise Kernel).
Adoption usually follows organizational Oracle relationships.

---

## Migration paths from CentOS 7

CentOS Linux 7 → CentOS Linux 8/9 **does not exist**. Choose from:

| Goal | Path |
|------|------|
| Paid enterprise support / compliance | RHEL 8 or 9 |
| Free, stable, closest to old CentOS | **Rocky Linux 8/9** or **AlmaLinux 8/9** |
| Staying in Oracle ecosystem | Oracle Linux 8/9 |
| RHEL upstream dev / preview | CentOS Stream 9/10 (not production-stable) |

### In-place vs. fresh install

There is **no supported in-place upgrade** from CentOS 7 to any EL8/EL9
variant. Options:

- **Fresh install + re-apply dotfiles**: recommended. Boot from ISO, then
  `chezmoi init` + ansible on the new OS. Typically takes 30-60 min.
- **Leapp migration** (Red Hat's official in-place tool): officially supported
  for RHEL → RHEL upgrades. Community-backed Leapp paths exist for CentOS 7 →
  AlmaLinux/Rocky but are higher-risk on customized systems.
- **Stay on CentOS 7 using containers**: build-time isolation via Apptainer /
  Docker. Useful when the OS itself cannot be migrated immediately. See
  [linux-toolchain-baseline.md § Apptainer](linux-toolchain-baseline.md#2-apptainer--singularity--podman-rootless-container).

### Compatibility note for dotfiles

This repo's configs were developed on CentOS 7 (`glibc 2.17`, `gcc 4.8.5`,
kernel 3.10). After migrating to EL8/EL9 the main differences are:

| Area | EL7 | EL8/9 |
|------|-----|-------|
| Default Python | 2.7 (`python`) | 3.x only; no `python` symlink by default |
| System Python 3 | 3.6.8 (EPEL) | 3.9 (EL8) / 3.11+ (EL9) |
| Package manager | `yum` | `dnf` (`yum` is a `dnf` alias) |
| `ntp` service | `ntpd` | `chrony` |
| `ifconfig` / `netstat` | in base | in `net-tools` (install manually) |
| SCL (`scl enable`) | common pattern | replaced by module streams |

The chezmoi templates in this repo use `.chezmoi.os` and version-sniff
patterns; they do not hard-code CentOS 7 paths, so re-applying on EL8/9 should
work without modification.

---

## Quick-reference: choosing between Alma and Rocky

Both are solid choices. For this repo's use case (HPC / compute nodes /
single-developer workstations), the practical differences are minor:

| | AlmaLinux | Rocky Linux |
|-|-----------|-------------|
| Backing org | CloudLinux (commercial) | Rocky Enterprise Software Foundation |
| ABI compatibility stance | "ABI compatible" (since 9.2) | "1:1 RHEL rebuild" |
| Community size | Large | Large |
| HPC community adoption | Common | Very common (RHEL co-founder heritage) |
| Verdict | Either is fine | Slight edge in HPC/research contexts |

If your cluster already uses one, stay with it. If starting fresh, Rocky Linux
9 is a reasonable default.

---

## See also

- [linux-toolchain-baseline.md](linux-toolchain-baseline.md) — glibc / gcc /
  kernel version matrix per distro, SCL usage, Apptainer containers.
- [`pitfalls/centos7-noroot.md`](../../pitfalls/centos7-noroot.md) — noroot
  toolchain on CentOS 7 (`glibc 2.17` musl fallback).
- [`pitfalls/centos7-numpy-pandas-source-build.md`](../../pitfalls/centos7-numpy-pandas-source-build.md)
  — numpy 2.x meson build wall on CentOS 7.
- [`pitfalls/centos7-zsh-too-old.md`](../../pitfalls/centos7-zsh-too-old.md) —
  system zsh 5.0.2 vs. config requirements.

# Shared Storage — Cluster Filesystems and Network Mounts

Reference for "multiple machines need to see the same bytes." Picks a filesystem or protocol based on workload shape (POSIX vs object, HPC vs general, Linux-only vs mixed OS) and how much operational complexity you're willing to absorb.

## Quick answer

| Problem | Pick |
|---------|------|
| Shared `/home` for 5-20 Linux users on a LAN | [NFSv4](#nfsv4) (simplest); pair with [autofs](#client-mount-recipes) |
| Same but with Mac/Windows clients | [Samba (SMB/CIFS)](#smbcifs-samba) |
| HPC / ML research lab, many nodes, high throughput | [BeeGFS](#beegfs) or [Lustre](#lustre) |
| You already run Ceph and need a POSIX FS too | [CephFS](#cephfs) |
| Small team, want scale-out NAS, simple ops | [MooseFS](#moosefs--lizardfs) / [SeaweedFS](#seaweedfs) / [JuiceFS](#juicefs) |
| Just want S3-compatible object store | [MinIO](https://min.io) / [Ceph RGW](https://docs.ceph.com/en/latest/radosgw/) / SeaweedFS |
| Sync cloud storage onto local path (per-user) | [rclone](https://rclone.org) (already installed in this repo, see [README.md](../../README.md)) |

## The landscape

| System | License | Type | POSIX | Metadata | Client | Op complexity | Best for |
|--------|---------|------|-------|----------|--------|---------------|----------|
| [NFSv4](https://datatracker.ietf.org/doc/html/rfc7530) | Open standard | Network FS | Yes | Server-side | Kernel (all OSes) | Low | Shared home dirs, config, small clusters |
| [Samba (SMB/CIFS)](https://www.samba.org) | GPLv3 | Network FS | Mostly | Server-side | Kernel (all OSes incl. Windows) | Low | Mixed-OS desktops |
| [CephFS](https://docs.ceph.com/en/latest/cephfs/) | LGPLv2.1 | Distributed POSIX FS | Yes | Distributed (MDS) | Kernel or FUSE | High (MON/MGR/OSD/MDS) | Unified object+block+FS; K8s via [Rook](https://rook.io) |
| [BeeGFS](https://www.beegfs.io) | Open core (community edition free) | Parallel FS | Yes | Distributed metadata servers | Kernel module | Medium | HPC, high metadata ops/sec |
| [Lustre](https://www.lustre.org) | GPLv2 | Parallel FS | Yes | MDS + OSTs | Kernel module | Very high | Extreme bandwidth HPC (TOP500) |
| [GlusterFS](https://www.gluster.org) | GPLv2/LGPLv3 | Distributed FS | Yes | Client-hashed | FUSE or native | Medium | Scale-out NAS (declining; see notes) |
| [MooseFS / LizardFS](https://moosefs.com) | GPLv2 / BSD | Distributed FS | Yes | Single master + shadows | FUSE | Low-medium | Simple "big NAS" |
| [SeaweedFS](https://github.com/seaweedfs/seaweedfs) | Apache 2.0 | Distributed FS + object | Yes (FUSE) | Distributed | FUSE or S3 | Medium | Billions of small files |
| [JuiceFS](https://juicefs.com) | Apache 2.0 / commercial | POSIX-on-object | Yes | Redis / TiKV / MySQL | FUSE | Low | POSIX FS backed by S3/MinIO |
| [MinIO](https://min.io) | AGPLv3 / commercial | Object store | No (S3 only) | Distributed | S3 SDK | Low | S3-compatible object storage |
| [OpenZFS](https://openzfs.org) | CDDL | Local/replicated FS | Yes | Local | Native | Low per-host | Single-node NAS; pair with NFS/Samba for sharing |

## Per-system notes

### NFSv4

The simplest, most universal network filesystem. Every Unix and Mac already has a client.

- Server-side: Linux `nfs-kernel-server` + `/etc/exports`. One server is a SPOF; scale by moving to NFS-Ganesha (userspace) fronting Ceph/GlusterFS, or by sharding users across servers.
- Security: NFSv4 supports Kerberos (`sec=krb5p`). Without it, UIDs are trusted on the wire — bad on untrusted networks.
- Locking: NFSv4 has proper POSIX locks (unlike NFSv3). Still, databases and some build systems (bazel, cargo on shared cache) hate NFS; keep fast-mutation workloads local.
- Use cases: shared `/home`, shared configs, SSO-authenticated read-mostly corpora, HPC scratch when bandwidth isn't the bottleneck.

### SMB/CIFS (Samba)

SMB3 is the protocol Windows speaks natively. Linux and macOS both speak it as clients.

- Server: `smbd` on Linux, configured in `/etc/samba/smb.conf`. Can join an AD domain.
- Strong for mixed OS environments; supports per-user ACLs that map to Windows ACLs.
- Weaker than NFS for dense small-file POSIX workloads; better for "department shared drive."

### CephFS

CephFS is the POSIX-filesystem API on top of Ceph, alongside RBD (block) and RGW (object/S3). All three ride on the same RADOS object store.

- Operational cost: a Ceph cluster is MON + MGR + OSD + (for FS) MDS daemons across at least 3 nodes. Day-2 expertise non-trivial (PGs, CRUSH maps, OSD rebalancing).
- Strength: one cluster, three APIs. Your K8s persistent volumes (RBD), your S3 (RGW), and your shared FS (CephFS) all share the same redundancy and pool.
- Client: mainline kernel client (`mount -t ceph`) or FUSE fallback. Works out of the box on modern Linux.
- Kubernetes: [Rook](https://rook.io) operator makes Ceph-on-K8s ergonomic; CephFS-CSI mounts volumes into pods.
- Best for: you already need object + block and want FS "for free."

### BeeGFS

Originally Fraunhofer ITWM, now ThinkParQ. Widely used in HPC and ML training clusters because of its metadata architecture (multiple metadata servers balance load, unlike Lustre's single-MDS classic layout).

- Components: management, metadata, storage, client. All userspace except the client kernel module.
- Free for community use (open source), enterprise support from ThinkParQ.
- Strong fit when users have millions of small files (typical ML datasets).
- Commonly combined with SLURM + FreeIPA as the "lab cluster" stack — see [compute-scheduling.md](compute-scheduling.md) and [shared-home-identity.md](shared-home-identity.md).

### Lustre

The "if you have to ask, you don't need it" option. Powers most TOP500 supercomputers.

- Extreme bandwidth, great for sequential HPC IO.
- Kernel-module client, coupled to specific kernel versions.
- Requires dedicated sysadmins. Not a DIY choice.
- If you're not at >PB scale across >100 nodes, pick BeeGFS instead.

### GlusterFS

Scale-out NAS with FUSE or native client.

- Historically popular, but [RedHat ended RHGS in 2024](https://access.redhat.com/announcements/7019004) and upstream contributions have slowed. Evaluate carefully for greenfield projects.
- Still fine for existing deployments; migration path to CephFS is the common recommendation.

### MooseFS / LizardFS

Single-master distributed FS with FUSE client. LizardFS is a community fork (older; less active now).

- Simple mental model: master + chunk servers + FUSE clients.
- Good for "big NAS for a small team" without Ceph complexity.
- Master is a SPOF unless you run shadow masters (Pro edition).

### SeaweedFS

Object-first, but exposes a FUSE POSIX layer.

- Optimized for billions of small files (Facebook Haystack-inspired).
- Has S3, HDFS, FUSE, WebDAV frontends.
- Lighter ops than Ceph. Active community.

### JuiceFS

Interesting hybrid: POSIX FS metadata in Redis/TiKV/MySQL, data in any S3-compatible object store.

- Mount on any client, back onto cheap cloud object storage.
- Metadata in a DB you already run.
- Good for "I want a POSIX FS but pay object-store prices" and for cross-region shared FS.

### OpenZFS on a single host + NFS/Samba export

Not distributed, but worth naming: OpenZFS on one powerful server (ideally with replication via `zfs send` to a second box) + NFS/Samba export is the pragmatic answer for many teams.

- Snapshot + send/receive + compression + integrity.
- Works under TrueNAS, on Proxmox host, on stock Ubuntu via `zfs-dkms`.
- Scales vertically, not horizontally.

## Decision matrix by workload

| Scenario | Pick | Why |
|----------|------|-----|
| Shared `/home` for 10-person team | NFSv4 + ZFS backing | Simplest; snapshot story via ZFS; good enough at this scale |
| GPU cluster, 20-100 nodes, ML training | BeeGFS | Fast metadata; handles millions of small dataset files |
| HPC cluster, MPI jobs, >100 nodes | Lustre or BeeGFS | Bandwidth; Lustre if you have dedicated FS admins |
| K8s cluster needing object + block + FS | CephFS + RBD + RGW via Rook | One storage layer for three APIs |
| Mixed Mac/Win/Linux office file share | Samba | Only one that native Windows speaks cleanly |
| "POSIX FS but cheap" | JuiceFS on S3 | Object-storage economics, POSIX semantics |
| "Big NAS, simple ops, Linux only" | MooseFS or SeaweedFS | Less complex than Ceph; no HPC needs |
| Single beefy NAS host | OpenZFS + NFS/Samba | Vertical scaling is fine; snapshots are king |

## Client mount recipes

### NFSv4 mount

```bash
# One-off mount
sudo mount -t nfs -o vers=4.2 nas.example.com:/home /mnt/home

# Persistent via /etc/fstab
echo 'nas.example.com:/home  /home  nfs  vers=4.2,hard,nconnect=8,_netdev  0 0' | sudo tee -a /etc/fstab
```

### autofs for on-demand `/home`

Standard pattern for a shared-home cluster — mount each user's home only when they log in.

```bash
# /etc/auto.master.d/home.autofs
/home /etc/auto.home --timeout=600

# /etc/auto.home
*  -fstype=nfs4,rw,hard,nconnect=8  nas.example.com:/home/&
```

`&` is replaced by the requested subdirectory (username). See also [shared-home-identity.md](shared-home-identity.md).

### CephFS mount

```bash
# Kernel client, requires CephX secret file
sudo mount -t ceph user@.myfs=/ /mnt/cephfs \
  -o mon_addr=mon1.ceph:6789/mon2.ceph:6789,secretfile=/etc/ceph/client.user.secret
```

### BeeGFS mount

```bash
# After installing beegfs-client + beegfs-helperd packages, edit:
#   /etc/beegfs/beegfs-client.conf  -> set sysMgmtdHost
sudo systemctl enable --now beegfs-helperd beegfs-client
# Default mount point is /mnt/beegfs
```

### SMB/CIFS

```bash
sudo mount -t cifs //server/share /mnt/share \
  -o username=alice,uid=$(id -u),gid=$(id -g),vers=3.1.1,seal
```

### rclone (S3 / WebDAV / GDrive as POSIX)

```bash
rclone mount myremote: ~/mnt/myremote --vfs-cache-mode full --daemon
```

Per-user, no root required. Good for cloud-backed personal working sets.

**macOS prerequisite — macFUSE, not the rclone binary.** `rclone mount` on macOS
needs a current [macFUSE](https://macfuse.github.io/) (5.x on macOS 26+). The
*binary* choice is **not** the blocker: modern Homebrew rclone (≥ 1.73, the build
this repo installs) ships with `mount` support, same as the official build — so
there's no need to swap install methods. After a macOS major upgrade, an old
macFUSE 4.x kext triggers an "Unsupported macOS Version" dialog and mounts fail;
fix with `brew reinstall --cask macfuse` → reboot → approve the system extension
in System Settings ▸ Privacy & Security. macFUSE is **not** managed by this repo
(it needs a reboot + GUI approval). See
[`pitfalls/macfuse-too-old-unsupported-macos-version-rclone-mount.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/macfuse-too-old-unsupported-macos-version-rclone-mount.md).
On Linux, mount works via the system libfuse — no extra step.

## Storage for containers and K8s

Shared storage often surfaces to workloads via CSI drivers:

- [ceph-csi](https://github.com/ceph/ceph-csi) — CephFS + RBD
- [nfs-subdir-external-provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner) — dynamic PVs from a single NFS export
- [Longhorn](https://longhorn.io) — SUSE / Rancher block storage for K8s (replicated local disks)
- [OpenEBS](https://openebs.io) — per-node local PV + replicated engines
- [JuiceFS CSI](https://juicefs.com/docs/csi/introduction/) — POSIX mount backed by S3

When containers need to share a volume across pods (RWX), you need a shared FS — typically CephFS, NFS, or JuiceFS. RBD and Longhorn are block-level (RWO).

## Related

- [virtualization.md](virtualization.md) — VM disks often live on the same Ceph/ZFS/NFS
- [compute-scheduling.md](compute-scheduling.md) — schedulers assume a shared FS to deliver job inputs/outputs
- [shared-home-identity.md](shared-home-identity.md) — the "everyone's `$HOME` on the NAS" end-to-end pattern
- [docs/tools/containers.md](../tools/containers.md) — container bind mounts and volumes

## Upstream docs

- [Ceph docs](https://docs.ceph.com/en/latest/)
- [BeeGFS docs](https://doc.beegfs.io/)
- [Lustre manual](https://doc.lustre.org/)
- [Samba wiki](https://wiki.samba.org/)
- [NFSv4 on Linux](https://linux-nfs.org/wiki/index.php/Main_Page)
- [Rook (Ceph-on-K8s)](https://rook.io/docs/rook/latest-release/Getting-Started/intro/)

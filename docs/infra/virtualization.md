# Virtualization — VM Managers, Hypervisors, and K8s-Native VMs

Three different tiers that are often confused because they all "run VMs":

1. **Desktop VM managers** — apps you install on your laptop to run a single VM or a handful locally.
2. **Type-1 bare-metal hypervisors** — an operating system you install on dedicated hardware; the host OS *is* the hypervisor.
3. **Cloud-native VM platforms** — VMs scheduled inside Kubernetes, coexisting with pods.

The repo installs OrbStack on macOS (tier 1). Everything else is documented here for when you need to reach outside the laptop.

## Quick answer: OrbStack vs Proxmox vs VMware vs VirtualBox

These are **not** direct competitors — they solve different problems at different scales:

| Tool | Tier | Runs on | Good for |
|------|------|---------|----------|
| [OrbStack](https://orbstack.dev) | Desktop | macOS (as an app) | Laptop containers + lightweight Linux VMs |
| [VirtualBox](https://www.virtualbox.org) | Desktop | macOS / Windows / Linux (as an app) | Cross-platform "classic" desktop VMs; GUI console |
| [VMware Fusion](https://www.vmware.com/products/fusion.html) / [Workstation](https://www.vmware.com/products/workstation-pro.html) | Desktop | macOS / Windows / Linux (as an app) | Desktop VMs with enterprise features, snapshot trees |
| [Proxmox VE](https://www.proxmox.com/en/) | Type-1 | Bare metal (host OS) | Home lab / small-to-medium server fleet, open-source, web UI |
| [VMware ESXi](https://www.vmware.com/products/esxi-and-esx.html) | Type-1 | Bare metal (host OS) | Enterprise vSphere ecosystem, commercial support |

Rule of thumb: if you're choosing between OrbStack and Proxmox, you're comparing apples to orchards. OrbStack runs *on* your Mac; Proxmox runs *as* a server OS on a different machine you access over the network.

## Desktop VM managers

Per-user, on your laptop. Install as a normal app.

| Tool | OS | License | Backend | Notable |
|------|----|---------|---------|---------|
| [OrbStack](https://orbstack.dev) | macOS (Apple Silicon + Intel) | Freemium (free for personal use) | Lightweight macOS virtualization framework | Also runs Docker containers natively; extremely fast boot; low idle RAM |
| [UTM](https://mac.getutm.app) | macOS / iOS | Open source (Apache 2.0) | QEMU | Good for ARM emulation on Intel Mac or x86 on Apple Silicon |
| [VirtualBox](https://www.virtualbox.org) | macOS / Windows / Linux | GPLv3 (with proprietary Extension Pack) | Own hypervisor | Most portable; slow on Apple Silicon (software emulation) |
| [VMware Fusion](https://www.vmware.com/products/fusion.html) | macOS | Free for personal use (post-Broadcom) | VMware's VMX/VMM | Strong Windows guest support; snapshot trees |
| [VMware Workstation](https://www.vmware.com/products/workstation-pro.html) | Windows / Linux | Free for personal use | VMware's VMX/VMM | Windows/Linux equivalent of Fusion |
| [Parallels Desktop](https://www.parallels.com/products/desktop/) | macOS | Commercial | Own hypervisor | Best Windows-on-Mac UX; priciest |
| [Lima](https://lima-vm.io) | macOS / Linux | Apache 2.0 | QEMU / macOS virt framework | Headless Linux VMs; used under the hood by `colima`, `nerdctl` |
| [Tart](https://tart.run) | macOS (Apple Silicon only) | Fair Source | Apple Virtualization.framework | CI-optimized macOS-on-macOS VMs |
| [libvirt + virt-manager](https://virt-manager.org) | Linux | LGPL / GPL | KVM / QEMU | The Linux-native stack; `virsh` CLI; `virt-manager` GUI |
| [GNOME Boxes](https://apps.gnome.org/Boxes/) | Linux | GPLv2+ | libvirt + QEMU | Simplified GUI on top of libvirt |

### Picking one (macOS)

- **Containers + occasional Linux VM** → OrbStack (already installed by this repo)
- **Pure Linux VM workloads, scripted** → Lima (headless, YAML-driven)
- **ARM Linux + x86 emulation mix** → UTM
- **Need to run Windows with good graphics / gaming** → Parallels > VMware Fusion > UTM
- **Portable, cross-team, cheap** → VirtualBox (but expect slow performance on Apple Silicon)

### Picking one (Linux)

- **Default path** → libvirt + virt-manager (install via distro package: `apt install libvirt-daemon-system virt-manager`)
- **Headless / scripted** → `virsh` or Lima
- **Same tool as Windows users** → VirtualBox
- **Commercial features, snapshot trees** → VMware Workstation Pro (free for personal use)

## Type-1 bare-metal hypervisors

These are host operating systems. You install them on dedicated hardware (a server or a spare PC). You then manage VMs from a web UI or CLI. You **do not** install these from Homebrew.

| Tool | License | Governance | Storage | Clustering | Web UI |
|------|---------|------------|---------|------------|--------|
| [Proxmox VE](https://www.proxmox.com/en/) | AGPLv3 | Proxmox Server Solutions | ZFS, LVM, Ceph (built-in), directory | Built-in multi-node | Yes (native) |
| [VMware ESXi](https://www.vmware.com/products/esxi-and-esx.html) | Commercial (Broadcom) | VMware / Broadcom | VMFS, vSAN | via vCenter | via vCenter / Host Client |
| [XCP-ng](https://xcp-ng.org) | GPLv2 | Vates / open source | LVM, NFS, XOSAN | via pool + Xen Orchestra | via [Xen Orchestra](https://xen-orchestra.com) |
| [Harvester](https://harvesterhci.io) | Apache 2.0 | SUSE / Rancher | Longhorn (K8s-native) | K8s-native | Yes |
| [Nutanix CE](https://www.nutanix.com/products/community-edition) | Free (with registration) | Nutanix | Nutanix AOS | HCI cluster | Prism |
| [oVirt](https://www.ovirt.org) | Apache 2.0 | Community (ex-RHV upstream) | GlusterFS, NFS, iSCSI | Yes | oVirt Engine |

### Picking one

- **Home lab, hobby, 1-5 node cluster, open source** → **Proxmox VE**. Debian-based, KVM + LXC, built-in web UI, free clustering, integrates with Ceph for HCI, active community. This is the pragmatic default for "I have an old PC and want to run 4 VMs on it."
- **Enterprise, commercial support, vCenter ecosystem** → VMware ESXi. Expect licensing to bite post-Broadcom acquisition; many orgs are migrating away.
- **Open-source alternative to VMware, mature** → XCP-ng + Xen Orchestra. Xen-based; used by cloud providers.
- **K8s-first org wanting VMs in the same plane** → Harvester (SUSE) or Proxmox + KubeVirt on top.
- **Hyperconverged, turnkey, willing to register** → Nutanix CE.

### What "bare metal" actually means for setup

You boot an ISO on the target hardware and install it as the only OS. After install, you don't typically SSH as a normal user — you hit `https://<host>:8006` (Proxmox) or vCenter / Xen Orchestra. Network, storage, and cluster membership are configured from the web UI. VMs are uploaded as ISOs or cloned from templates.

If your "target hardware" is actually a VM or cloud instance (nested virt), most of these hypervisors work but lose hardware acceleration. Use Proxmox/ESXi on real metal or on servers that expose CPU virt extensions to the guest.

### OrbStack vs Proxmox: the explicit comparison

| Aspect | OrbStack | Proxmox VE |
|--------|----------|------------|
| Install form | macOS app (`brew install --cask orbstack`) | ISO boot on dedicated hardware |
| Runs on | macOS (your Mac) | Bare metal / dedicated VM (a different machine) |
| Primary use case | Dev laptop: containers + occasional quick Linux VM | Server / home lab: long-lived VMs and LXC containers for other users |
| Management UI | Menu bar + local CLI | Web UI at `https://host:8006` |
| Clustering | No (single Mac) | Yes (multi-node cluster, HA, live migration) |
| Storage | Sparse disk file on macOS APFS | ZFS / LVM / Ceph / NFS backends |
| Target audience | One developer | One small team or home-lab operator |

They coexist. Typical setup: OrbStack on your laptop for daily dev, Proxmox on a box under the desk for longer-running services and test clusters.

## Cloud-native VMs on top of Kubernetes

When you already run K8s for pods and need to keep some legacy VMs, don't stand up a separate hypervisor — run them inside K8s:

- [KubeVirt](https://kubevirt.io) — VMs as K8s CRDs, scheduled alongside pods. Same kubectl, same network policies, same storage classes. Production-ready; used by [OpenShift Virtualization](https://www.redhat.com/en/technologies/cloud-computing/openshift/virtualization).
- [Harvester](https://harvesterhci.io) — packaged distribution: OS + K3s + KubeVirt + Longhorn, managed as one cluster; effectively "Proxmox but K8s underneath".

Use these when:

- You already operate K8s and don't want two control planes
- You need to keep an appliance VM (e.g. vendor firewall, legacy Windows app) without adopting vSphere
- You want CSI snapshots, PVCs, and `kubectl get vm` uniformity

Don't use these when you don't already have K8s — they're not a simpler on-ramp than Proxmox.

## Related

- [docs/tools/containers.md](../tools/containers.md) — OrbStack's container side (this doc covers its VM side)
- [shared-storage.md](shared-storage.md) — backing store for VM disks (Ceph RBD, NFS, iSCSI, ZFS)
- [compute-scheduling.md](compute-scheduling.md) — VM placement and HA in a Proxmox or vSphere cluster
- [docs/tools/infrastructure-as-code.md](../tools/infrastructure-as-code.md) — Terraform/OpenTofu providers for Proxmox ([`Telmate/proxmox`](https://registry.terraform.io/providers/Telmate/proxmox/latest)), [vSphere](https://registry.terraform.io/providers/hashicorp/vsphere/latest), [libvirt](https://registry.terraform.io/providers/dmacvicar/libvirt/latest)

## Upstream docs

- [Proxmox VE Admin Guide](https://pve.proxmox.com/pve-docs/)
- [VMware ESXi docs](https://techdocs.broadcom.com/us/en/vmware-cis/vsphere.html)
- [XCP-ng docs](https://docs.xcp-ng.org/)
- [KubeVirt user guide](https://kubevirt.io/user-guide/)
- [libvirt Wiki](https://wiki.libvirt.org/)
- [OrbStack docs](https://docs.orbstack.dev/)

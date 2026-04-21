# Compute Scheduling — Multi-User CPU / GPU / VM Allocation

The core problem: multiple users want to run jobs; the cluster has finite CPUs, GPUs, and RAM; you want automatic, fair allocation without everyone emailing "who's using the A100?"

Four distinct eras / philosophies of schedulers, each still in active use for different reasons.

## Quick answer

| Scenario | Pick |
|----------|------|
| ML / HPC research lab, 10-100 users, batch GPU jobs | [SLURM](#slurm) |
| Modern containerized workloads, multi-tenant product | [Kubernetes](#kubernetes) + [Kueue](https://kueue.sigs.k8s.io) or [Volcano](https://volcano.sh) |
| Small team, mixed containers + VMs + raw binaries, simpler than K8s | [Nomad](#nomad) |
| Pure VM placement in a Proxmox cluster | [Proxmox HA](https://pve.proxmox.com/wiki/High_Availability) (built-in) |
| Private cloud / IaaS | [OpenStack Nova](#openstack-nova) |
| Distributed Python / ML jobs without a full scheduler | [Ray](https://www.ray.io) / [Dask](https://www.dask.org) |
| Legacy Hadoop / Spark-on-YARN stack | [YARN](#yarn) |

## The landscape

| Scheduler | License | Era | Granularity | Typical users | Shared FS? |
|-----------|---------|-----|-------------|---------------|------------|
| [SLURM](https://slurm.schedmd.com) | GPLv2 | HPC (1990s-now) | Node / core / GPU, batch job | Research labs, universities | Yes (BeeGFS/Lustre/NFS) |
| [HTCondor](https://htcondor.org) | Apache 2.0 | HPC / HTC (1988-now) | Job slot, opportunistic | HEP physics, pooled desktops | Optional |
| [OpenPBS](https://www.openpbs.org) / [PBS Pro](https://www.altair.com/pbs-professional) | AGPLv3 / commercial | HPC (1990s) | Batch job | Legacy HPC sites | Yes |
| [Oracle Grid Engine / Son of Grid Engine](http://gridscheduler.sourceforge.net) | SISSL | HPC | Batch job | Legacy sites | Yes |
| [YARN](https://hadoop.apache.org/docs/stable/hadoop-yarn/hadoop-yarn-site/YARN.html) | Apache 2.0 | Hadoop (2012) | Container (not Docker) | Hadoop/Spark/Hive | HDFS |
| [Apache Mesos](https://mesos.apache.org) | Apache 2.0 | Datacenter (2010) | CPU/RAM fraction | Historically Twitter; fading | — |
| [Kubernetes](https://kubernetes.io) | Apache 2.0 | Cloud-native (2014-now) | Pod | Everyone | Optional (PVCs) |
| [Nomad](https://www.nomadproject.io) | BUSL | Cloud-native (2015) | Job (container/VM/exec) | HashiCorp shops | Optional |
| [OpenStack Nova](https://docs.openstack.org/nova/latest/) | Apache 2.0 | IaaS (2010) | VM | Telcos, research clouds | Yes (Cinder/Swift/Manila) |
| [Ray](https://www.ray.io) | Apache 2.0 | App-level (2017) | Task / actor | ML practitioners | — |
| [Dask](https://www.dask.org) | BSD-3 | App-level (2015) | Task graph | Data scientists | — |

## Per-system notes

### SLURM

The de facto HPC / ML research scheduler.

- **Unit**: batch job submitted via `sbatch job.sh`. Each job declares resources (`--cpus-per-task`, `--mem`, `--gres=gpu:a100:2`, `--time`). Interactive jobs via `srun` or `salloc`.
- **Fair share**: configured via accounts, QOS, and the multi-factor priority plugin. Can cap users/groups, enforce GPU-hour budgets.
- **Topology**: controller (`slurmctld`) + accounting DB (`slurmdbd`, usually MySQL) + node agents (`slurmd`).
- **Integrates with**: BeeGFS/Lustre for data, FreeIPA for identity, module systems (Lmod) for software environments, [Open OnDemand](https://openondemand.org) for a web portal.
- **Sweet spot**: 5-5000 nodes, GPU training queues, HPC simulations. If users talk about "partitions" and "sbatch", they want SLURM.

Example submission:

```bash
#!/bin/bash
#SBATCH --job-name=train
#SBATCH --account=ml-lab
#SBATCH --partition=gpu
#SBATCH --gres=gpu:a100:2
#SBATCH --cpus-per-task=16
#SBATCH --mem=128G
#SBATCH --time=24:00:00
#SBATCH --output=logs/%x-%j.out

srun python train.py
```

### Kubernetes

Pods as the unit, but "pod" here is "one or more containers scheduled together." Out of the box, multi-tenancy is coarse:

- **Namespaces** isolate API objects per team.
- **ResourceQuota** caps total CPU/memory per namespace.
- **LimitRange** sets per-container defaults / max.
- **PriorityClass** + preemption handles priority.

For actual batch / fair-share scheduling, add one of these:

- [Kueue](https://kueue.sigs.k8s.io) — Kubernetes-native job queue; ClusterQueue / LocalQueue / ResourceFlavor abstractions; designed to handle the SLURM-style "wait until my quota has room" semantics. Part of SIG Scheduling.
- [Volcano](https://volcano.sh) — CNCF project; stronger for gang scheduling (MPI, distributed training); used by Huawei, Baidu.
- [YuniKorn](https://yunikorn.apache.org) — Apache; queue hierarchies similar to YARN.

GPU scheduling:

- [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html) — installs drivers, device plugin, DCGM exporter.
- [MIG](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/) for A100/H100 partitioning.
- [KAI Scheduler](https://github.com/NVIDIA/KAI-Scheduler) (from Run:ai / NVIDIA) — GPU-aware fair-share scheduling.

VMs on K8s: [KubeVirt](https://kubevirt.io) — see [virtualization.md](virtualization.md#cloud-native-vms-on-top-of-kubernetes).

### Nomad

HashiCorp's scheduler. Same cluster can run Docker, raw binaries, Java JARs, or QEMU VMs as first-class "drivers."

- Simpler mental model than K8s: one binary (`nomad`), jobs declared in HCL.
- Integrates naturally with [Consul](https://www.consul.io) (service discovery) and [Vault](https://www.vaultproject.io) (secrets).
- **License note**: Nomad moved to BUSL 1.1 in Aug 2023, like Terraform. Fork: [OpenBao](https://openbao.org) exists for Vault but no equivalent Nomad fork has gained traction yet.
- **Sweet spot**: teams who want less K8s ceremony, or need to schedule non-container workloads (static binaries, VMs) alongside containers.

### HTCondor

Predates almost everything else. Originally for "steal idle desktop cycles" (HTC = High-Throughput Computing). Still heavily used in HEP (CERN, Fermilab).

- Philosophy: best-effort, checkpointing, opportunistic.
- Less relevant for tight-coupled HPC (use SLURM) or cloud-native (use K8s).
- Use if you're in a scientific computing context that already runs it.

### OpenPBS / PBS Pro / Torque / Grid Engine

Older batch schedulers still present at some HPC sites. Feature-wise comparable to SLURM. For greenfield deployments today, SLURM is the default choice; these are mostly "keep what you have" systems.

### YARN

Hadoop's scheduler. Relevant if:

- You run Hadoop, Spark-on-YARN, Hive, Flink on YARN.
- Otherwise, not relevant. Spark on K8s is the modern replacement.

### Mesos

Historically important (Twitter, Airbnb, Apple Siri). Largely superseded by Kubernetes after the [D2iQ / Mesosphere pivot](https://d2iq.com). Don't pick it for new deployments.

### OpenStack Nova

The compute service in OpenStack. If you're building a **private IaaS** (your own EC2 equivalent), Nova is the VM-scheduling brain. Paired with Neutron (network), Cinder (block), Keystone (identity), Swift (object), Glance (images).

- **Scale**: telco, research cloud, large enterprise private cloud.
- **Complexity**: high. Not a weekend project.
- Alternatives at smaller scale: [Proxmox cluster](https://pve.proxmox.com/wiki/High_Availability), [OpenNebula](https://opennebula.io).

### Proxmox HA

If your only "scheduling" need is "place this VM on a node with free RAM, migrate away if the host dies" — Proxmox's built-in HA and affinity rules are enough. No separate scheduler to install.

### Ray and Dask

Application-level distributed compute. Not cluster schedulers themselves, but fill the role for Python / ML users who don't want to write SLURM scripts.

- [Ray](https://www.ray.io) — tasks + actors + libraries (Ray Train, Ray Tune, Ray Serve). Runs standalone, on K8s ([KubeRay](https://github.com/ray-project/kuberay)), or submits to SLURM.
- [Dask](https://www.dask.org) — task graphs from pandas/numpy-like APIs. Same deployment options.

Use as a **layer on top** of another scheduler: Ray/Dask spins up a cluster inside a SLURM allocation or a K8s namespace, then your Python code just sees a pool of workers.

## Multi-user fair allocation — recurring concepts

Regardless of which scheduler you pick, these concepts recur:

| Concept | What it does | SLURM | K8s (Kueue) | Nomad |
|---------|--------------|-------|-------------|-------|
| **Queue / partition** | Logical pool of nodes | Partition | ClusterQueue | Namespace + constraints |
| **Account / project** | Whose budget this job charges | Account | WorkloadPriorityClass | Namespace |
| **QOS / priority** | Ordering within a queue | QOS | WorkloadPriorityClass | Priority |
| **Quota** | Hard cap per user/group | Association limits | ResourceQuota + ClusterQueue nominalQuota | Quota spec |
| **Fair share** | Proportional past-usage decay | Multi-factor priority | (Kueue cohorts) | (Nomad Enterprise) |
| **Preemption** | Kick low-pri jobs to make room | `--requeue` + PriorityTier | PriorityClass + preemption | Priority |
| **Backfill** | Fill gaps with shorter jobs | Built-in | — | — |
| **GPU sharing** | Let 4 jobs share one GPU | cgroups + MIG / MPS | MIG + GPU Operator | Bin-packing + MPS |

## Picking a stack

Three realistic "house" configurations for a dotfiles-shaped homelab/lab cluster:

1. **ML research lab (10-50 users, GPU-heavy)**
   - Hardware: Proxmox or bare-metal Ubuntu
   - Scheduler: SLURM
   - Storage: BeeGFS or Lustre for `/scratch`, NFS for `/home`
   - Identity: FreeIPA (see [shared-home-identity.md](shared-home-identity.md))
   - UI: Open OnDemand web portal

2. **Cloud-native product team (mixed services + batch)**
   - Platform: Kubernetes (Rancher / RKE2 / vanilla)
   - Batch: Kueue or Volcano
   - Storage: Rook-Ceph (see [shared-storage.md](shared-storage.md#cephfs))
   - Identity: OIDC (Dex / Keycloak) + RBAC
   - GPU: NVIDIA GPU Operator + MIG

3. **HashiCorp-friendly team**
   - Scheduler: Nomad
   - Service discovery: Consul
   - Secrets: Vault
   - Provisioning: Terraform / OpenTofu (see [docs/tools/infrastructure-as-code.md](../tools/infrastructure-as-code.md))
   - Storage: whatever works (NFS, Ceph, etc.)

## Related

- [virtualization.md](virtualization.md) — what runs under the scheduler (VMs or bare metal)
- [shared-storage.md](shared-storage.md) — jobs need a shared FS for inputs/outputs/checkpoints
- [shared-home-identity.md](shared-home-identity.md) — users' UIDs must be consistent across compute nodes
- [docs/tools/infrastructure-as-code.md](../tools/infrastructure-as-code.md) — Terraform/OpenTofu providers for K8s, Nomad, OpenStack, Proxmox

## Upstream docs

- [SLURM documentation](https://slurm.schedmd.com/documentation.html)
- [Kubernetes scheduling](https://kubernetes.io/docs/concepts/scheduling-eviction/)
- [Kueue concepts](https://kueue.sigs.k8s.io/docs/concepts/)
- [Volcano docs](https://volcano.sh/en/docs/)
- [Nomad learn guides](https://developer.hashicorp.com/nomad/tutorials)
- [HTCondor manual](https://htcondor.readthedocs.io/en/latest/)
- [Open OnDemand](https://osc.github.io/ood-documentation/latest/)
- [OpenStack Nova docs](https://docs.openstack.org/nova/latest/)

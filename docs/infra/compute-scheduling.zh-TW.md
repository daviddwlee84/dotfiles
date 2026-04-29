# 運算排程 —— 多使用者 CPU / GPU / VM 配置

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

核心問題：多位使用者都想跑工作；叢集 (cluster) 上的 CPU、GPU、RAM 有限；你想要自動且公平的配置，避免每個人都來信問「現在誰在用 A100？」

排程器有四個截然不同的世代 / 哲學，每一種至今仍因不同理由活躍使用中。

## 快速答案

| 情境 | 選擇 |
|----------|------|
| ML / HPC 研究實驗室，10-100 位使用者，批次 GPU 工作 | [SLURM](#slurm) |
| 現代容器化工作負載、多租戶 (multi-tenant) 產品 | [Kubernetes](#kubernetes) + [Kueue](https://kueue.sigs.k8s.io) 或 [Volcano](https://volcano.sh) |
| 小團隊，混合容器 + VM + 原生執行檔，比 K8s 簡單 | [Nomad](#nomad) |
| 純粹在 Proxmox 叢集中安排 VM | [Proxmox HA](https://pve.proxmox.com/wiki/High_Availability)（內建） |
| 私有雲 / IaaS | [OpenStack Nova](#openstack-nova) |
| 不想動用整套排程器的分散式 Python / ML 工作 | [Ray](https://www.ray.io) / [Dask](https://www.dask.org) |
| 舊有 Hadoop / Spark-on-YARN 技術堆疊 | [YARN](#yarn) |

## 整體版圖

| 排程器 | 授權 | 世代 | 粒度 | 典型使用者 | 共享 FS？ |
|-----------|---------|-----|-------------|---------------|------------|
| [SLURM](https://slurm.schedmd.com) | GPLv2 | HPC（1990 年代至今） | 節點 / 核心 / GPU、批次工作 | 研究實驗室、大學 | 是（BeeGFS/Lustre/NFS） |
| [HTCondor](https://htcondor.org) | Apache 2.0 | HPC / HTC（1988 年至今） | 工作槽位、機會式 | HEP 物理、桌面池 | 選用 |
| [OpenPBS](https://www.openpbs.org) / [PBS Pro](https://www.altair.com/pbs-professional) | AGPLv3 / 商業 | HPC（1990 年代） | 批次工作 | 老牌 HPC 站台 | 是 |
| [Oracle Grid Engine / Son of Grid Engine](http://gridscheduler.sourceforge.net) | SISSL | HPC | 批次工作 | 老牌站台 | 是 |
| [YARN](https://hadoop.apache.org/docs/stable/hadoop-yarn/hadoop-yarn-site/YARN.html) | Apache 2.0 | Hadoop（2012） | Container（非 Docker） | Hadoop/Spark/Hive | HDFS |
| [Apache Mesos](https://mesos.apache.org) | Apache 2.0 | Datacenter（2010） | CPU/RAM 比例 | 過去由 Twitter 採用；逐漸式微 | — |
| [Kubernetes](https://kubernetes.io) | Apache 2.0 | Cloud-native（2014 至今） | Pod | 所有人 | 選用 (PVCs) |
| [Nomad](https://www.nomadproject.io) | BUSL | Cloud-native（2015） | Job (container/VM/exec) | HashiCorp 派 | 選用 |
| [OpenStack Nova](https://docs.openstack.org/nova/latest/) | Apache 2.0 | IaaS（2010） | VM | 電信業、研究雲 | 是（Cinder/Swift/Manila） |
| [Ray](https://www.ray.io) | Apache 2.0 | 應用層（2017） | Task / actor | ML 工作者 | — |
| [Dask](https://www.dask.org) | BSD-3 | 應用層（2015） | Task graph | 資料科學家 | — |

## 各系統說明

### SLURM

事實上的 HPC / ML 研究排程器。

- **單位**：透過 `sbatch job.sh` 提交的批次工作。每份工作宣告其資源需求 (`--cpus-per-task`、`--mem`、`--gres=gpu:a100:2`、`--time`)。互動式工作則透過 `srun` 或 `salloc`。
- **公平共享 (fair share)**：透過 account、QOS 與 multi-factor priority plugin 設定。可限制使用者/群組、強制 GPU 工時預算。
- **拓撲**：controller (`slurmctld`) + 計帳資料庫 (`slurmdbd`，通常為 MySQL) + 節點代理 (`slurmd`)。
- **整合對象**：BeeGFS/Lustre 用於資料、FreeIPA 用於身分、模組系統 (Lmod) 用於軟體環境、[Open OnDemand](https://openondemand.org) 提供 Web 入口。
- **甜蜜點**：5-5000 個節點、GPU 訓練佇列、HPC 模擬。如果使用者談到「partition」與「sbatch」，他們要的是 SLURM。

提交範例：

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

以 Pod 為單位，但這裡的 「pod」是「一起被排程的一個或多個容器」。預設情況下，多租戶機制粗略：

- **Namespace** 將每個團隊的 API 物件隔離。
- **ResourceQuota** 設定每個 namespace 的 CPU/memory 總上限。
- **LimitRange** 設定每個 container 的預設值 / 上限。
- **PriorityClass** + preemption 處理優先順序。

要做真正的批次 / 公平共享排程，需加裝以下其中之一：

- [Kueue](https://kueue.sigs.k8s.io) —— Kubernetes 原生的工作佇列；包含 ClusterQueue / LocalQueue / ResourceFlavor 抽象；設計上能處理 SLURM 風格的「等到我的 quota 有空位才執行」語意。為 SIG Scheduling 的一部分。
- [Volcano](https://volcano.sh) —— CNCF 專案；對 gang scheduling（MPI、分散式訓練）支援較強；華為、百度採用。
- [YuniKorn](https://yunikorn.apache.org) —— Apache 專案；佇列階層類似 YARN。

GPU 排程：

- [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html) —— 安裝驅動程式、device plugin、DCGM exporter。
- [MIG](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/) 用於 A100/H100 切分。
- [KAI Scheduler](https://github.com/NVIDIA/KAI-Scheduler)（來自 Run:ai / NVIDIA）—— 具 GPU 感知能力的公平共享排程。

K8s 上的 VM：[KubeVirt](https://kubevirt.io) —— 請見 [virtualization.md](virtualization.md#cloud-native-vms-on-top-of-kubernetes)。

### Nomad

HashiCorp 的排程器。同一個叢集可以將 Docker、原生執行檔、Java JAR 或 QEMU VM 視為一等公民的「driver」來執行。

- 心智模型比 K8s 簡單：一個 binary (`nomad`)、用 HCL 宣告的工作。
- 自然整合 [Consul](https://www.consul.io)（服務探索）與 [Vault](https://www.vaultproject.io)（祕密管理）。
- **授權注意**：Nomad 在 2023 年 8 月轉為 BUSL 1.1，跟 Terraform 一樣。Fork：[OpenBao](https://openbao.org) 是 Vault 的替代品，但 Nomad 目前還沒有具影響力的 fork。
- **甜蜜點**：想少一點 K8s 儀式感的團隊，或需要將非容器工作負載（靜態 binary、VM）與容器一起排程的場景。

### HTCondor

幾乎比所有排程器都早出現。最初是為了「偷用閒置桌面 CPU」（HTC = High-Throughput Computing）。在 HEP（CERN、Fermilab）仍大量使用。

- 哲學：盡力 (best-effort)、checkpoint、機會式。
- 對緊耦合 HPC 較不適用（請用 SLURM），對 cloud-native 也不適用（請用 K8s）。
- 適用於已在使用它的科學運算情境。

### OpenPBS / PBS Pro / Torque / Grid Engine

仍存在於部分 HPC 站台的老牌批次排程器。功能上與 SLURM 相當。今日全新部署的預設選擇是 SLURM；這些屬於「沿用既有」系統。

### YARN

Hadoop 的排程器。在以下情況相關：

- 你跑 Hadoop、Spark-on-YARN、Hive、Flink on YARN。
- 否則就無關了。Spark on K8s 是現代替代方案。

### Mesos

歷史上重要（Twitter、Airbnb、Apple Siri）。在 [D2iQ / Mesosphere 轉型](https://d2iq.com)後大致被 Kubernetes 取代。新部署不要選它。

### OpenStack Nova

OpenStack 中的運算服務。如果你要打造**私有 IaaS**（自家版本的 EC2），Nova 就是 VM 排程的大腦。搭配 Neutron（網路）、Cinder（block）、Keystone（身分）、Swift（物件）、Glance（映像檔）。

- **規模**：電信業、研究雲、大型企業私有雲。
- **複雜度**：高。不是週末玩玩的專案。
- 較小規模的替代方案：[Proxmox cluster](https://pve.proxmox.com/wiki/High_Availability)、[OpenNebula](https://opennebula.io)。

### Proxmox HA

如果你的「排程」需求僅止於「把這台 VM 放到還有空閒 RAM 的節點上、主機掛掉時遷走」 —— Proxmox 內建的 HA 與 affinity 規則就夠了。不需另外安裝排程器。

### Ray 與 Dask

應用層級的分散式運算。本身並非叢集排程器，但對於不想寫 SLURM 腳本的 Python / ML 使用者來說，能扮演類似角色。

- [Ray](https://www.ray.io) —— task + actor + 函式庫 (Ray Train、Ray Tune、Ray Serve)。可獨立執行、跑在 K8s 上 ([KubeRay](https://github.com/ray-project/kuberay))，或提交到 SLURM。
- [Dask](https://www.dask.org) —— 從 pandas/numpy 風格 API 產生的 task graph。同樣的部署選項。

通常作為其他排程器**之上的一層**：Ray/Dask 在 SLURM 配置好的資源裡或 K8s namespace 內啟動一個叢集，然後你的 Python 程式碼只看到一個 worker 池。

## 多使用者公平配置 —— 反覆出現的概念

不論你選哪個排程器，這些概念都會反覆出現：

| 概念 | 作用 | SLURM | K8s (Kueue) | Nomad |
|---------|--------------|-------|-------------|-------|
| **Queue / partition** | 邏輯上的節點池 | Partition | ClusterQueue | Namespace + constraints |
| **Account / project** | 此工作扣誰的預算 | Account | WorkloadPriorityClass | Namespace |
| **QOS / priority** | 佇列內的排序 | QOS | WorkloadPriorityClass | Priority |
| **Quota** | 對使用者/群組的硬上限 | Association limits | ResourceQuota + ClusterQueue nominalQuota | Quota spec |
| **Fair share** | 依過去使用量按比例衰減 | Multi-factor priority | (Kueue cohorts) | (Nomad Enterprise) |
| **Preemption** | 踢掉低優先工作以挪出空間 | `--requeue` + PriorityTier | PriorityClass + preemption | Priority |
| **Backfill** | 用較短的工作填補空檔 | 內建 | — | — |
| **GPU sharing** | 讓 4 份工作共用一張 GPU | cgroups + MIG / MPS | MIG + GPU Operator | Bin-packing + MPS |

## 挑選技術堆疊

針對 dotfiles 等級的家用實驗室 / 研究叢集，三套實際可行的「房屋」配置：

1. **ML 研究實驗室（10-50 位使用者，GPU 為主）**
   - 硬體：Proxmox 或裸機 Ubuntu
   - 排程器：SLURM
   - 儲存：BeeGFS 或 Lustre 用於 `/scratch`、NFS 用於 `/home`
   - 身分：FreeIPA（請見 [shared-home-identity.md](shared-home-identity.md)）
   - UI：Open OnDemand 網頁入口

2. **雲原生產品團隊（混合服務 + 批次）**
   - 平台：Kubernetes (Rancher / RKE2 / vanilla)
   - 批次：Kueue 或 Volcano
   - 儲存：Rook-Ceph（請見 [shared-storage.md](shared-storage.md#cephfs)）
   - 身分：OIDC (Dex / Keycloak) + RBAC
   - GPU：NVIDIA GPU Operator + MIG

3. **HashiCorp 風格的團隊**
   - 排程器：Nomad
   - 服務探索：Consul
   - 祕密管理：Vault
   - 佈建：Terraform / OpenTofu（請見 [docs/tools/infrastructure-as-code.md](../tools/infrastructure-as-code.md)）
   - 儲存：能用就好（NFS、Ceph 等）

## 相關連結

- [virtualization.md](virtualization.md) —— 排程器底下跑什麼（VM 或裸機）
- [shared-storage.md](shared-storage.md) —— 工作需要共享 FS 來放輸入/輸出/checkpoint
- [shared-home-identity.md](shared-home-identity.md) —— 跨運算節點的使用者 UID 必須一致
- [docs/tools/infrastructure-as-code.md](../tools/infrastructure-as-code.md) —— K8s、Nomad、OpenStack、Proxmox 的 Terraform/OpenTofu provider

## 上游文件

- [SLURM documentation](https://slurm.schedmd.com/documentation.html)
- [Kubernetes scheduling](https://kubernetes.io/docs/concepts/scheduling-eviction/)
- [Kueue concepts](https://kueue.sigs.k8s.io/docs/concepts/)
- [Volcano docs](https://volcano.sh/en/docs/)
- [Nomad learn guides](https://developer.hashicorp.com/nomad/tutorials)
- [HTCondor manual](https://htcondor.readthedocs.io/en/latest/)
- [Open OnDemand](https://osc.github.io/ood-documentation/latest/)
- [OpenStack Nova docs](https://docs.openstack.org/nova/latest/)

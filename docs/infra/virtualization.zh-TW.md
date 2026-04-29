# 虛擬化 —— VM 管理工具、Hypervisor 與 K8s 原生 VM

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

三個層級因為都「跑 VM」而常被混淆：

1. **桌面 VM 管理工具**：你裝在筆電上、用來在本機跑單一或少數 VM 的應用程式。
2. **Type-1 裸機 hypervisor**：你直接安裝在專屬硬體上的作業系統；主機作業系統*就是*hypervisor。
3. **雲原生 VM 平台**：在 Kubernetes 內排程、與 pod 共存的 VM。

本 repo 在 macOS 上安裝 OrbStack（第 1 層）。其他都記錄在這裡，作為你需要超出筆電範圍時的參考。

## 快速答案：OrbStack 與 Proxmox 與 VMware 與 VirtualBox

它們**並非**直接競爭對手 —— 它們在不同規模解決不同問題：

| 工具 | 層級 | 跑在哪 | 適合什麼 |
|------|------|---------|----------|
| [OrbStack](https://orbstack.dev) | 桌面 | macOS（作為應用程式） | 筆電上的容器 + 輕量 Linux VM |
| [VirtualBox](https://www.virtualbox.org) | 桌面 | macOS / Windows / Linux（作為應用程式） | 跨平台「經典」桌面 VM；GUI console |
| [VMware Fusion](https://www.vmware.com/products/fusion.html) / [Workstation](https://www.vmware.com/products/workstation-pro.html) | 桌面 | macOS / Windows / Linux（作為應用程式） | 具企業功能、快照樹的桌面 VM |
| [Proxmox VE](https://www.proxmox.com/en/) | Type-1 | 裸機（主機作業系統） | 家用實驗室 / 中小型伺服器機隊、開源、網頁 UI |
| [VMware ESXi](https://www.vmware.com/products/esxi-and-esx.html) | Type-1 | 裸機（主機作業系統） | 企業 vSphere 生態系、商業支援 |

通則：如果你在 OrbStack 與 Proxmox 之間做選擇，那是拿蘋果跟整片果園比較。OrbStack 跑*在*你的 Mac 上；Proxmox 則是跑在另一台機器上、由你透過網路存取的*伺服器*作業系統。

## 桌面 VM 管理工具

依使用者、在你的筆電上。當作一般應用程式安裝。

| 工具 | 作業系統 | 授權 | 後端 | 重點 |
|------|----|---------|---------|---------|
| [OrbStack](https://orbstack.dev) | macOS（Apple Silicon + Intel） | Freemium（個人使用免費） | 輕量 macOS virtualization framework | 同時原生跑 Docker container；啟動極快；閒置 RAM 占用低 |
| [UTM](https://mac.getutm.app) | macOS / iOS | 開源 (Apache 2.0) | QEMU | 適合在 Intel Mac 模擬 ARM、或在 Apple Silicon 模擬 x86 |
| [VirtualBox](https://www.virtualbox.org) | macOS / Windows / Linux | GPLv3（含專屬 Extension Pack） | 自家 hypervisor | 最跨平台；在 Apple Silicon 上慢（軟體模擬） |
| [VMware Fusion](https://www.vmware.com/products/fusion.html) | macOS | 個人使用免費（後 Broadcom 時代） | VMware 的 VMX/VMM | Windows guest 支援強；快照樹 |
| [VMware Workstation](https://www.vmware.com/products/workstation-pro.html) | Windows / Linux | 個人使用免費 | VMware 的 VMX/VMM | Windows/Linux 上等同 Fusion |
| [Parallels Desktop](https://www.parallels.com/products/desktop/) | macOS | 商業 | 自家 hypervisor | Windows-on-Mac 體驗最佳；最貴 |
| [Lima](https://lima-vm.io) | macOS / Linux | Apache 2.0 | QEMU / macOS virt framework | Headless Linux VM；`colima`、`nerdctl` 底下使用它 |
| [Tart](https://tart.run) | macOS（僅 Apple Silicon） | Fair Source | Apple Virtualization.framework | 為 CI 最佳化的 macOS-on-macOS VM |
| [libvirt + virt-manager](https://virt-manager.org) | Linux | LGPL / GPL | KVM / QEMU | Linux 原生堆疊；`virsh` CLI；`virt-manager` GUI |
| [GNOME Boxes](https://apps.gnome.org/Boxes/) | Linux | GPLv2+ | libvirt + QEMU | 建立在 libvirt 之上的簡化 GUI |

### 挑選一個（macOS）

- **容器 + 偶爾的 Linux VM** → OrbStack（已由本 repo 安裝）
- **純 Linux VM 工作負載、可腳本化** → Lima（headless、YAML 驅動）
- **ARM Linux + x86 模擬混合** → UTM
- **要跑 Windows 且圖形 / 遊戲表現要好** → Parallels > VMware Fusion > UTM
- **跨平台、跨團隊、便宜** → VirtualBox（但在 Apple Silicon 上效能會慢）

### 挑選一個（Linux）

- **預設路徑** → libvirt + virt-manager（透過發行版套件安裝：`apt install libvirt-daemon-system virt-manager`）
- **Headless / 可腳本化** → `virsh` 或 Lima
- **與 Windows 使用者相同工具** → VirtualBox
- **商業功能、快照樹** → VMware Workstation Pro（個人使用免費）

## Type-1 裸機 hypervisor

這些是主機作業系統。安裝在專屬硬體（伺服器或備用 PC）上。然後透過網頁 UI 或 CLI 管理 VM。**不要**用 Homebrew 安裝它們。

| 工具 | 授權 | 治理 | 儲存 | 叢集化 | 網頁 UI |
|------|---------|------------|---------|------------|--------|
| [Proxmox VE](https://www.proxmox.com/en/) | AGPLv3 | Proxmox Server Solutions | ZFS、LVM、Ceph（內建）、目錄 | 內建多節點 | 是（原生） |
| [VMware ESXi](https://www.vmware.com/products/esxi-and-esx.html) | 商業 (Broadcom) | VMware / Broadcom | VMFS、vSAN | 透過 vCenter | 透過 vCenter / Host Client |
| [XCP-ng](https://xcp-ng.org) | GPLv2 | Vates / 開源 | LVM、NFS、XOSAN | 透過 pool + Xen Orchestra | 透過 [Xen Orchestra](https://xen-orchestra.com) |
| [Harvester](https://harvesterhci.io) | Apache 2.0 | SUSE / Rancher | Longhorn (K8s 原生) | K8s 原生 | 是 |
| [Nutanix CE](https://www.nutanix.com/products/community-edition) | 免費（需註冊） | Nutanix | Nutanix AOS | HCI 叢集 | Prism |
| [oVirt](https://www.ovirt.org) | Apache 2.0 | 社群（前 RHV 上游） | GlusterFS、NFS、iSCSI | 是 | oVirt Engine |

### 挑選一個

- **家用實驗室、業餘、1-5 節點叢集、開源** → **Proxmox VE**。基於 Debian、KVM + LXC、內建網頁 UI、免費叢集化、整合 Ceph 做 HCI、社群活躍。對「我有一台舊 PC，想在上面跑 4 個 VM」這種需求是務實預設。
- **企業、商業支援、vCenter 生態系** → VMware ESXi。Broadcom 收購後授權問題會卡你；許多組織正在轉移。
- **VMware 的開源替代品、成熟** → XCP-ng + Xen Orchestra。基於 Xen；雲端供應商使用。
- **K8s 為主的組織想把 VM 放到同一個平面** → Harvester（SUSE）或 Proxmox + KubeVirt 疊上去。
- **Hyperconverged、整套裝好、願意註冊** → Nutanix CE。

### 「裸機」實際上對安裝意味著什麼

你在目標硬體上開機 ISO，把它當成唯一的作業系統安裝。安裝後通常不是以一般使用者 SSH 登入 —— 你會打開 `https://<host>:8006`（Proxmox）或 vCenter / Xen Orchestra。網路、儲存與叢集成員都從網頁 UI 設定。VM 以 ISO 形式上傳或從 template clone 而來。

如果你的「目標硬體」其實是 VM 或雲端 instance（巢狀虛擬化），多數這類 hypervisor 還是能運作但會失去硬體加速。請在實體裸機，或在能將 CPU 虛擬化擴充功能曝露給 guest 的伺服器上跑 Proxmox/ESXi。

### OrbStack 與 Proxmox：明確對照

| 面向 | OrbStack | Proxmox VE |
|--------|----------|------------|
| 安裝形式 | macOS app（`brew install --cask orbstack`） | 在專屬硬體上開機 ISO |
| 跑在 | macOS（你的 Mac） | 裸機 / 專屬 VM（另一台機器） |
| 主要用途 | 開發筆電：容器 + 偶爾快速開個 Linux VM | 伺服器 / 家用實驗室：給其他使用者用的長期 VM 與 LXC 容器 |
| 管理 UI | 選單列 + 本機 CLI | `https://host:8006` 上的網頁 UI |
| 叢集化 | 否（單一 Mac） | 是（多節點叢集、HA、live migration） |
| 儲存 | macOS APFS 上的 sparse 磁碟檔 | ZFS / LVM / Ceph / NFS 後端 |
| 目標對象 | 一位開發者 | 一個小團隊或家用實驗室操作者 |

兩者可共存。典型配置：在筆電上用 OrbStack 做日常開發、在桌下放一台 Proxmox 跑長期服務與測試叢集。

## Kubernetes 之上的雲原生 VM

當你已經為 pod 跑 K8s，又需要保留某些舊 VM 時，不要另立一套 hypervisor —— 把它們跑在 K8s 內：

- [KubeVirt](https://kubevirt.io) —— 把 VM 當作 K8s CRD，與 pod 一同排程。同一份 kubectl、同一份 network policy、同一份 storage class。已可上 production；[OpenShift Virtualization](https://www.redhat.com/en/technologies/cloud-computing/openshift/virtualization) 採用。
- [Harvester](https://harvesterhci.io) —— 包好的發行版：OS + K3s + KubeVirt + Longhorn，作為單一叢集管理；實際上是「Proxmox 但底下是 K8s」。

下列情境適合用：

- 你已經在營運 K8s，不想要兩套 control plane
- 你需要保留一台 appliance VM（例如廠商的 firewall、舊版 Windows 應用），又不想引進 vSphere
- 你想要 CSI snapshot、PVC、`kubectl get vm` 一致性

下列情境不適合：你還沒有 K8s —— 它們不是比 Proxmox 更簡單的入門選擇。

## 相關連結

- [docs/tools/containers.md](../tools/containers.md) —— OrbStack 的容器側（本文件涵蓋其 VM 側）
- [shared-storage.md](shared-storage.md) —— VM 磁碟的後端儲存（Ceph RBD、NFS、iSCSI、ZFS）
- [compute-scheduling.md](compute-scheduling.md) —— Proxmox 或 vSphere 叢集中的 VM 配置與 HA
- [docs/tools/infrastructure-as-code.md](../tools/infrastructure-as-code.md) —— Proxmox 的 Terraform/OpenTofu provider ([`Telmate/proxmox`](https://registry.terraform.io/providers/Telmate/proxmox/latest))、[vSphere](https://registry.terraform.io/providers/hashicorp/vsphere/latest)、[libvirt](https://registry.terraform.io/providers/dmacvicar/libvirt/latest)

## 上游文件

- [Proxmox VE Admin Guide](https://pve.proxmox.com/pve-docs/)
- [VMware ESXi docs](https://techdocs.broadcom.com/us/en/vmware-cis/vsphere.html)
- [XCP-ng docs](https://docs.xcp-ng.org/)
- [KubeVirt user guide](https://kubevirt.io/user-guide/)
- [libvirt Wiki](https://wiki.libvirt.org/)
- [OrbStack docs](https://docs.orbstack.dev/)

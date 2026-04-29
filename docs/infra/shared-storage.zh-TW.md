# 共享儲存 —— 叢集檔案系統與網路掛載

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

「多台機器需要看到同一份位元組」的參考。依工作負載形態（POSIX 與物件、HPC 與一般、僅 Linux 與混合作業系統）以及你願意承擔多少營運複雜度，挑選一個檔案系統或通訊協定。

## 快速答案

| 問題 | 選擇 |
|---------|------|
| LAN 上 5-20 位 Linux 使用者的共享 `/home` | [NFSv4](#nfsv4)（最簡單）；搭配 [autofs](#client-mount-recipes) |
| 同上但有 Mac/Windows client | [Samba (SMB/CIFS)](#smbcifs-samba) |
| HPC / ML 研究實驗室、多節點、高吞吐量 | [BeeGFS](#beegfs) 或 [Lustre](#lustre) |
| 已經跑 Ceph，又需要一個 POSIX FS | [CephFS](#cephfs) |
| 小團隊，想要 scale-out NAS、營運簡單 | [MooseFS](#moosefs--lizardfs) / [SeaweedFS](#seaweedfs) / [JuiceFS](#juicefs) |
| 只想要 S3 相容物件儲存 | [MinIO](https://min.io) / [Ceph RGW](https://docs.ceph.com/en/latest/radosgw/) / SeaweedFS |
| 將雲端儲存同步到本機路徑（依使用者） | [rclone](https://rclone.org)（本 repo 已預裝，請見 [README.md](../../README.md)） |

## 整體版圖

| 系統 | 授權 | 類型 | POSIX | 中介資料 (metadata) | Client | 營運複雜度 | 適合場景 |
|--------|---------|------|-------|----------|--------|---------------|----------|
| [NFSv4](https://datatracker.ietf.org/doc/html/rfc7530) | 開放標準 | 網路 FS | 是 | 伺服器端 | 核心 (所有作業系統) | 低 | 共享家目錄、設定、小型叢集 |
| [Samba (SMB/CIFS)](https://www.samba.org) | GPLv3 | 網路 FS | 大致是 | 伺服器端 | 核心 (含 Windows 在內所有 OS) | 低 | 混合作業系統的桌面環境 |
| [CephFS](https://docs.ceph.com/en/latest/cephfs/) | LGPLv2.1 | 分散式 POSIX FS | 是 | 分散式 (MDS) | 核心或 FUSE | 高 (MON/MGR/OSD/MDS) | 一站式物件 + block + FS；K8s 上透過 [Rook](https://rook.io) |
| [BeeGFS](https://www.beegfs.io) | 開放核心（社群版免費） | 平行 FS | 是 | 分散式中介資料伺服器 | 核心模組 | 中 | HPC、高中介資料 ops/sec |
| [Lustre](https://www.lustre.org) | GPLv2 | 平行 FS | 是 | MDS + OST | 核心模組 | 非常高 | 極大頻寬 HPC（TOP500） |
| [GlusterFS](https://www.gluster.org) | GPLv2/LGPLv3 | 分散式 FS | 是 | client 端 hashing | FUSE 或原生 | 中 | Scale-out NAS（衰退中；見備註） |
| [MooseFS / LizardFS](https://moosefs.com) | GPLv2 / BSD | 分散式 FS | 是 | 單一 master + shadow | FUSE | 低-中 | 簡單的「大 NAS」 |
| [SeaweedFS](https://github.com/seaweedfs/seaweedfs) | Apache 2.0 | 分散式 FS + 物件 | 是 (FUSE) | 分散式 | FUSE 或 S3 | 中 | 數十億個小檔案 |
| [JuiceFS](https://juicefs.com) | Apache 2.0 / 商業 | 物件儲存上的 POSIX | 是 | Redis / TiKV / MySQL | FUSE | 低 | 由 S3/MinIO 撐起的 POSIX FS |
| [MinIO](https://min.io) | AGPLv3 / 商業 | 物件儲存 | 否（僅 S3） | 分散式 | S3 SDK | 低 | S3 相容物件儲存 |
| [OpenZFS](https://openzfs.org) | CDDL | 本機/複寫 FS | 是 | 本機 | 原生 | 單機低 | 單節點 NAS；搭配 NFS/Samba 對外分享 |

## 各系統說明

### NFSv4

最簡單、最通用的網路檔案系統。所有 Unix 與 Mac 都已經有 client。

- 伺服器端：Linux `nfs-kernel-server` + `/etc/exports`。單一伺服器是 SPOF；要擴展可改用 NFS-Ganesha（使用者空間）作為 Ceph/GlusterFS 的前端，或將使用者依伺服器分片。
- 安全性：NFSv4 支援 Kerberos (`sec=krb5p`)。沒有它的話，UID 會在傳輸線上被信任 —— 在不可信網路上很糟糕。
- Locking：NFSv4 有正規 POSIX lock（不像 NFSv3）。即便如此，資料庫和某些建置系統 (bazel、cargo on shared cache) 痛恨 NFS；快速變動的工作負載請放在本機。
- 用途：共享 `/home`、共享設定、SSO 認證的多讀少寫資料、頻寬非瓶頸時的 HPC scratch。

### SMB/CIFS (Samba)

SMB3 是 Windows 的原生通訊協定。Linux 與 macOS 都能作為 client 與其對話。

- 伺服器：Linux 上的 `smbd`，設定於 `/etc/samba/smb.conf`。可加入 AD 網域。
- 對混合作業系統環境支援強；支援可對應到 Windows ACL 的 per-user ACL。
- 對密集小檔案 POSIX 工作負載比 NFS 弱；較適合「部門共用磁碟機」。

### CephFS

CephFS 是 Ceph 之上的 POSIX 檔案系統 API，與 RBD（block）和 RGW（物件/S3）並列。三者都跑在同一個 RADOS 物件儲存之上。

- 營運成本：Ceph 叢集需要至少 3 個節點上的 MON + MGR + OSD +（提供 FS 時）MDS daemon。Day-2 專業度不簡單（PG、CRUSH map、OSD rebalancing）。
- 強項：一個叢集、三套 API。你的 K8s persistent volume (RBD)、你的 S3 (RGW)、你的共享 FS (CephFS) 全都共用同一份冗餘與 pool。
- Client：主線核心 client (`mount -t ceph`) 或退而求其次的 FUSE。在現代 Linux 上開箱即用。
- Kubernetes：[Rook](https://rook.io) operator 讓 Ceph-on-K8s 變得人性化；CephFS-CSI 將 volume 掛入 pod。
- 適合：你已經需要物件 + block，FS「順便附贈」也好。

### BeeGFS

源自 Fraunhofer ITWM，現由 ThinkParQ 維護。在 HPC 與 ML 訓練叢集中廣泛使用，因為它的中介資料架構（多個中介資料伺服器分擔負載，不像 Lustre 經典單一 MDS 的設計）。

- 元件：管理、中介資料、儲存、client。除了 client 核心模組以外都在使用者空間。
- 社群使用免費（開源），ThinkParQ 提供企業支援。
- 對使用者擁有數百萬個小檔案的場景（典型的 ML 資料集）特別適合。
- 常與 SLURM + FreeIPA 一起組成「實驗室叢集」技術堆疊 —— 請見 [compute-scheduling.md](compute-scheduling.md) 與 [shared-home-identity.md](shared-home-identity.md)。

### Lustre

「如果你還要問就代表你不需要它」這種選項。撐起多數 TOP500 超級電腦。

- 極大頻寬，對序列式 HPC IO 表現極佳。
- Kernel-module client，與特定 kernel 版本綁定。
- 需要專職系統管理員。不是 DIY 的選擇。
- 如果你不在 >PB 規模、>100 節點，請改選 BeeGFS。

### GlusterFS

具 FUSE 或原生 client 的 scale-out NAS。

- 歷史上很受歡迎，但 [RedHat 在 2024 年終止 RHGS](https://access.redhat.com/announcements/7019004)，上游貢獻也已減緩。新專案請審慎評估。
- 既有部署仍可用；常見建議的遷移路徑是 CephFS。

### MooseFS / LizardFS

具 FUSE client 的單一 master 分散式 FS。LizardFS 是社群分支（較舊；目前活躍度較低）。

- 心智模型簡單：master + chunk server + FUSE client。
- 適合「給小團隊用的大 NAS」，無需 Ceph 的複雜度。
- Master 是 SPOF，除非你跑 shadow master（Pro 版）。

### SeaweedFS

物件優先，但提供 FUSE POSIX 層。

- 為數十億個小檔案最佳化（受 Facebook Haystack 啟發）。
- 提供 S3、HDFS、FUSE、WebDAV 前端。
- 比 Ceph 的營運負擔輕。社群活躍。

### JuiceFS

有趣的混合模式：POSIX FS 中介資料存於 Redis/TiKV/MySQL，資料則存於任何 S3 相容物件儲存。

- 任何 client 都可掛載，背後接到便宜的雲端物件儲存。
- 中介資料存在你已經在用的資料庫。
- 適合「我想要 POSIX FS 但只想付物件儲存的價格」與跨地區共享 FS。

### 單一主機上的 OpenZFS + NFS/Samba 匯出

不是分散式，但值得一提：在一台強力伺服器上跑 OpenZFS（最好用 `zfs send` 複寫到第二台）+ NFS/Samba 匯出，是許多團隊務實的答案。

- 快照 + send/receive + 壓縮 + 完整性。
- 可在 TrueNAS、Proxmox 主機，或透過 `zfs-dkms` 在原生 Ubuntu 上運作。
- 垂直擴展，非水平擴展。

## 依工作負載分類的決策矩陣

| 情境 | 選擇 | 原因 |
|----------|------|-----|
| 10 人團隊的共享 `/home` | NFSv4 + 後端 ZFS | 最簡單；快照故事由 ZFS 負責；此規模下夠好 |
| GPU 叢集，20-100 節點，ML 訓練 | BeeGFS | 中介資料快；能處理數百萬個小資料集檔案 |
| HPC 叢集、MPI 工作、>100 節點 | Lustre 或 BeeGFS | 看頻寬；若有專職 FS 管理員選 Lustre |
| 同時需要物件 + block + FS 的 K8s 叢集 | 透過 Rook 的 CephFS + RBD + RGW | 一套儲存層支援三套 API |
| 混合 Mac/Win/Linux 辦公檔案分享 | Samba | Windows 唯一原生支援良好的選項 |
| 「想要 POSIX FS 但要便宜」 | JuiceFS on S3 | 物件儲存的成本、POSIX 的語意 |
| 「大 NAS、簡單營運、僅 Linux」 | MooseFS 或 SeaweedFS | 比 Ceph 簡單；無 HPC 需求 |
| 單一強力 NAS 主機 | OpenZFS + NFS/Samba | 垂直擴展可以；快照是王道 |

## Client 端掛載範例

### NFSv4 掛載

```bash
# 一次性掛載
sudo mount -t nfs -o vers=4.2 nas.example.com:/home /mnt/home

# 透過 /etc/fstab 持久化
echo 'nas.example.com:/home  /home  nfs  vers=4.2,hard,nconnect=8,_netdev  0 0' | sudo tee -a /etc/fstab
```

### autofs 用於按需掛載 `/home`

共享家目錄叢集的標準模式 —— 只在使用者登入時掛載其家目錄。

```bash
# /etc/auto.master.d/home.autofs
/home /etc/auto.home --timeout=600

# /etc/auto.home
*  -fstype=nfs4,rw,hard,nconnect=8  nas.example.com:/home/&
```

`&` 會被替換為要存取的子目錄（使用者名稱）。同時請見 [shared-home-identity.md](shared-home-identity.md)。

### CephFS 掛載

```bash
# 核心 client，需要 CephX secret 檔
sudo mount -t ceph user@.myfs=/ /mnt/cephfs \
  -o mon_addr=mon1.ceph:6789/mon2.ceph:6789,secretfile=/etc/ceph/client.user.secret
```

### BeeGFS 掛載

```bash
# 安裝 beegfs-client + beegfs-helperd 套件後，編輯：
#   /etc/beegfs/beegfs-client.conf  -> 設定 sysMgmtdHost
sudo systemctl enable --now beegfs-helperd beegfs-client
# 預設掛載點為 /mnt/beegfs
```

### SMB/CIFS

```bash
sudo mount -t cifs //server/share /mnt/share \
  -o username=alice,uid=$(id -u),gid=$(id -g),vers=3.1.1,seal
```

### rclone（將 S3 / WebDAV / GDrive 當成 POSIX）

```bash
rclone mount myremote: ~/mnt/myremote --vfs-cache-mode full --daemon
```

依使用者，不需 root。適合雲端儲存撐起的個人工作集。

## 容器與 K8s 的儲存

共享儲存通常透過 CSI driver 給工作負載使用：

- [ceph-csi](https://github.com/ceph/ceph-csi) —— CephFS + RBD
- [nfs-subdir-external-provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner) —— 從單一 NFS 匯出動態提供 PV
- [Longhorn](https://longhorn.io) —— SUSE / Rancher 為 K8s 設計的 block storage（複寫式本機磁碟）
- [OpenEBS](https://openebs.io) —— per-node 本機 PV + 複寫引擎
- [JuiceFS CSI](https://juicefs.com/docs/csi/introduction/) —— 由 S3 撐起的 POSIX 掛載

當容器需要跨 pod 共享 volume (RWX) 時，你需要一個共享 FS —— 通常是 CephFS、NFS 或 JuiceFS。RBD 與 Longhorn 是 block-level (RWO)。

## 相關連結

- [virtualization.md](virtualization.md) —— VM 磁碟通常就放在同一份 Ceph/ZFS/NFS 上
- [compute-scheduling.md](compute-scheduling.md) —— 排程器會假設有共享 FS 來傳遞工作的輸入/輸出
- [shared-home-identity.md](shared-home-identity.md) —— 「所有人的 `$HOME` 都在 NAS 上」端到端模式
- [docs/tools/containers.md](../tools/containers.md) —— container bind mount 與 volume

## 上游文件

- [Ceph docs](https://docs.ceph.com/en/latest/)
- [BeeGFS docs](https://doc.beegfs.io/)
- [Lustre manual](https://doc.lustre.org/)
- [Samba wiki](https://wiki.samba.org/)
- [NFSv4 on Linux](https://linux-nfs.org/wiki/index.php/Main_Page)
- [Rook (Ceph-on-K8s)](https://rook.io/docs/rook/latest-release/Getting-Started/intro/)

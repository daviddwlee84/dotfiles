# RHEL 生態系與 CentOS 遷移指南

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：套件管理員
    (package manager)。**不自創翻譯**——若無公認譯名直接保留英文原文。

本頁說明 RHEL/CentOS 家族譜系，以及從 CentOS 7（本 dotfiles repo 最初開發環境）
遷移的路徑選擇。工具鏈層級的細節（glibc / gcc / 核心版本）請見
[linux-toolchain-baseline.md](linux-toolchain-baseline.md)。

---

## 家族譜系

```
Fedora（尖端上游）
  │
  ▼
CentOS Stream  ←── RHEL 下一個 minor release 的開發預覽分支
  │
  ▼
RHEL（Red Hat 付費企業產品）
  │
  ├── AlmaLinux（社群 RHEL 相容，CloudLinux 支持）
  ├── Rocky Linux（社群 RHEL rebuild，CentOS 共同創辦者血統）
  └── Oracle Linux（Oracle 支持；可選 RHEL 相容核心或 UEK 核心）
```

**2020 年的關鍵轉向：** Red Hat 改變了 CentOS Project 的方向。舊模型是
`RHEL → CentOS Linux`（RHEL 發布後再 rebuild）。新模型讓 CentOS Stream 成為
*RHEL 之前*的開發分支——精神上更接近 Fedora。

---

## EOL 時間表

| 發行版 | EOL |
|--------|-----|
| CentOS Linux 6 | 2020-11-30 |
| CentOS Linux 7 | **2024-06-30**（已到期） |
| CentOS Linux 8 | 2021-12-31（提前終止） |
| CentOS Stream 8 | 2024-05-31 |
| CentOS Stream 9 | ~2027（隨 RHEL 9 生命週期） |
| CentOS Stream 10 | ~2030（隨 RHEL 10 生命週期） |
| RHEL / Alma / Rocky 8 | 2029-05 |
| RHEL / Alma / Rocky 9 | 2032-05 |

CentOS Linux 8 被提前縮短了 4 年（2020 年宣布，2021 年 EOL）。**不存在
CentOS Linux 9**——同等定位的穩定社群 rebuild 是 AlmaLinux 9 與 Rocky Linux 9。

---

## 各發行版現在是什麼

### RHEL
Red Hat 的付費企業產品。若公司有訂閱或合規需求時使用。大多數「RHEL 相容」
保證都以 RHEL 的 ABI 為基準。

### CentOS Stream
已不再是穩定版 RHEL 複製品。它現在是 *RHEL 下一個 minor release 的上游開發分支*：

```
Fedora → CentOS Stream → RHEL → Alma/Rocky
```

適合想預覽 RHEL 變化或向上游貢獻的開發者。**不建議作為正式伺服器的
CentOS 7 替代品。**

### AlmaLinux
由 CloudLinux 支持的社群驅動 RHEL 相容發行版，主要目標是填補 CentOS Linux
消失後的空缺。從 RHEL 9.2 起，AlmaLinux 策略從「逐位元 clone」轉向「ABI/應用程式
相容性」——實際使用上差異極小。社群大且活躍。

### Rocky Linux
由 Gregory Kurtzer（CentOS 共同創辦者之一）創辦的社群 RHEL rebuild。精神上最接近
原始 CentOS Linux 的「RHEL 發布後 rebuild」哲學。在 HPC 與研究環境中口碑良好。

### Oracle Linux
Oracle 支持的 RHEL 相容發行版，可選 RHEL 相容核心或 Oracle 自有的 UEK
(Unbreakable Enterprise Kernel)。採用與否通常取決於組織與 Oracle 的生態關係。

---

## 從 CentOS 7 遷移的路徑

CentOS Linux 7 → CentOS Linux 8/9 **這條路不存在**。請從以下選項選擇：

| 目標 | 路徑 |
|------|------|
| 付費企業支援 / 合規需求 | RHEL 8 或 9 |
| 免費、穩定、最接近舊 CentOS | **Rocky Linux 8/9** 或 **AlmaLinux 8/9** |
| 留在 Oracle 生態 | Oracle Linux 8/9 |
| RHEL 上游開發 / 預覽 | CentOS Stream 9/10（非正式穩定版） |

### 原地升級 vs. 全新安裝

從 CentOS 7 到任何 EL8/EL9 變體，**沒有官方支援的原地升級路徑**：

- **全新安裝 + 重新套用 dotfiles**：建議做法。從 ISO 開機，再執行 `chezmoi init`
  與 ansible。通常 30-60 分鐘內完成。
- **Leapp migration**（Red Hat 官方原地遷移工具）：官方支援 RHEL → RHEL 升級。
  社群也有 CentOS 7 → AlmaLinux/Rocky 的 Leapp 路徑，但在高度客製化的系統上
  風險較高。
- **以容器維持 CentOS 7**：透過 Apptainer / Docker 做建置時隔離。OS 本身暫時
  無法遷移時的緩兵之計。見
  [linux-toolchain-baseline.md § Apptainer](linux-toolchain-baseline.md#2-apptainer--singularity--podman-rootless-container)。

### Dotfiles 相容性說明

本 repo 的設定檔在 CentOS 7（`glibc 2.17`、`gcc 4.8.5`、kernel 3.10）上開發。
遷移到 EL8/EL9 後主要差異：

| 項目 | EL7 | EL8/9 |
|------|-----|-------|
| 預設 Python | 2.7 (`python`) | 僅 3.x；預設無 `python` symlink |
| 系統 Python 3 | 3.6.8（EPEL） | 3.9（EL8）/ 3.11+（EL9） |
| 套件管理員 | `yum` | `dnf`（`yum` 是 `dnf` 的別名） |
| NTP 服務 | `ntpd` | `chrony` |
| `ifconfig` / `netstat` | 內建 | 需安裝 `net-tools` |
| SCL (`scl enable`) | 常見模式 | 由 module streams 取代 |

本 repo 的 chezmoi 模板使用 `.chezmoi.os` 與版本偵測模式，不寫死 CentOS 7
路徑，在 EL8/9 上重新套用不需修改。

---

## 快速比較：AlmaLinux vs Rocky Linux

兩者都是可靠選擇。對本 repo 的主要使用情境（HPC / 計算節點 /
單人工作站），實際差異不大：

| | AlmaLinux | Rocky Linux |
|-|-----------|-------------|
| 背後組織 | CloudLinux（商業） | Rocky Enterprise Software Foundation |
| 相容性立場 | 「ABI 相容」（9.2 後） | 「1:1 RHEL rebuild」 |
| 社群規模 | 大 | 大 |
| HPC 社群採用 | 普遍 | 非常普遍（RHEL 共同創辦者血統） |
| 建議 | 兩者皆可 | HPC/研究情境略有優勢 |

若叢集已在用其中一個，繼續用即可。若重新建置，Rocky Linux 9 是合理預設選擇。

---

## 延伸閱讀

- [linux-toolchain-baseline.md](linux-toolchain-baseline.md) — 各發行版 glibc /
  gcc / 核心版本矩陣、SCL 用法、Apptainer 容器。
- [`pitfalls/centos7-noroot.md`](../../pitfalls/centos7-noroot.md) — CentOS 7
  無 root 工具鏈（`glibc 2.17` musl 備援路徑）。
- [`pitfalls/centos7-numpy-pandas-source-build.md`](../../pitfalls/centos7-numpy-pandas-source-build.md)
  — numpy 2.x meson 編譯牆。
- [`pitfalls/centos7-zsh-too-old.md`](../../pitfalls/centos7-zsh-too-old.md) —
  系統 zsh 5.0.2 與設定檔需求不符。

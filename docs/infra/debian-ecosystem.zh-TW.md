# Debian 生態系：Debian / Ubuntu / Raspberry Pi OS

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現。**不自創翻譯**——
    若無公認譯名直接保留英文原文。

本頁說明 Debian 家族譜系、各發行版的 release 節奏，以及如何在三者之間選擇。
RHEL/CentOS 系列請見 [rhel-ecosystem.md](rhel-ecosystem.md)。
工具鏈層級細節（glibc / gcc / 核心版本）請見
[linux-toolchain-baseline.md](linux-toolchain-baseline.md)。

---

## 家族譜系

```
Debian（stable / testing / unstable）
  │
  ├── Raspberry Pi OS（Debian base + Pi 硬體 + raspi-config）
  │
  └── Ubuntu（Canonical；6 個月週期，2 年 LTS）
        ├── 官方 flavour：Kubuntu、Xubuntu、Lubuntu、Ubuntu Server、
        │   Ubuntu Core、Ubuntu Studio …
        └── 下游衍生：Linux Mint、Pop!_OS、elementary OS、Zorin OS …
```

Ubuntu 是*基於* Debian，但**不是** Debian 的官方下一版。
Raspberry Pi OS 是*基於* Debian，但針對 Pi 硬體特化。
兩者都是平行的 fork，不是彼此的下游「版本」。

---

## Debian

這一族的根。主要特色：

- **社群治理** — 沒有單一企業主導。
- **非常保守的 release 節奏** — 「準備好再發」，大約每 2-3 年一次，非固定日曆。
- **同時維護三個分支**：

  | 分支 | 別名 | 說明 |
  |------|------|------|
  | `stable` | 當前代號 | 正式穩定版；security patch 約 5 年 |
  | `testing` | 下個代號 | 下一個 stable 的候選池 |
  | `unstable` | `sid` | 滾動更新；永遠不會成為 stable |

- **`apt` / `dpkg` 的源頭** — Debian 家族所有發行版都繼承此套件生態。
- **Toy Story 人物代號**（見[版本代號](#版本代號)）。

### 何時選 Debian

| 使用情境 | 適合？ |
|----------|--------|
| 長期穩定伺服器、NAS、家庭實驗室 | 是 — 非常穩定、低 churn |
| 最小化安裝、不要廠商預設值 | 是 |
| 最新 GPU stack / CUDA / NVIDIA 驅動 | 否 — 用 Ubuntu 或 backports |
| 線上教學 / PPA 生態 | 否 — Ubuntu 教學多得多 |
| Raspberry Pi 硬體 | 否 — 用 Raspberry Pi OS |

---

## Ubuntu

Canonical 基於 Debian 打造的產品。大多數開發者說「我用 Linux 開發」時指的就是它。

### Release 節奏

| 類型 | 節奏 | 支援期 |
|------|------|--------|
| Interim release | 每 6 個月（四月 + 十月） | 9 個月 |
| LTS | 每 2 年（四月，偶數年） | 5 年標準；Ubuntu Pro 延長至 10 年 |

Ubuntu Pro 免費提供個人帳號最多 5 台機器的 10 年 LTS 支援。

### 近期版本

| 版本 | 代號 | 類型 | EOL |
|------|------|------|-----|
| 22.04 | Jammy Jellyfish | LTS | 2027-04（標準） |
| 24.04 | Noble Numbat | LTS | 2029-04（標準） |
| 25.10 | Questing Quokka | Interim | 2026-07 |
| 26.04 | Resolute Raccoon | LTS | 2031-04（標準） |

正式伺服器請一律使用 LTS；Interim release 適合想要更新套件的開發機。

### 為什麼 Ubuntu 主導雲端 / 開發 / AI 工作負載

- **NVIDIA / CUDA**：官方驅動、CUDA repo、容器映像都以 Ubuntu LTS 為第一優先。
- **Docker / Kubernetes**：官方安裝文件預設 Ubuntu。
- **PPA 生態**：`add-apt-repository` 讓你不用自己編譯就能裝到新版工具。
- **雲端 AMI / 映像**：AWS、GCP、Azure 都把 Ubuntu LTS 列為一等公民映像。
- **教學數量**：DevOps、AI/ML、系統管理的教學大多以 Ubuntu 為範例。

### Ubuntu 的取捨

- **Snap**：Canonical 對部分系統套件（例如 Firefox）強推 Snap；社群褒貶不一。
  在較新版本上 `apt install firefox` 可能裝到 Snap 而非 deb。
- **比 Debian 更「產品化」** — Canonical 的產品決策會影響所有使用者。
- **6 個月 Interim releases** — 若追 Interim，工作流程可能被打斷；穩定性優先就用 LTS。

---

## Raspberry Pi OS

前身叫 **Raspbian**，是 Raspberry Pi 的官方作業系統。

```
Raspberry Pi OS = Debian base
               + Pi 開機 firmware / config.txt
               + Pi kernel + device tree + GPIO / camera / 螢幕支援
               + raspi-config 工具
               + Pi 官方桌面（LXDE based）
```

Pi OS 的 release 跟 Debian stable 代號對齊（bullseye → bookworm → trixie）。
它**不是** Ubuntu for Pi — 它是 Debian for Pi。

### 在 Raspberry Pi 上如何選 OS

| 目標 | 最佳選擇 |
|------|----------|
| 最省事、硬體支援最完整（GPIO、相機、螢幕） | **Raspberry Pi OS** |
| Headless 伺服器、想與雲端 VM 用同一 OS | Ubuntu Server for Raspberry Pi |
| 純 Debian、不要 Pi extras | Debian arm64（硬體支援可能不如官方 Pi OS 順暢） |
| 僅 64-bit | Raspberry Pi OS（64-bit）或 Ubuntu Server |

Raspberry Pi OS 三種 flavour：

| Flavour | 說明 |
|---------|------|
| Desktop | 完整 GUI，推薦初學者 |
| Desktop Lite | 精簡 GUI |
| Lite | 無 GUI — 最適合 headless 伺服器 / embedded |

---

## Debian、Ubuntu、Raspberry Pi OS 怎麼選

| 目標 | 建議 |
|------|------|
| 一般 Linux 伺服器 | Debian stable 或 Ubuntu LTS |
| 開發機 / AI / Docker / CUDA | **Ubuntu LTS** |
| 雲端 VM | Ubuntu LTS（映像支援最廣）；Debian 也可 |
| 最保守、最精簡的穩定伺服器 | **Debian stable** |
| Raspberry Pi（GPIO / 相機 / 感測器） | **Raspberry Pi OS** |
| Raspberry Pi 當 headless 伺服器 | Raspberry Pi OS Lite 或 Ubuntu Server |
| 想減少 Canonical 產品決策影響 | Debian |
| 教學最多、兼容性最廣 | Ubuntu |

一句話總結：

> **Debian**：穩、乾淨、社群、保守。  
> **Ubuntu**：好用、支援多、產品化、開發友善。  
> **Raspberry Pi OS**：Debian 系，但以 Pi 硬體為第一優先。

---

## Debian 系 vs RHEL 系：主要差異

| | Debian / Ubuntu | RHEL / Rocky / Alma |
|-|-----------------|---------------------|
| 套件格式 | `.deb` / `apt` / `dpkg` | `.rpm` / `dnf` / `rpm` |
| 社群 / 企業平衡 | 社群主導（Debian）、產品化（Ubuntu） | 企業優先（RHEL）、社群 rebuild（Rocky/Alma） |
| 雲端 / DevOps 主導地位 | Ubuntu LTS 非常強 | RHEL / Alma 在法規合規 / HPC / 企業 |
| 桌面 / 新手採用率 | Ubuntu 主導 | Fedora / Alma 市佔較小 |
| ABI 穩定性保證 | Ubuntu LTS 在同版本內穩定 | RHEL 以跨 minor release 的二進位 ABI 保證著稱 |
| 穩定版工具鏈新舊 | Ubuntu LTS 的 gcc/glibc 通常比同期 RHEL 新 | RHEL 9 ≈ Ubuntu 22.04 LTS 工具鏈版本相近 |

從本 repo 使用情境交叉對照：

| 情境 | 選擇 |
|------|------|
| 個人開發機 / AI / CUDA / Docker | Ubuntu LTS |
| HPC 叢集 / 企業內部伺服器 | Rocky / Alma / RHEL |
| Raspberry Pi / GPIO / embedded | Raspberry Pi OS |
| 最乾淨穩定伺服器、不要廠商預設 | Debian stable |
| CentOS 7 遷移目標 | Rocky Linux 9 / AlmaLinux 9（見 [rhel-ecosystem.md](rhel-ecosystem.md)） |

---

## 版本代號

### Debian（Toy Story 人物）

| 版本 | 代號 | 狀態 |
|------|------|------|
| 11 | bullseye | oldstable |
| 12 | bookworm | oldstable（自 Debian 13 發布後） |
| 13 | trixie | **stable**（2025-08-09 發布） |
| — | sid | unstable（永久別名） |

### Ubuntu（形容詞 + 動物，按字母順序）

| 版本 | 代號 | 類型 |
|------|------|------|
| 22.04 LTS | Jammy Jellyfish | LTS |
| 24.04 LTS | Noble Numbat | LTS |
| 25.10 | Questing Quokka | Interim |
| 26.04 LTS | Resolute Raccoon | LTS |

### Raspberry Pi OS

跟 Debian stable 代號對齊。目前版本：bookworm（穩定）、trixie（較新）。
最新推薦映像請查[官方下載頁](https://www.raspberrypi.com/software/operating-systems/)。

---

## 延伸閱讀

- [rhel-ecosystem.md](rhel-ecosystem.md) — RHEL / CentOS 家族，CentOS 7 遷移。
- [linux-toolchain-baseline.md](linux-toolchain-baseline.md) — glibc / gcc /
  核心版本矩陣，含 Ubuntu 與 Debian 列。

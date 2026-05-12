# GLIBC vs musl：遇到 "version not found" 時，實際該怎麼處理

針對這個特定錯誤的實用參考：

```text
$ tv
tv: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found (required by tv)
```

…以及為什麼**為了單一個 user-space CLI 工具去升級整個 host OS，幾乎永遠不
是正確答案**。

## 兩種 libc 實作

每個動態連結的 Linux binary 都會連結到**某一份 libc**（C 標準函式庫——
`malloc`、`printf`、`open`、執行緒、DNS resolver、locale 等等）。主流有兩種：

| | glibc | musl |
|---|---|---|
| 全名 | GNU C Library | musl libc |
| 大小 | 大（數十 MB） | 小（~1 MB） |
| 預設裝在 | Ubuntu / Debian / RHEL / Fedora / Arch | Alpine Linux、許多 Docker base image |
| 連結慣例 | 動態 | 常常是**靜態連結**進 binary |
| 帶版本符號 | **嚴格**——對 `GLIBC_2.39` 編的 binary 無法跑在 `GLIBC_2.35` 的主機 | 沒有——musl 靜態 binary 在執行時對 libc 完全零依賴 |
| 行為差異 | 大多數 Linux 軟體的參考行為 | DNS resolver、locale、執行緒邊角案例不同 |

造成 `GLIBC_2.X not found` 的關鍵不對稱：**glibc 帶版本的符號是向前不相容
的**。在 Ubuntu 24.04（glibc 2.39）編出來的 binary 會記錄 `GLIBC_2.38` /
`GLIBC_2.39` 符號參照；在 22.04（glibc 2.35）的 host 上，動態連結器檢查版
本表後會拒絕載入。

## GitHub release 的「musl binary」到底是什麼

當 release 頁面列出例如 `tool-x86_64-unknown-linux-musl.tar.gz`，這個
binary 是：

1. 用 `x86_64-unknown-linux-musl` target 編譯（用 musl 的 header 和 crt
   而不是 glibc）。
2. **靜態連結**——musl 本身被打包進 binary。

結果：這個 binary 完全忽略 host 的 `libc.so.6`。任何 Linux x86_64 都能
跑——Ubuntu 14.04、RHEL 7、Alpine、container scratch image 都行——因為它
唯一的 kernel ABI 需求只有 syscall 介面。

驗證：

```bash
file ./tool
# glibc 動態：dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2
# musl 靜態：static-pie linked  （或 "statically linked"）

ldd ./tool
# glibc：       linux-vdso.so.1 ... libc.so.6 => ...
# musl 靜態：   not a dynamic executable    （或 "statically linked"）
```

如果 `file` 顯示 `static-pie linked` 而 `ldd` 顯示 `not a dynamic
executable` → host glibc 版本完全無關緊要。

### 為什麼 Rust 出 musl build，C/C++ 很少出

Rust 的 cross-compile 讓 musl 變得很簡單：`cargo build --target
x86_64-unknown-linux-musl` 就能產出可攜的 binary，不需要額外處理。大多數
熱門 Rust CLI 工具（`ripgrep`、`fd`、`bat`、`eza`、`delta`、`yazi`、
`zoxide`、`starship`、`television`、`bottom`、`tokei`、`hyperfine` 等等）
GitHub release 都同時提供 glibc 和 musl tarball。

C/C++ 專案很少這樣做，因為實際的 musl 移植會碰到一堆行為差異（locale、
DNS、`getaddrinfo`、執行緒、dlopen 邊角案例），這些 glibc 都幫忙抹平了。
Go 是另一個「預設靜態」的生態系——Go binary 預設不帶 CGO 就是靜態，連
musl variant 都不需要。

## 遇到 `GLIBC_2.X not found` 的決策樹

```
                      ┌──────────────────────────────────┐
                      │  binary X 需要更新的 GLIBC       │
                      └──────────────────┬───────────────┘
                                         │
                        ┌────────────────┴────────────────┐
                        │ 是 Rust / Go CLI 工具嗎？       │
                        └────────────────┬────────────────┘
                                         │
                       ┌────── 是 ───────┴─────── 否 ──────┐
                       ▼                                   ▼
            ┌────────────────────────┐          ┌─────────────────────┐
            │ 找 release 裡的 *-musl │          │ Linuxbrew 可用嗎？  │
            │ 或 *-static 版本。     │          │（有 sudo 或已經裝好）│
            │ Rust CLI ~95% 有；Go   │          └──────────┬──────────┘
            │ 預設就是靜態。         │                     │
            └────────────────────────┘            ┌── 是 ──┴── 否 ──┐
                                                  ▼                 ▼
                                       ┌────────────────┐  ┌──────────────────┐
                                       │ brew install X │  │ distrobox / pod- │
                                       │ ——brew 自己帶  │  │ man 跑新版 Ubun- │
                                       │ glibc 在       │  │ tu/Fedora image, │
                                       │ /home/         │  │ binary 暴露給    │
                                       │ linuxbrew      │  │ host             │
                                       └────────────────┘  └──────────────────┘
```

**最後手段（單一工具幾乎絕對不該走這條）**：透過 `do-release-upgrade` 升
級整個 host OS。見下面「什麼時候升級 OS *是*正確的選擇」。

## 三種安裝策略，依優先順序

### 1. 直接抓 musl / static binary（單一 Rust/Go 工具的首選）

零負擔、零風險、即時生效。本 repo 既有的 GitHub-binary 安裝模式
（[`linux-package-sources.md`](linux-package-sources.md)）很多工具都已經這樣。

```bash
# Pattern: 下載 → 解壓 → 裝到 ~/.local/bin → 驗證
url=$(curl -s https://api.github.com/repos/<owner>/<repo>/releases/latest \
      | grep browser_download_url \
      | grep -E 'x86_64.*linux.*musl.*\.tar\.gz' \
      | head -1 | cut -d'"' -f4)
curl -sL "$url" -o /tmp/x.tar.gz
tar xzf /tmp/x.tar.gz -C /tmp/
cp /tmp/<extracted>/<binary> ~/.local/bin/
file ~/.local/bin/<binary>      # 預期：static-pie linked
ldd  ~/.local/bin/<binary>      # 預期：not a dynamic executable
```

如果 release 有發 SHA256 一定要驗。

### 2. Linuxbrew（有 sudo + 多工具一起裝時首選）

Linuxbrew 裝在 `/home/linuxbrew/.linuxbrew/`，自帶較新的 glibc 在
`Cellar/glibc/`，並用 `RPATH` 讓 brew 編出來的 binary 完全略過系統的
`libc.so.6`。和 macOS 共用 `Brewfile`、共用 formula 名、有最新的上游版本。

```bash
brew install neovim delta yazi television
```

權衡細節在 [`linux-package-sources.md`](linux-package-sources.md)。注意：
安裝時需要 sudo（要 `chown` `/home/linuxbrew`）；非特權的 `~/homebrew`
模式失去 bottle → 強制 source build → 拉一堆 `-dev` 套件 → 反而還是要 sudo。
在無 sudo 的 host 上，退回策略 1 或 3。

### 3. distrobox / podman / docker（工具需要真實的 glibc 環境時）

針對複雜工具、GUI app 或整個 stack（例如某個 build toolchain *本身* 需要
sysroot 裡有 glibc 2.39），把整套東西跑在 Ubuntu 24.04 / Fedora 40 容器
裡，host 完全不動。

```bash
# distrobox 是好用的 wrapper —— 自動掛 $HOME、$XDG_RUNTIME_DIR、
# X11/Wayland socket、GPU 裝置；透過 distrobox-export 在 ~/.local/bin
# 放 shim 把容器裡的 binary 暴露給 host。
sudo apt install distrobox podman   # 一次性，需要 sudo
distrobox create -i ubuntu:24.04 -n u24
distrobox enter u24
# 在容器裡：apt install <什麼需要 glibc 2.39 的東西>
# distrobox-export --bin /usr/bin/<tool>   # 暴露到 host PATH
```

GPU / CUDA passthrough 在 NVIDIA host 上是開箱即用（distrobox 直接繼承
host 的 `/dev/nvidia*` 和 userland libs）。

## 什麼時候升級 OS *是*正確的選擇

**只有以下全部成立時**：

- 工具是系統層級（不只是單一 CLI），例如 kernel module、深度整合 PAM /
  D-Bus / NetworkManager 的 systemd unit。
- 跑在容器裡的代價無法接受（例如它需要當 PID 1，或要管理 host 服務）。
- 你本來就為了別的原因要做 LTS 升級。

對於 Ubuntu 22.04 個人工作站想要 glibc 2.39：

| 風險點 | 在這類機器上的風險 |
|---|---|
| **NVIDIA driver + CUDA stack** | 高——kernel 從 5.15 跳到 6.8，driver 必須重編，`cuda-ubuntu2204` repo 要重新指向 `2404`，cuDNN 相容性要重驗。要安排維護時段。 |
| **第三方 apt repo**（例如 BeeGFS、Docker、NVIDIA、ngrok、GitHub CLI） | 中——升級前先 disable，升級完換 `noble` 版本再加回。有些供應商在新 release 之後會有空窗。 |
| **out-of-tree kernel module**（BeeGFS client、ZFS、DKMS-based driver） | 高——必須對新 kernel 重編；如果供應商還沒支援新 kernel，可能會無法開機。 |
| **Snap / Flatpak** | 低——通常 LTS 升級透明。 |
| **`/boot` 殘留舊 kernel** | 中——升級前用 `apt autoremove --purge` 清掉，避免 `/boot` 滿。 |
| **Linuxbrew** | 低——`/home/linuxbrew` 會留著，但升完跑一次 `brew doctor` 比較安心。 |

升級前清潔檢查清單：

```bash
# 套件狀態快照
dpkg --get-selections > ~/pkglist-$(date +%F).txt
sudo apt-mark showmanual > ~/manual-$(date +%F).txt
sudo tar czf /backup/etc-$(date +%F).tar.gz /etc

# 升級前先清乾淨
sudo apt update && sudo apt full-upgrade
sudo apt autoremove --purge

# 暫時 disable 那些還沒有 noble/jammy+1 版本的第三方 repo
sudo mv /etc/apt/sources.list.d/cuda-ubuntu2204.list ~/disabled-repos/

# 跑升級
sudo do-release-upgrade        # 加 -d 跑還沒正式 release 的版本
```

## 30 秒診斷流程

```bash
# 1. host 的 libc 版本是多少？
ldd --version | head -1

# 2. 出問題的 binary 是動態用 glibc 嗎？
file $(which <tool>)
ldd  $(which <tool>) 2>&1 | head -5

# 3. 這個 binary 在要哪個 symbol？
objdump -T $(which <tool>) | grep GLIBC_ | sort -u | tail -5
# 或：
strings -a $(which <tool>) | grep -E '^GLIBC_[0-9]'

# 4. host 實際提供哪些版本？
strings -a /lib/x86_64-linux-gnu/libc.so.6 | grep -E '^GLIBC_[0-9]' | sort -u
```

如果第 4 步的最大版本 < 第 3 步的最大版本 → 換 binary（上面的策略 1–3）。
**不要動 host libc**。

**絕對不要**從不匹配的 distro release 裝較新的 `libc6` 套件，**也絕對不要**
從 source 編譯 glibc 蓋掉系統那份。兩條路都會把機器砸壞（系統上每個
binary，包括 `bash`、`apt`、`sudo`、`ssh`，執行時都連到 `libc.so.6`）。如
果你真的需要新 glibc 到願意考慮這條，請用 distrobox。

## 交叉引用

- [Linux 套件來源：apt vs Linuxbrew vs snap vs GitHub binary](linux-package-sources.zh-TW.md)
  ——選擇哪種套件來源裝什麼工具的全貌。
- 陷阱筆記：[tv binary 在 jammy 上要 GLIBC_2.39 not found](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/tv-binary-glibc-2-39-not-found.md)
  ——觸發這份文件的具體除錯過程。

# 容器執行階段、代理與 GFW 鏡像策略

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

針對四種真實世界安裝方式 (Docker / OrbStack / Docker Desktop / Podman) 的操作筆記，重點放在本 repo 自動管理的部分，以及那些只在「需要時才套用」的手動配方手冊。

關於「哪個設定檔由誰讀取」的對照（CLI vs daemon vs systemd vs Desktop app、有根 (rootful) vs 無根 (rootless)），請見 [container-config-map.md](container-config-map.md)。本文聚焦於如何操作你的機器；對照文件則聚焦於理解整體版圖。

另請參閱：[docs/infra/virtualization.md](../infra/virtualization.md#desktop-vm-managers) 介紹 OrbStack 作為虛擬機管理員 (VM manager) 的角色（與 Proxmox / UTM / VirtualBox 並列），以及 [docs/infra/shared-storage.md](../infra/shared-storage.md#storage-for-containers-and-k8s) 探討容器卷 (volume) 在多節點叢集 (cluster) 中遇到 CSI / CephFS / NFS 的情境。

本文主要處理的痛點：

- **我該編輯哪個設定檔？** 答案取決於執行階段與安裝模式；至少有四個不同位置，schema 還互有重疊。
- **GFW / 中國鏡像 (mirror) 故事。** `daemon.json` 的 `registry-mirrors` 只涵蓋 Docker Hub。對於 `gcr.io` / `ghcr.io` / `quay.io` 你需要另一套策略（前綴替換）。
- **代理 (proxy) 在兩個層級。** Daemon 端（給 `docker pull` 用）與 client 端（給 `docker run` / `docker build` 用）是不同的；忘記這個區別常會導致「為什麼我的代理在容器裡不生效」的困惑。

## TL;DR

| 議題 | 檔案 | 由 chezmoi 管理？ | 觸發條件 |
|---------|------|---------------------|---------|
| 容器代理環境變數 (`docker run`、`docker build`) | `~/.docker/config.json` 的 `proxies.default` | 是，跨平台 | apply 時 `$LOCAL_PROXY_URL` 已設定 |
| 無根 daemon 的 registry mirrors (`docker pull` 經由 mirror) | `~/.config/docker/daemon.json` 的 `registry-mirrors` | 是，僅限 Linux + `useChineseMirror` | chezmoi data 中 `useChineseMirror=true` |
| 無根 daemon 的 HTTP 代理 (`docker pull` 經由代理) | `~/.config/systemd/user/docker.service.d/proxy.conf` | 否，下方有手動配方 | — |
| 系統 daemon 代理 / mirrors | `/etc/docker/daemon.json` + `/etc/systemd/system/docker.service.d/http-proxy.conf` | 否（需要 sudo） | — |
| Docker Desktop / OrbStack 代理 + mirrors | GUI 設定 | 否（由 GUI 管理） | — |
| 非 Docker Hub 的 registry (`gcr.io`、`ghcr.io`、`quay.io`、…) | 改寫 image 引用 | 否（應用層級） | 見下方 [kubesre 策略](#strategy-b-prefix-substitution-kubesre) |

原始檔案：

- [dot_docker/modify_config.json.tmpl](../../dot_docker/modify_config.json.tmpl) — client 端代理合併腳本。
- [dot_config/docker/modify_daemon.json.tmpl](../../dot_config/docker/modify_daemon.json.tmpl) — 無根 registry-mirrors 合併腳本。
- [dot_config/zsh/tools/50_networking.zsh](../../dot_config/zsh/tools/50_networking.zsh) — 共用的 `$LOCAL_PROXY_URL` 慣例與 `proxy-on` / `withproxy` 輔助函式。

## 執行階段一覽

| 執行階段 | 平台 | 模式 | 適用場景 | 注意事項 |
|---------|----------|------|----------|---------|
| [Docker Engine](https://docs.docker.com/engine/) | Linux | 系統（root daemon） | 傳統 Linux 伺服器使用；工具相容性最廣 | Daemon 以 root 執行；設定/重啟需 sudo |
| [Docker Engine rootless](https://docs.docker.com/engine/security/rootless/) | Linux | 每個使用者一個 daemon (systemd --user) | 開發機、共用伺服器、權限收緊的環境 | 網路功能受限（預設無 `iptables` MASQ）；部分儲存後端 (storage backend) 不可用 |
| [Docker Desktop](https://www.docker.com/products/docker-desktop/) | macOS / Windows | VM 後端的 daemon | 與上游 Docker 功能對等；對企業友善 | 大型組織有授權層級；RAM 占用比 OrbStack 高；冷啟動慢 |
| [OrbStack](https://orbstack.dev) | macOS（Apple Silicon + Intel） | 輕量 VM | 本 repo 在 macOS 的預設；啟動快、idle RAM 低、原生 ARM | 僅限 macOS（無 Windows/Linux）；無企業支援合約 |
| [Podman](https://podman.io) | Linux + Mac（透過 `podman machine`） | 無 daemon、預設無根 | 授權乾淨的替代品；不需 systemd unit 即可達到無根 Docker 的安全性 | `podman compose` 在某些網路邊緣案例落後 `docker compose`；不支援 Swarm；BuildKit 功能對等度有缺口 |

本 repo 預設：macOS 上使用 OrbStack，**Ubuntu 上使用無根 Docker Engine**（由 ansible role 安裝；`systemctl --user` 生命週期，日常設定不需 `sudo`）。見 [dot_ansible/roles/docker/tasks/main.yml](../../dot_ansible/roles/docker/tasks/main.yml)。系統（有根）Docker 仍可作為備援，若你需要全機共用的 daemon 來搭配特定工具；但它已不是預設安裝路徑。

## 各種安裝方式的設定檔位置

四種安裝、三套不同的檔案 schema、兩個層級（client vs daemon）。摘要：

| 安裝方式 | Daemon 代理 | Daemon registry-mirrors | Client 代理 (`docker run`) |
|---------|--------------|--------------------------|------------------------------|
| **無根 Docker Engine（Linux，repo 預設）** | `~/.config/systemd/user/docker.service.d/proxy.conf` | `~/.config/docker/daemon.json`（chezmoi 管理） | `~/.docker/config.json`（chezmoi 管理） |
| OrbStack（macOS，repo 預設） | GUI：Settings > Network > Proxy | `~/.orbstack/config/docker.json`（`registry-mirrors` 鍵，或 GUI） | `~/.docker/config.json`（chezmoi 管理） |
| Docker Desktop（macOS/Win，備援） | GUI：Settings > Resources > Proxies | GUI：Settings > Docker Engine > `registry-mirrors` JSON | `~/.docker/config.json`（chezmoi 管理） |
| 系統 Docker Engine（Linux，備援） | `/etc/systemd/system/docker.service.d/http-proxy.conf`（sudo） | `/etc/docker/daemon.json`（sudo） | `~/.docker/config.json`（chezmoi 管理） |

注意事項：

- **Client** 端檔案 (`~/.docker/config.json`) 在所有變體中路徑都一樣 —— Docker CLI 不知道也不在乎它在跟哪個 daemon 對話。
- **Daemon** 端檔案位置不同，因為每種安裝變體的生命週期擁有者不同（systemd root、systemd --user、VM-inside-GUI 等等）。
- 由 GUI 管理的變體（Docker Desktop、OrbStack）會把設定序列化為磁碟上的 JSON，但不建議直接編輯這些檔案 —— app 下次啟動時會覆寫。

## Client 端代理（chezmoi 管理）

### 它做什麼

`~/.docker/config.json` 有一個頂層的 `proxies.default` 區塊，Docker CLI 會在每次 `docker run` / `docker build` / `docker compose up` 時讀取，並把 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` / `ALL_PROXY` 注入到容器的環境變數中（在 image 建置時也會作為 build-args 注入）。

它**不會**影響 `docker pull` —— 那是 daemon 端的操作，需要 daemon 端的設定（見下一節）。

### 本 repo 如何管理

[dot_docker/modify_config.json.tmpl](../../dot_docker/modify_config.json.tmpl) 是一個 chezmoi `modify_` 腳本。每次 `chezmoi apply` 時：

1. 從 stdin 讀取現有的 `~/.docker/config.json`。
2. 如果 apply 時環境變數有設 `$LOCAL_PROXY_URL`，就透過 `jq` 把 `proxies.default` 合併進 JSON。任何由 `docker login` 或 CLI 自己寫入的 `auths` / `credsStore` / `credHelpers` / `currentContext` / `plugins` / `features` 鍵都會被保留。
3. 如果 `$LOCAL_PROXY_URL` 沒設，則移除 `proxies.default`，若這讓 `.proxies` 變成空的，連那個鍵也一併移除。冪等清理。

URL 命名慣例與 shell 代理輔助函式共用（[docs/tools/web-reader.md](web-reader.md) > 「Proxy behavior」）：

```bash
export LOCAL_PROXY_URL="http://127.0.0.1:7890"           # HTTP/HTTPS
export LOCAL_PROXY_SOCKS_URL="socks5://127.0.0.1:7891"   # 選用；填入 allProxy
chezmoi apply
```

### 驗證

```bash
# 應該顯示 proxies.default 區塊
jq '.proxies' ~/.docker/config.json

# 跑一個容器，檢查環境變數
docker run --rm alpine env | grep -iE 'proxy'
# 預期：HTTP_PROXY、HTTPS_PROXY、NO_PROXY、http_proxy、https_proxy、no_proxy、all_proxy

# docker info 顯示的是 daemon 自己知道的代理（不同層！）
docker info 2>/dev/null | grep -iE 'proxy'
```

### 關閉

```bash
# 暫時：取消設定環境變數，重新 apply
unset LOCAL_PROXY_URL
chezmoi apply

# 永久：從 ~/.zshenv（或你設定的地方）移除 export，
# 下次 chezmoi apply 就會把 proxies.default 移除。
```

## Daemon 端代理（手動配方）

當 `docker pull` 需要走代理時（例如在 GFW 範圍內拉 image）。每種安裝變體都有自己的配方。

### 無根 Docker（Linux）—— systemd --user drop-in

```bash
mkdir -p ~/.config/systemd/user/docker.service.d/
cat > ~/.config/systemd/user/docker.service.d/proxy.conf <<'EOF'
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:7890"
Environment="HTTPS_PROXY=http://127.0.0.1:7890"
Environment="NO_PROXY=localhost,127.0.0.1,.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
EOF

systemctl --user daemon-reload
systemctl --user restart docker
```

驗證：

```bash
docker info | grep -iE 'proxy'
# 預期：
#  HTTP Proxy: http://127.0.0.1:7890
#  HTTPS Proxy: http://127.0.0.1:7890
#  No Proxy: localhost,127.0.0.1,...
```

這**不是**由 chezmoi 管理。原因：編輯它需要重啟 daemon，會殺掉執行中的容器 —— 對自動化的 apply 流程而言不可接受。當代理 URL 改變時請自行管理。

如果 user unit 不在標準位置（某些發行版放法不同），可以用 `systemctl --user status docker` 找出來，看 `Loaded:` 那一行。

### 系統 Docker Engine（Linux）—— systemd drop-in（sudo）

```bash
sudo mkdir -p /etc/systemd/system/docker.service.d/
sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf > /dev/null <<'EOF'
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:7890"
Environment="HTTPS_PROXY=http://127.0.0.1:7890"
Environment="NO_PROXY=localhost,127.0.0.1,.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
EOF

sudo systemctl daemon-reload
sudo systemctl restart docker
```

### Docker Desktop / OrbStack

使用 GUI：

- **Docker Desktop**：Settings > Resources > Proxies。打開「Manual proxy configuration」並填入 HTTP / HTTPS / bypass list。Docker Desktop 會自動重啟 VM 的 daemon。
- **OrbStack**：Settings > Network > Proxy。同樣概念。

直接編輯 JSON 檔案（Desktop 的 `~/Library/Group Containers/group.com.docker/settings.json`；OrbStack 的 `~/.orbstack/config/docker.json`）也行，但下次啟動時若 GUI 寫入相同的鍵就會被蓋掉。

## Registry mirrors —— 兩種策略

### 策略 A：`daemon.json` 中的 `registry-mirrors`

Docker 原生機制。`daemon.json`：

```json
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.mirrors.ustc.edu.cn",
    "https://docker.nju.edu.cn",
    "https://mirror.iscas.ac.cn",
    "https://mirror.baidubce.com"
  ]
}
```

順序很重要：Docker 會依序嘗試 mirror，失敗時 fallback 到 `docker.io`。把 DaoCloud 放第一，因為它最完整；學術 mirror 放後面當 fallback。

**關鍵限制**：`registry-mirrors` 只會鏡像 `docker.io` (Docker Hub)。對 `gcr.io` / `ghcr.io` / `quay.io` / `registry.k8s.io` / `mcr.microsoft.com` / `nvcr.io` **完全沒用**。那些需要 [策略 B](#strategy-b-prefix-substitution-kubesre)。

**Mirror 端點壽命**：mirror 提供者可能下線、限速或被封鎖。目前狀態筆記（截至 2026 年）：

- `docker.m.daocloud.io` —— 多數使用者的首選。已知問題追蹤於 [DaoCloud/public-image-mirror#2328](https://github.com/DaoCloud/public-image-mirror/issues/2328)（大型 image 拉取偶爾會卡住）；解法是重試或換下一個 mirror。
- `docker.mirrors.ustc.edu.cn`、`docker.nju.edu.cn`、`mirror.iscas.ac.cn` —— 學術 mirror；通常可靠，有時較慢。
- `mirror.baidubce.com` —— 百度雲；可靠但有限速。

**為供應鏈安全已移除 (removed for supply-chain safety，2026-07)**：`dockerhub.azk8s.cn`（已棄用的 Azure-China 鏡像）與 `dockerproxy.com`（第三方、ToS 反覆變更）已從受管清單移除。pull-through 鏡像負責解析 `tag→digest`，而 Docker Content Trust 預設關閉，因此一個失效／第三方的鏡像域名一旦註冊過期並被攻擊者重新註冊，就會變成惡意的 pull-through cache，可對 `latest` 之類的 tag 供應被竄改的 image。若要重新加入任何鏡像，請優先選擇高信譽營運方；敏感 image 請以 digest 拉取（`repo@sha256:…`）或啟用 Content Trust。見 mirrors.md 的「安全性與信任模型 (Security and trust model)」一節。

apply + daemon 重啟後驗證：

```bash
docker info | grep -A10 'Registry Mirrors'
```

#### 各安裝變體的放置位置

- **無根 Docker（Linux，repo 預設）** —— `~/.config/docker/daemon.json`。**由 chezmoi 管理**，透過 [dot_config/docker/modify_daemon.json.tmpl](../../dot_config/docker/modify_daemon.json.tmpl)，需 `useChineseMirror=true` + Linux OS 才會啟用。apply 後執行：

  ```bash
  systemctl --user daemon-reload && systemctl --user restart docker
  ```

  chezmoi 刻意不自動重啟（會殺掉執行中的容器；對隱式 apply 不安全）。

- **OrbStack** —— `~/.orbstack/config/docker.json` 或 GUI Settings > Docker > 「Docker daemon config」。OrbStack 在儲存時會重新套用。

- **Docker Desktop** —— GUI：Settings > Docker Engine，把 `registry-mirrors` 貼進 JSON 編輯器，apply + 重啟。

- **系統 Docker Engine（Linux，備援）** —— `/etc/docker/daemon.json`。不由 chezmoi 管理（需要 sudo；chezmoi 管理的無根路徑在這裡不適用）。配方：

  ```bash
  sudo mkdir -p /etc/docker
  sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
  {
    "registry-mirrors": [
      "https://docker.m.daocloud.io",
      "https://docker.mirrors.ustc.edu.cn",
      "https://mirror.baidubce.com"
    ]
  }
  EOF
  sudo systemctl daemon-reload && sudo systemctl restart docker
  ```

##### 遷移筆記：轉向前的有根安裝

如果本 repo 在轉向無根之前就幫你設定好了 Linux 機器（也就是透過舊的 `get.docker.com` 便利腳本任務，只留下有根的 `dockerd` 在跑），chezmoi 管理的 `~/.config/docker/daemon.json` 中的 mirrors 會被默默忽略 —— 有根 daemon 只讀 `/etc/docker/daemon.json`。可以用 `docker info | grep -A10 'Registry Mirrors'` 驗證；如果它是空的、但 `useChineseMirror=true` 且 `~/.config/docker/daemon.json` 有內容，那就是這個狀態。

兩種解法：

1. **轉向無根（建議）** —— 與 repo 預設一致。重新跑 ansible role：它現在會安裝 `docker-ce-rootless-extras` + 前置依賴、停用有根 daemon、跑 `dockerd-rootless-setuptool.sh install`，並啟用 `loginctl enable-linger`。完成後執行 `systemctl --user daemon-reload && systemctl --user restart docker`，再用 `docker info` 驗證有顯示你的 mirrors。
2. **維持有根** —— 用上面的配方把 mirrors 複製到 `/etc/docker/daemon.json`，重啟系統 daemon，並在 chezmoi 中設定 `useChineseMirror=false`（或接受那個沒用到的無根檔案閒置在那裡）。

#### 切換 chezmoi 管理的設定

不修改 template 也能關閉 mirrors：

```bash
chezmoi init --force   # 對 useChineseMirror 答 `n`
chezmoi apply
# modify 腳本會在下次 apply 時移除 .["registry-mirrors"]
systemctl --user daemon-reload && systemctl --user restart docker
```

### 策略 B：前綴替換 (kubesre)

對於 `registry-mirrors` 幫不上忙的 registry。模型：把 image 引用改寫，讓它走 mirror 自己的網域。不需要 `daemon.json` 條目。

來源：[kubesre/docker-registry-mirrors](https://github.com/kubesre/docker-registry-mirrors)。公開端點有限速（撰寫時為 20 req/min/IP）；若你在意持續吞吐量請自架 —— 上游 README 有單檔 Cloudflare Worker 配方。

兩種形式：

1. **前綴附加**（推薦）：

   ```text
   k8s.gcr.io/coredns/coredns        =>  kubesre.xyz/k8s.gcr.io/coredns/coredns
   ```

2. **前綴替換**（依 registry）：

   | 上游 | 替換為 |
   |----------|-------------|
   | `docker.io` | `dhub.kubesre.xyz`（注意：`docker.kubesre.xyz` 已被封鎖） |
   | `gcr.io` | `gcr.kubesre.xyz` |
   | `ghcr.io` | `ghcr.kubesre.xyz` |
   | `k8s.gcr.io` | `k8s-gcr.kubesre.xyz` |
   | `registry.k8s.io` | `k8s.kubesre.xyz` |
   | `mcr.microsoft.com` | `mcr.kubesre.xyz` |
   | `nvcr.io` | `nvcr.kubesre.xyz` |
   | `quay.io` | `quay.kubesre.xyz` |
   | `docker.elastic.co` | `elastic.kubesre.xyz` |
   | `cr.l5d.io` | `l5d.kubesre.xyz` |

範例工作流程 —— 透過 mirror 拉取，再重新打 tag 為標準名稱，這樣本地引用就不必更動：

```bash
docker pull ghcr.kubesre.xyz/kubevirt/virt-launcher:v1.2.0
docker tag  ghcr.kubesre.xyz/kubevirt/virt-launcher:v1.2.0 \
            ghcr.io/kubevirt/virt-launcher:v1.2.0
```

或者在 Dockerfile / compose.yaml 中直接就地修改 image 引用。

**何時用哪個：**

- `docker.io/foo:bar` → 策略 A (daemon.json) 透明處理。不需改動 image 引用。
- `gcr.io/foo:bar`、`ghcr.io/...`、`quay.io/...` → 策略 B（改寫）。
- 實務模式：兩者並用 —— daemon.json 處理 Docker Hub，視需要改寫非 Hub 的引用。

## OrbStack 評估

目前 macOS 預設於 [dot_ansible/roles/docker/tasks/main.yml](../../dot_ansible/roles/docker/tasks/main.yml)（如果 Docker Desktop 已安裝就 fallback 到 Docker Desktop —— 避免與既有安裝打架）。

它為什麼贏得這個位置：

- **RAM**：OrbStack idle 時只占幾百 MB；Docker Desktop 在零容器狀態下通常坐在 2 GB+。
- **啟動**：次秒級冷啟動 vs Docker Desktop 的 10-30 秒 VM 啟動。
- **Apple Silicon**：原生虛擬化，`arm64` image 沒有 Rosetta 開銷。
- **內建 K8s**：一鍵切換的輕量叢集，比 Docker Desktop 內嵌的 k8s 快。
- **Docker CLI 直接相容**：`docker` / `docker compose` / `docker buildx` 行為一致；`~/.docker/config.json` 會被尊重（所以 chezmoi 管理的 client 代理也能用）。

何時應該 fallback 到 Docker Desktop：

- **企業政策**強制使用 Docker Desktop（驗證、稽核、支援合約）。
- **Compose V1 邊緣案例** —— 罕見，但 Docker Desktop 隨附 reference 實作。
- **Windows 主機** —— OrbStack 僅限 macOS。

OrbStack 把它的 daemon 覆寫存在 `~/.orbstack/config/docker.json`（與 `/etc/docker/daemon.json` 同 schema）。在那裡新增的 registry mirrors 會在 OrbStack 重啟後生效（GUI 會在儲存時自動處理重啟）。

## Podman 評估

對 Linux / macOS 開發機而言是合理的未來替代品。預設沒有切換過去，因為 Docker 生態的 compose 操作體驗依然稍微順手一些。

何時值得考慮：

- **授權乾淨** —— Podman 從頭到尾都是 Apache-2.0；不必擔心 Docker Desktop 的授權層級。
- **無 daemon + 預設無根** —— 在不需要 systemd user-unit 機制的情況下，達到無根 Docker 的安全性故事。`podman run` 直接以你的使用者身分 fork；沒有長壽 daemon 需要重啟。
- **`alias docker=podman`** —— 不改程式碼就能涵蓋日常 `docker run` / `docker build` / `docker ps` 用法的 80-90%。

何時暫緩：

- **`podman compose` 落後 `docker compose`** 在網路邊緣案例（自訂 DNS 的使用者定義 bridge、跨網路的 service alias）以及部分 volume 語意上。
- **BuildKit 功能對等** —— podman 底層使用 `buildah`；多數 BuildKit 功能可用，但偶爾特定的 `--mount=type=cache` 或 secret 處理語法會有差異。
- **不支援 Swarm**（個人使用幾乎不相關，但仍然存在）。
- **macOS** 需要 `podman machine` —— 又一個有自己生命週期的 VM，抵銷了 podman 在 Mac 上「無 daemon」的部分吸引力。

代理設定：純環境變數（無 daemon）。[dot_config/zsh/tools/50_networking.zsh](../../dot_config/zsh/tools/50_networking.zsh) 中的 `proxy-on` shell 函式會把 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` 匯出到當前 shell —— 那正是 `podman run` / `podman build` 所遵守的變數。

Registry mirrors：不同 schema。`~/.config/containers/registries.conf` 使用 `[[registry]]` 區塊搭配 `mirror` 子區塊：

```toml
unqualified-search-registries = ["docker.io"]

[[registry]]
prefix   = "docker.io"
location = "docker.io"
  [[registry.mirror]]
  location = "docker.m.daocloud.io"
  [[registry.mirror]]
  location = "docker.mirrors.ustc.edu.cn"
```

本 repo 不由 chezmoi 管理（尚無 Podman 安裝 role）。若你真的切換過去，就加一個。

結論：值得了解，但今天還不值得切換。如果 Docker 的授權情況收緊、或是無根 Docker 的網路故事變成真正的阻礙，再回頭看。

## 驗證檢查清單

```bash
# 1. Client 代理（chezmoi 管理）
jq '.proxies' ~/.docker/config.json
docker run --rm alpine env | grep -iE 'proxy'

# 2. Daemon 代理
docker info | grep -iE 'proxy'

# 3. Registry mirrors
docker info | grep -A10 'Registry Mirrors'

# 4. 端到端：拉一個 image，量時間。如果有設定，應該會先用 mirror。
time docker pull hello-world

# 5. 確認 chezmoi 管理的檔案符合預期
chezmoi managed | grep -iE 'docker'
chezmoi diff ~/.docker/config.json ~/.config/docker/daemon.json
```

## 疑難排解

| 症狀 | 可能原因 | 修法 |
|---------|--------------|-----|
| `docker pull` 很慢／逾時 | 在 GFW 網路上沒設定 daemon 代理 | 寫入 systemd drop-in（[見上](#rootless-docker-linux--systemd---user-drop-in)）或新增 `registry-mirrors`；重啟 daemon |
| 容器裡的 `docker run` 連不上網 | 沒有 client 代理；或 `chezmoi apply` 跑的時候 `$LOCAL_PROXY_URL` 沒設 | 匯出 `$LOCAL_PROXY_URL`，重新 apply：`chezmoi apply`；以 `docker run --rm alpine env \| grep -i proxy` 驗證 |
| 設定改了但 `docker info` 還顯示舊代理 | Daemon 沒重啟 | `systemctl --user daemon-reload && systemctl --user restart docker`（或對應你的變體） |
| `daemon.json` 中的 registry-mirrors 對 `gcr.io` 拉取無效 | 策略 A 設計上只支援 Docker Hub | 使用 [kubesre 前綴替換](#strategy-b-prefix-substitution-kubesre) |
| 每次 apply `chezmoi diff` 都因為純格式變動而 churn | `jq` 一律 pretty-print；既存檔案是 minified | 純粹外觀問題 —— 接受一次 diff；之後的 apply 都是 no-op |
| `~/.docker/config.json` 被覆寫，我的 `auths` 不見了 | 是不是你繞過了 `modify_` 腳本？ | 本 repo 的腳本使用 `jq --arg` 路徑限定寫入，會保留其他鍵。如果你手動改過，從 `docker login`（或你的 cred store）恢復 |
| `useChineseMirror=false` 但 `~/.config/docker/daemon.json` 仍有 mirrors | 上次 apply 留下的殘留 + template 行為正確但目標 daemon 檔案沒被觸碰 | 檢查 `chezmoi diff ~/.config/docker/daemon.json`；在 macOS 上 modify 腳本會輸出空的，chezmoi 會放著檔案不動，你可能需要手動刪除 |

## 相關

- [docs/tools/container-config-map.md](container-config-map.md) —— 每個容器設定檔的對照地圖（誰在讀它、有根 vs 無根、原生 vs 相容層）。
- [docs/tools/web-reader.md](web-reader.md) —— 與本設定共用的 `$LOCAL_PROXY_URL` 慣例與 shell 代理輔助函式。
- [docs/shells/aliases.md](../shells/aliases.md) —— `proxy-on` / `proxy-off` / `withproxy` / `try_direct_then_proxy` 速查。
- [docs/linux-package-sources.md](../linux-package-sources.md) —— 更廣的 Linux 套件政策（apt vs snap vs brew vs GitHub binaries），如果你在決定要透過 apt 還是 Linuxbrew 安裝 Docker。

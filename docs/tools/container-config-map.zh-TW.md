# 容器 (Container) 設定地圖 —— 哪個檔案是給誰讀的

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

針對盤根錯節的「Docker 設定」生態的參考地圖。如果你正要編輯一個外觀像 Docker 的檔案、卻不確定它屬於哪一層，請從這裡開始。實際的操作食譜（本倉庫實際管理什麼，以及如何設定你的機器），請見 [containers.md](containers.md)。

簡短版：看起來像「同一份設定、多個位置」的東西，其實是好幾個各自獨立的層次，只是它們都會提及 Docker。同一個檔名根據是「誰在讀」，可能代表完全不同的東西。

## 四個讀取者

你磁碟上的每一份「Docker 設定」檔，恰好會被以下其中一個讀取：

1. **Docker CLI**（`docker`） —— 命令列客戶端 (client)，讀取使用者層級的客戶端偏好設定。
2. **Docker daemon**（`dockerd`） —— 真正執行建構／拉取／執行容器的引擎行程 (process)。
3. **Service manager**（實務上是 systemd） —— 讀取 unit 檔與 drop-in 來決定 daemon 如何啟動。
4. **桌面 app 包裝層**（Docker Desktop、OrbStack） —— 在引擎之上包裝自己一份設定的 GUI／VM 層。
5. **相容層 (compatibility layer)**（Podman、OrbStack） —— 為了互通會讀取部分 Docker 檔案，其餘則完全略過。

各讀取者的標準路徑：

| 讀取者 | 標準路徑 | 內容 | 備註 |
|--------|----------------|----------|-------|
| Docker CLI | `~/.docker/config.json` | `auths`、`credsStore`、`credHelpers`、`currentContext`、`proxies.default`、`plugins`、`features` | 不是 daemon 檔。可由 `$DOCKER_CONFIG` 覆寫。 |
| Docker daemon（rootful） | `/etc/docker/daemon.json` | `registry-mirrors`、`data-root`、`dns`、`insecure-registries`、`experimental`、`features`、…… | 編輯需要 root 權限。 |
| Docker daemon（rootless） | `~/.config/docker/daemon.json` | 與 rootful 相同 schema | 路徑刻意與 CLI 目錄（`~/.docker`）不同。 |
| systemd（rootful） | `/etc/systemd/system/docker.service.d/*.conf` | `Environment=HTTP_PROXY=...`、`ExecStart=` 覆寫 | drop-in，跑在 PID 1 之下。 |
| systemd（rootless） | `~/.config/systemd/user/docker.service.d/*.conf` | 概念相同 | 在 `systemctl --user` 之下執行。 |
| Docker Desktop（macOS） | `~/Library/Group Containers/group.com.docker/settings-store.json` | 完整的 Desktop 設定儲存（proxy、Kubernetes 開關、資源限制、……） | 不建議直接編輯；GUI 會覆寫。 |
| Docker Desktop（Linux） | `~/.docker/desktop/settings-store.json` | 概念相同 | |
| Docker Desktop（Windows） | `%APPDATA%\Docker\settings-store.json` | 概念相同 | |
| Docker Desktop 受管理（企業） | `admin-settings.json`（依平台而異） | 由組織管理員推送的政策覆寫 | |
| OrbStack | `~/.orbstack/config/docker.json` | 與 `daemon.json` 相同 schema；管理 OrbStack 內嵌的引擎 | 不是 `/etc/docker/daemon.json`。 |
| Podman | `containers.conf`、`storage.conf`、`registries.conf`、`auth.json` | Podman 自己的設定家族，依 XDG 規範擺放 | **不會**讀取 `daemon.json`。可能僅針對認證 (auth) 退而求其次去讀 `~/.docker/config.json`。 |

## 安裝樣態矩陣

相同的 Docker 指令，實際生效的檔案卻不同。四種真實世界的安裝樣態：

### A. Docker Engine rootful（Linux，系統 daemon）

- **客戶端**：`~/.docker/config.json`
- **Daemon**：`/etc/docker/daemon.json`
- **Service 覆寫**：`/etc/systemd/system/docker.service.d/*.conf`
- **Socket**：`/var/run/docker.sock`
- **資料**：`/var/lib/docker`

範圍：daemon 是整機共用（`docker` 群組裡的所有使用者都能與同一個 daemon 對話）。編輯 daemon 設定需要 `sudo`。Service 重啟會踢掉所有正在執行的容器。

### B. Docker Engine rootless（Linux，每使用者一個 daemon）

- **客戶端**：`~/.docker/config.json`
- **Daemon**：`~/.config/docker/daemon.json`
- **Service 覆寫**：`~/.config/systemd/user/docker.service.d/*.conf`
- **Socket**：`$XDG_RUNTIME_DIR/docker.sock`（通常是 `/run/user/$UID/docker.sock`）
- **資料**：`~/.local/share/docker`

範圍：每使用者獨立。daemon 端任何操作都不需要 sudo。重啟只會影響自己的容器。`systemctl --user` 必須處於啟用狀態（需要 `dbus-user-session` 套件 + `loginctl enable-linger` 才能在登出後仍持續執行）。設定 `DOCKER_HOST=unix://...` 讓 CLI 找得到使用者 socket。

這是本倉庫在 Linux 上的預設模式 —— 見 [dot_ansible/roles/docker/tasks/main.yml](../../dot_ansible/roles/docker/tasks/main.yml)。

### C. Docker Desktop（macOS／Windows／有時 Linux）

- **客戶端**：`~/.docker/config.json`（與其他環境相同）
- **Desktop 設定**：`settings-store.json`（路徑見上方平台對應）
- **Daemon 設定編輯器**：GUI → Settings → Docker Engine（會寫入一段 JSON blob，由 Docker Desktop 餵給 VM 內的 `dockerd`）
- **Proxy**：Settings → Resources → Proxies。**Docker Desktop 的 proxy 不會讀取 `daemon.json`** —— 這在上游文件中明確指出；proxy 一律要透過 Desktop UI 設定。
- **企業政策**：受管理部署用的 `admin-settings.json`

範圍：Desktop app 擁有 daemon 生命週期（VM 開機、引擎重啟）。手動編輯 JSON 檔可能有效，直到 GUI 在下次啟動時把同樣的 key 覆寫。

### D. OrbStack（macOS）

- **客戶端**：`~/.docker/config.json`
- **Daemon 設定**：`~/.orbstack/config/docker.json`（與 `daemon.json` 相同 schema）或 GUI → Settings → Docker
- **Socket 相容性**：在獲得管理權限時，OrbStack 會把 `/var/run/docker.sock` 符號連結到自己的引擎 socket，這樣硬寫死 rootful 路徑的第三方工具仍能運作
- **Proxy**：GUI → Settings → Network → Proxy

範圍：以 VM 為後端，生命週期故事與 Docker Desktop 類似，但設定路徑不同。並非 Docker 原生：傳統的 `/etc/docker/daemon.json` 路徑根本沒在用。

### E. Podman（Linux + 透過 `podman machine` 在 macOS 上執行）

- **CLI 認證（fallback）**：`~/.docker/config.json` —— Podman 會優先看自己的 `auth.json`，不存在時才退而求其次到此
- **自有設定家族**：
  - `~/.config/containers/containers.conf` —— 執行階段 (runtime)、引擎、網路預設值
  - `~/.config/containers/storage.conf` —— 儲存驅動 (storage driver) / graphroot
  - `~/.config/containers/registries.conf` —— registry 搜尋順序與鏡像（TOML 的 `[[registry]]` 區塊，並非 `daemon.json` 的 schema）
  - `$XDG_RUNTIME_DIR/containers/auth.json` —— 認證 token
- **Socket（rootless）**：`$XDG_RUNTIME_DIR/podman/podman.sock`
- **資料**：`~/.local/share/containers/storage`

範圍：無 daemon (daemonless)（Podman 直接以你的使用者身分 fork 出行程；沒有需要重啟的長壽引擎）。沒有 `daemon.json`。Docker 相容性透過 REST API shim 與一個 compose provider 達成，並非檔案層級的共用。

## 為什麼 `~/.docker` 與 `~/.config/docker` 並存

歷史包袱：

- `~/.docker` 早於 XDG Base Directory 規範被廣泛採用之前。它是 Docker CLI 長期以來的 home。
- Rootless Docker 較新，從一開始就圍繞 XDG 設計（`~/.config/docker/daemon.json`、`~/.local/share/docker`、`$XDG_RUNTIME_DIR/docker.sock`）。
- 兩條路徑並存，是因為更動 `~/.docker` 會打壞所有把它寫死的工具。

上游文件明確指出：rootless daemon 的設定目錄（`~/.config/docker`）**刻意**與客戶端目錄（`~/.docker`）不同。它們是給不同讀取者看的。

## 相容層的陷阱

那些「看起來相容但其實不是」、或反過來的情況：

- **Podman 會讀取 `~/.docker/config.json`** —— 但僅作為 auth 的 fallback。它不會讀取 `daemon.json`。如果你把 `docker` 換成 `podman`，registry 認證仍然有效；你的鏡像則不會。
- **OrbStack 的 socket symlink** —— 當 `/var/run/docker.sock` 指向 OrbStack 引擎時，VS Code Dev Containers、Testcontainers 等工具，以及任何把 `DOCKER_HOST=unix:///var/run/docker.sock` 寫死的程式都「直接可用」。但實際的 daemon 設定在 `~/.orbstack/config/docker.json`，不是 `/etc/docker/daemon.json`。
- **Docker Desktop 的 proxy 不會讀取 `daemon.json`** —— 上游文件明確指出：proxy 設定必須來自 Desktop UI（或 `admin-settings.json`）。把 `proxies` 寫進 `daemon.json` 在 Desktop 上是默默無作用 (silently does nothing)。
- **`registry-mirrors` 只會鏡像 Docker Hub** —— 不包含 `gcr.io`、`ghcr.io`、`quay.io`、`registry.k8s.io` 等。對這些 registry，請見 [containers.md 的 Strategy B（kubesre 前綴替換）](containers.md#strategy-b-prefix-substitution-kubesre)。
- **rootful 與 rootless 互相獨立** —— `/etc/systemd/system/docker.service.d/` 裡的 systemd drop-in 對 `systemctl --user` 的 docker unit 完全沒效，反之亦然。兩者都不會影響 Docker Desktop VM 的引擎。

## 判斷準則

當你在野外撞見一份「Docker 設定」檔、不確定它在控制什麼時，問三個問題：

1. **誰在讀？** CLI？daemon？systemd？Desktop app？相容層？
2. **rootful 還是 rootless？**（只在 Linux 原生 Docker 才有意義。）看路徑前綴：`/etc/...` 或 `/var/...` → rootful；`~/.config/...`、`~/.local/...`、`$XDG_RUNTIME_DIR/...` → rootless。
3. **原生 Docker 還是相容層？** `/etc/docker/...` / `~/.config/docker/...` / `~/.docker/...` → 原生。`~/.orbstack/...` → OrbStack。`~/.config/containers/...` → Podman。`settings-store.json` / `admin-settings.json` → Docker Desktop。

回答完這三個問題，該檔案的範圍與重啟語意 (semantics) 也就一目了然。

## 本倉庫管理什麼、放生什麼

回顧邊界 —— 完整操作食譜在 [containers.md](containers.md)：

| 層級 | 檔案 | 由誰寫 |
|-------|------|---------------|
| 系統層（root） | `/etc/docker/...`、`/etc/systemd/...` | Ansible（搭配 `sudo`），僅供 rootful 退路使用；正常情況下不動 |
| 使用者層（daemon） | `~/.config/docker/daemon.json` | chezmoi：[dot_config/docker/modify_daemon.json.tmpl](../../dot_config/docker/modify_daemon.json.tmpl) |
| 使用者層（systemd 覆寫） | `~/.config/systemd/user/docker.service.d/proxy.conf` | 手動（食譜在 `containers.md`） |
| 使用者層（客戶端） | `~/.docker/config.json` | chezmoi：[dot_docker/modify_config.json.tmpl](../../dot_docker/modify_config.json.tmpl) |
| 安裝本身 | Docker Engine + rootless 設定 | Ansible：[dot_ansible/roles/docker/tasks/main.yml](../../dot_ansible/roles/docker/tasks/main.yml) |
| 桌面 app | OrbStack / Docker Desktop 設定 | 由 GUI 擁有；不要納入 dotfiles 追蹤 |

原則：**系統層設定走 Ansible（搭配 sudo），使用者層設定走 chezmoi。** Linux 上做到 rootless 的轉向後，這條界線才劃得乾淨 —— 現在 chezmoi 管理的 Docker 設定全都是使用者範圍，所以無需 root 也能運作。

## 相關連結

- [containers.md](containers.md) —— 操作食譜、proxy 策略、鏡像端點 (mirror endpoint) 備註、疑難排解。
- [web-reader.md](web-reader.md) —— 與 shell proxy 輔助函式 (helper) 共用的 `$LOCAL_PROXY_URL` 慣例。
- [dot_config/zsh/tools/50_networking.zsh](../../dot_config/zsh/tools/50_networking.zsh) —— `proxy-on` / `withproxy` 輔助函式以及 rootless 模式的 `DOCKER_HOST` export。

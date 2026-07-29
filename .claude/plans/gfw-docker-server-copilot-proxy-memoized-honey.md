# docker-net — GFW 下 Docker registry 出口的診斷與自動接線

## Context

**問題**:GFW 下 `docker pull` 經常「找不到 server」,而且遇到 mirror 沒有的 image(ghcr/gcr/quay,或 DaoCloud 限流的)只能手動做 workaround(例如把 `metacubex/mihomo` 換成 `alpine` + 從 GitHub 抓 binary 塞進去)。

**目前 repo 的處理**只有兩層,而且兩層都不管 `docker pull`:

| 檔案 | 管什麼 | 對 `docker pull` 有用嗎 |
|---|---|---|
| `dot_config/docker/modify_daemon.json.tmpl` | `registry-mirrors`(5 個) | 只對 `docker.io` 有用 |
| `dot_docker/modify_config.json.tmpl` | `~/.docker/config.json` 的 `proxies.default` | **沒用** — 那只注入到 `docker run`/`build` 的 container 環境 |

daemon 層的 proxy(真正決定 `docker pull` 走哪條路的東西)**repo 完全沒管**,`docs/tools/containers.md:114-141` 只有一段手動 recipe,理由是「改了要重啟 daemon,會殺掉 running containers,不適合放進自動 apply」。

### 本機實測(2026-07-29,`david-ubuntu`)

跑了 `docker info` / `readlink /proc/<pid>/ns/net` / 對每個 mirror 與 registry 做 `curl /v2/` 直連與走 proxy 的雙向探測、以及用「pull 一個不存在的 tag」測 daemon 自己的出口。結論:

1. **daemon 完全沒有 proxy** — `docker info` 的 `HttpProxy`/`HttpsProxy`/`NoProxy` 全是空字串。
2. **現在能通純粹是因為 mihomo 開了 TUN** — `Meta` 介面 + `auto-route: true` + `dns-hijack: any:53` + `fake-ip-range: 198.18.0.1/16`。一旦 mihomo 改回單純 mixed-port 模式(或換一台只有 SOCKS tunnel 的機器),`docker pull` 立刻全滅。
3. **`registry-mirrors` 5 個裡 4 個是死的**(全部實測):

   | mirror | 直連結果 | 判讀 |
   |---|---|---|
   | `docker.m.daocloud.io` | `401` / 47ms | 健康(唯一) |
   | `docker.mirrors.ustc.edu.cn` | `Could not resolve host` | 網域已無 DNS 紀錄 |
   | `docker.nju.edu.cn` | `403` | 校園網限定 |
   | `mirror.iscas.ac.cn` | `502` | 壞了 |
   | `mirror.baidubce.com` | `SSL_ERROR_SYSCALL` | BCE 內網限定,外部 TLS reset |

   Docker 是**依序**試 mirror 的,4 個死的每個都要吃一次 timeout / 吐一次誤導性錯誤,這就是「經常找不到 server」的主因。錯誤長相是 `unexpected status from HEAD request to https://...` 和 `failed to resolve reference "docker.io/library/..."` — 看起來像 image 不存在,其實是 mirror 掛了。

4. **有兩份 pre-pivot 的死設定在誤導除錯**:`/etc/systemd/system/docker.service.d/http-proxy.conf`(內容正確地指向 `127.0.0.1:7890`)和 `/etc/docker/daemon.json`(`{"dns":["8.8.8.8","8.8.4.4"]}`),但 rootful `docker.service` 早已 `disabled`+`inactive`(repo 在 `ec3434a` pivot 到 rootless)。看到那個檔案的人會以為 proxy 設好了。

5. **關鍵好消息 — rootless dockerd 跑在 host netns**。`dockerd` (pid 2549) 的 `net:[4026531833]` 和 shell 相同;只有 rootlesskit 的 child (pid 2400) 在 detached netns。這是 rootlesskit ≥2.0 的 `--detach-netns` 行為(cmdline 實際有這個 flag)。**所以廣為流傳的「rootless docker 連不到 host loopback、proxy 不能寫 127.0.0.1」在這裡不成立** — daemon proxy 是可以設而且會生效的。但這依賴 Docker ≥25 / rootlesskit ≥2.0,舊版會**靜默失效**,所以工具要偵測而不是假設。

6. **副作用發現**:`~/.zshrc.adhoc:18` 有 `export HTTP_PROXY=... HTTPS_PROXY=... ALL_PROXY=socks://127.0.0.1:7890` — `socks://` 不是合法 scheme(Go 和 curl 認的是 `socks5://`),而且只有大寫沒有小寫、也沒有 `NO_PROXY`。這是使用者自己的 untracked 檔案,repo 不能管,但 `doctor` 應該要抓出來。

**目標**:把 daemon 層的出口變成可偵測、可診斷、可一鍵接線的東西,並且給「mirror 沒有的 image」一條不用重啟 daemon 的即時退路。

---

## 設計

### 決策紀錄

| 決策 | 選擇 | 理由 |
|---|---|---|
| 工具形態 | shell 函式族 `dot_config/shell/51_docker_net.sh` | 直接呼叫 `__net_detect_proxy`,零 IPC;照 `43_copilot_proxy.sh` 前例 |
| 名字 | `docker-net` | `docker-proxy` **不能用** — 那是 Docker 自己的 `/usr/bin/docker-proxy` port forwarder |
| daemon proxy 機制 | daemon.json 的 `proxies` key,**不用** systemd drop-in | 實測 `dockerd --http-proxy/--https-proxy/--no-proxy` flag 存在(Engine ≥23),單一檔案、rootless/rootful 寫法一致、不需要 systemd 知識 |
| mirror 清單 | 縮到只留 DaoCloud | 4 個實測已死;而且每個 pull-through mirror 都是一個 tag→digest 信任面(Content Trust 預設關閉),減少數量同時是安全性收斂 |
| 退路工具 | `skopeo` | apt(Ubuntu 24.04 universe `1.13.3`)+ brew(`1.23.0`)都有;`docker-daemon:` transport 直接寫進 daemon,不需要中間 tar、不需要重啟 |

### 寫入者切分(避免兩個 writer 打架)

`~/.config/docker/daemon.json` 由兩方共用,但**各自只碰自己的 key**:

- **chezmoi 只管 `registry-mirrors`** — 現有 template(`:43-51`)本來就只做 `.["registry-mirrors"] = [...]` / `del(...)`,其他 key 一律保留。不需要改這個語意。
- **`docker-net` 是 `.proxies` 的唯一 writer** — chezmoi 永遠不碰。fleet 的重現方式是 `just fleet-exec 'docker-net on'`,不是 apply-time env。

（刻意**不**沿用 `dot_docker/modify_config.json.tmpl` 那種 apply-time `$LOCAL_PROXY_URL` 的做法:proxy port 會變(Verge 7897 / mihomo 7890),apply 當下烤進去的值很快就過期。）

### 兩種重載成本不同 — 這點目前 repo 的文件講錯了

- `registry-mirrors` **是 SIGHUP-reloadable** → `systemctl --user reload docker`,**不會殺掉 running containers**
- `proxies` **不是** → 必須 restart

現在 `modify_daemon.json.tmpl:9-11` 和 `containers.md:139` 一律說「要 restart,會殺 container」,對 mirror 那半是過度保守。實作時要實測驗證(見 Verification 第 3 項),確認後修正這兩處文案。

---

## 實作

### 1. `dot_config/shell/51_docker_net.sh`(新;`51_` 目前未佔用,且排在 `50_networking.sh` 之後)

沿用 `43_copilot_proxy.sh` 的三個既有模式:

- **proxy 解析**:照抄 `_copilot_resolve_http_proxy`(`43_copilot_proxy.sh:436-475`)的形狀 — `DOCKER_NET_PROXY=auto|always|never|<url>`,委派給 `__net_detect_proxy`,並保留 `command -v __net_detect_proxy` 的 guard。預設用 `_NET_PROXY_CACHE`(`http://` 那個,走 CONNECT),`--socks` 才改用 `__net_all_proxy_url`。**必須拒絕 `socks://`**(非法 scheme)並提示 `socks5://`。
- **探測**:照抄 `_copilot_probe`(`:366-375`)— `curl -o /dev/null -sS -w '%{http_code}|%{time_total}' --max-time 12`,無 proxy 時 `--noproxy '*'`,有則 `-x`。關鍵語意保留:**任何 HTTP status 都代表對方有回應,只有 connect 失敗才算故障**。
- **報表**:照抄 `doctor` 的 `_ok/_bad/_note/_skip/_hint` reporters(`:696-700`),含 `[ -t 1 ]` 才上色、離開時 `unset -f`。

**動詞**:

| 動詞 | 行為 |
|---|---|
| `docker-net status`(無參數時的預設) | 一屏現況:install shape、daemon netns、daemon proxy、生效中的 mirror、`__net_detect_proxy` 的結果與 source、TUN 偵測、死設定警告 |
| `docker-net doctor` | 下面 9 段完整診斷 |
| `docker-net on [URL]` | 解析 proxy → jq 寫入 `.proxies` → 列出 running containers 並確認(`-y` 跳過)→ restart → 用 `docker info` 驗證前後差異 |
| `docker-net off` | `jq 'del(.proxies)'` + 同樣的重啟流程 |
| `docker-net mirrors` | 只跑 doctor 的第 6 段,快速版 |
| `docker-net pull <ref> [args...]` | 降級階梯(見下) |

**`doctor` 的 9 段**:

1. **Install shape** — rootless / rootful / Desktop / OrbStack;`DOCKER_HOST`;version;**在用的 daemon.json 路徑是否對得上 install shape**(這段抓 pre-pivot 孤兒)
2. **Daemon netns** — 比對 `readlink /proc/<dockerd-pid>/ns/net` 與 shell 的。相同 → `127.0.0.1` proxy 可用;不同 → 警告 loopback 不通,建議改用 LAN IP。**這是 rootlesskit 版本差異的靜默失效點,必須偵測不能假設**
3. **Stale config** — rootful drop-in 與 `/etc/docker/daemon.json` 在 rootful 已停用時的告警。**只印出 `sudo rm` 指令,絕不自動刪**
4. **Local proxy** — 委派 `__net_detect_proxy`;檢查 scheme 合法性、大小寫 env 是否成對、`NO_PROXY` 是否缺漏
5. **Transparent proxy** — TUN 介面(`Meta`/`utun*`)+ fake-ip 路由偵測。有 TUN 且 daemon 在 host netns → 明說「daemon 出口已經被 L3 接管,顯式 proxy 是可選的」。**沒有這段,使用者設完 proxy 也分不出到底有沒有生效**
6. **Mirror 健康矩陣** — mirror 清單從 `docker info` 讀(不是從檔案讀,才不會和實際生效的漂掉);每個做直連 + 走 proxy 雙探測
7. **Upstream registry 矩陣** — `docker.io` / `ghcr.io` / `gcr.io` / `quay.io` / `registry.k8s.io`,同樣雙探測
8. **Daemon 端出口** — `docker pull <registry>/<不存在的 repo>:__probe__`。這是**唯一測到 daemon 真實路徑**的探法(curl 測的是 shell 的路徑,兩者可以不同),而且不會下載任何東西
9. Summary:`N failed, M warning(s)`

`/v2/` 回應的判讀表(給第 6、7 段共用):

| 回應 | 判讀 |
|---|---|
| `200` / `401` | 健康 |
| `403` | 連得到但拒絕(校園網 / geo-block) |
| `404` | 不是 registry endpoint |
| `5xx` | mirror 壞了 |
| `000` + `Could not resolve host` | 網域沒了 |
| `000` + `SSL_ERROR_SYSCALL` | TLS reset(被阻斷或內網限定) |
| `000` + timeout | 黑洞 |

**`docker-net pull` 的降級階梯**(每一階往 stderr 印 `[docker-net] rung N: ...`,照 `try_direct_then_proxy` 的 `[retry via proxy ...]` 慣例):

1. `docker pull <ref>` 原樣
2. 失敗且 ref 屬於 Docker Hub → 對每個**健康的** mirror `M`:`docker pull M/<repo>:<tag>` → `docker tag` 回正規名 → `docker rmi` 掉 mirror tag。單段 repo 名要補 `library/`(`nginx` → `docker.m.daocloud.io/library/nginx`)
3. 還是失敗 → `withproxy skopeo copy --retry-times 3 docker://<ref> docker-daemon:<ref>` — **client 自己走 proxy,完全繞過 daemon 的網路**。skopeo 沒裝就印安裝指令並停。`DOCKER_NET_PLATFORM` 轉成 `--override-os/--override-arch`
4. 還是失敗 → 提示 `docker-net on` 與 `docker-net doctor`

**env 旋鈕**:`DOCKER_NET_PROXY`(`auto|always|never|<url>`,預設 `auto`)、`DOCKER_NET_NO_PROXY`(額外 no-proxy 條目)、`DOCKER_NET_MIRRORS`(覆寫探測用的 mirror 清單)。

`no-proxy` 預設值:`localhost,127.0.0.1,::1,*.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16` **+ 每個生效中的 mirror hostname**(否則 CN mirror 的流量會被繞去 proxy,又慢又可能不通)+ `$DOCKER_NET_NO_PROXY`。

### 2. `dot_config/docker/modify_daemon.json.tmpl`(改)

- mirror 清單 `:43-49` → 只留 `https://docker.m.daocloud.io`
- header comment 加兩件事:`.proxies` 由 `docker-net` 獨佔、此處刻意不碰;`registry-mirrors` 用 `systemctl --user reload docker`(SIGHUP)即可,不必 restart
- 保留 `jq` guard(`:28-31`,`pitfalls/modify-script-jq-bootstrap-cycle.md` 的要求)與 else 分支的 `del()`

### 3. `dot_ansible/roles/devtools/tasks/main.yml`(改)

`skopeo` 加進 macOS brew 清單(`:56-` 附近)與 Debian apt 清單。**注意** `apt` 任務要沿用該 role 既有的 `update_cache: false` 慣例(`roles/docker/tasks/main.yml:50-54` 指向 `pitfalls/apt-update-fails-base-role-empty-error.md`)。

### 4. 文件

**新增 `docs/tools/docker-net.md`** + `mkdocs.yml` nav(放 Tools → Git & DevOps,和 `containers.md` / `container-config-map.md` 同區)。內容:

- 三層模型:mirror(只管 docker.io)/ daemon proxy(管全部,要重啟)/ client-side fetch(不用重啟)
- rootless netns 那件事 — 為什麼網路上大部分「rootless 不能用 127.0.0.1 proxy」的說法在 Docker ≥25 已經過時,以及怎麼自己驗證
- **client-side registry 工具比較表**(使用者明確要求):

  | 工具 | 安裝 | 直接寫進 daemon | 吃 `HTTPS_PROXY` | 定位 |
  |---|---|---|---|---|
  | `skopeo` | apt + brew | `docker-daemon:` ✓ | ✓ | 本 repo 選用;registry↔registry / registry↔daemon 搬運 |
  | `crane` | brew / GitHub release | 要 `\| docker load` | ✓ | 單一 Go binary,適合 CI |
  | `regctl` (regclient) | brew / GitHub release | 要 `\| docker load` | ✓ | manifest / digest 操作最細 |
  | `nerdctl` | GitHub release | 走 containerd,非 dockerd | ✓ | containerd 原生 |
  | `oras` | brew | ✗ | ✓ | OCI artifact(非 image) |
  | `podman` | apt + brew | ✗(自己的 store) | ✓ | 另一套完整 runtime |

**改**(`CLAUDE.md:34` 的硬規則:動到 `registry-mirrors` 就必須同步這四份,並寫明**安全性**理由):

- `docs/tools/containers.md` + `.zh-TW.md` — mirror 清單、新增 `docker-net` 一節、修正「restart 會殺 container」對 mirror 那半的說法、補 rootless netns 事實
- `docs/tools/mirrors.md` + `.zh-TW.md` — coverage matrix 那列、Tier-3 信任模型那段補上「縮減清單同時是信任面收斂」與實測依據
- `docs/tools/container-config-map.md` + `.zh-TW.md` — 補 `proxies` key 這列與 who-writes-what
- `docs/shells/aliases.md` + `.zh-TW.md` — `docker-net` 各動詞的列(接在 Proxy helpers `:569-581` 之後)
- `docs/this_repo/tool-managers.md` — Tool index (A–Z) 補 `skopeo` 一列(格式:`| **skopeo** | brew | apt | devtools |`)
- `README.md:213` — managed daemon.json 那條的描述

**新增 pitfalls**(照 `pitfalls/README.md:63-93` 的模板,**以症狀命名**,錯誤訊息逐字不改寫,並在 `pitfalls/README.md` 的索引表補列,保持字母序):

- `docker-pull-fails-dead-registry-mirrors.md` — 症狀:`unexpected status from HEAD request to https://...`、`failed to resolve reference "docker.io/library/..."`。含上面那張 4/5 已死的實測表與判讀方式
- `docker-proxy-set-but-docker-info-shows-empty.md` — rootful→rootless pivot 的孤兒 drop-in:檔案在、內容正確、`docker info` 的 `HttpProxy` 卻是空的

### 5. Completions(小項,可裁)

`docker-net` 是 shell 函式不是 `dot_dotfiles/bin/executable_*`,所以 `CLAUDE.md:27` 的強制規則不適用(`copilot-proxy` 也沒有)。但動詞集合固定,補兩份很便宜:`dot_config/zsh/tools/58_docker_net_completion.zsh` + `dot_config/bash/58_docker_net_completion.bash`(58 是下一個空號),並補 `docs/zsh/zsh-completions.md` § F 一列。

---

## Verification

1. **Template 兩個分支都渲染** — `chezmoi execute-template --init --promptBool useChineseMirror=true < dot_config/docker/modify_daemon.json.tmpl`,以及 `=false`;確認 else 分支仍然只 `del(.["registry-mirrors"])`,不碰 `.proxies`。
2. **`chezmoi diff ~/.config/docker/daemon.json`** 只該顯示 mirror 陣列縮短。apply 後 `jq . ~/.config/docker/daemon.json` 確認格式仍合法。
3. **驗證 SIGHUP 假設(這條決定文案怎麼寫)** — `systemctl --user reload docker` 後 `docker info --format '{{json .RegistryConfig.Mirrors}}'` 是否已反映新清單,且 `docker ps` 的 container 仍在跑。**若 reload 沒生效就改回 restart 並據實修正文件**,不要沿用未驗證的說法。
4. **`docker-net doctor` 在本機的預期輸出** — rootless / netns=host / daemon proxy 空 / mihomo TUN up / 1 個健康 mirror / 5 個 upstream 皆可達 / 2 個 stale config 警告。和本 plan 的 Context 對照,對不上就是工具有 bug。
5. **`on`/`off` 往返** — `docker-net on` → `docker info --format '{{.HttpProxy}}'` 非空 → `docker-net off` → 回到空。過程中 `docker ps` 的確認提示要出現。
6. **`pull` 的第 3 階真的會動** — 挑一個 ghcr.io 上的小 image(mirror 一定沒有),先 `docker-net off` 讓 daemon 無 proxy,再 `docker-net pull ghcr.io/...`,確認落到 skopeo 那階並成功寫進 daemon(`docker images` 看得到,tag 是正規名)。
7. **bats** — 新增 `tests/unit/docker_net.bats`,照 `tests/unit/zsh_proxy.bats` 的做法用 `setup_path_stub` + `$BATS_STUB_DIR` stub 掉 `docker`/`curl`/`nc`/`systemctl`,並用 `zsh -f -c "source ...; ..."` 避免 cache 洩漏。順手修掉 `zsh_proxy.bats:40` 那個過期註解(port 清單已改成 7 個,1087 是第五不是第三)。
8. **`uv run mkdocs build --strict`** — 新 doc 的 nav 與連結。
9. **Ansible** — `--tags devtools --check` 或最窄的實跑,確認 skopeo 任務在 macOS/Debian 兩邊都成立。
10. **`just check-all`**(lint + bats + docker smoke)。
11. **fleet 視角** — `just fleet-exec 'docker-net doctor'` 看整個機隊的 mirror/proxy 狀態,順便驗證函式在非互動 SSH 下不會卡在確認提示。

## 不做的事

- **不自動刪** `/etc/systemd/system/docker.service.d/http-proxy.conf` 與 `/etc/docker/daemon.json` — 只在 `doctor` 印出 `sudo rm` 指令。那台機器將來可能改回 rootful。
- **不加第三方 mirror**(`docker.1ms.run` 實測健康但是第三方網域,和 2026-07 因供應鏈風險移除的 `dockerproxy.com` 同一風險等級)。
- **不動** `~/.zshrc.adhoc` — 那是使用者的 untracked override 檔,repo 依約不管;`doctor` 會把 `socks://` 這個非法 scheme 報出來,改不改由使用者決定。
- **不把 `.proxies` 交給 chezmoi 管** — apply 當下烤進去的 proxy port 很快會過期。

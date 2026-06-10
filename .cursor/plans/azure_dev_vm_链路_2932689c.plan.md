---
name: Azure Dev VM 链路
overview: 实作「一条命令开出可用 dev VM」核心链路：mise runtime gating（前置瘦身）→ cloud-vm lean bundle → az-dev-vm provision/teardown 脚本（含 fleet 注册与成本护栏），GPU 仅留参数 seam。
todos:
  - id: mise-gating
    content: "Phase 1: installExtraRuntimes prompt + mise config.toml.tmpl 守卫 + TAGS 剔除 + gen/doctor"
    status: completed
  - id: cloud-vm-bundle
    content: "Phase 2: BUNDLES 新增 cloud-vm + ask_bundle 列表 + README 表格"
    status: completed
  - id: dev-vm-script
    content: "Phase 3: scripts/azure/dev_vm.py（up/down/status/ssh，含 auto-shutdown、GPU seam、fleet 注册）"
    status: completed
  - id: just-recipes
    content: "Phase 3: justfile 新增 az-dev-vm* recipes"
    status: completed
  - id: docs-backlog
    content: "Phase 4: docs/this_repo/az-dev-vm.md + TODO.md/backlog 收尾"
    status: completed
  - id: verify
    content: 验证：doctor + docker smoke + 真机 e2e 开/关一次
    status: completed
  - id: todo-1781099487334-zii2ve3eo
    content: git commit changes
    status: completed
  - id: todo-1781099505046-t9tklxzfz
    content: list how to remove the test VM
    status: completed
isProject: false
---

# Azure Dev VM Provision 核心链路

目标：`just az-dev-vm` 一条命令 → Azure VM 创建 → 等 SSH → 远程非交互 `chezmoi init --apply --bundle cloud-vm` → 自动注册进 fleet；配对 `just az-dev-vm-down` 与默认 auto-shutdown。GPU 只留 `--size`/`--gpu` seam，monitoring 以成本护栏为主。

## Phase 1 — mise runtime gating（前置，省 ~1.8GB + 修 dotnet 合同 bug）

依据 [backlog/mise-runtime-gating.md](backlog/mise-runtime-gating.md) 的「A + C」结论：

- [scripts/init/dotfiles_init.py](scripts/init/dotfiles_init.py) `PROMPTS` 新增 `installExtraRuntimes`（bool，Dev tooling 组，**default True** 保持既有机器行为），然后跑 `gen` 重新生成 `.chezmoi.toml.tmpl` prompt 块 + Dockerfile ARG，`doctor` 验证（SSOT codegen 已落地，无需手工三处同步）。
- [dot_config/mise/config.toml.tmpl](dot_config/mise/config.toml.tmpl) `[tools]` 改造（非 oldEL 分支）：
  - `node` 永远保留（nvim/agents 硬依赖）
  - `dotnet` 改为 `installDotnetTools` 守卫（修复「答 No 仍装 650MB」bug）
  - `rust`、`bun`、`ruby` 改为 `installExtraRuntimes` 守卫（ruby 同时保留现有 noRoot 条件）
- [.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl](.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl)：当 `installExtraRuntimes=false` 时从 TAGS 中剔除 `rust_cargo_tools` / `ruby_gem_tools`（否则 cargo/gem 安装会因缺 toolchain 失败）。
- 现有 `BUNDLES` 补上该 flag：`minimal` / 新 `cloud-vm` 设 False，其余 True。
- 注意：新 prompt key 会让既有 fleet 主机出现 `toml-mismatch`（fleet-status 会标出，属预期，README/文档提一句即可）。

## Phase 2 — `cloud-vm` lean bundle

- [scripts/init/dotfiles_init.py](scripts/init/dotfiles_init.py) `BUNDLES` 新增 `cloud-vm`：目标是「ergonomic shell + tmux + nvim + coding agents」——`installCodingAgents=True`、`backupMode="smart"`，其余 installX 全 False，`installExtraRuntimes=False`、`installDotnetTools=False`、`enableVimMode` 留默认。
- 在 `ask_bundle()` 的列表（约 [scripts/init/dotfiles_init.py](scripts/init/dotfiles_init.py) L650）加一行描述；`list-bundles` 自动带出。
- 更新 README.md 的 bundle 表格 + AGENTS.md 相关 cross-file 行（如有）。
- 验证：`uv run scripts/init/dotfiles_init.py doctor` 通过；`docker compose build devbox` 用 cloud-vm flag 集 smoke 一次（可选）。

## Phase 3 — `scripts/azure/dev_vm.py` + just recipes

新建 `scripts/azure/dev_vm.py`（uv PEP-723 inline script：`tyro` + `rich`，风格对齐 `scripts/fleet/`），子命令：

- `up`：
  - 前置检查：`az` 在 PATH、`az account show` 已登录，否则带提示退出
  - 幂等：固定 RG（默认 `dev-vm-rg`）+ VM 名（默认 `devbox-1`），存在即跳过创建直接走后续步骤
  - `az vm create`：Ubuntu 24.04 LTS Gen2、默认 `Standard_B2s`、`--os-disk-size-gb 32`、注入 `~/.ssh/id_ed25519.pub`（可参数化）；`--spot` 可选
  - **GPU seam**：`--gpu` flag = 换 NC 系列 size + `az vm extension set --name NvidiaGpuDriverLinux`（不做 CUDA ansible role，工具链留给项目级 conda/uv）
  - **成本护栏（默认开）**：`az vm auto-shutdown --time <UTC>`（默认如 1900 UTC，可 `--no-auto-shutdown` 关）
  - 轮询 :22 直到 SSH 可达
  - 远程 bootstrap：SSH 进去 curl 安装 chezmoi → 非交互 `chezmoi init --apply <repo>` 带全套 `--promptBool/--promptChoice` flag。flag 集**直接 import `scripts/init/dotfiles_init.py` 的 `PROMPTS`/`BUNDLES` 计算**（复用 SSOT，避免第四份手抄的 flag 列表）
  - 注册 fleet：往 `~/.config/fleet/machines.toml` 追加 `[[hosts]]`（name、hostname=公网 IP、user、identity_file、`no_root_machine=false`），已存在则更新 IP
- `down`：删 VM 及关联资源（RG 为专用时直接 `az group delete`）+ 从 machines.toml 反注册；与 `up` 严格对称
- `status`：VM 列表 + power state + 公网 IP +（若装有 azure-cost-cli 则附成本提示）
- `ssh`：便捷直连
- [justfile](justfile) 新 recipes：`az-dev-vm`（up）、`az-dev-vm-down`、`az-dev-vm-status`、`az-dev-vm-ssh`
- 确认 `scripts/**` 已在 `.chezmoiignore.tmpl`（不部署到 $HOME，与 fleet 同约定）

## Phase 4 — 文档与 backlog 收尾

- 新增 `docs/this_repo/az-dev-vm.md`（用法、幂等/teardown 语义、GPU seam 说明、成本护栏）
- `TODO.md`：把 cloud-vm bundle、provision combo、mise gating 三条移到 Done；CUDA role 条目补注「已决定走 driver extension seam，不做 role」
- 更新三份 backlog 文件的 Decision 段

## 验证

- `dotfiles_init.py doctor` + `gen --check`（如有）通过
- `docker compose --profile test up test`（既有 smoke）不回归
- 真机 e2e：`just az-dev-vm` 开一台 B2s → SSH 进去确认 zsh/tmux/nvim/claude 可用 → `fleet info --hosts <name>` 可见 → `just az-dev-vm-down` 干净删除

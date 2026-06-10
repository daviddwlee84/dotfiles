---
name: 补充 pitfall 文档分析
overview: 在 zsh-insecure-directories pitfall 文档中补充"为什么 ZSH_DISABLE_COMPFIX 修复不是 ad hoc"的分析，引用 Homebrew 官方对 multi-user 的立场。
todos:
  - id: doc-section
    content: 在 pitfall 文档新增 'Why this is NOT an ad-hoc hack' 一节
    status: pending
  - id: doc-links
    content: 补充 Homebrew Support Tiers / Homebrew-on-Linux 官方链接
    status: pending
isProject: false
---

# 补充 pitfall 文档：为什么该修复不是 ad hoc

## 目标

在 [pitfalls/zsh-insecure-directories-prompt-shared-linuxbrew.md](pitfalls/zsh-insecure-directories-prompt-shared-linuxbrew.md) 中新增一节，沉淀本次讨论的结论，防止以后回看时再怀疑 `ZSH_DISABLE_COMPFIX` 修复的正当性。

## 改动内容

在 "Fix (shipped)" 与 "Things that do NOT fix it" 之间新增一节 **"Why this is NOT an ad-hoc hack"**，要点：

- **服务器端与客户端是两个正交层面**：Homebrew 官方推荐的多用户架构（dedicated `linuxbrew` owner、prefix 755、单一 maintainer、Brewfile 审计）解决的是 install/upgrade 治理；本修复解决的是非 owner 用户的 zsh 启动问题。前者是服务器管理员的事，dotfiles 无法也不应控制。
- **关键论据：即使按官方推荐架构部署，compaudit 依然失败**。compaudit 要求目录 owner 是 root 或当前用户；`linuxbrew:linuxbrew 755` 对其他用户来说仍是"另一个非 root 用户"，必然不通过。因此每个非 owner 用户都需要 `compinit -u`（即 `ZSH_DISABLE_COMPFIX=true`）作为标准配套。
- **官方立场**：Homebrew Support Tiers 明确把 "multiple users share the same installation" 列为 unsupported（https://docs.brew.sh/Support-Tiers）；`/home/linuxbrew/.linuxbrew` 是官方固定 Linux prefix（https://docs.brew.sh/Homebrew-on-Linux），路径写死是合理的。
- **推荐架构反而扩大触发面**：官方/常见做法是在 `/etc/profile.d/linuxbrew.sh` 全局 `eval brew shellenv`（含 `export FPATH`），这会让所有 login shell 都带上 brew 的 site-functions——当前"仅 nested shell 触发"会变成"所有 shell 触发"，客户端修复更加必要。
- **已考虑过的更精确替代**：compinit 前从 fpath 剔除非 owner 的 brew 目录可保留完整 audit，但会丢失所有 brew 包的补全（rg、fd、gh 等），在"同团队安装的共享 prefix 可信"前提下得不偿失。

同时更新文档头部 **Status** 行或 "Related" 一节，加上 Support Tiers / Homebrew-on-Linux 两个官方链接。

## 不改动

- `dot_zshrc.tmpl`、`dot_zshenv.tmpl` 代码维持原样。
- `pitfalls/README.md` 索引行已存在且状态为 fixed，无需变更（除非措辞需要微调）。

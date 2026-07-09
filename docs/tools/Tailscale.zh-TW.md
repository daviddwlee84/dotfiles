# Tailscale

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

- [Download | Tailscale](https://tailscale.com/download/mac)
  - [tailscale-app — Homebrew Formulae](https://formulae.brew.sh/cask/tailscale-app) - 桌面應用程式（獨立版 Standalone）
    - [Tailscale Packages - stable track](https://pkgs.tailscale.com/stable/#macos)
  - [tailscale — Homebrew Formulae](https://formulae.brew.sh/formula/tailscale) - CLI
  - [Tailscale App - App Store](https://apps.apple.com/ca/app/tailscale/id1475387142)

> 獨立版 (Standalone) > App Store

## 本 repo 如何安裝 (macOS)

- **GUI app + daemon** → `cask "tailscale-app"`（[`Brewfile.darwin`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/homebrew/Brewfile.darwin.tmpl)）——即 **macsys 獨立版 (standalone)** build（`io.tailscale.ipn.macsys`），其 **system extension** 就是 daemon。先前用 `mas "Tailscale"`，但 Tailscale 已從 Mac App Store 下架（`mas` 安裝會失敗），改用 cask 是官方支援路徑。
- **CLI(PATH)** → **一樣來自 cask**，不需要另裝 formula:cask 的 pkg 會安裝 `/usr/local/bin/tailscale`,那是一個指向 app bundle 的 shell wrapper(`exec /Applications/Tailscale.app/Contents/MacOS/tailscale "$@"`)。**不要**再裝獨立的 `brew "tailscale"` formula——它多餘,且每次升級都會跟 cask 搶同一個路徑(ollama 式的 link 衝突),還會裝一個 app 的 system extension 已經在跑的 `tailscaled`。
- macOS 上**絕不要** `brew services start tailscale`:app 的 system extension 已經是 daemon,再起一個 `tailscaled` 會衝突。

### 「Another Tailscale copy was found on this Mac」

若 debug 面板回報 `/Applications/Tailscale.localized/Tailscale.app` 的衝突(常伴隨 `DNS Unavailable` / `dns-forward-failing`),那是 `mas → cask` 遷移**遺留的舊 App Store build**(`chezmoi apply` 只裝不移除)。修法:

```bash
sudo rm -rf /Applications/Tailscale.localized   # 只刪閒置的 App Store 那份
```

完整偵測 + 根因: [`pitfalls/tailscale-another-copy-app-store-leftover.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/tailscale-another-copy-app-store-leftover.md)。

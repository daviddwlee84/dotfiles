# Specify CLI (Spec Kit)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

`specify-cli` 是 GitHub Spec Kit 的 CLI，用於規格驅動 (spec-driven) 開發流程。

## 在本 dotfiles 倉庫中的安裝方式

`specify-cli` 由 `coding_agents` ansible 角色透過 `uv` 自動安裝。

角色使用的安裝指令：

```bash
uv tool install specify-cli --from git+https://github.com/github/spec-kit.git
```

## 手動安裝 / 升級

```bash
# 安裝
uv tool install specify-cli --from git+https://github.com/github/spec-kit.git

# 升級
uv tool install specify-cli --force --from git+https://github.com/github/spec-kit.git
```

## 驗證與快速開始

```bash
specify check
specify init . --ai claude
```

## 參考資料

- [Spec Kit repository](https://github.com/github/spec-kit)
- [Spec Kit documentation](https://github.github.io/spec-kit/)

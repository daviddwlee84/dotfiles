# tsum: 用 prompt-hash 取代 TTL 作為快取 key

## Context

目前 `tsum` 的快取機制有兩個缺點：

1. **粗粒度失效**：cache key 只 hash 了 session 結構（name / window 數 / `index:cmd` 對），所以當你還在跑同一組 session、但 pane 內容已經完全變了（例如測試從跑中變成跑完、deploy 從進行中變成失敗），快取仍然命中、回傳過期摘要 — 必須等 `TSUM_CACHE_TTL`（預設 600s）過期或手動 `--refresh`。
2. **過度失效**：反過來，如果你 10 分鐘沒動電腦、什麼都沒變，再次跑 `tsum` 還是要花一次 LLM call，因為 TTL 到了。

`build_prompt()` 的輸出已經完整描述了 LLM 的輸入（PREAMBLE + sessions + 可選的 pane tail），所以 **hash(prompt) 才是真正的「LLM 輸入是否變動」的指標**。Prompt 一樣 → 結果就一樣 → 直接回傳。

但在 deep 模式下，pane tail 包含 `htop` / `watch` / 進度條 / 時鐘這類高頻變動內容，純 hash-based 會讓快取永遠 miss、token 用量飆升。所以加一個**反向 TTL：min-refresh interval** — hash 不同時也不立刻打 LLM，除非距離上次刷新已超過 N 秒。

## Recommended Approach

把 cache key 從「session 結構 hash」改成「`build_prompt()` 輸出的 hash」；TTL 語意從「過期即丟」翻轉成「太頻繁就壓住」。

### 修改的檔案

**主檔案**：`dot_config/tmux/executable_tmux-session-summary.py`

**user-facing 註解 / help text**：`dot_config/shell/61_tmux_summary.sh`（HELP heredoc 第 56、68、75–76 行提到 cache TTL 與路徑語意，要同步更新）

### 具體變更（`executable_tmux-session-summary.py`）

#### 1. 重新命名 / 重新定義環境變數（line 151）

```python
# 舊
TSUM_CACHE_TTL = int(os.environ.get("TSUM_CACHE_TTL", "600"))

# 新
# 距離上次 LLM call 在此秒數內，即使 prompt hash 不同也直接回傳舊摘要
# （防 deep 模式下 htop/watch/進度條的高頻變動把 token 燒光）。
# 設為 0 = 完全 hash-based、不節流。
TSUM_MIN_REFRESH_INTERVAL = int(
    os.environ.get("TSUM_MIN_REFRESH_INTERVAL")
    or os.environ.get("TSUM_CACHE_TTL", "120")  # 接受舊名作為向後相容；預設改成 120s
)
```

預設值降到 120s（2 分鐘）— 比現有 600s 積極很多，因為 hash 命中時可以「無限期」沿用舊快取；只有 hash 不同時才會被這個門檻擋住。

#### 2. Bump cache schema 版本（line 386）

```python
_CACHE_VERSION = "v3"  # v2→v3: sig 改名為 prompt_hash, ttl_seconds 拿掉
```

舊 v2 cache 檔自動失效（沿用 line 397–398 現有機制）。

#### 3. 改寫 `load_cache` → `lookup_cache`（line 389–405）

回傳「summaries + 為什麼命中」的二元組，讓上層可以區分 *hash hit* vs *throttled*：

```python
def lookup_cache(prompt_hash: str, deep: bool) -> tuple[list[dict] | None, str]:
    """Returns (summaries, reason). reason ∈ {"hit", "throttled", "miss"}.

    - "hit":       cached prompt_hash == current prompt_hash → 一定可重用
    - "throttled": hash 不同但距上次刷新 < TSUM_MIN_REFRESH_INTERVAL → 沿用舊
    - "miss":      hash 不同且超過 min-refresh window → 需要重打 LLM
    """
    p = cache_path(deep)
    if not p.is_file():
        return None, "miss"
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None, "miss"
    if data.get("version") != _CACHE_VERSION:
        return None, "miss"
    summaries = data.get("sessions")
    if not isinstance(summaries, list):
        return None, "miss"

    if data.get("prompt_hash") == prompt_hash:
        return summaries, "hit"

    age = time.time() - float(data.get("generated_at_epoch", 0))
    if age < TSUM_MIN_REFRESH_INTERVAL:
        return summaries, "throttled"

    return None, "miss"
```

#### 4. 改寫 `save_cache`（line 408–425）

把 `sig` 改名為 `prompt_hash`、拿掉 `ttl_seconds`（在 hash-based 模型下沒語意）：

```python
def save_cache(prompt_hash: str, summaries: list[dict], deep: bool) -> None:
    p = cache_path(deep)
    try:
        p.write_text(
            json.dumps(
                {
                    "version": _CACHE_VERSION,
                    "prompt_hash": prompt_hash,
                    "generated_at_epoch": time.time(),
                    "sessions": summaries,
                },
                indent=2,
            ),
            encoding="utf-8",
        )
    except OSError as e:
        err.print(f"[yellow]tmux-session-summary: cache write failed: {e}[/yellow]")
```

#### 5. 移除 `session_signature`（line 354–367）

不再需要 — prompt 本身就是更好的 key。`deep` 已經被 `build_prompt(deep=...)` 內化進 prompt 文字，所以也不必另外加進 hash。連帶 cache_path 的 `<host>-<mode>.json` 拆分仍保留（避免 deep/shallow 兩種模式互相覆蓋彼此的最新快取）。

#### 6. 重排主流程（line 829–859）

把 prompt build 提前到 `--dry-run` 分支之前，並讓快取查詢以它的 hash 為 key：

```python
prompt = build_prompt(sessions, deep=args.deep)
prompt_hash = hashlib.sha256(prompt.encode("utf-8")).hexdigest()[:16]

if args.dry_run:
    print(prompt)
    return 0

cached: list[dict] | None = None
cache_reason = "skipped"
if not args.refresh and not args.no_cache:
    cached, cache_reason = lookup_cache(prompt_hash, args.deep)

if cached is not None:
    summaries = cached
    # 可選：在 stderr 印 cache_reason（"hit" / "throttled"）讓 user 知道
    # 為什麼這次沒打 LLM；用 [dim] 樣式避免干擾 picker 模式
else:
    agent = detect_agent()
    if agent is None:
        # ...（不動）
    # build_prompt 不必再呼叫一次，直接用上面算好的 prompt
    with err.status(f"[dim]{agent} ({model_for(agent)}) thinking…[/dim]", spinner="dots"):
        reply = invoke_agent(agent, prompt, TSUM_TIMEOUT)
    summaries = parse_reply(reply) or []
    if not summaries:
        # ...（不動）
    if not args.no_cache:
        save_cache(prompt_hash, summaries, args.deep)
```

### `--dry-run` 角色

維持現有語意：「印 prompt，不打 LLM、不讀寫快取」。但實作上 prompt 不再只在 dry-run 路徑算 — 主路徑也需要它來算 hash，所以提前到分支前共用。

### Help text / 文件同步（`61_tmux_summary.sh`）

- Line 56 `tsum -r | --refresh   bypass the 10-min cache` → 改成 `bypass the prompt-hash cache and force a fresh LLM call`
- Line 68 `TSUM_CACHE_TTL  seconds, default 600` → 改成：
  ```
  TSUM_MIN_REFRESH_INTERVAL   seconds, default 120. Even when the prompt
                              hash differs from the cached one, reuse the
                              old summary if the previous LLM call was
                              within this window (protects against high-
                              volatility deep-mode panes like htop/watch).
                              Set to 0 to disable throttling. Old
                              TSUM_CACHE_TTL is accepted as fallback.
  ```
- Line 75–76 CACHE section：可加一句說明 key 是 prompt 內容的 SHA256 前綴

### 復用的既有 helper

- `build_prompt()` (line 487–511) — 直接拿 output 當 hash 輸入
- `cache_path()` (line 370–380) — 仍是 `<host>-<mode>.json`，不需動
- `hashlib.sha256(...).hexdigest()[:16]` 風格已在原 `session_signature` 用過

### 不動的部分

- CLI flag 全部不變：`--refresh` / `--no-cache` / `--dry-run` / `--deep` / `--shallow` 語意都維持
- Picker / list / fallback render 路徑全部不動
- Per-host、deep/shallow 兩檔的拆分維持

## Verification

1. **單元行為**：
   ```bash
   # 第一次跑 → cache miss → 打 LLM
   tsum -d

   # 立刻再跑 → prompt 應該一樣 → hash hit → 沒打 LLM
   tsum -d   # 觀察是否仍出現 "thinking…" spinner，不該出現

   # 看 cache 內容是否含 prompt_hash 欄位、不含 ttl_seconds
   cat ~/.cache/tmux-session-summary/$(hostname -s)-deep.json | jq .
   ```

2. **Hash 變動觸發 refresh**：
   ```bash
   tsum -d
   # 開一個新 tmux window 或在 active pane 多輸出幾行
   tsum -d   # 應該重新打 LLM（hash 改變、且超過 min-refresh window 或設 TSUM_MIN_REFRESH_INTERVAL=0）
   ```

3. **Min-refresh 節流**：
   ```bash
   TSUM_MIN_REFRESH_INTERVAL=60 tsum -d
   # 在 active pane echo 一行新內容
   TSUM_MIN_REFRESH_INTERVAL=60 tsum -d   # hash 變了但 <60s → 應該回傳 "throttled" 的舊摘要
   ```

4. **舊 v2 cache 自動失效**：手動把 `~/.cache/tmux-session-summary/*.json` 改成 `"version": "v2"`，再跑 `tsum` — 應走 miss 路徑、重新寫成 v3。

5. **`--dry-run` 不寫 cache**：
   ```bash
   rm ~/.cache/tmux-session-summary/*.json
   tsum --dry-run -d > /tmp/p.txt
   ls ~/.cache/tmux-session-summary/   # 應為空
   ```

6. **`TSUM_CACHE_TTL` 向後相容**：`unset TSUM_MIN_REFRESH_INTERVAL; TSUM_CACHE_TTL=30 tsum -d` 應該套用 30s 節流。

7. **回歸**：跑 `tsum -i` (picker) / `tsum --sort closability` / `tsum --only safe` 確認 view 層不受影響。

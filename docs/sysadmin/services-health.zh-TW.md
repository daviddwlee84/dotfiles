# Service health

對應現有 `tv services` channel（productivity 取向）的健康取向 channel。
凸顯：

- **Failed unit** (`systemctl --failed`)
- **Restart loop unit** (`NRestarts > 3`)
- **近期 OOM kill** (`journalctl -k | grep -iE 'out of memory|oom-killer'`)
- **近期 error 級 crash** (`journalctl -p err`)

完整對照表見
[helpers.md → tv services-health](helpers.md#television-channels)。把這些
信號包成一行 verdict 的早晨摘要命令見 `health-check`，於
[helpers.md → 即時監控 + 早晨摘要](helpers.md#即時監控--早晨摘要)。

## 快速用法

```bash
# 互動
tv services-health

# CLI verdict（一行）
health-check --quick

# 完整 dump
health-check --full
```

`tv services-health` 鍵位：

- `Enter` — `lnav` 開完整 unit log
- `Alt+R` — 重啟 unit（確認）
- `Alt+S` — 停止 unit（確認）
- `Alt+E` — `systemctl edit --full <unit>`

## 為什麼跟 `tv services` 分開？

`tv services`（在 [`dot_config/television/cable/services.toml.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/television/cable/services.toml.tmpl)）
列所有東西支援 productivity workflow（「哪個 app 的 daemon 要重啟？」）。
`tv services-health` 過濾到真有問題的子集 — failed、restart-loop、
OOM-kill — 支援早晨健康檢查不用滑過 200 個健康 service。

兩個 channel 並存；按你問的問題選對的。

## macOS 注意

- launchd 的「errored」偵測用 `launchctl list` 輸出的
  `Status != 0 AND Status != "-"`。這抓得到非零退出，但抓不到本該跑但
  乾淨 `bootout` 掉的 service。
- macOS 上的 `Alt+R` 用 `launchctl kickstart -k user/<uid>/<label>` 而非
  restart，因為 launchd 沒有單步 "restart" 動詞。

## 另見

- [auditd 框架](auditd.md) — security 相關的 service crash (sshd、sudo、
  audit 本身) 也值得有 audit 規則
- [排程任務](scheduled-jobs.md) — restart loop 常因 unit 設了
  `Restart=always` 但本來就起不來
- [Cookbook recipe 12](cookbook.md#12-網路曝險--persistence每週掃一次)

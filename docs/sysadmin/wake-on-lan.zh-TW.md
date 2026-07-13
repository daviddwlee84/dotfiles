# Wake-on-LAN（遠端開機）

實體主機的 sysadmin 提問：**能不能從網路把這台開機**，而不用走過去按電源鍵？

本頁說明 `wake` CLI + `wakeonlan`（**主動 / 發送端**）與 `wake_on_lan` ansible
role（chezmoi prompt `installWakeOnLan`，**被動 / 接收端**）。它是
[random-hard-poweroff.md](../playbooks/random-hard-poweroff.md) 的另一面 —— 那頁講
「這台為什麼自己關機」，本頁講「把它重新開起來」。

> **只支援有線乙太網路。** WoL over Wi-Fi 需要 WoWLAN + AP 配合，不在範圍內。
> 接收端**僅限 Linux**；發送端到處都能跑（`wake` CLI 是純 stdlib Python，macOS
> 也能用）。

## 原理（30 秒）

- **Magic packet** = `6×0xFF` 接上目標 MAC 重複 16 次，以 UDP **broadcast** 送到
  port 9。
- 目標網卡靠**待機電**保持運作，逐一檢查每個 frame，比對到就把主機板從睡眠
  (S3) 或關機 (S5) 拉起來。
- **兩件事必須同時成立**，而且會各自獨立失敗：
  1. 網卡在 OS 端被 **arm** —— `ethtool -s <if> wol g`（單獨設定**不會**在重開機後
     保留 → 我們裝一個 systemd unit）；
  2. **韌體**在關機後仍供待機電給網卡並承認喚醒 —— 這是 BIOS 設定，OS 無法代勞。

## 主動端 —— 發送封包（任何機器）

自製的 **`wake`** CLI 會把主機名稱解析成 MAC 再廣播：

```bash
wake david-ubuntu          # 從 ~/.config/wake/hosts.toml 查 MAC 後送出
wake de:ad:be:ef:12:34     # 直接給 raw MAC，不需設定檔也行
wake --list                # 列出已設定的主機
wake host -b 10.0.0.255    # 覆寫 broadcast 位址
wake host -c 5             # 送 5 個封包（預設 3）
```

主機清單放在 `~/.config/wake/hosts.toml`（chezmoi 只 seed 一次、mode 0600；真實
MAC 留在這個**私人**檔案，不進 repo）：

```toml
[hosts.david-ubuntu]
mac       = "de:ad:be:ef:12:34"   # 目標網卡 MAC（`ip link` / `ethtool -P eno1`）
broadcast = "192.168.31.255"      # 選填；你 LAN 的 directed broadcast
# port    = 9                     # 選填（預設 9）
```

`wake` 一律同時送 `255.255.255.255` **與**該主機的 directed broadcast（有些網路
會擋掉其中一個）。它是純 stdlib —— 不依賴 `wakeonlan` binary —— 所以在全新的機器
上也能用。上游的 **`wakeonlan`**（由 `networking_tools` 安裝）是等價的原始工具：

```bash
wakeonlan de:ad:be:ef:12:34
wakeonlan -i 192.168.31.255 de:ad:be:ef:12:34   # directed broadcast
```

## 被動端 —— 讓一台機器可被喚醒（Linux）

打開 chezmoi prompt **`installWakeOnLan`**（或用 `server-linux` bundle）。
`wake_on_lan` role 會在 `chezmoi apply` 時：

1. 安裝 **ethtool**；
2. 放一個 templated 的 **`wol@.service`** systemd unit；
3. 自動偵測每張支援 magic packet 的有線網卡，並為它 **enable
   `wol@<iface>.service`** —— 讓 `ethtool -s <if> wol g` 在每次開機重新套用
   （否則重開機就失效）。

在一次性的機器上手動做：

```bash
sudo apt install -y ethtool
sudo tee /etc/systemd/system/wol@.service >/dev/null <<'UNIT'
[Unit]
Description=Enable Wake-on-LAN (magic packet) on %i
Requires=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ethtool -s %i wol g
[Install]
WantedBy=sys-subsystem-net-devices-%i.device
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now wol@eno1.service   # 你的有線網卡
```

**確認網卡已 arm**（這是最有用的一個檢查）：

```bash
sudo ethtool eno1 | grep -i wake-on
#   Supports Wake-on: pumbg     ← 必須含 'g'（magic packet）
#   Wake-on: g                  ← 必須是 'g'，不是 'd'（disabled）
```

若 `Supports Wake-on` 裡沒有 `g`，代表這張網卡/驅動不支援 magic-packet WoL，怎麼
設都沒用。

## BIOS / 韌體 —— 從「關機」喚醒必需 (S5)

從**完全關機**喚醒，需要主機板在關機後仍供網卡待機電。進 BIOS（以 ASUS 為例，
各廠命名不同）：

| 設定 | 值 | 為什麼 |
|---|---|---|
| **Power On By PCI-E / PCI** | **Enabled** | 讓網卡的 PME 訊號能把主機板開機 |
| **ErP Ready** / **EuP** | **Disabled** | ErP 會在 S4/S5 切掉網卡待機電 —— 「suspend 能喚醒、關機喚不醒」的頭號元兇 |
| **Deep Sleep** / **Deep S5** | **Disabled** | 同一件事、另一個名字 |

更新 BIOS 會把這些重置 —— 刷完要重設一次。韌體無法由 Ansible 設定，所以這份清單
維持手動。

## 睡眠 (S3) vs 完全關機 (S5)

測試時把變數隔離：**S3（suspend）只要 OS 端 arm 好就能喚醒**（不用改 BIOS），因為
網卡從沒失去待機電。**S5（完全關機）額外需要上面的 BIOS 設定。** 所以：

```bash
# 先證明 OS/網卡/封包這條路通，不用動 BIOS：
ssh box 'sudo systemctl suspend'   # 然後從另一台：  wake box
# 再把 BIOS 清單設好，測真正的目標：
ssh box 'sudo poweroff'            # 然後：  wake box
```

冷開機喚醒後約 30–70 秒才會回應 ping（POST + 開機），屬正常。

## 疑難排解

| 症狀 | 可能原因 | 修法 |
|---|---|---|
| 重開機後 `Wake-on: d` | arming 沒保留 | enable `wol@<iface>.service`（或用 role） |
| `Supports Wake-on` 沒有 `g` | 網卡/驅動不支援 magic packet | 換網卡，或檢查驅動 |
| **suspend** 能喚醒、**關機**喚不醒 | BIOS ErP Ready 開著 | 關掉 ErP / Deep Sleep |
| 完全喚不醒 | 走 Wi-Fi（非有線）、防火牆擋 broadcast、或不在同一個 L2 | 用有線網卡；送到該子網的 directed broadcast；在同一 LAN |
| 喚醒後立刻又關機 | 那不是 WoL 的問題 —— 見 [random-hard-poweroff.md](../playbooks/random-hard-poweroff.md) | 跑 `crash-blackbox` |

## 檔案

- 發送端：[`dot_dotfiles/bin/executable_wake`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_dotfiles/bin/executable_wake) · 設定 `~/.config/wake/hosts.toml`（範本 `dot_config/wake/create_private_hosts.toml`）
- 接收端：`dot_ansible/roles/wake_on_lan/`（prompt `installWakeOnLan`）→ `/etc/systemd/system/wol@.service`
- 套件：`wakeonlan`（`networking_tools`）；`ethtool`（`wake_on_lan`）
- 姊妹頁：[隨機硬關機](../playbooks/random-hard-poweroff.md) · [`crash-blackbox`](../tools/crash-blackbox.md)

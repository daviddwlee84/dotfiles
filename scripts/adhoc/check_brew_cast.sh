#!/usr/bin/env bash
set -euo pipefail

APPS=$(
  cat <<'EOF'
东方财富.app
同花顺.app
AeroSpace.app
Alacritty.app
AltTab.app
Anki.app
Applite.app
Arc.app
BaiduNetdisk_mac.app
Battle.net.app
Binance.app
ChatGPT Atlas.app
ChatGPT.app
Clash for Windows.app
Claude.app
Cursor.app
DBeaver.app
Dereference.app
DingTalk.app
Discord.app
Docker.app
FileZilla.app
Frpc-Desktop.app
Google Chrome.app
Google Docs.app
Google Drive.app
Google Sheets.app
Google Slides.app
Grammarly Desktop.app
HSTracker.app
Ice.app
Immersive Translate.app
iTerm.app
Itsycal.app
Keynote.app
LINE.app
Magnet.app
Mathpix Snipping Tool.app
Messenger.app
Minecraft.app
NetSonar.app
Numbers.app
Obsidian.app
Ollama.app
OpenVPN Connect
OpenVPN Connect.app
osu!.app
Pages.app
Perplexity.app
Portsly.app
Raycast.app
Readest.app
res-downloader.app
rishiqing.app
Safari.app
Scroll Reverser.app
ShareMouse.app
Sloth.app
Spotify.app
Steam.app
Super Productivity.app
Superset.app
Tailscale.app
TeamViewerHost.app
TeX
Telegram.app
TencentMeeting.app
Termius.app
The Unarchiver.app
Tor Browser.app
TradingView.app
Utilities
VibeTunnel.app
VirtualBox.app
Visual Studio Code.app
Warp.app
WeChat.app
WhatsApp.app
Windows App.app
Wine Staging.app
Wispr Flow.app
YuantaCGCryptServiSign.app
EOF
)

# 一些常見「名稱 != token」的手動對照（你也可自行加）
declare -A OVERRIDE=(
  ["iTerm"]="iterm2"
  ["AltTab"]="alt-tab"
  ["Visual Studio Code"]="visual-studio-code"
  ["Google Chrome"]="google-chrome"
  ["The Unarchiver"]="the-unarchiver"
  ["Tor Browser"]="tor-browser"
  ["Mathpix Snipping Tool"]="mathpix-snipping-tool"
  ["DBeaver"]="dbeaver-community"
  ["Battle.net"]="battle-net"
  ["OpenVPN Connect"]="openvpn-connect"
  ["TeamViewerHost"]="teamviewer-host"
)

norm_token() {
  local s="$1"
  s="${s%.app}"
  s="${s//_/ }"
  s="$(echo "$s" | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^ //; s/ $//')"
  if [[ -n "${OVERRIDE[$s]+x}" ]]; then
    echo "${OVERRIDE[$s]}"
    return
  fi
  # 轉成一般 token：小寫，空白 -> -
  echo "$s" | tr '[:upper:]' '[:lower:]' | tr ' ' '-'
}

echo "== Checking casks via brew info --cask =="
echo "$APPS" | while IFS= read -r app; do
  [[ -z "$app" ]] && continue
  # 跳過不是 app 的資料夾/分類
  if [[ "$app" == "Utilities" || "$app" == "TeX" ]]; then
    continue
  fi
  base="${app%.app}"
  token="$(norm_token "$base")"

  if brew info --cask "$token" >/dev/null 2>&1; then
    printf "✅ %-30s -> %s\n" "$app" "$token"
  else
    printf "❌ %-30s (no exact cask: %s)\n" "$app" "$token"
  fi
done

echo
echo "== Fuzzy suggestions (brew search --cask) =="
echo "$APPS" | while IFS= read -r app; do
  [[ -z "$app" ]] && continue
  if [[ "$app" == "Utilities" || "$app" == "TeX" ]]; then
    continue
  fi
  base="${app%.app}"
  # 取一個比較短的 keyword（去掉空白）
  key="$(echo "$base" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  hits="$(brew search --cask "$key" 2>/dev/null | head -n 5 || true)"
  if [[ -n "$hits" ]]; then
    echo "🔎 $app"
    echo "$hits" | sed 's/^/    - /'
  fi
done
